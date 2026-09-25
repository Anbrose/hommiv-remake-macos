import Foundation
import H4Engine

/// The right-click window of an army (layers.dialog.army_right_click): its members in the row of
/// circles (heroes first), and under them the chosen one: name, level and class, alignment,
/// its five primary skills (a hero) or abilities (a creature), and its numbers. "Army" opens the
/// hero screen, the cross closes it.
struct ArmyPopup {
    var hero: Int        // index in game.heroes
    var selected = 0     // member of the army shown below (heroes, then the stacks)
}

extension Renderer {
    static let armyPopupSize = (w: 464, h: 494)
    var armyPopupOrigin: (Int, Int) { ((AdventureUI.mapViewportWidth - Renderer.armyPopupSize.w) / 2, (AdventureUI.height - Renderer.armyPopupSize.h) / 2) }

    /// The circles' centres (seven across creature_circles).
    func armyPopupCentres(_ d: LayerFile, _ ox: Int, _ oy: Int) -> [(Int, Int)] {
        guard let c = d["creature_circles"] else { return [] }
        return (0..<7).map { k in (ox + c.x + c.width * (2 * k + 1) / 14, oy + c.y + c.height / 2) }
    }

    func armyPopupQuads() -> [Quad] {
        guard let ap = armyPopup, let g = game, ap.hero < g.heroes.count, let ui = ui, let d = ui.dialog("army_right_click") else { return [] }
        let (ox, oy) = armyPopupOrigin
        let leader = g.heroes[ap.hero], heroes = [leader] + leader.companions
        // the background first (the file lists the Army button before it)
        var out = dialogImages(d, key: "armyrc", at: ox, oy, skip: Set(d.layers.map { $0.name }).subtracting(["Background"]))
        out += dialogImages(d, key: "armyrc", at: ox, oy, skip: ["Background", "Town_Released", "Close_Button"])
        let ink: (UInt8, UInt8, UInt8) = (40, 24, 8)
        // the members
        let centres = armyPopupCentres(d, ox, oy)
        var icons: [(UILayer?, String?)] = heroes.map { (ui.portrait(keyword: $0.keyword, alignment: $0.alignment), nil) }
        icons += leader.army.map { (ui.creatureIcon($0.creature), String($0.count)) }
        for (k, (icon, count)) in icons.prefix(7).enumerated() {
            let (cx, cy) = centres[k]
            if let l = icon { out.append(Quad(texture: uiTexture("icon|\(l.name)", { l.bitmap }), x: cx - l.width / 2, y: cy - l.height / 2 - 6, w: l.width, h: l.height)) }
            if let c = count { out += centred(c, in: UILayer(name: "", kind: 1, x: cx - ox - 25, y: cy - oy + 24, width: 50, height: 16, bitmap: Bitmap(width: 1, height: 1)), at: ox, oy, font: ui.numberFont, colour: ink) }
        }
        if ap.selected < icons.count, ap.selected < 7, let hl = ui.creatureRing("select") ?? nil {
            let (cx, cy) = centres[ap.selected]
            out.append(Quad(texture: uiTexture("cring|select", { hl.bitmap }), x: cx - hl.width / 2, y: cy - hl.height / 2, w: hl.width, h: hl.height))
        }
        var values: [(String, String)] = []
        if ap.selected < heroes.count {
            let h = heroes[ap.selected]
            out += centred(h.name, in: d["Title"], at: ox, oy, font: ui.dateFont)
            out += centred(classLine(h), in: d["Level"], at: ox, oy, font: ui.numberFont)
            out += centred(h.alignment.capitalized, in: d["Alignment"], at: ox, oy, font: ui.numberFont)
            if h.skill(id: 17) > 0 { out += centred(skillName(17, level: h.skill(id: 17)).name, in: d["Stealth"], at: ox, oy, font: ui.numberFont) }
            for (k, p) in (0..<9).filter({ h.skill(id: $0) > 0 }).prefix(5).enumerated() {
                guard let slot = d["Skill_\(k + 1)"] else { continue }
                for l in skillIcon(p, level: h.skill(id: p)) {
                    out.append(Quad(texture: uiTexture("skillicon|\(l.name)|\(p)", { l.bitmap }), x: ox + slot.x + 1 + l.x, y: oy + slot.y + l.y, w: l.width, h: l.height))
                }
            }
            let s = g.heroStats(h)
            values = [("Damage_Text", s.damage), ("Melee_Attack_Text", "\(s.attack)"), ("Melee_Defense_Text", "\(s.defense)"), ("Hit_Points_Text", "\(s.hitPoints)"),
                      ("Speed_Text", "\(s.speed)"), ("Movement_Text", "\(Int(leader.movement.rounded()))/\(Int(leader.maxMovement))"),
                      ("Shots_Text", "0"), ("Ranged_Attack_Text", "\(s.attack)"), ("Ranged_Defense_Text", "\(s.defense)"), ("Spell_Points_Text", "0"),
                      ("Experience_Text", "\(h.experience)"), ("Luck_Text", "0")]
        } else if let st = leader.army[safe: ap.selected - heroes.count], let c = g.tables?.creature(st.creature) {
            out += centred("\(st.count) \(st.count == 1 ? c.name : c.plural)", in: d["Title"], at: ox, oy, font: ui.dateFont)
            out += centred("Level \(c.level)", in: d["Level"], at: ox, oy, font: ui.numberFont)
            out += centred(c.alignment.capitalized, in: d["Alignment"], at: ox, oy, font: ui.numberFont)
            let skills = iconSheet("skills.creature.52")
            for (k, a) in (RuleTables.creatureAbilities[c.keyword.lowercased()] ?? []).prefix(5).enumerated() {
                if let l = skills[a.lowercased()], let slot = d["Skill_\(k + 1)"] {
                    out.append(Quad(texture: uiTexture("skill|\(a)", { l.bitmap }), x: ox + slot.x + (slot.width - l.width) / 2, y: oy + slot.y + (slot.height - l.height) / 2, w: l.width, h: l.height))
                }
            }
            values = [("Damage_Text", "\(c.damageLow)-\(c.damageHigh)"), ("Melee_Attack_Text", "\(c.attack)"), ("Melee_Defense_Text", "\(c.defense)"),
                      ("Hit_Points_Text", "\(c.hitPoints)"), ("Speed_Text", "\(c.speed)"), ("Movement_Text", "\(c.move / 3)"),
                      ("Shots_Text", c.shots > 0 ? "\(c.shots)" : "N/A"), ("Ranged_Attack_Text", c.shots > 0 ? "\(c.attack)" : "N/A"),
                      ("Ranged_Defense_Text", "\(c.defense)"), ("Spell_Points_Text", "\(c.spellPoints)"), ("Experience_Text", "\(c.experience)"), ("Luck_Text", "0")]
        }
        let army: [(alignment: String, undead: Bool)] = heroes.map { ($0.alignment, false) } + leader.army.compactMap { st in
            g.tables?.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let m = Battle.armyMorale(own: leader.alignment, army: army)
        values.append(("Morale_Text", m > 0 ? "+\(m)" : "\(m)"))
        for (slot, v) in values { out += centred(v, in: d[slot], at: ox, oy, font: ui.numberFont) }
        let mood = iconSheet("morale.44")
        for (slot, name) in [("Morale", "\(max(-10, min(10, m))) morale"), ("Luck", "0 luck")] {
            if let l = mood[name], let s = d[slot] { out.append(Quad(texture: uiTexture("mood|\(name)", { l.bitmap }), x: ox + s.x + (s.width - l.width) / 2, y: oy + s.y + (s.height - l.height) / 2, w: l.width, h: l.height)) }
        }
        if let s = d["Close_Button"], let b = ui.button("close") ?? ui.button("cancel") {
            out.append(Quad(texture: uiTexture("button|\(b.name)|close", { b.bitmap }), x: ox + s.x + (s.width - b.width) / 2, y: oy + s.y + (s.height - b.height) / 2, w: b.width, h: b.height))
        }
        return out
    }

    /// A left click with the window open: a member, Army, the cross, or outside (closes it).
    func armyPopupClick(x: Float, y: Float) {
        guard var ap = armyPopup, let g = game, ap.hero < g.heroes.count, let ui = ui, let d = ui.dialog("army_right_click") else { armyPopup = nil; return }
        let (ox, oy) = armyPopupOrigin
        let leader = g.heroes[ap.hero]
        let n = 1 + leader.companions.count + leader.army.count
        for (k, c) in armyPopupCentres(d, ox, oy).enumerated() where k < n && abs(x - Float(c.0)) < 28 && abs(y - Float(c.1)) < 40 {
            ap.selected = k; armyPopup = ap; return
        }
        if inside(d["Army_Released"], at: ox, oy, x, y) {
            sound?.play("miscellaneous.button")
            heroShown = min(ap.selected, leader.companions.count)
            armyPopup = nil; adventureDialog = .hero(ap.hero); return
        }
        let w = Renderer.armyPopupSize
        if inside(d["Close_Button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + w.w) || y < Float(oy) || y >= Float(oy + w.h) { armyPopup = nil }
    }

    /// The name and help of a skill under the pointer, on the hero screen or the right-click window.
    func heroWindowTip(x: Float, y: Float) -> String? {
        guard let g = game, let ui = ui else { return nil }
        if let ap = armyPopup, ap.hero < g.heroes.count, let d = ui.dialog("army_right_click") {
            let (ox, oy) = armyPopupOrigin
            let heroes = [g.heroes[ap.hero]] + g.heroes[ap.hero].companions
            guard ap.selected < heroes.count else { return nil }
            let h = heroes[ap.selected]
            for (k, p) in (0..<9).filter({ h.skill(id: $0) > 0 }).prefix(5).enumerated() where inside(d["Skill_\(k + 1)"], at: ox, oy, x, y) {
                let t = skillName(p, level: h.skill(id: p)); return "\(t.name): \(t.help)"
            }
            return nil
        }
        if case .hero(let i)? = adventureDialog, i < g.heroes.count, let d = ui.dialog("army.layout") {
            let army = [g.heroes[i]] + g.heroes[i].companions
            return heroThingTip(army[min(heroShown, army.count - 1)], d, (AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2, x: x, y: y)
        }
        return nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
