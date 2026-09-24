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
        // the ground: a ship's backdrop, or the map's terrain around the fight (1:1, scaled into the scene)
        if let bd = f.backdrop {
            out.append(Quad(texture: uiTexture("battlefield|\(cs.fieldName)", { bd.bitmap }), x: 0, y: 0, w: Int(Float(bd.width) * sc), h: Int(Float(bd.height) * sc)))
        } else {
            let (ox, oy) = cs.origin
            for q in terrain {
                let x = (Float(q.x) - ox) * sc, y = (Float(q.y) - oy) * sc
                if x + Float(q.w) * sc < 0 || y + Float(q.h) * sc < 0 || x > 885 || y > 768 { continue }
                out.append(Quad(texture: q.texture, x: Int(x), y: Int(y), w: Int(Float(q.w) * sc), h: Int(Float(q.h) * sc)))
            }
        }
        // the acting unit's reach as a faint shade (the game's "movement shadow" option)
        if showReach, let cur = b.current, cur.side == 0, !cs.busy, cs.result == nil {
            for (key, _) in b.reachable(cur) {
                let x = key % Battlefield.columns, y = key / Battlefield.columns
                let (px, py) = CombatScreen.point(Float(x), Float(y))
                let s = Float(Battlefield.cellSize) * sc
                out.append(Quad(texture: reachShade, x: Int(px - s / 2), y: Int(py - s * 0.9), w: Int(s), h: Int(s)))
            }
        }
        // obstacles and units, back to front
        var drawn: [(Float, [Quad])] = []
        for o in f.obstacles {
            guard let s = cs.obstacleSprite(o.name), let fr = s.frames.first else { continue }
            let (px, py) = CombatScreen.point(Float(o.x) + Float(o.w - 1) / 2, Float(o.y))
            var q: [Quad] = []
            if let sh = s.shadow(for: fr) { q.append(Quad(texture: texture(for: sh, of: o.name), x: Int(px + Float(s.origin.x + Int32(sh.box.left)) * sc), y: Int(py + Float(s.origin.y + Int32(sh.box.top)) * sc), w: Int(Float(sh.bitmap.width) * sc), h: Int(Float(sh.bitmap.height) * sc))) }
            q.append(Quad(texture: texture(for: fr, of: o.name), x: Int(px + Float(s.origin.x + Int32(fr.box.left)) * sc), y: Int(py + Float(s.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            drawn.append((py - 1, q))
        }
        for u in b.units where u.alive || !cs.dead.contains(u.id) {
            let pos = cs.unitPos[u.id] ?? (Float(u.x), Float(u.y))
            let (px, py) = CombatScreen.point(pos.0, pos.1)
            var q: [Quad] = []
            if b.current?.id == u.id, cs.result == nil, let ring = arrowSprite("active_shadow.2", prefix: "combat_object"), let fr = ring.frames.first {
                q.append(Quad(texture: texture(for: fr, of: "active_shadow"), x: Int(px + Float(ring.origin.x + Int32(fr.box.left)) * sc), y: Int(py + Float(ring.origin.y + Int32(fr.box.top)) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc)))
            }
            let st = cs.unitState[u.id]
            let state = st?.state ?? (u.alive ? "fidget" : "die")
            if let (s, entry) = combatSprite(cs, actor: u.actor, state: state, facing: u.facing) {
                let tl = s.timeline
                var frame = s.frames.first, shadow = frame.flatMap { s.shadow(for: $0) }
                if !tl.isEmpty {
                    let period = tl[0].frame.speed > 0 ? Double(tl[0].frame.speed) / 60.0 : 0.1
                    var index: Int
                    if let st = st, st.once {
                        index = min(tl.count - 1, Int(now.timeIntervalSince(st.since) / period))
                        if index == tl.count - 1, state == "flinch" || state == "block" { cs.unitState[u.id] = nil }
                    } else if state == "walk" {
                        index = Int(now.timeIntervalSince(st?.since ?? now) * 12) % tl.count
                    } else {
                        index = Int((now.timeIntervalSince1970 + Double(u.id) * 0.37) / period) % tl.count
                    }
                    let e = tl[index]; frame = e.frame; shadow = e.shadow
                }
                if !u.alive, cs.dead.contains(u.id), let last = tl.last { frame = last.frame; shadow = last.shadow }
                let ox = px + Float(s.origin.x) * sc, oy = py + Float(s.origin.y) * sc
                if let sh = shadow { q.append(Quad(texture: texture(for: sh, of: entry), x: Int(ox + Float(sh.box.left) * sc), y: Int(oy + Float(sh.box.top) * sc), w: Int(Float(sh.bitmap.width) * sc), h: Int(Float(sh.bitmap.height) * sc))) }
                if let fr = frame { q.append(Quad(texture: texture(for: fr, of: entry), x: Int(ox + Float(fr.box.left) * sc), y: Int(oy + Float(fr.box.top) * sc), w: Int(Float(fr.bitmap.width) * sc), h: Int(Float(fr.bitmap.height) * sc))) }
                // the label above the head: a waving banner in the owner's colour with the stack
                // size, the acting unit's taller "selected" one; heroes show health and mana bars
                if u.alive, let sheet = cs.labels(u.side == 0 ? AdventureUI.playerColourNames[0].lowercased() : "gray") {
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
                            let count = String(u.stats.count)
                            let w = ui.numberFont.measure(count)
                            q.append(Quad(texture: uiTexture("count|\(count)|dark", { ui.numberFont.render(count, colour: (40, 24, 8)) }), x: boxX + (boxW - w) / 2, y: boxY + (boxH - ui.numberFont.size) / 2, w: w, h: ui.numberFont.size))
                        }
                    }
                }
            }
            drawn.append((py + (u.alive ? 0 : -1000), q))
        }
        for (_, q) in drawn.sorted(by: { $0.0 < $1.0 }) { out += q }
        // damage numbers
        for fl in cs.floaters {
            let age = Float(max(0, now.timeIntervalSince(fl.since)))
            let (px, py) = CombatScreen.point(fl.x, fl.y)
            let w = ui.dateFont.measure(fl.text)
            out.append(Quad(texture: uiTexture("date|\(fl.text)|red", { ui.dateFont.render(fl.text, colour: (255, 80, 60)) }), x: Int(px) - w / 2, y: Int(py - 70 - age * 25), w: w, h: ui.dateFont.size))
        }
        // the frame and the panel
        for l in cs.frame.layers where l.isImage && l.name != "Ring_Released" {
            out.append(Quad(texture: uiTexture("combatframe|\(l.name)", { l.bitmap }), x: l.x, y: l.y, w: l.width, h: l.height))
        }
        if let cur = b.current, cs.result == nil {
            if let ring = cs.hotspot("Ring_Released") { out.append(Quad(texture: uiTexture("combatframe|ring", { ring.bitmap }), x: ring.x, y: ring.y, w: ring.width, h: ring.height)) }
            if let slot = cs.hotspot("creature_icon") {
                let icon = cur.stats.isHero ? ui.portrait(keyword: cur.keyword, alignment: cs.hero?.alignment ?? "life") : ui.creatureIcon(cur.keyword)
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: slot.x + (slot.width - icon.width) / 2, y: slot.y + (slot.height - icon.height) / 2, w: icon.width, h: icon.height)) }
            }
            let health = "\(cur.stats.hitPoints - cur.stats.wounds)/\(cur.stats.hitPoints)"
            out += centred(health, in: cs.hotspot("Health_Text"), at: 0, 0, font: ui.numberFont)
            out += centred("\(cur.shots)", in: cs.hotspot("Shots_Text"), at: 0, 0, font: ui.numberFont)
            out += centred("0", in: cs.hotspot("Spell_Points_Text"), at: 0, 0, font: ui.numberFont)
            let name = cur.stats.isHero ? cur.stats.name : "\(cur.stats.count) \(cur.stats.name)"
            for (i, line) in AdventureUI.wrap(name + "\nRound \(b.round)", font: ui.numberFont, width: 95).enumerated() {
                if let at = cs.hotspot("Action_Text") { out.append(Quad(texture: uiTexture("num|\(line)", { ui.numberFont.render(line, colour: (40, 24, 8)) }), x: at.x + (at.width - ui.numberFont.measure(line)) / 2, y: at.y + 40 + i * ui.numberFont.lineHeight, w: ui.numberFont.measure(line), h: ui.numberFont.size)) }
            }
        }
        for (hs, name) in [("cast_spell", "cast_spell"), ("defend", "defend"), ("wait", "wait"), ("melee", "melee"), ("auto_attack", "auto"), ("combat_options", "options"), ("retreat", "retreat"), ("surrender", "surrender")] {
            guard let slot = cs.hotspot(hs) else { continue }
            let disabled = ["cast_spell", "options", "surrender"].contains(name) || (name == "melee" && !(b.current?.shots ?? 0 > 0))
            if let img = ui.button("combat.\(name)", state: disabled ? "Disabled" : "Released") {
                out.append(Quad(texture: uiTexture("button|combat.\(name)|\(disabled)", { img.bitmap }), x: slot.x + (slot.width - img.width) / 2, y: slot.y + (slot.height - img.height) / 2, w: img.width, h: img.height))
            }
        }
        out += hoverQuads()
        if cs.showResults { out += combatResultQuads() }
        return out
    }

    var reachShade: MTLTexture {
        uiTexture("solid|reach", { var bm = Bitmap(width: 2, height: 2); for i in 0..<4 { bm.pixels[i * 4] = 60; bm.pixels[i * 4 + 1] = 90; bm.pixels[i * 4 + 2] = 160; bm.pixels[i * 4 + 3] = 70 }; return bm })
    }

    /// layers.dialog.Combat_results: victor and loser portraits, losses.
    func combatResultQuads() -> [Quad] {
        guard let cs = combat, let b = cs.battle, let ui = ui, let d = ui.dialog("Combat_results"), let r = cs.result else { return [] }
        let ox = (AdventureUI.width - 798) / 2, oy = (AdventureUI.height - 599) / 2
        var out = dialogImages(d, key: "results", at: ox, oy, skip: ["ok_button"])
        out += centred(r.won ? "Victory!" : "Defeat", in: d["Title"], at: ox, oy, font: ui.dateFont)
        let text = r.won ? "Your army has won the battle after \(r.rounds) rounds and gains \(b.experience) experience." : "Your army was defeated after \(r.rounds) rounds."
        out += paragraph(text, in: d["Combat_Results_Text"], at: ox, oy, font: ui.numberFont)
        let winner = r.won ? 0 : 1, loser = 1 - winner
        func portrait(side: Int, in slot: String) {
            guard let s = d[slot] else { return }
            let lead = b.units.first { $0.side == side }
            let icon = lead.map { u in u.stats.isHero ? ui.portrait(keyword: u.keyword, alignment: cs.hero?.alignment ?? "life") : ui.creatureIcon(u.keyword) } ?? nil
            if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: ox + s.x + (s.width - icon.width) / 2, y: oy + s.y + (s.height - icon.height) / 2, w: icon.width, h: icon.height)) }
        }
        portrait(side: winner, in: "Winner_Portrait"); portrait(side: loser, in: "Loser_Portrait")
        func losses(side: Int, in slot: String) {
            guard let s = d[slot] else { return }
            let units = b.units.filter { $0.side == side }
            let step = s.width / 7
            for (k, u) in units.prefix(7).enumerated() {
                let cx = ox + s.x + step * k + step / 2, cy = oy + s.y + s.height / 2
                let icon = u.stats.isHero ? ui.portrait(keyword: u.keyword, alignment: cs.hero?.alignment ?? "life") : ui.creatureIcon(u.keyword)
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2 - 8, w: icon.width, h: icon.height)) }
                let lost = u.stats.isHero ? (u.alive ? "" : "dead") : "\(u.stats.count)"
                if !lost.isEmpty {
                    let w = ui.numberFont.measure(lost)
                    out.append(Quad(texture: shade, x: cx - w / 2 - 4, y: cy + 20, w: w + 8, h: ui.numberFont.size + 2))
                    out.append(Quad(texture: uiTexture("count|\(lost)", { ui.numberFont.render(lost, colour: (255, 236, 200)) }), x: cx - w / 2, y: cy + 21, w: w, h: ui.numberFont.size))
                }
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
        if cs.showResults {
            closeCombat(); return
        }
        guard !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0 else { return }
        for (hs, action) in [("defend", "defend"), ("wait", "wait"), ("auto_attack", "auto"), ("retreat", "retreat"), ("melee", "melee")] {
            guard let slot = cs.hotspot(hs), x >= Float(slot.x), x < Float(slot.x + slot.width), y >= Float(slot.y), y < Float(slot.y + slot.height) else { continue }
            switch action {
            case "defend": b.defend()
            case "wait": b.wait()
            case "auto": b.autoResolve()
            case "retreat": while b.finished == nil, let u = b.current, u.side == 0 { u.stats.count = 0; b.defend() }; b.autoResolve()
            case "melee": combatMeleeMode.toggle()
            default: break
            }
            cs.pump(); return
        }
        guard x < Float(cs.hotspot("battle_scene")?.width ?? 885) else { return }
        let c = CombatScreen.cell(at: x, y)
        if let target = b.units.first(where: { $0.alive && $0.side == 1 && $0.x == c.0 && $0.y == c.1 }) {
            if cur.shots > 0, !combatMeleeMode { _ = b.shoot(target.id) } else { _ = b.attack(target.id) }
            combatMeleeMode = false
        } else {
            _ = b.move(to: c.0, c.1)
        }
        cs.pump()
        _ = g
    }

    /// Leave the combat screen and apply the result to the map.
    func closeCombat() {
        guard let cs = combat, let b = cs.battle, let g = game, let h = cs.hero, let p = cs.placed, let t = g.tables else { combat?.battle = nil; return }
        let won = b.finished ?? false
        let army = b.units.filter { $0.side == 0 && !$0.stats.isHero && $0.alive }.map { Hero.Stack(creature: $0.keyword, count: $0.stats.count) }
        let left = b.units.first { $0.side == 1 }?.stats.count ?? 0
        g.finishBattle(hero: h, monsterAt: cs.monsterIndex, p, won: won, army: army, monstersLeft: left, experience: b.experience, rounds: b.round)
        _ = t
        cs.battle = nil
    }

    /// The status line over an enemy: "Attack <creature> for N - M damage" (the game's
    /// attack.combat and text_damage_range texts), the range from the damage rules.
    func combatStatusText(x: Float, y: Float) -> String? {
        guard let cs = combat, let b = cs.battle, !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0, x < 885, let t = game?.tables else { return nil }
        let c = CombatScreen.cell(at: x, y)
        guard let target = b.units.first(where: { $0.alive && $0.side == 1 && $0.x == c.0 && $0.y == c.1 }) else { return nil }
        let ranged = cur.shots > 0 && !combatMeleeMode && !b.units.contains { $0.alive && $0.side == 1 && Battle.adjacent(cur, $0) }
        let (lo, hi) = b.damageRange(cur, target, ranged: ranged)
        let range = lo == hi ? (t.strings["text_damage_range_1"] ?? "%damage damage").replacingOccurrences(of: "%damage", with: "\(lo)")
                             : (t.strings["text_damage_range_2"] ?? "%damage_low - %damage_high damage").replacingOccurrences(of: "%damage_low", with: "\(lo)").replacingOccurrences(of: "%damage_high", with: "\(hi)")
        let name = target.stats.count == 1 ? target.stats.name : "\(target.stats.count) " + (t.creature(target.keyword)?.plural ?? target.stats.name)
        return (t.strings["attack.combat"] ?? "Attack %creature_name\nfor %damage").replacingOccurrences(of: "%creature_name", with: name).replacingOccurrences(of: "%damage", with: range).replacingOccurrences(of: "\n", with: " ")
    }

    /// Which combat cursor fits the cell under the pointer.
    func combatCursor(x: Float, y: Float) -> String {
        guard let cs = combat, let b = cs.battle, !cs.busy, cs.result == nil, let cur = b.current, cur.side == 0, x < 885 else { return "combat.normal" }
        let c = CombatScreen.cell(at: x, y)
        if let t = b.units.first(where: { $0.alive && $0.side == 1 && $0.x == c.0 && $0.y == c.1 }) {
            if cur.shots > 0, !combatMeleeMode, !b.units.contains(where: { $0.alive && $0.side == 1 && Battle.adjacent(cur, $0) }) { return "combat.shoot" }
            let names = ["e": "east", "w": "west", "n": "north", "s": "south", "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest"]
            let dir = Battle.facing(dx: t.x - cur.x, dy: t.y - cur.y)
            return "combat.melee.\(names[dir] ?? "east")"
        }
        return b.reachable(cur)[c.1 * Battlefield.columns + c.0] != nil ? "combat.walk" : "combat.normal"
    }
}
