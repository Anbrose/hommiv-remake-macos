import Foundation
import Metal
import H4Engine

/// The combat screen (combat_ui_spec.md): the battlefield clipped to battle_scene (0,0)-(885,768),
/// the grid and movement shading overlays, the units with their ground marks and labels, the
/// floating messages, then the frame (Background, Border), the buttons and the side panel.
extension Renderer {
    typealias RGB = (UInt8, UInt8, UInt8)
    /// The font cache (0x875bc0): table 0xa84798 holds one nominal height per loaded font, in the
    /// order of the 14 font.Prose_Antique files (10, 12, ..., 36); a size picks the font whose value
    /// is the largest no bigger than it (9 -> Prose_Antique.10, 23 -> .24, 30 -> .32).
    static let proseHeights = [9, 11, 12, 14, 16, 18, 20, 23, 25, 27, 29, 30, 33, 34]
    func proseFont(_ n: Int) -> H4Font {
        ui!.font(n)   // 0x875bc0's slot table (AdventureUI.fontSlots)
    }
    /// A text window (t_text_window 0x8859f0): word-wrapped to its width, left or centred
    /// (+0xc4), top-aligned or centred vertically as a block (+0xd4); black unless told, the halo
    /// only when one is given (0x886b10).
    func textWindow(_ s: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, font f: H4Font, centre: Bool = true, vcentre: Bool = false,
                    colour: RGB = (0, 0, 0), halo: RGB? = nil) -> [Quad] {
        guard !s.isEmpty else { return [] }
        let lines = s.components(separatedBy: "\n").flatMap { AdventureUI.wrap($0, font: f, width: w) }
        var top = y
        if vcentre, lines.count * f.lineHeight < h { top = y + (h - lines.count * f.lineHeight) / 2 }
        var out: [Quad] = []
        let hk = halo.map { "\($0.0).\($0.1).\($0.2)" } ?? "-"
        for (k, line) in lines.enumerated() where !line.isEmpty {
            let lw = f.measure(line)
            let lx = centre ? x + max(0, (w - lw) / 2) : x
            out.append(Quad(texture: uiTexture("tw|\(f.size)|\(colour.0).\(colour.1).\(colour.2)|\(hk)|\(line)", { f.render(line, colour: colour, halo: halo) }),
                            x: lx, y: top + k * f.lineHeight, w: lw, h: f.size))
        }
        return out
    }
    func textWindow(_ s: String, in l: UILayer?, _ ox: Int = 0, _ oy: Int = 0, font f: H4Font, centre: Bool = true, vcentre: Bool = false,
                    colour: RGB = (0, 0, 0), halo: RGB? = nil) -> [Quad] {
        guard let l = l else { return [] }
        return textWindow(s, ox + l.x, oy + l.y, l.width, l.height, font: f, centre: centre, vcentre: vcentre, colour: colour, halo: halo)
    }
    /// A layer by name, whatever the case (0x58e950).
    func layer(_ d: LayerFile?, _ name: String) -> UILayer? {
        guard let d = d else { return nil }
        return d[name] ?? d.layers.first { $0.name.lowercased() == name.lowercased() }
    }
    /// A layer drawn at a point, optionally scaled (0x58fa40's scaled layer cache).
    func image(_ l: UILayer, key: String, _ x: Int, _ y: Int, scale s: Float = 1) -> Quad {
        Quad(texture: uiTexture(key, { l.bitmap }), x: x, y: y, w: max(1, Int(Float(l.width) * s)), h: max(1, Int(Float(l.height) * s)))
    }

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
        unitHeads = []
        guard let cs = combat, let b = cs.battle, ui != nil, let f = cs.field else { return [] }
        var out: [Quad] = []
        let sc = CombatScreen.sceneScale
        // the ground: a ship's backdrop, or the terrain's tiles
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
        }
        // a citadel's or castle's moat: terrain cells x 50...53 down the whole field (water tiles)
        if !f.moat.isEmpty, let water = cs.groundPatch(terrain: 0, variant: 0, alt: 1) {
            for ax in 25...26 { for ay in 0..<(Battlefield.size / 2 + 1) {
                let (px, py) = CombatScreen.point(Float(2 * ax + 1), Float(2 * ay + 1))
                if px < -40 || py < -30 || px > 925 || py > 800 { continue }
                let ti = 22 + (ay % 5)
                out.append(Quad(texture: uiTexture("moat|\(ti)", { water.tiles[min(ti, water.tiles.count - 1)] }), x: Int(px - 32 * sc), y: Int(py - 16 * sc), w: Int(64 * sc) + 1, h: Int(32 * sc) + 1))
            } }
        }
        // the grid (option show_grid, 0x588b60): table.combat_grid_colors per terrain, cell (x, y) in
        // colour [(x + y) & 1] (0 the odd entry, 1 the even), cells an obstacle blocks untinted; the
        // overlay's level n of 15
        if cs.showGrid {
            let key = f.backdrop != nil ? "water" : (CombatScreen.terrainKeys[f.terrain] ?? "grass")
            let tint = cs.gridColors?.byTerrain[key] ?? GridColors.Entry(alpha: 4, odd: nil, even: (12, 36, 12))
            let alpha = UInt8(min(255, tint.alpha * 255 / 15))
            for x in 0..<Battlefield.size { for y in 0..<Battlefield.size where Battlefield.onField(x, y) && b.field.isOpen(x, y) {
                guard let c = (x + y) & 1 == 0 ? tint.odd : tint.even else { continue }
                let (px, py) = CombatScreen.point(Float(x) + 0.5, Float(y) + 0.5)
                out.append(Quad(texture: cellDiamond("grid|\(c.0)|\(c.1)|\(c.2)|\(alpha)", c.0, c.1, c.2, alpha), x: Int(px - 16 * sc), y: Int(py - 8 * sc), w: Int(32 * sc), h: Int(16 * sc)))
            } }
        }
        // movement shading (show_movement_grid, 0x57bae0): every cell the acting stack can reach this
        // turn in (50,50,200) at level 5 of 15
        if showReach, let cur = b.current, cur.side == 0, !cs.busy, cs.result == nil {
            let a = UInt8(5 * 255 / 15)
            for (k, _) in b.reachable(cur) {
                let x = k / Battlefield.size, y = k % Battlefield.size
                let (px, py) = CombatScreen.point(Float(x) + 0.5, Float(y) + 0.5)
                out.append(Quad(texture: cellDiamond("reach", 50, 50, 200, a), x: Int(px - 16 * sc), y: Int(py - 8 * sc), w: Int(32 * sc), h: Int(16 * sc)))
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
            drawn.append((o.w * o.h > 9 ? CombatScreen.point(Float(o.x) + Float(o.w) / 2, Float(o.y) + Float(o.h) / 2).1 : py - 1, q))
        }
        // the castle gate, in its state (intact, light_damage, heavy_damage, destroyed)
        if !f.gateCells.isEmpty {
            let gx = f.gateCells.map { $0 / Battlefield.size }.min() ?? 0, gy = f.gateCells.map { $0 % Battlefield.size }.min() ?? 0
            let name = f.gateName.replacingOccurrences(of: ".intact.", with: ".\(b.field.gateState).")
            if let s = cs.obstacleSprite(name) ?? cs.obstacleSprite(f.gateName), let fr = s.frames.first {
                let (px, py) = CombatScreen.point(Float(gx), Float(gy))
                let q = [Quad(texture: texture(for: fr, of: name), x: Int(px + Float(s.origin.x + Int32(fr.box.left)) * sc), y: Int(py + Float(s.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc))]
                drawn.append((CombatScreen.point(Float(gx) + 1, Float(gy) + 5).1, q))
            }
        }
        let labels = combatLabels(cs, b, now: now)
        // every unit, the dead too: a dead stack stays on the field as the last frame of its
        // die sequence (the combat actor has no other corpse state), under the living
        for u in b.units {
            let pos = cs.unitPos[u.id] ?? cs.shownPos[u.id] ?? (Float(u.x), Float(u.y))
            let shownAlive = cs.shownAlive(u)
            // the actor's origin is the footprint's centre
            let (px, py) = CombatScreen.point(pos.0 + Float(u.size) / 2, pos.1 + Float(u.size) / 2)
            var q: [Quad] = []
            // the ground marks, sized to the footprint (combat_object.<active|target>_shadow.<2...7>):
            // the acting unit's, and the red one under the creature the pointer targets
            let shadowSize = min(7, max(2, u.size))
            let (tx, ty) = CombatScreen.point(pos.0, pos.1)
            let targeted = combatTarget == u.id && cs.shownAlive(u)
            if targeted, let ring = arrowSprite("target_shadow.\(shadowSize)", prefix: "combat_object"), let fr = ring.frames.first {
                q.append(Quad(texture: texture(for: fr, of: "target_shadow.\(shadowSize)"), x: Int(tx + Float(ring.origin.x + Int32(fr.box.left)) * sc), y: Int(ty + Float(ring.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            }
            if cs.shownCurrent == u.id, cs.result == nil, let ring = arrowSprite("active_shadow.\(shadowSize)", prefix: "combat_object"), let fr = ring.frames.first {
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
                let c = cs.shownCentre(u)
                unitHeads.append((c.0, c.1, px, frame.map { oy + Float($0.box.top) * sc } ?? (py - 100 * sc)))
            }
            q += labels[u.id] ?? []
            drawn.append((py + (shownAlive ? 0 : -1000), q))
        }
        for (_, q) in drawn.sorted(by: { $0.0 < $1.0 }) { out += q }
        // spell-style effects over units: the frame canvas centred on the unit, its bottom at the feet
        for fx in cs.effects {
            guard let sp = cs.effectSprite(fx.name), !sp.frames.isEmpty else { continue }
            let frames = sp.frames
            let info = cs.effectInfo[fx.name]
            let order = info?.order.isEmpty == false ? info!.order : Array(frames.indices)
            let step = Int(now.timeIntervalSince(fx.since) * 1000) / max(1, info?.ms ?? 83)
            let fr = frames[max(0, min(frames.count - 1, order[min(order.count - 1, step)]))]
            let width = frames.map { $0.box.right }.max() ?? fr.box.right, height = frames.map { $0.box.bottom }.max() ?? fr.box.bottom
            let u = b.unit(fx.unit)
            let corners = [(Float(u.x), Float(u.y)), (Float(u.x + u.size), Float(u.y)), (Float(u.x), Float(u.y + u.size)), (Float(u.x + u.size), Float(u.y + u.size))].map { CombatScreen.point($0.0, $0.1) }
            let px = corners.map { $0.0 }.min() ?? 0, py = CombatScreen.point(u.centre.0, u.centre.1).1
            let anchor = info.map { $0.anchor.0 != 0 || $0.anchor.1 != 0 ? $0.anchor : (width / 2, height - 8) } ?? (width / 2, height - 8)
            out.append(Quad(texture: texture(for: fr, of: "spell.\(fx.name)"), x: Int(px) - anchor.0 + fr.box.left, y: Int(py) - anchor.1 + fr.box.top, w: fr.bitmap.width, h: fr.bitmap.height))
        }
        out += floaterQuads(cs, now: now)
        out += combatPanelQuads(cs, b, now: now)
        out += combatInfoQuads()
        out += hoverQuads()
        if cs.showResults { out += combatResultQuads() }
        out += spellBookQuads()
        out += optionsQuads()
        if prompt != nil { out += messageBoxQuads() }
        return out
    }

    // MARK: stack labels (t_combat_label, B1)

    /// "%i" with thousands separators, or shortened to one decimal and k / M / G when that is
    /// wider than the text rect (0x401660).
    func labelCount(_ n: Int, font f: H4Font, width: Int) -> String {
        let full = Renderer.grouped(n)
        guard n >= 1000, f.measure(full) > width else { return full }
        var v = Double(n), k = 0
        let units = ["", "k", "M", "G"]
        while v >= 1000, k < 3 { v /= 1000; k += 1 }
        let s = String(format: "%.1f", (v * 10).rounded(.down) / 10)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + units[k]
    }

    /// Every living stack's label, keyed by unit: the banner of its owner's colour sheet
    /// (icons.combat_labels.<colour>, scaled by the zoom), the acting stack's bobbing "selected"
    /// frames at 100 ms each; the count in white with a black halo (creatures) or the health and
    /// mana bars (heroes). Anchored at the footprint centre raised by (actor height + 52) x zoom,
    /// offset by half the frame box; a label overlapping one before it moves down below it.
    func combatLabels(_ cs: CombatScreen, _ b: Battle, now: Date) -> [Int: [Quad]] {
        let s = CombatScreen.sceneScale
        func sc(_ v: Int) -> Int { Int(Float(v) * s) }
        var rects: [(x: Int, y: Int, w: Int, h: Int)] = []
        var out: [Int: [Quad]] = [:]
        for u in b.units where cs.shownAlive(u) && cs.unitPos[u.id] == nil {
            let colour = CombatScreen.labelColourNames[cs.sideColour(u.side)]
            guard let sheet = cs.labels(colour), let frame = sheet["frame_1"] else { continue }
            let pos = cs.shownPos[u.id] ?? (Float(u.x), Float(u.y))
            let (px, py) = CombatScreen.point(pos.0 + Float(u.size) / 2, pos.1 + Float(u.size) / 2)
            let ax = Int(px), ay = Int(py - (cs.actorHeight(u.actor) + 52) * s)
            // the frame list's union box at this scale, halved (C truncation)
            let bx0 = sc(frame.x), by0 = sc(frame.y), bw = sc(frame.x + frame.width) - bx0, bh = sc(frame.y + frame.height) - by0
            let offX = -bw / 2, offY = -bh / 2
            var r = (x: ax + offX + bx0, y: ay + offY + by0, w: bw, h: bh)
            // overlap avoidance (0x5673c0): down below any label it overlaps, then scan again
            var moved = true, guardN = 0
            while moved, guardN < 50 {
                moved = false; guardN += 1
                if r.y < 0 { r.y = 0 }
                for o in rects where r.x < o.x + o.w && o.x < r.x + r.w && r.y < o.y + o.h && o.y < r.y + r.h {
                    r.y += o.y + o.h - r.y + 1; moved = true; break
                }
            }
            rects.append(r)
            let dy = r.y - (ay + offY + by0)
            let ox = ax + offX, oy = ay + offY + dy
            var q: [Quad] = []
            let selected = cs.shownCurrent == u.id && cs.result == nil
            let k = Int(now.timeIntervalSince1970 * 10) % 8 + 1
            if let l = selected ? sheet["selected_\(k)"] : frame {
                q.append(image(l, key: "label|\(colour)|\(l.name)", ox + sc(l.x), oy + sc(l.y), scale: s))
            }
            if u.stats.isHero {
                // the bars: `background` at the sheet's health_bar hotspot, each bar cropped to value / max
                if let hs = cs.healthSheet, let bg = hs["background"], let hb = hs["health_bar"], let mb = hs["mana_bar"], let at = sheet["health_bar"] {
                    let bx = ox + sc(at.x), by = oy + sc(at.y)
                    q.append(image(bg, key: "label|health|bg", bx, by, scale: s))
                    let hp = max(1, u.stats.hitPoints), cur = max(0, min(hp, hp - u.stats.wounds))
                    let maxSP = max(1, maxSpellPoints(u)), sp = min(u.caster?.spellPoints ?? 0, maxSP)
                    for (bar, v, m, key) in [(hb, cur, hp, "hb"), (mb, sp, maxSP, "mb")] {
                        let w = bar.width * v / m
                        guard w > 0 else { continue }
                        q.append(Quad(texture: uiTexture("label|health|\(key)|\(w)", { Renderer.crop(bar.bitmap, width: w) }), x: bx + sc(bar.x), y: by + sc(bar.y), w: max(1, sc(w)), h: max(1, sc(bar.height))))
                    }
                }
            } else if let t = sheet["text"] {
                let tx = sc(t.x), ty = sc(t.y), tw = sc(t.x + t.width) - tx, th = sc(t.y + t.height) - ty
                let f = proseFont(th)
                let n = labelCount(cs.shownCount[u.id] ?? u.stats.count, font: f, width: tw)
                let w = f.measure(n)
                q.append(Quad(texture: uiTexture("labelcount|\(f.size)|\(n)", { f.render(n, colour: (255, 255, 255), halo: (0, 0, 0)) }), x: ox + tx + (tw - w) / 2, y: oy + ty, w: w, h: f.size))
            }
            out[u.id] = q
        }
        return out
    }
    static func crop(_ bm: Bitmap, width w: Int) -> Bitmap {
        var out = Bitmap(width: max(1, min(w, bm.width)), height: bm.height)
        for y in 0..<bm.height { for x in 0..<out.width { for c in 0..<4 { out.pixels[(y * out.width + x) * 4 + c] = bm.pixels[(y * bm.width + x) * 4 + c] } } }
        return out
    }

    // MARK: floating messages (B2)

    /// Prose_Antique 40 x zoom (30 at 0.75), the owner's colour with a black halo; the icon right
    /// of the text, top-aligned; a deaths line right-aligned under the damage line; every message
    /// drifting (-1,-1) px per 100 ms; a message overlapping one before it moves down below it.
    func floaterQuads(_ cs: CombatScreen, now: Date) -> [Quad] {
        let f = proseFont(Int(885 * 40 / 1180))
        let icons = iconSheet("combat_messages")
        var rects: [(x: Int, y: Int, w: Int, h: Int)] = []
        var out: [Quad] = []
        for fl in cs.floaters where now >= fl.since {
            let (px, py) = CombatScreen.point(fl.world.0, fl.world.1)
            let step = Int(now.timeIntervalSince(fl.since) * 10)
            // the lines: text window auto-sized to the text, the icon's bitmap window at its top-right
            var parts: [(text: String, w: Int, icon: UILayer?, lx: Int, ly: Int)] = []
            var y = 0
            var w1 = 0
            for (k, line) in fl.lines.enumerated() {
                let tw = f.measure(line.text)
                let ic = line.icon.flatMap { icons[$0.lowercased()] }
                let lx = k == 0 ? 0 : max(0, w1 - tw)
                if k == 0 { w1 = tw }
                parts.append((line.text, tw, ic, lx, y))
                y += f.size
            }
            let bw = parts.map { $0.lx + $0.w + ($0.icon.map { $0.x + $0.width } ?? 0) }.max() ?? 0
            let bh = max(y, parts.map { $0.ly + ($0.icon.map { $0.y + $0.height } ?? 0) }.max() ?? 0)
            var r = (x: Int(px) - step, y: Int(py - fl.height * CombatScreen.sceneScale) - step, w: bw, h: bh)
            r.x = max(0, min(885 - bw, r.x)); r.y = max(0, r.y)
            var moved = true, guardN = 0
            while moved, guardN < 30 {
                moved = false; guardN += 1
                for o in rects where r.x < o.x + o.w && o.x < r.x + r.w && r.y < o.y + o.h && o.y < r.y + r.h { r.y = o.y + o.h; moved = true; break }
            }
            rects.append(r)
            for p in parts {
                let c = fl.colour
                out.append(Quad(texture: uiTexture("floattext|\(f.size)|\(c.0).\(c.1).\(c.2)|\(p.text)", { f.render(p.text, colour: c, halo: (0, 0, 0)) }), x: r.x + p.lx, y: r.y + p.ly, w: p.w, h: f.size))
                if let ic = p.icon { out.append(image(ic, key: "msgicon|\(ic.name)", r.x + p.lx + p.w + ic.x, r.y + p.ly + ic.y)) }
            }
        }
        return out
    }

    /// A 32x16 diamond (one combat cell) in a colour.
    func cellDiamond(_ key: String, _ r: UInt8, _ g: UInt8, _ bl: UInt8, _ a: UInt8) -> MTLTexture {
        uiTexture("cell|\(key)|\(a)", {
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

    func text(_ key: String, _ fallback: String) -> String { game?.tables?.strings[key] ?? fallback }

    /// The status line over an enemy: "Attack <creature> for N - M damage" (the game's
    /// attack.combat and text_damage_range texts), the range from the damage rules.
    func combatStatusText(x: Float, y: Float) -> String? {
        guard let cs = combat, let b = cs.battle, !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0, x < 885, let t = game?.tables else { return nil }
        guard let target = enemyUnder(b, x: x, y: y) else { return nil }
        let mode = cs.shownMode(cur)
        guard mode != 4 else { return nil }
        let ranged = b.canShoot(cur) && mode == 0
        let (lo, hi) = b.damageRange(cur, target, ranged: ranged)
        let range = lo == hi ? (t.strings["text_damage_range_1"] ?? "%damage damage").replacingOccurrences(of: "%damage", with: "\(lo)")
                             : (t.strings["text_damage_range_2"] ?? "%damage_low - %damage_high damage").replacingOccurrences(of: "%damage_low", with: "\(lo)").replacingOccurrences(of: "%damage_high", with: "\(hi)")
        let name = target.stats.count == 1 ? target.stats.name : "\(target.stats.count) " + (t.creature(target.keyword)?.plural ?? target.stats.name)
        return (t.strings["attack.combat"] ?? "Attack %creature_name\nfor %damage").replacingOccurrences(of: "%creature_name", with: name).replacingOccurrences(of: "%damage", with: range).replacingOccurrences(of: "\n", with: " ")
    }

    /// Which combat cursor fits the cell under the pointer.
    func combatCursor(x: Float, y: Float) -> String {
        combatTarget = nil
        guard let cs = combat, let b = cs.battle, cs.info == nil, prompt == nil, spellBook == nil, !cs.busy, cs.result == nil, !cs.autoCombat, let cur = b.current, cur.side == 0, x < 885 else { return "combat.normal" }
        if let spell = casting {
            if let t = unitUnder(b, x: x, y: y), b.canTarget(spell, by: cur, t) { combatTarget = t.id; return "combat.cast_spell" }
            return "combat.no_cast"
        }
        let mode = cs.shownMode(cur)
        if mode != 4, onGate(b, x: x, y: y), b.nextToGate(cur) || b.canShoot(cur) { return "combat.attack_Gate" }
        if mode != 4, let t = enemyUnder(b, x: x, y: y) {
            combatTarget = t.id
            if mode == 3 { return "combat.cast_spell" }
            if b.canShoot(cur), mode == 0 {
                // the shooting pointer's frames are the damage divisor: 1, 2, 4, 8 (range and obstacles)
                let div = b.rangeDivisor(cur, t)
                cursorFrameIndex = div >= 8 ? 3 : div >= 4 ? 2 : div >= 2 ? 1 : 0
                return "combat.shoot"
            }
            cursorFrameIndex = min(4, b.turnsToAttack(cur, t) ?? 1) - 1   // melee pointers too: 1, 2, 3, 4+ turns
            let names = ["e": "east", "w": "west", "n": "north", "s": "south", "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest"]
            let dir = Battle.facing(dx: t.centre.0 - cur.centre.0, dy: t.centre.1 - cur.centre.1)
            return "combat.melee.\(names[dir] ?? "east")"
        }
        // walking: the number beside the pointer is the turns needed to get there
        let c = footprintAt(cur, x: x, y: y)
        guard let cost = b.cost(cur, to: c.0, c.1) else { return "combat.normal" }
        cursorFrameIndex = min(4, max(1, Int((cost / Float(max(1, cur.move))).rounded(.up)))) - 1
        return cur.stats.has("flying") ? "combat.fly" : "combat.walk"
    }

    /// Is the pointer on the unbroken castle gate?
    func onGate(_ b: Battle, x: Float, y: Float) -> Bool {
        guard !b.field.gateCells.isEmpty, !b.field.gateDestroyed else { return false }
        let c = CombatScreen.cell(at: x, y)
        for d in 0...4 where b.field.gateCells.contains(Battlefield.key(c.0 - d, c.1 - d)) { return true }
        return false
    }
}
