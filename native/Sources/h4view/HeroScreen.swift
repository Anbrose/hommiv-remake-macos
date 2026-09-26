import Foundation
import H4Engine

/// The parts of the hero screen (layers.dialog.army.layout) and the right-click window that show
/// a hero's own things: skills, worn artifacts and the backpack.
///
/// Skills: one row of the Skill_Frame per primary skill the hero knows (at most five), the
/// primary first and its known secondaries after it; icons from layers.icons.skills.<primary>.52
/// named by skill keyword, with the level's badge (Advanced / Expert / Master / Grandmaster
/// layers of the same sheet) over them. Artifacts: the class picture layers.dialog.army.<model>
/// has a hotspot per slot (Head, Neck, Left Hand, ...); icons are in layers.icons.artifacts.*
/// by artifact keyword.
extension Renderer {
    static let primarySheets = ["tactics", "combat", "scouting", "nobility", "life", "order", "death", "chaos", "nature"]

    /// The skill icon with its level badge, as layers to draw at a slot's origin.
    func skillIcon(_ id: Int, level: Int) -> [UILayer] {
        let sheet = iconSheet("skills.\(Renderer.primarySheets[RuleTables.primary(of: id)]).52")
        guard let icon = sheet[RuleTables.skillIds[id]] else { return [] }
        let badge = level >= 2 ? sheet[["advanced", "expert", "master", "grandmaster"][level - 2]] : nil
        return [icon] + (badge.map { [$0] } ?? [])
    }

    /// The rows of skills: each known primary with its known secondaries.
    func skillRows(_ h: Hero) -> [[Int]] {
        (0..<9).filter { h.skill(id: $0) > 0 }.map { p in [p] + (9..<36).filter { RuleTables.primary(of: $0) == p && h.skill(id: $0) > 0 } }
    }
    func skillName(_ id: Int, level: Int) -> (name: String, help: String) {
        let k = RuleTables.skillIds[id], l = RuleTables.skillLevelNames[max(0, min(4, level - 1))]
        return game?.tables?.skillTexts["\(k)_\(l)"] ?? (k.capitalized, "")
    }

    /// The artifact's icon (any of the four sheets) by id.
    func artifactIcon(_ id: Int) -> UILayer? {
        let id = RuleTables.artifactBase(id)
        guard id < RuleTables.artifactIds.count else { return nil }
        let k = RuleTables.artifactIds[id]
        for s in ["armor", "item", "weapon", "special"] { if let l = iconSheet("artifacts.\(s)")[k] { return l } }
        return nil
    }
    func artifactName(_ id: Int) -> (name: String, help: String) {
        let b = RuleTables.artifactBase(id)
        guard b < RuleTables.artifactIds.count else { return ("?", "") }
        let k = RuleTables.artifactIds[b]
        let a = game?.tables?.artifacts[k]
        return (game?.artifactName(id) ?? a?.name ?? k, a?.help ?? "")
    }
    /// The hero's paper doll layout (layers.dialog.army.<model>, e.g. death_might_male).
    func dollLayout(_ h: Hero) -> LayerFile? {
        ui?.dialog("army." + h.actor.replacingOccurrences(of: "hero.", with: ""))
    }
    static let slotLayers = ["Bow", "Feet", "Head", "Left Ring", "Misc_1", "Misc_2", "Misc_3", "Misc_4", "Neck", "Right Ring", "Left Hand", "shoulders", "torso", "Right Hand"]

