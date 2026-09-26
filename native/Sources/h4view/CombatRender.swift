import Foundation
import Metal
import H4Engine

extension Renderer {
    /// The sprite of a combat actor's state for a facing, loaded on demand.
    func combatSprite(_ cs: CombatScreen, actor: String, state: String, facing: String) -> (Sprite, String)? {
        guard let a = cs.actor(actor), let r = resolver else { return nil }
        var entry = a.sequenceEntry(state: state, facing: facing)
        if entry == nil || r.entry(entry!) == nil {   // fall back to the standing frame
            entry = a.sequenceEntry(state: "base_frame", facing: facing) ?? a.sequenceEntry(state: "fidget", facing: facing)
        }
        guard let e = entry, let real = r.entry(e) else { return nil }
        if actorSprites[real] == nil { actorSprites[real] = try? Sprite(data: r.archive.payload(real)) }
        guard let s = actorSprites[real] else { return nil }
        return (s, real)
    }

    /// Quads of the combat screen.
    func combatQuads(now: Date) -> [Quad] {
        guard let cs = combat, let b = cs.battle, let ui = ui, let f = cs.field else { return [] }
        var out: [Quad] = []
        let sc = CombatScreen.sceneScale
        // the ground: a ship's backdrop, or the terrain's tiles diamond by diamond with
        // alternate diamonds a shade darker (the original's chequered field)
        if let bd = f.backdrop {
            out.append(Quad(texture: uiTexture("battlefield|\(cs.fieldName)", { bd.bitmap }), x: 0, y: 0, w: Int(Float(bd.width) * sc), h: Int(Float(bd.height) * sc)))
        } else if let patch = cs.groundPatch(terrain: f.terrain, variant: f.variant, alt: 1) {
            // the terrain's 64x32 tiles, each covering 2x2 combat cells, continuous as on the map
            let n = Battlefield.size / 2 + 1
            for ax in 0..<n { for ay in 0..<n {
                let (px, py) = CombatScreen.point(Float(2 * ax + 1), Float(2 * ay + 1))
                if px < -40 || py < -30 || px > 925 || py > 800 { continue }
                let row = ax + ay, colI = (ay - ax - (((ax + ay) % 2) + 2) % 2) / 2
                let ti = ((((row % 6) + 6) % 6) + 2) * 10 + ((((colI % 6) + 6) % 6) + 2)
                let tex = uiTexture("ground|\(f.terrain)|\(f.variant)|\(ti)", { patch.tiles[min(ti, patch.tiles.count - 1)] })
                out.append(Quad(texture: tex, x: Int(px - 32 * sc), y: Int(py - 16 * sc), w: Int(64 * sc) + 1, h: Int(32 * sc) + 1))
            } }
            // the checker: table.combat_grid_colors tints odd and even cells per terrain
            let key = CombatScreen.terrainKeys[f.terrain] ?? "grass"
            let tint = cs.gridColors?.byTerrain[key] ?? GridColors.Entry(alpha: 4, odd: nil, even: (12, 36, 12))
            let alpha = UInt8(min(255, tint.alpha * 16))
            for x in 0..<Battlefield.size { for y in 0..<Battlefield.size where Battlefield.onField(x, y) {
                guard let c = (x + y) % 2 == 1 ? tint.odd : tint.even else { continue }
                let (px, py) = CombatScreen.point(Float(x) + 0.5, Float(y) + 0.5)
                out.append(Quad(texture: cellDiamond("grid|\(c.0)|\(c.1)|\(c.2)|\(alpha)", c.0, c.1, c.2, alpha), x: Int(px - 16 * sc), y: Int(py - 8 * sc), w: Int(32 * sc), h: Int(16 * sc)))
            } }
        }
        // the acting unit's reach as the game's purple-grey cells (the "movement shadow" option):
        // every cell its footprint can cover
        if showReach, let cur = b.current, cur.side == 0, !cs.busy, cs.result == nil {
            var cells = Set<Int>()
            for (k, _) in b.reachable(cur) {
                let x = k / Battlefield.size, y = k % Battlefield.size
                for i in 0..<cur.size { for j in 0..<cur.size { cells.insert((x + i) * Battlefield.size + y + j) } }
            }
            for k in cells {
                let x = k / Battlefield.size, y = k % Battlefield.size
                let (px, py) = CombatScreen.point(Float(x) + 0.5, Float(y) + 0.5)
                out.append(Quad(texture: cellDiamond("reach", 120, 110, 170, 120), x: Int(px - 16 * sc), y: Int(py - 8 * sc), w: Int(32 * sc), h: Int(16 * sc)))
            }
        }
        // obstacles and units, back to front
        var drawn: [(Float, [Quad])] = []
        for o in f.obstacles {
            guard let s = cs.obstacleSprite(o.name), let fr = s.frames.first else { continue }
            // the sprite's origin is the footprint's top vertex, as for adventure objects
            let (px, py) = CombatScreen.point(Float(o.x), Float(o.y))
            var q: [Quad] = []
            if let sh = s.shadow(for: fr) { q.append(Quad(texture: texture(for: sh, of: o.name), x: Int(px + Float(s.origin.x + Int32(sh.box.left)) * sc), y: Int(py + Float(s.origin.y + Int32(sh.box.top)) * sc), w: Int(Float(sh.bitmap.width) * sc), h: Int(Float(sh.bitmap.height) * sc))) }
            q.append(Quad(texture: texture(for: fr, of: o.name), x: Int(px + Float(s.origin.x + Int32(fr.box.left)) * sc), y: Int(py + Float(s.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            drawn.append((py - 1, q))
        }
        // every unit, the dead too: a dead stack stays on the field as the last frame of its
        // die sequence (the combat actor has no other corpse state), under the living
        for u in b.units {
            let pos = cs.unitPos[u.id] ?? cs.shownPos[u.id] ?? (Float(u.x), Float(u.y))
            let shownAlive = cs.shownAlive(u)
            // the actor's origin is the footprint's centre
            let (px, py) = CombatScreen.point(pos.0 + Float(u.size) / 2, pos.1 + Float(u.size) / 2)
            var q: [Quad] = []
            // the ground marks, sized to the footprint (combat_object.<active|target>_shadow.<2...7>):
            // the acting unit's, and the red one under the creature the pointer would strike
            let shadowSize = min(7, max(2, u.size))
            // these sprites are anchored at the footprint's top corner (target_shadow.3: origin -51,-8,
            // image x -32...33, y 7...41 -- centred on a 3-cell diamond hanging from its top vertex)
            let (tx, ty) = CombatScreen.point(pos.0, pos.1)
            let targeted = combatTarget == u.id && cs.shownAlive(u)
            if targeted, let ring = arrowSprite("target_shadow.\(shadowSize)", prefix: "combat_object"), let fr = ring.frames.first {
                q.append(Quad(texture: texture(for: fr, of: "target_shadow.\(shadowSize)"), x: Int(tx + Float(ring.origin.x + Int32(fr.box.left)) * sc), y: Int(ty + Float(ring.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            }
            if b.current?.id == u.id, cs.result == nil, let ring = arrowSprite("active_shadow.\(shadowSize)", prefix: "combat_object"), let fr = ring.frames.first {
                q.append(Quad(texture: texture(for: fr, of: "active_shadow.\(shadowSize)"), x: Int(tx + Float(ring.origin.x + Int32(fr.box.left)) * sc), y: Int(ty + Float(ring.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            }
            let st = cs.unitState[u.id]
            let state = st?.state ?? (shownAlive ? "wait" : "die")
            if let (s, entry) = combatSprite(cs, actor: u.actor, state: state, facing: u.facing) {
                let tl = s.timeline
                var frame = s.frames.first, shadow = frame.flatMap { s.shadow(for: $0) }
                if !tl.isEmpty {
                    let period = cs.framePeriod(u.actor, state)
                    var index: Int
                    if let st = st, st.once {
                        index = min(tl.count - 1, Int(now.timeIntervalSince(st.since) / period))
                        if index == tl.count - 1, now.timeIntervalSince(st.since) >= Double(tl.count) * period, state == "flinch" || state == "block" || state == "fidget" { cs.idleDone(u.id, now: now) }
                    } else if state == "walk" {   // loops at its own speed (one loop covers the actor's walk distance)
                        index = Int(now.timeIntervalSince(st?.since ?? now) / period) % tl.count
                    } else {
                        index = Int((now.timeIntervalSince1970 + Double(u.id) * 0.37) / period) % tl.count
                    }
                    let e = tl[index]; frame = e.frame; shadow = e.shadow
                }
                if !shownAlive, cs.dead.contains(u.id) || st == nil, let last = tl.last { frame = last.frame; shadow = last.shadow }
                let ox = px + Float(s.origin.x) * sc, oy = py + Float(s.origin.y) * sc
                if let sh = shadow { q.append(Quad(texture: texture(for: sh, of: entry), x: Int(ox + Float(sh.box.left) * sc), y: Int(oy + Float(sh.box.top) * sc), w: Int(Float(sh.bitmap.width) * sc), h: Int(Float(sh.bitmap.height) * sc))) }
                if let fr = frame { q.append(Quad(texture: texture(for: fr, of: entry), x: Int(ox + Float(fr.box.left) * sc), y: Int(oy + Float(fr.box.top) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc))) }
                // the label above the head: a waving banner in the owner's colour with the stack
                // size, the acting unit's taller "selected" one; heroes show health and mana bars
                if shownAlive, let sheet = cs.labels(u.side == 0 ? AdventureUI.playerColourNames[0].lowercased() : "gray") {
                    let selected = b.current?.id == u.id && cs.result == nil
                    let k = Int(now.timeIntervalSince1970 * 8) % (selected ? 8 : 4) + 1
                    if let l = sheet[selected ? "selected_\(k)" : "frame_\(k)"] {
                        // the sheet's origin sits 44 px above the sprite's top; the text box is the sheet's "text" hotspot
                        let top = frame.map { oy + Float($0.box.top) * sc } ?? (py - 100 * sc)
                        let lx = Int(px) - 22, ly = Int(top) - 44
                        q.append(Quad(texture: uiTexture("label|\(u.side == 0 ? "red" : "gray")|\(l.name)", { l.bitmap }), x: lx + l.x, y: ly + l.y, w: l.width, h: l.height))
                        let boxX = lx + 2, boxY = ly + 11, boxW = 34, boxH = 21
                        if u.stats.isHero, let hs = cs.healthSheet, let bg = hs["background"], let hb = hs["health_bar"], let mb = hs["mana_bar"] {
                            let bx = boxX + (boxW - bg.width) / 2, by = boxY + (boxH - bg.height) / 2
                            q.append(Quad(texture: uiTexture("label|health|bg", { bg.bitmap }), x: bx, y: by, w: bg.width, h: bg.height))
                            let hf = max(0, min(1, Float(u.stats.hitPoints - u.stats.wounds) / Float(max(1, u.stats.hitPoints))))
                            if hf > 0 { q.append(Quad(texture: uiTexture("label|health|hb", { hb.bitmap }), x: bx + hb.x, y: by + hb.y, w: Int(Float(hb.width) * hf), h: hb.height)) }
                            q.append(Quad(texture: uiTexture("label|health|mb", { mb.bitmap }), x: bx + mb.x, y: by + mb.y, w: mb.width / 2, h: mb.height))
                        } else {
                            let count = String(cs.shownCount[u.id] ?? u.stats.count)
                            let labelFont = ui.font(18)
                            let w = labelFont.measure(count)
                            q.append(Quad(texture: uiTexture("count18|\(count)|white", { labelFont.render(count, colour: (255, 255, 255)) }), x: boxX + (boxW - w) / 2, y: boxY + (boxH - labelFont.size) / 2, w: w, h: labelFont.size))
                        }
                    }
                }
            }
            drawn.append((py + (shownAlive ? 0 : -1000), q))
        }
        for (_, q) in drawn.sorted(by: { $0.0 < $1.0 }) { out += q }
        // spell-style effects over units: the frame canvas centred on the unit, its bottom at the feet
        for fx in cs.effects {
            guard let sp = cs.effectSprite(fx.name), !sp.frames.isEmpty else { continue }
            let frames = sp.frames
            let info = cs.effectInfo[fx.name]
            // the file's frame order at its pace; the anchor point of the frame canvas on the stack's centre
            let order = info?.order.isEmpty == false ? info!.order : Array(frames.indices)
            let step = Int(now.timeIntervalSince(fx.since) * 1000) / max(1, info?.ms ?? 83)
            let fr = frames[max(0, min(frames.count - 1, order[min(order.count - 1, step)]))]
            let width = frames.map { $0.box.right }.max() ?? fr.box.right, height = frames.map { $0.box.bottom }.max() ?? fr.box.bottom
            let u = b.unit(fx.unit)
            // the reference point is the footprint's leftmost corner on screen, level with its centre
            let corners = [(Float(u.x), Float(u.y)), (Float(u.x + u.size), Float(u.y)), (Float(u.x), Float(u.y + u.size)), (Float(u.x + u.size), Float(u.y + u.size))].map { CombatScreen.point($0.0, $0.1) }
            let px = corners.map { $0.0 }.min() ?? 0, py = CombatScreen.point(u.centre.0, u.centre.1).1
            let anchor = info.map { $0.anchor.0 != 0 || $0.anchor.1 != 0 ? $0.anchor : (width / 2, height - 8) } ?? (width / 2, height - 8)
            out.append(Quad(texture: texture(for: fr, of: "spell.\(fx.name)"), x: Int(px) - anchor.0 + fr.box.left, y: Int(py) - anchor.1 + fr.box.top, w: fr.bitmap.width, h: fr.bitmap.height))
        }
        // damage numbers
        // floating messages: large white numbers with the message icon to their right, rising
        let messageFont = ui.font(24)
        for fl in cs.floaters where now >= fl.since {
            let age = Float(max(0, now.timeIntervalSince(fl.since)))
            let (px, py) = CombatScreen.point(fl.x, fl.y)
            let icon = fl.icon.flatMap { iconSheet("combat_messages")[$0.lowercased()] }
            let w = messageFont.measure(fl.text), iw = icon?.width ?? 0
            let x0 = Int(px) - (w + iw) / 2, y0 = Int(py - 80 - age * 25) + fl.line * 30
            let colour: (UInt8, UInt8, UInt8) = fl.red ? (230, 40, 30) : (255, 255, 255)
            out.append(Quad(texture: uiTexture("float|\(fl.text)|shadow", { messageFont.render(fl.text, colour: (0, 0, 0)) }), x: x0 + 1, y: y0 + 1, w: w, h: messageFont.size))
            out.append(Quad(texture: uiTexture("float|\(fl.text)|\(fl.red)", { messageFont.render(fl.text, colour: colour) }), x: x0, y: y0, w: w, h: messageFont.size))
            if let ic = icon { out.append(Quad(texture: uiTexture("msgicon|\(ic.name)", { ic.bitmap }), x: x0 + w + 2, y: y0 + (messageFont.size - ic.height) / 2, w: ic.width, h: ic.height)) }
        }
        // the frame and the panel
        for l in cs.frame.layers where l.isImage && l.name != "Ring_Released" && l.name != "creature_icon" {   // creature_icon is only a placeholder box
            out.append(Quad(texture: uiTexture("combatframe|\(l.name)", { l.bitmap }), x: l.x, y: l.y, w: l.width, h: l.height))
        }
        if let cur = b.current, cs.result == nil {
            // the portrait centred in the ring, the ring over it
            if let ring = cs.hotspot("Ring_Released") {
                let icon = cur.stats.isHero ? ui.portrait(keyword: cur.keyword, alignment: cs.hero?.alignment ?? "life") : ui.creatureIcon(cur.keyword)
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: ring.x + (ring.width - icon.width) / 2, y: ring.y + (ring.height - icon.height) / 2, w: icon.width, h: icon.height)) }
                out.append(Quad(texture: uiTexture("combatframe|ring", { ring.bitmap }), x: ring.x, y: ring.y, w: ring.width, h: ring.height))
            }
            let health = "\(cur.stats.hitPoints - cur.stats.wounds)/\(cur.stats.hitPoints)"
            out += centred(health, in: cs.hotspot("Health_Text"), at: 0, 0, font: ui.numberFont)
            out += centred("\(cur.shots)", in: cs.hotspot("Shots_Text"), at: 0, 0, font: ui.numberFont)
            out += centred("\(cur.caster?.spellPoints ?? 0)", in: cs.hotspot("Spell_Points_Text"), at: 0, 0, font: ui.numberFont)
        }
        for (hs, name) in [("cast_spell", "cast_spell"), ("defend", "defend"), ("wait", "wait"), ("melee", "melee"), ("auto_attack", "auto"), ("combat_options", "options"), ("retreat", "retreat"), ("surrender", "surrender")] {
            guard let slot = cs.hotspot(hs) else { continue }
            let disabled = ["cast_spell", "options"].contains(name) || (name == "melee" && !(b.current?.shots ?? 0 > 0))
            if let img = ui.button("combat.\(name)", state: disabled ? "Disabled" : "Released") {
                out.append(Quad(texture: uiTexture("button|combat.\(name)|\(disabled)", { img.bitmap }), x: slot.x + (slot.width - img.width) / 2, y: slot.y + (slot.height - img.height) / 2, w: img.width, h: img.height))
            }
        }
        out += combatInfoQuads()
        out += hoverQuads()
        if cs.showResults { out += combatResultQuads() }
        out += spellBookQuads()
        if prompt != nil { out += messageBoxQuads() }
        return out
    }

    /// A 32x16 diamond (one combat cell) in a colour.
    func cellDiamond(_ key: String, _ r: UInt8, _ g: UInt8, _ bl: UInt8, _ a: UInt8) -> MTLTexture {
        uiTexture("cell|\(key)", {
            var bm = Bitmap(width: 32, height: 16)
            for y in 0..<16 {
                for x in 0..<32 {
                    let dx: Float = abs(Float(x) - 15.5) / 16
                    let dy: Float = abs(Float(y) - 7.5) / 8
                    if dx + dy > 1 { continue }
                    let i = (y * 32 + x) * 4
                    bm.pixels[i] = r; bm.pixels[i + 1] = g; bm.pixels[i + 2] = bl; bm.pixels[i + 3] = a
                }
            }
            return bm
        })
    }

    /// The enemy unit under a canvas point: its footprint, or its picture's upper body.
    func enemyUnder(_ b: Battle, x: Float, y: Float) -> Battle.Unit? { unitUnder(b, x: x, y: y, side: 1) }
    func unitUnder(_ b: Battle, x: Float, y: Float, side: Int? = nil) -> Battle.Unit? {
        let (wx, wy) = Battlefield.world(x / CombatScreen.sceneScale, y / CombatScreen.sceneScale)
        return b.units.first { u in
            guard u.alive, side == nil || u.side == side else { return false }
            if wx >= Float(u.x), wx < Float(u.x + u.size), wy >= Float(u.y), wy < Float(u.y + u.size) { return true }
            let (cx, cy) = CombatScreen.point(u.centre.0, u.centre.1)
            return abs(x - cx) < 18 && y < cy && y > cy - 70
        }
    }
    /// Where the current unit's footprint would stand for a click on a cell: centred on it.
    func footprintAt(_ u: Battle.Unit, x: Float, y: Float) -> (Int, Int) {
        let (wx, wy) = Battlefield.world(x / CombatScreen.sceneScale, y / CombatScreen.sceneScale)
        return (Int((wx - Float(u.size) / 2).rounded()), Int((wy - Float(u.size) / 2).rounded()))
    }

    /// layers.dialog.Combat_results: victor and loser portraits, losses.
    /// The combat results (layers.dialog.Combat_results): the title, the outcome text, the battle's
    /// movie in Cut_Scene (movies.h4r: win_battle / lose_battle / retreat, intro once then the
    /// loop), the winner left and the loser right in their frames with "Victorious" / "Defeated"
    /// under them, and each side's "Casualties": every stack with the creatures it lost.
    func combatResultQuads() -> [Quad] {
        guard let cs = combat, let b = cs.battle, let ui = ui, let d = ui.dialog("Combat_results"), let r = cs.result else { return [] }
        let ox = (AdventureUI.width - 798) / 2, oy = (AdventureUI.height - 599) / 2
        var out = dialogImages(d, key: "results", at: ox, oy)
        out += centred(text("combat_results_title.combat", "Combat Results"), in: d["Title"], at: ox, oy, font: ui.font(18))
        var line = r.won ? text("player_won_battle.combat", "You have vanquished your foe!") + "  \(b.experience) experience." : "Your army was defeated after \(r.rounds) rounds."
        if b.retreated, let h = cs.hero, let t = cs.retreatTown, let g = game {
            line = text("one_hero_retreats.combat", "%Hero_name retreats shamefully to %town_name.")
                .replacingOccurrences(of: "%Hero_name", with: h.name).replacingOccurrences(of: "%town_name", with: g.towns[t].name)
        }
        out += paragraph(line, in: d["Combat_Results_Text"], at: ox, oy, font: ui.dateFont)
        // the movie
        if let slot = d["Cut_Scene"], let movies = movies {
            let kind = r.won ? "win_battle" : b.retreated ? "retreat" : "lose_battle"
            let since = cs.resultShownAt ?? Date()
            if cs.resultShownAt == nil { cs.resultShownAt = since }
            let t = Date().timeIntervalSince(since)
            var frame: (Movie, Int)? = nil
            if let intro = movies.movie("\(kind)_intro") {
                let n = Int(t * intro.fps)
                if n < intro.frames.count { frame = (intro, n) }
                else if let loop = movies.movie("\(kind)_loop") {
                    frame = (loop, Int((t - Double(intro.frames.count) / intro.fps) * loop.fps) % loop.frames.count)
                } else { frame = (intro, intro.frames.count - 1) }
            }
            if let (m, i) = frame {
                out.append(Quad(texture: uiTexture("movie|\(kind)|\(ObjectIdentifier(m).hashValue)|\(i)", { m.frames[i] }), x: ox + slot.x + (slot.width - m.width) / 2, y: oy + slot.y + (slot.height - m.height) / 2, w: m.width, h: m.height))
            }
        }
        let winner = r.won ? 0 : 1, loser = 1 - winner
        func icon(_ u: Battle.Unit, size: Int) -> UILayer? {
            u.stats.isHero ? (ui.portrait(keyword: u.keyword, alignment: cs.hero?.alignment ?? "life", size: size) ?? ui.portrait(keyword: u.keyword, alignment: cs.hero?.alignment ?? "life"))
                           : (ui.creatureIcon(u.keyword, size: size) ?? ui.creatureIcon(u.keyword))
        }
        // the side's leader in its frame, and the label under it
        func leader(side: Int, frame: String, label: String, text words: String) {
            if let f = d[frame], let lead = b.units.first(where: { $0.side == side }), let ic = icon(lead, size: 82) {
                out.append(Quad(texture: uiTexture("icon82|\(ic.name)", { ic.bitmap }), x: ox + f.x + (f.width - ic.width) / 2, y: oy + f.y + (f.height - ic.height) / 2, w: ic.width, h: ic.height))
                out.append(Quad(texture: uiTexture("dlg|results|\(frame)", { f.bitmap }), x: ox + f.x, y: oy + f.y, w: f.width, h: f.height))
            }
            out += centred(words, in: d[label], at: ox, oy, font: ui.font(18))
        }
        leader(side: winner, frame: "Winner_Frame", label: "Victor", text: text("victorious.combat", "Victorious"))
        leader(side: loser, frame: "Loser_Frame", label: "Defeated", text: text("defeated.combat", "Defeated"))
        out += centred(text("creatures_lost_victor.combat", "Casualties"), in: d["Victor_Losses"], at: ox, oy, font: ui.dateFont)
        out += centred(text("creatures_lost_victor.combat", "Casualties"), in: d["Defeated_Losses"], at: ox, oy, font: ui.dateFont)
        // casualties: each stack of the side (up to 8, four to a row) with what it lost
        func losses(side: Int, in slot: String) {
            guard let s = d[slot] else { return }
            let units = b.units.filter { $0.side == side }
            let cols = 4, stepX = s.width / cols, stepY = s.height / 2
            for (k, u) in units.prefix(8).enumerated() {
                let cx = ox + s.x + stepX * (k % cols) + stepX / 2, top = oy + s.y + stepY * (k / cols) + 4
                if let ic = icon(u, size: 52) { out.append(Quad(texture: uiTexture("icon|\(ic.name)", { ic.bitmap }), x: cx - ic.width / 2, y: top, w: ic.width, h: ic.height)) }
                let lost = u.stats.isHero ? (u.alive ? "0" : text("combat_label.dead", "dead")) : "\(u.initialCount - u.stats.count)"
                let w = ui.numberFont.measure(lost)
                out.append(Quad(texture: shade, x: cx - w / 2 - 4, y: top + 54, w: w + 8, h: ui.numberFont.size + 2))
                out.append(Quad(texture: uiTexture("count|\(lost)", { ui.numberFont.render(lost, colour: (255, 236, 200)) }), x: cx - w / 2, y: top + 55, w: w, h: ui.numberFont.size))
            }
        }
        losses(side: winner, in: "Winner_Rings"); losses(side: loser, in: "Loser_Rings")
        if let ok = d["ok_button"], let btn = ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|ok|Released", { btn.bitmap }), x: ox + ok.x + (ok.width - btn.width) / 2, y: oy + ok.y + (ok.height - btn.height) / 2, w: btn.width, h: btn.height))
        }
        return out
    }

    /// A click on the combat screen (canvas coordinates).
    func combatClick(x: Float, y: Float) {
        guard let cs = combat, let b = cs.battle, let g = game else { return }
        if prompt != nil { _ = messageBoxClick(x: x, y: y); return }
        if cs.info != nil { cs.info = nil; return }   // a click closes the creature window (OK or anywhere)
        if cs.showResults {
            closeCombat(); return
        }
        guard !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0 else { return }
        if let spell = casting {   // aiming a spell: a stack it can land on, anything else cancels
            casting = nil
            if x < 885, let t = unitUnder(b, x: x, y: y), b.canTarget(spell, by: cur, t) { b.cast(spell, on: t.id, tables: g.tables); cs.pump() }
            return
        }
        if let slot = cs.hotspot("cast_spell"), x >= Float(slot.x), x < Float(slot.x + slot.width), y >= Float(slot.y), y < Float(slot.y + slot.height) {
            sound?.play("miscellaneous.button"); openCombatBook(); return
        }
        for (hs, action) in [("defend", "defend"), ("wait", "wait"), ("auto_attack", "auto"), ("retreat", "retreat"), ("surrender", "surrender"), ("melee", "melee")] {
            guard let slot = cs.hotspot(hs), x >= Float(slot.x), x < Float(slot.x + slot.width), y >= Float(slot.y), y < Float(slot.y + slot.height) else { continue }
            switch action {
            case "defend": b.defend()
            case "wait": b.wait()
            case "auto": b.autoResolve()
            case "retreat": askRetreat()
            case "surrender": prompt = (text("no_surrender_to_neutral.combat", "You cannot surrender to neutral armies."), false, nil)   // monsters take no surrender
            case "melee": combatMeleeMode.toggle()
            default: break
            }
            cs.pump(); return
        }
        guard x < Float(cs.hotspot("battle_scene")?.width ?? 885) else { return }
        if let target = enemyUnder(b, x: x, y: y) {
            if b.canShoot(cur), !combatMeleeMode { _ = b.shoot(target.id) } else { _ = b.attack(target.id) }
            combatMeleeMode = false
        } else {
            let c = footprintAt(cur, x: x, y: y)
            _ = b.move(to: c.0, c.1)
        }
        cs.pump()
        _ = g
    }

    func text(_ key: String, _ fallback: String) -> String { game?.tables?.strings[key] ?? fallback }

    /// Retreat (the original's texts): only a hero can retreat, to the player's nearest town,
    /// losing all the troops, after "wish_to_retreat.combat"; without a town, "no_town_after_retreat.combat".
    func askRetreat() {
        guard let cs = combat, let b = cs.battle, let g = game, let h = cs.hero else { return }
        guard let town = g.retreatTown(for: h) else {
            prompt = (text("no_town_after_retreat.combat", "You must have a town to retreat."), false, nil); return
        }
        cs.retreatTown = town
        let q = text("wish_to_retreat.combat", "Are you sure you want to retreat to %town_name?  You will lose all your troops!")
            .replacingOccurrences(of: "%town_name", with: g.towns[town].name)
        prompt = (q, true, { [weak self] in b.retreat(); self?.combat?.pump() })
    }

    /// Leave the combat screen and apply the result to the map.
    func closeCombat() {
        guard let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, let p = cs.placed, let t = g.tables else { combat?.battle = nil; return }
        if b.retreated, let town = cs.retreatTown {
            g.retreat(hero: h, monsterAt: cs.monsterIndex, monstersLeft: b.units.first { $0.side == 1 }?.stats.count ?? 0, to: town)
            cs.battle = nil; return
        }
        let won = b.finished ?? false
        // the heroes keep the spell points they have left; summoned stacks go
        for (hh, u) in zip([h] + h.companions, b.units.filter { $0.side == 0 && $0.stats.isHero }) { if let c = u.caster { hh.spellPoints = c.spellPoints } }
        let army = b.units.filter { $0.side == 0 && !$0.stats.isHero && $0.alive && !$0.summoned }.map { Hero.Stack(creature: $0.keyword, count: $0.stats.count) }
        let left = b.units.first { $0.side == 1 }?.stats.count ?? 0
        g.finishBattle(hero: h, monsterAt: cs.monsterIndex, p, won: won, army: army, monstersLeft: left, experience: b.experience, rounds: b.round)
        _ = t
        cs.battle = nil
    }

    /// The status line over an enemy: "Attack <creature> for N - M damage" (the game's
    /// attack.combat and text_damage_range texts), the range from the damage rules.
    func combatStatusText(x: Float, y: Float) -> String? {
        guard let cs = combat, let b = cs.battle, !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0, x < 885, let t = game?.tables else { return nil }
        guard let target = enemyUnder(b, x: x, y: y) else { return nil }
        let ranged = b.canShoot(cur) && !combatMeleeMode
        let (lo, hi) = b.damageRange(cur, target, ranged: ranged)
        let range = lo == hi ? (t.strings["text_damage_range_1"] ?? "%damage damage").replacingOccurrences(of: "%damage", with: "\(lo)")
                             : (t.strings["text_damage_range_2"] ?? "%damage_low - %damage_high damage").replacingOccurrences(of: "%damage_low", with: "\(lo)").replacingOccurrences(of: "%damage_high", with: "\(hi)")
        let name = target.stats.count == 1 ? target.stats.name : "\(target.stats.count) " + (t.creature(target.keyword)?.plural ?? target.stats.name)
        return (t.strings["attack.combat"] ?? "Attack %creature_name\nfor %damage").replacingOccurrences(of: "%creature_name", with: name).replacingOccurrences(of: "%damage", with: range).replacingOccurrences(of: "\n", with: " ")
    }

    /// Which combat cursor fits the cell under the pointer.
    func combatCursor(x: Float, y: Float) -> String {
        combatTarget = nil
        guard let cs = combat, let b = cs.battle, cs.info == nil, prompt == nil, spellBook == nil, !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0, x < 885 else { return "combat.normal" }
        if let spell = casting {
            if let t = unitUnder(b, x: x, y: y), b.canTarget(spell, by: cur, t) { combatTarget = t.id; return "combat.cast_spell" }
            return "combat.no_cast"
        }
        if let t = enemyUnder(b, x: x, y: y) {
            combatTarget = t.id
            if b.canShoot(cur), !combatMeleeMode { return "combat.shoot" }
            cursorFrameIndex = min(4, b.turnsToAttack(cur, t) ?? 1) - 1   // melee pointers too: 1, 2, 3, 4+ turns
            let names = ["e": "east", "w": "west", "n": "north", "s": "south", "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest"]
            let dir = Battle.facing(dx: t.centre.0 - cur.centre.0, dy: t.centre.1 - cur.centre.1)
            return "combat.melee.\(names[dir] ?? "east")"
        }
        // walking: the number beside the pointer is the turns needed to get there
        let c = footprintAt(cur, x: x, y: y)
        guard let cost = b.cost(cur, to: c.0, c.1) else { return "combat.normal" }
        // the pointer's frame is the turns needed: 1, 2, 3, 4+ (layers.cursor.combat.walk / fly)
        cursorFrameIndex = min(4, max(1, Int((cost / Float(max(1, cur.move))).rounded(.up)))) - 1
        return cur.stats.has("flying") ? "combat.fly" : "combat.walk"
    }
}
