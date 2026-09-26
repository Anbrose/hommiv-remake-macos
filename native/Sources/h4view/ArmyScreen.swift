import Foundation
import H4Engine

/// The army screen (t_army_dialog; army_screen_spec.md), drawn as the exe builds it: the layout's
/// Background; the hero list (Hero_Background, the paper doll at 264,147, the skills in columns
/// 30/90/147/204 under Skill_Frame, the backpack) or the creature list (Creature_Background with
/// its scroll and model frame, the model window, the abilities under Abilities_Frame, Dismiss);
/// OK, the formation toggles, the potion button, the spell book; one ring row (a single army:
/// Single_Ring_Background, pieces from x 147 at y 480) with split_Single; the stat icons, morale
/// and luck from icons.morale.34, the portrait under Portrait_Border; the texts in Prose_Antique,
/// black with the (200,200,200) halo; the army list (4 rows, arrows only past 4 armies).
extension Renderer {
    static let armyHalo: (UInt8, UInt8, UInt8) = (200, 200, 200)

    /// A text window (0x8859f0): the font of `size`, left or centred, optionally centred vertically as a block.
    func armyText(_ s: String, _ l: UILayer?, size: Int, centre: Bool, vcentre: Bool, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui, let l = l, !s.isEmpty else { return [] }
        let f = ui.font(size)
        let lines = s.components(separatedBy: "\n").flatMap { $0.isEmpty ? [""] : AdventureUI.wrap($0, font: f, width: l.width) }
        var y = l.y
        if vcentre, lines.count * f.lineHeight < l.height { y = l.y + (l.height - lines.count * f.lineHeight) / 2 }
        var out: [Quad] = []
        for (k, line) in lines.enumerated() where !line.isEmpty {
            let w = f.measure(line)
            let x = centre ? l.x + max(0, (l.width - w) / 2) : l.x
            out.append(Quad(texture: uiTexture("atext|\(size)|\(line)", { f.render(line, colour: (0, 0, 0), halo: Renderer.armyHalo) }), x: ox + x, y: oy + y + k * f.lineHeight, w: w, h: f.size))
        }
        return out
    }
    /// A layout layer at its own box (bitmap windows; kind-1 layers with a palette are images too).
    func layoutImage(_ d: LayerFile, _ name: String, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let l = d[name] ?? d.layers.first(where: { $0.name.lowercased() == name.lowercased() }) else { return [] }
        return [Quad(texture: uiTexture("army|\(l.name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height)]
    }
    /// A button file's state image with its top-left at a hotspot's top-left.
    func buttonAt(_ file: String, _ state: String, _ l: UILayer?, _ ox: Int, _ oy: Int) -> [Quad] {
        guard let ui = ui, let l = l else { return [] }
        let f = ((try? ui.archive.payload("layers.button.\(file).h4d")) ?? (try? ui.archive.payload("layers.Button.\(file).h4d"))).flatMap { try? LayerFile(data: $0) }
        guard let b = f?[state] ?? f?.layers.first(where: { $0.name.lowercased() == state.lowercased() }) else { return [] }
        return [Quad(texture: uiTexture("btn|\(file)|\(b.name)", { b.bitmap }), x: ox + l.x + b.x, y: oy + l.y + b.y, w: b.width, h: b.height)]
    }
    /// The single ring row's slot frames: pieces Left, Middle x5, Right laid from x 147, their tops at y 480.
    func armyRingSlots(_ ox: Int, _ oy: Int) -> [(piece: String, fx: Int, fy: Int)] {
        guard let ui = ui else { return [] }
        var cursor = 147
        var out: [(String, Int, Int)] = []
        for k in 0..<7 {
            let name = k == 0 ? "Left" : k == 6 ? "Right" : "Middle"
            guard let p = ui.creatureRing(name) else { continue }
            out.append((name, ox + cursor - p.x, oy + 480 - p.y))
            cursor += p.width
        }
        return out
    }

    func armyScreenQuads(_ i: Int) -> [Quad] {
        guard let g = game, let ui = ui, i < g.heroes.count, let d = ui.dialog("army.layout") else { return [] }
        let leader = g.heroes[i], army = [leader] + leader.companions
        let ox = (AdventureUI.width - 800) / 2, oy = (AdventureUI.height - 600) / 2
        let sel = min(heroShown, army.count + leader.army.count - 1)
        let hero: Hero? = sel < army.count ? army[sel] : nil
        let stack: Hero.Stack? = sel >= army.count ? leader.army[sel - army.count] : nil
        let creature = stack.flatMap { g.tables?.creature($0.creature) }
        var out = layoutImage(d, "Background", ox, oy)
        if let h = hero {
            out += layoutImage(d, "Hero_Background", ox, oy)
            // the doll (its Background at hero_inventory's top-left), the skills, the backpack
            out += heroThingsQuads(h, d, ox, oy)
        } else {
            out += layoutImage(d, "Creature_Background", ox, oy)
            if let st = stack { out += creatureModelQuads(st.creature, d, ox, oy) }
        }
        // buttons
        out += buttonAt("ok", "Released", d["ok_button"], ox, oy)
        for (n, on) in [("loose", true), ("tight", false), ("square", false)] { out += layoutImage(d, on ? "\(n)_pressed" : "\(n)_Released", ox, oy) }
        if stack != nil { out += buttonAt("dismiss", "Released", d["dismiss"], ox, oy) }
        out += buttonAt("hide_Potion", "Show_Potions_Released", d["Hide_Potions_Button"], ox, oy)
        if hero != nil || (creature?.spellPoints ?? 0) > 0 { out += layoutImage(d, "SpellBook_Released", ox, oy) }
        // the ring row
        out += layoutImage(d, "Single_Ring_Background", ox, oy)
        out += buttonAt("split_Single", "Released", d["Single_Split_Button"], ox, oy)
        let slots = armyRingSlots(ox, oy)
        var items: [(UILayer?, String?)] = army.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil) }
        items += leader.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
        for (k, s) in slots.enumerated() {
            let cx = s.fx + 41, cy = s.fy + 41
            if k < items.count, let icon = items[k].0 { out.append(Quad(texture: uiTexture("icon|\(icon.name)", { icon.bitmap }), x: cx - icon.width / 2, y: cy - icon.height / 2, w: icon.width, h: icon.height)) }
            if let p = ui.creatureRing(k == sel ? s.piece + "_Highlight" : s.piece) ?? ui.creatureRing(s.piece) {
                out.append(Quad(texture: uiTexture("cring|\(p.name)", { p.bitmap }), x: s.fx + p.x, y: s.fy + p.y, w: p.width, h: p.height))
            }
            if k < items.count { ringLabel(&out, ui: ui, cx: cx, cy: cy, count: items[k].1, hero: k < army.count) }
        }
        // stat icons, always
        for n in ["Spell_Points", "Damage", "Hit Points", "Move", "Speed", "Experience", "Shots", "Melee_Attack", "Melee_Defense", "Ranged_Attack", "Ranged_Defense"] { out += layoutImage(d, n, ox, oy) }
        // morale and luck: icons.morale.34 "%i Morale" / "%i Luck", centred in their 39x39 places
        let moraleArmy: [(alignment: String, undead: Bool)] = army.map { ($0.alignment, false) } + leader.army.compactMap { st in g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let bonus = ArmyBonuses(heroes: army)
        var morale = Battle.armyMorale(own: hero?.alignment ?? creature?.alignment ?? leader.alignment, army: moraleArmy)
        if let c = creature {
            if Combatant(creature: c, count: 1).has("undead") || Combatant(creature: c, count: 1).has("mechanical") { morale = 0 } else { morale += bonus.morale }
        }
        let luck = creature != nil ? bonus.luck : 0
        let icons = iconSheet("morale.34")
        for (slot, v, word) in [("Morale", min(10, max(-10, morale)), "morale"), ("Luck", min(10, max(-10, luck)), "luck")] {
            guard let l = d[slot], let ic = icons["\(v) \(word)"] else { continue }
            out.append(Quad(texture: uiTexture("moraleicon|\(ic.name)", { ic.bitmap }), x: ox + l.x + (l.width - ic.width) / 2, y: oy + l.y + (l.height - ic.height) / 2, w: ic.width, h: ic.height))
        }
        // the portrait (82 px, top-left at creature_portrait's) under Portrait_Border
        let portrait = hero.map { ui.portrait(keyword: $0.keyword, alignment: $0.alignment, size: 82) } ?? stack.map { ui.creatureIcon($0.creature, size: 82) }
        if let p = portrait ?? nil, let slot = d["creature_portrait"] {
            out.append(Quad(texture: uiTexture("p82|\(p.name)", { p.bitmap }), x: ox + slot.x, y: oy + slot.y, w: p.width, h: p.height))
        }
        out += layoutImage(d, "Portrait_Border", ox, oy)
        if stack != nil { out += layoutImage(d, "Abilities_Frame", ox, oy) } else { out += layoutImage(d, "Skill_Frame", ox, oy) }
        if let c = creature, let st = stack {
            let skills = iconSheet("skills.creature.52")
            let cols = [30, 90, 147, 204]
            for (k, ab) in (RuleTables.creatureAbilities[c.keyword.lowercased()] ?? []).prefix(4).enumerated() {
                if let l = skills[ab.lowercased()] { out.append(Quad(texture: uiTexture("skill|\(ab)", { l.bitmap }), x: ox + cols[k] + (52 - l.width) / 2, y: oy + 167 + (52 - l.height) / 2, w: l.width, h: l.height)) }
            }
            _ = st
        }
        // texts
        func t(_ s: String, _ slot: String, _ size: Int, centre: Bool = true, v: Bool = true) { out += armyText(s, d[slot], size: size, centre: centre, vcentre: v, ox, oy) }
        if let h = hero {
            t(h.name, "name_text", 16, centre: false, v: false)
            t(classLine(h), "class_text", 16, centre: false, v: false)
            let s = g.heroStats(h)
            t(s.damage, "Damage_Text", 14); t("\(s.hitPoints)", "Hit_Points_Text", 14)
            t("\(Int(h.movement))\n(\(Int(h.maxMovement)))", "Move_Text", 14); t("\(s.speed)", "Speed_Text", 14)
            t("\(s.shots)", "Shots_Text", 14); t(Renderer.grouped(h.experience), "Experience_Text", 20)
            t("\(s.attack)", "Melee_Attack_Text", 14); t("\(s.defense)", "Melee_Defense_Text", 14)
            t(s.shots > 0 ? "\(s.ranged)" : "N/A", "Ranged_Attack_Text", 14); t("\(s.defense)", "Ranged_Defense_Text", 14)
            t("\(g.spellPoints(h))\n(\(g.maxSpellPoints(h)))", "Spell_Points_Text", 14)
        } else if let c = creature, let st = stack {
            func tenths(_ v: Int, _ pct: Int) -> String {
                let x = Int((Double(v * (100 + pct)) / 10 + 0.5)); return x % 10 == 0 ? "\(x / 10)" : String(format: "%.1f", Double(x) / 10)
            }
            let ranged = c.shots > 0
            // the shown values (creature_info_spec §1): a shooter without normal melee strikes at half its
            // attack; insubstantial doubles defence, skeletal doubles it again against shots
            let ab = Set(RuleTables.creatureAbilities[c.keyword.lowercased()] ?? [])
            let melee = ranged && !ab.contains("normal_melee") ? c.attack / 2 : c.attack
            let defence = ab.contains("insubstantial") ? c.defense * 2 : c.defense
            let rangedDefence = ab.contains("skeletal") ? defence * 2 : defence
            t("\(st.count) \(st.count == 1 ? c.name : c.plural)", "name_text", 16, centre: false, v: false)
            t("\(c.damageLow)-\(c.damageHigh)", "Damage_Text", 14); t("\(c.hitPoints)", "Hit_Points_Text", 14)
            t("\(Int(leader.movement))\n(\(Int(leader.maxMovement)))", "Move_Text", 14); t("\(c.speed + bonus.speed)", "Speed_Text", 14)
            t(ranged ? "\(c.shots)" : "N/A", "Shots_Text", 14)
            t(tenths(melee, bonus.attackPercent), "Melee_Attack_Text", 14); t(tenths(defence, bonus.defensePercent), "Melee_Defense_Text", 14)
            t(ranged ? tenths(c.attack, bonus.attackPercent) : "N/A", "Ranged_Attack_Text", 14); t(tenths(rangedDefence, bonus.defensePercent), "Ranged_Defense_Text", 14)
            if c.spellPoints > 0 { t("\(c.spellPoints)", "Spell_Points_Text", 14) }
            t(c.longHelp, "creature_text", 20, centre: false, v: true)
        }
        t(morale > 0 ? "+\(morale)" : "\(morale)", "Morale_Text", 18); t(luck > 0 ? "+\(luck)" : "\(luck)", "Luck_Text", 18)
        // the army list: 4 rows at (706, 210 + 77k) of adventure.army_rings; arrows only past 4 armies
        if let list = d["Army_list"], let rings = (try? ui.archive.payload("layers.adventure.army_rings.h4d")).flatMap({ try? LayerFile(data: $0) }) {
            for (k, h) in g.heroes.prefix(4).enumerated() {
                let rx = ox + list.x, ry = oy + list.y + 77 * k
                if let p = rings["portrait"], let pic = ui.portrait(keyword: h.keyword, alignment: h.alignment) {
                    out.append(Quad(texture: uiTexture("icon|\(pic.name)", { pic.bitmap }), x: rx + p.x, y: ry + p.y, w: pic.width, h: pic.height))
                }
                if let f = rings[h === leader ? "Army_Frame_Highlight" : "Army_Frame"] ?? rings["Army_Frame"] {
                    out.append(Quad(texture: uiTexture("armyring|\(f.name)", { f.bitmap }), x: rx + f.x, y: ry + f.y, w: f.width, h: f.height))
                }
            }
            if g.heroes.count > 4 { out += layoutImage(d, "Army_Up_Released", ox, oy); out += layoutImage(d, "Army_Down_Released", ox, oy) }
        }
        return out
    }
}