    /// Where the skill icons of the hero screen go: (skill, level, x, y) in canvas coordinates.
    func heroSkillSlots(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [(id: Int, x: Int, y: Int)] {
        var out: [(Int, Int, Int)] = []
        let rows = [d["skill_1"]] + (2...5).map { d["skill_row_\($0)"] }
        for (r, ids) in skillRows(h).prefix(5).enumerated() {
            guard let row = rows[r] else { continue }
            let cols = [30, 90, 147, 204]   // skill_1..skill_4 x, for every row
            for (k, id) in ids.prefix(4).enumerated() { out.append((id, ox + cols[k], oy + row.y)) }
        }
        return out
    }
    /// Where the paper doll and backpack artifacts go: (artifact id, x, y) of 44x44 slots.
    func heroArtifactSlots(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> (doll: (x: Int, y: Int)?, items: [(id: Int, x: Int, y: Int)]) {
        var items: [(Int, Int, Int)] = []
        var doll: (Int, Int)? = nil
        if let inv = d["hero_inventory"], let m = dollLayout(h), let bg = m["Background"] {
            let dx = ox + inv.x, dy = oy + inv.y   // (top-left, 0x597f50)
            doll = (dx, dy)
            for (i, a) in h.equipped.enumerated() where i < 14 {
                if let a = a, let s = m[Renderer.slotLayers[i]] { items.append((a, dx + s.x, dy + s.y)) }
            }
        }
        for (k, a) in h.backpack.prefix(10).enumerated() {
            if let s = d["backpack \(k + 1) slot"] { items.append((a, ox + s.x, oy + s.y)) }
        }
        return (doll, items)
    }

    func heroThingsQuads(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [Quad] {
        var out: [Quad] = []
        for s in heroSkillSlots(h, d, ox, oy) {
            for l in skillIcon(s.id, level: h.skill(id: s.id)) {
                out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(s.id)", { l.bitmap }), x: s.x + l.x, y: s.y + l.y, w: l.width, h: l.height))
            }
        }
        let (doll, items) = heroArtifactSlots(h, d, ox, oy)
        if let (dx, dy) = doll, let m = dollLayout(h), let bg = m["Background"] {
            out.append(Quad(texture: uiTexture("doll|\(h.actor)", { bg.bitmap }), x: dx, y: dy, w: bg.width, h: bg.height))
        }
        for it in items {
            guard let l = artifactIcon(it.id) else { continue }
            out.append(Quad(texture: uiTexture("art|\(it.id)", { l.bitmap }), x: it.x + l.x, y: it.y + l.y, w: l.width, h: l.height))
        }
        return out
    }

    /// The name and help of a skill or artifact under the pointer on the hero screen.
    func heroThingTip(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int, x: Float, y: Float) -> String? {
        func at(_ sx: Int, _ sy: Int, _ size: Int) -> Bool { x >= Float(sx) && x < Float(sx + size) && y >= Float(sy) && y < Float(sy + size) }
        for s in heroSkillSlots(h, d, ox, oy) where at(s.x, s.y, 52) {
            let t = skillName(s.id, level: h.skill(id: s.id)); return t.help.isEmpty ? t.name : "\(t.name): \(t.help)"
        }
        for it in heroArtifactSlots(h, d, ox, oy).items where at(it.x, it.y, 44) {
            let t = artifactName(it.id); return t.help.isEmpty ? t.name : "\(t.name): \(t.help)"
        }
        return nil
    }

    /// "Level 15 General" (the class names are strings.Text rows keyed by class keyword).
    func classLine(_ h: Hero) -> String {
        let k = h.classKeyword
        let name = game?.tables?.strings[k] ?? k.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        return "Level \(h.level) \(name)"
    }

    enum ArtifactHit { case worn(Int), backpack(Int) }
    /// Which worn slot or backpack place is under the pointer (a place holding an artifact).
    func heroArtifactHit(_ h: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int, x: Float, y: Float) -> ArtifactHit? {
        func at(_ sx: Int, _ sy: Int) -> Bool { x >= Float(sx) && x < Float(sx + 44) && y >= Float(sy) && y < Float(sy + 44) }
        if let inv = d["hero_inventory"], let m = dollLayout(h), let bg = m["Background"] {
            let dx = ox + inv.x, dy = oy + inv.y   // (top-left, 0x597f50)
            for (i, a) in h.equipped.enumerated() where i < 14 && a != nil {
                if let s = m[Renderer.slotLayers[i]], at(dx + s.x, dy + s.y) { return .worn(i) }
            }
        }
        for k in h.backpack.indices.prefix(10) {
            if let s = d["backpack \(k + 1) slot"], at(ox + s.x, oy + s.y) { return .backpack(k) }
        }
        return nil
    }
}

extension Renderer {
    /// The army screen's creature mode (creature_info_spec §1): the creature's portrait, "N name",
    /// its abilities and long help, the stats -- attack and defense raised by the army's best
    /// Offense / Defense and worn items, speed by Tactics -- and the army's morale.
    func creatureModeQuads(_ leader: Hero, stack st: Hero.Stack, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let c = g.tables?.creature(st.creature) else { return [] }
        var out = dialogImages(d, key: "herodlg", at: ox, oy, skip: ["Ring_Pressed", "Move_Army_Up", "Move_Army_Down", "Move_Tombstone_up", "loose_Released", "loose_Disabled",
                                                               "tight_Pressed", "tight_Disabled", "square_Pressed", "square_Disabled", "Up_Disabled", "name_text", "creature_text",
                                                               "Double_Ring_Background", "Skill_Frame", "Abilities_Frame", "Army_Up_Highlighted", "Army_Up_Pressed", "Army_Down_Highlighted",
                                                               "Army_Down_Pressed", "SpellBook_Highlighted", "SpellBook_Pressed", "SpellBook_Released", "Ranged", "Ranged_Text",
                                                               "skill_row_2", "skill_row_3", "skill_row_4", "skill_row_5", "Experience", "Experience_Text"])
        // the abilities' frame and the scroll behind the description
        for n in ["Abilities_Frame"] { if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|army|\(n)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) } }
        if let slot = d["creature_portrait"], let p = ui.creatureIcon(st.creature, size: 82) {
            out.append(Quad(texture: uiTexture("cicon82|\(st.creature)", { p.bitmap }), x: ox + slot.x + (slot.width - p.width) / 2, y: oy + slot.y + (slot.height - p.height) / 2, w: p.width, h: p.height))
        }
        out += centred("\(st.count) \(st.count == 1 ? c.name : c.plural)", in: d["name_text"], at: ox, oy, font: ui.dateFont)
        let skills = iconSheet("skills.creature.52")
        for (k, a) in (RuleTables.creatureAbilities[c.keyword.lowercased()] ?? []).prefix(4).enumerated() {
            if let l = skills[a.lowercased()], let slot = d["skill_\(k + 1)"] {
                out.append(Quad(texture: uiTexture("skill|\(a)", { l.bitmap }), x: ox + slot.x + (slot.width - l.width) / 2, y: oy + slot.y + (slot.height - l.height) / 2, w: l.width, h: l.height))
            }
        }
        if let t = d["creature_text"], let box = ui.popupBitmap(clientW: t.width - 10, clientH: t.height + 40, size: "large") {
            out.append(Quad(texture: uiTexture("band|\(box.bitmap.width)x\(box.bitmap.height)", { box.bitmap }), x: ox + t.x + 5 - box.clientX, y: oy + t.y - 20 - box.clientY, w: box.bitmap.width, h: box.bitmap.height))
        }
        if let t = d["creature_text"] {
            out += paragraph(c.longHelp, in: UILayer(name: "", kind: 1, x: t.x + 5, y: t.y - 16, width: t.width - 10, height: t.height + 36, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, font: ui.font(18))
        }
        out += creatureModelQuads(st.creature, d, ox, oy)
        let bonus = ArmyBonuses(heroes: [leader] + leader.companions)
        func tenths(_ v: Int, _ pct: Int) -> String {   // shown with a decimal when the bonus leaves one (ftol(v x 10 + 0.5))
            let t = Int((Double(v * (100 + pct)) / 10 + 0.5))
            return t % 10 == 0 ? "\(t / 10)" : String(format: "%.1f", Double(t) / 10)
        }
        let ranged = c.shots > 0
        let army: [(alignment: String, undead: Bool)] = ([leader] + leader.companions).map { ($0.alignment, false) } + leader.army.compactMap { s in
            g.tables?.creature(s.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let noMorale = Combatant(creature: c, count: 1).has("undead") || Combatant(creature: c, count: 1).has("mechanical")
        let m = noMorale ? 0 : Battle.armyMorale(own: c.alignment, army: army) + bonus.morale
        let values: [(String, String)] = [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)"), ("Hit_Points_Text", "\(c.hitPoints)"),
                                          ("Melee_Attack_Text", tenths(c.attack, bonus.attackPercent)), ("Melee_Defense_Text", tenths(c.defense, bonus.defensePercent)),
                                          ("Ranged_Attack_Text", ranged ? tenths(c.attack, bonus.attackPercent) : "N/A"), ("Ranged_Defense_Text", tenths(c.defense, bonus.defensePercent)),
                                          ("Speed_Text", "\(c.speed + bonus.speed)"), ("Move_Text", "\(Int(leader.movement))\n(\(Int(leader.maxMovement)))"),
                                          ("Spell_Points_Text", c.spellPoints > 0 ? "\(c.spellPoints)" : ""), ("Shots_Text", ranged ? "\(c.shots)" : "N/A"),
                                          ("Morale_Text", m > 0 ? "+\(m)" : "\(m)"), ("Luck_Text", "\(bonus.luck)")]
        out += statTexts(values, d, ox, oy)
        return out
    }
    /// The stats in their boxes; "a\nb" as two lines (the current value over its maximum).
    func statTexts(_ values: [(String, String)], _ d: LayerFile, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui else { return [] }
        var out: [Quad] = []
        for (slot, v) in values {
            guard let l = d[slot] else { continue }
            let parts = v.components(separatedBy: "\n")
            if parts.count == 1 { out += centred(v, in: l, at: ox, oy, font: ui.font(16)); continue }
            let f = ui.font(12)
            for (k, p) in parts.enumerated() {
                out += centred(p, in: UILayer(name: "", kind: 1, x: l.x, y: l.y + k * (l.height / 2), width: l.width, height: l.height / 2, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, font: f)
            }
        }
        return out
    }
}

extension Renderer {
    /// The army screen's two rows of rings (Top / Bottom pieces tiled edge to edge in
    /// Double_Ring_Background): the frame origins of a row's seven places.
    func armyRingOrigins(_ d: LayerFile, row: Int, ox: Int, oy: Int) -> [(piece: String, x: Int, y: Int)] {
        guard let ui = ui, let bg = d["Double_Ring_Background"] else { return [] }
        let name = row == 0 ? "Top" : "Bottom"
        let pieces = (0..<7).map { $0 == 0 ? "\(name)_Left" : $0 == 6 ? "\(name)_Right" : name }
        let widths = pieces.map { ui.creatureRing($0).map { $0.width } ?? 60 }
        var cursor = ox + bg.x + (bg.width - widths.reduce(0, +)) / 2
        let top = ui.creatureRing("Top"), piece0 = ui.creatureRing(pieces[0])
        let cursorY = oy + bg.y + (row == 0 ? 0 : (top?.height ?? 72))
        var out: [(piece: String, x: Int, y: Int)] = []
        for (k, p) in pieces.enumerated() {
            let l = ui.creatureRing(p)
            out.append((p, cursor - (l?.x ?? 0), cursorY - (piece0?.y ?? 0)))
            cursor += widths[k]
        }
        return out
    }
    /// What the army screen shows around the hero or creature part (layers.dialog.army.layout):
    /// the morale and luck icons, the formation buttons, the tents (move up / down), the two rows of
    /// rings with the army in the upper one, split, the spell book and potion buttons, the kingdom's
    /// armies down the right, OK.
    func armyScreenChrome(_ leader: Hero, _ d: LayerFile, _ ox: Int, _ oy: Int, selected: Int) -> [Quad] {
        guard let g = game, let ui = ui else { return [] }
        var out: [Quad] = []
        func img(_ n: String) { if let l = d[n] { out.append(Quad(texture: uiTexture("dlg|army|\(n)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)) } }
        func button(_ file: String, _ state: String, in slot: String) {
            guard let s = d[slot], let f = ((try? ui.archive.payload("layers.button.\(file).h4d")) ?? (try? ui.archive.payload("layers.Button.\(file).h4d"))).flatMap({ try? LayerFile(data: $0) }), let b = f[state] ?? f.layers.first(where: { $0.name.lowercased() == state.lowercased() }) else { return }
            out.append(Quad(texture: uiTexture("button|\(file)|\(state)", { b.bitmap }), x: ox + s.x + (s.width - b.width) / 2, y: oy + s.y + (s.height - b.height) / 2, w: b.width, h: b.height))
        }
        // morale and luck: their icons (icons.morale.34 "+1 Morale", "0 Luck") by the numbers
        let army = [leader] + leader.companions
        let moraleArmy: [(alignment: String, undead: Bool)] = army.map { ($0.alignment, false) } + leader.army.compactMap { st in g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let m = Battle.armyMorale(own: leader.alignment, army: moraleArmy)
        let icons = iconSheet("morale.34")
        for (slot, v, word) in [("Morale", m, "morale"), ("Luck", 0, "luck")] {
            guard let s = d[slot], let ic = icons["\(v > 0 ? "+" : "")\(v) \(word)"] ?? icons["\(v) \(word)"] else { continue }
            out.append(Quad(texture: uiTexture("moraleicon|\(ic.name)", { ic.bitmap }), x: ox + s.x + (s.width - ic.width) / 2, y: oy + s.y + (s.height - ic.height) / 2, w: ic.width, h: ic.height))
        }
        img("loose_pressed"); img("tight_Released"); img("square_Released")
        // the tents: move the army down to / up from the second row (button.move_Down / move_Up)
        button("move_Down", "Released", in: "Move_Army_Down"); button("move_Up", "Released", in: "Move_Army_Up")
        img("Double_Ring_Background")
        // the rings: the army in the upper row, the lower one empty (another army's place)
        var slots: [(UILayer?, String?)] = army.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil) }
        slots += leader.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
        for row in 0...1 {
            let origins = armyRingOrigins(d, row: row, ox: ox, oy: oy)
            for o in origins { if let piece = ui.creatureRing(o.piece) { out.append(Quad(texture: uiTexture("cring|\(o.piece)", { piece.bitmap }), x: o.x + piece.x, y: o.y + piece.y, w: piece.width, h: piece.height)) } }
            guard row == 0 else { continue }
            for (k, (icon, count)) in slots.prefix(origins.count).enumerated() {
                let cx = origins[k].x + 41, cy = origins[k].y + 41
                if k == selected, let ring = ui.creatureRing("selected") ?? d["Ring_Pressed"] { out.append(Quad(texture: uiTexture("ringsel|\(ring.name)", { ring.bitmap }), x: cx - ring.width / 2, y: cy - ring.height / 2, w: ring.width, h: ring.height)) }
                if let icon = icon { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) }
                ringLabel(&out, ui: ui, cx: cx, cy: cy, count: count, hero: k < army.count)
            }
        }
        button("split", "Released", in: "split_button")
        if selected < army.count { img("SpellBook_Released") }
        button("hide_Potion", "Hide_Potions_Released", in: "Hide_Potions_Button")
        // the kingdom's armies down the right: their leaders' portraits, this one ringed
        if let list = d["Army_list"] {
            for (k, h) in g.heroes.prefix(3).enumerated() {
                let cy = oy + list.y + 12 + k * 100, cx = ox + list.x + list.width / 2
                if let p = ui.portrait(keyword: h.keyword, alignment: h.alignment) { out.append(Quad(texture: uiTexture("icon|\(p.name)", { p.bitmap }), x: cx - p.width / 2, y: cy + 14, w: p.width, h: p.height)) }
                if h === leader, let r = d["Ring_Pressed"] { out.append(Quad(texture: uiTexture("dlg|army|Ring_Pressed", { r.bitmap }), x: cx - r.width / 2, y: cy, w: r.width, h: r.height)) }
            }
            img("Army_Up_Released"); img("Army_Down_Released")
        }
        if let ok = d["ok_button"], let b = ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|ok|\(b.name)", { b.bitmap }), x: ox + ok.x + (ok.width - b.width) / 2, y: oy + ok.y + (ok.height - b.height) / 2, w: b.width, h: b.height))
        }
        if selected >= army.count { button("dismiss", "Released", in: "dismiss") }
        return out
    }
    /// The creature model window (t_combat_model_window, army_screen_spec §4) at creature_box: the
    /// alignment's 300x300 backdrop and the figures at scale min(212,216)/280, the backdrop centred
    /// and clipped; up to three figures in the i_of_n places (fewer while their frames do not fit),
    /// facing sw, each mostly in its wait loop, now and then another action or a walk in place.
    func creatureModelQuads(_ keyword: String, _ d: LayerFile, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let g = game, let ui = ui, let box = d["creature_box"], let c = g.tables?.creature(keyword) else { return [] }
        var out: [Quad] = []
        let sc = Float(min(box.width, box.height)) / 280
        let back = (try? ui.archive.payload("layers.control.creature_model.\(c.alignment.lowercased()).h4d")).flatMap { try? LayerFile(data: $0) }
        if let bg = back?.layers.first(where: { $0.isImage || $0.width >= 300 }) {
            // the part of the scaled backdrop inside the window: offset ((212 - 227) / 2, (216 - 227) / 2)
            let sw = Float(bg.width) * sc, sh = Float(bg.height) * sc
            let offX = Int((Float(box.width) - sw) / 2), offY = Int((Float(box.height) - sh) / 2)
            let cx0 = Int(Float(-offX) / sc), cy0 = Int(Float(-offY) / sc)
            let cw = min(bg.width - cx0, Int(Float(box.width) / sc)), ch = min(bg.height - cy0, Int(Float(box.height) / sc))
            out.append(Quad(texture: uiTexture("cmodel|\(c.alignment)|\(cx0),\(cy0)", {
                var b = Bitmap(width: cw, height: ch)
                for y in 0..<ch { for x in 0..<cw { for k in 0..<4 { b.pixels[(y * cw + x) * 4 + k] = bg.bitmap.pixels[((y + cy0) * bg.width + x + cx0) * 4 + k] } } }
                return b
            }), x: ox + box.x, y: oy + box.y, w: box.width, h: box.height))
        }
        guard let cs = combat, let places = (try? ui.archive.payload("layers.control.creature_model.h4d")).flatMap({ try? LayerFile(data: $0) }) else { return out }
        let actor = cs.actorName(c)
        guard let a = cs.actor(actor) else { return out }
        // the fitting sequence's bounding box (walk if it has one, else wait)
        let fit = a.state("walk") != nil ? "walk" : "wait"
        guard let (fs, _) = combatSprite(cs, actor: actor, state: fit, facing: "sw") else { return out }
        let frames = fs.frames
        let left = frames.map { Int(fs.origin.x) + $0.box.left }.min() ?? 0, right = frames.map { Int(fs.origin.x) + $0.box.right }.max() ?? 0
        let top = frames.map { Int(fs.origin.y) + $0.box.top }.min() ?? 0, bottom = frames.map { Int(fs.origin.y) + $0.box.bottom }.max() ?? 0
        let bw = right - left, bh = bottom - top
        var n = 3
        while n > 1, let pl = places["1_of_\(n)"], pl.width < bw || pl.height < bh { n -= 1 }
        let now = Date()
        for k in 1...n {
            guard let pl = places["\(k)_of_\(n)"] else { continue }
            let x = Float(pl.x * 2 + pl.width) * sc * 0.5
            let y = Float(pl.y * 2 + pl.height) * sc * 0.5 + Float(bh) * sc / 2 - Float(Int(Float(a.size * 16) * sc))
            let (state, t0) = modelFigureState(key: "\(keyword)|\(k)", actor: actor, a, now: now)
            guard let (s, entry) = combatSprite(cs, actor: actor, state: state, facing: "sw") ?? combatSprite(cs, actor: actor, state: "wait", facing: "sw") else { continue }
            let tl = s.timeline
            var f = s.frames.first, sh = f.flatMap { s.shadow(for: $0) }
            if !tl.isEmpty {
                let e = tl[Int(now.timeIntervalSince(t0) / max(0.03, cs.framePeriod(actor, state))) % tl.count]; f = e.frame; sh = e.shadow
            }
            let ax = Float(ox + box.x) + x, ay = Float(oy + box.y) + y
            for img in [sh, f].compactMap({ $0 }) {
                out.append(Quad(texture: texture(for: img, of: entry), x: Int(ax + (Float(s.origin.x) + Float(img.box.left)) * sc), y: Int(ay + (Float(s.origin.y) + Float(img.box.top)) * sc),
                                w: Int(Float(img.bitmap.width) * sc), h: Int(Float(img.bitmap.height) * sc)))
            }
        }
        return out
    }
    /// A model figure's action now (t_creature_model_figure 0x6041f0): wait loops ~2 s, then a random
    /// pick (block, cast, fidget, flinch, melee, ranged, wait, or prewalk -> walk ~6 s -> postwalk);
    /// any other action plays once and goes back to wait.
    func modelFigureState(key: String, actor: String, _ a: CombatActor, now: Date) -> (String, Date) {
        guard let cs = combat else { return ("wait", now) }
        var st = modelFigures[key] ?? (state: "wait", since: now, until: now.addingTimeInterval(2 + Double.random(in: 0...1.5)))
        if now >= st.until {
            let dur: (String) -> Double = { max(0.2, cs.stateDuration(actor, $0, "sw")) }
            var next = "wait"
            switch st.state {
            case "prewalk": next = "walk"
            case "walk": next = "postwalk"
            case "wait":
                let pick = ["block", "cast_spell", "fidget", "flinch", "melee", "ranged", "wait", "prewalk", "prewalk", "prewalk"][Int.random(in: 0..<10)]
                next = a.state(pick) != nil ? pick : "wait"
            default: next = "wait"
            }
            let length: Double
            switch next {
            case "wait": length = max(2, ceil(2 / dur("wait")) * dur("wait"))
            case "walk": length = max(dur("walk"), ceil(6 / dur("walk")) * dur("walk"))
            default: length = dur(next)
            }
            st = (next, now, now.addingTimeInterval(length))
        }
        modelFigures[key] = st
        return (st.state, st.since)
    }
}
