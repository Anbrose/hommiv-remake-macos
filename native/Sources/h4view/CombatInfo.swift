import Foundation
import H4Engine

/// The creature window of the combat screen (layers.dialog.combat.creature), opened by a right
/// click on a creature: portrait, name, level and alignment, its abilities as icons
/// (layers.icons.skills.creature.52, named by ability keyword), the current stats under their
/// icons, and the spells on it (curses left, blessings right, icons from layers.icons.spells.*.52).
extension Renderer {
    static let infoSize = (w: 575, h: 600)
    var infoOrigin: (Int, Int) { ((AdventureUI.width - Renderer.infoSize.w) / 2, (AdventureUI.height - Renderer.infoSize.h) / 2) }

    /// The icons of a sheet of layers.icons.*, by lower-cased name.
    func iconSheet(_ name: String) -> [String: UILayer] {
        if let s = iconSheets[name] { return s }
        var map: [String: UILayer] = [:]
        if let ui = ui, let d = try? ui.archive.payload("layers.icons.\(name).h4d"), let f = try? LayerFile(data: d) {
            for l in f.layers { map[l.name.lowercased()] = l }
        }
        iconSheets[name] = map
        return map
    }
    func spellIcon(_ name: String) -> UILayer? {
        for a in ["chaos", "death", "life", "order", "nature"] { if let l = iconSheet("spells.\(a).52")[name.lowercased()] { return l } }
        return nil
    }

    /// The spells an ability put on the unit (curses) and the ones that help it (blessings).
    func unitSpells(_ u: Battle.Unit) -> (curses: [String], blessings: [String]) {
        var c: [String] = []
        if u.stats.cursed { c.append("Curse") }
        if u.stats.weakened { c.append("Weakness") }
        if u.stats.aged { c.append("Aging") }
        if u.boundBy != nil { c.append("Binding") }
        if u.stunned > 0 { c.append("Stun") }
        if u.frozen > 0 { c.append("Freeze") }
        if u.blind > 0 { c.append("Blind") }
        if u.poison > 0 { c.append("Poison") }
        if u.hypnotized { c.append("Hypnotize") }
        return (c, [])
    }

    func combatInfoQuads() -> [Quad] {
        guard let cs = combat, let id = cs.info, let b = cs.battle, let ui = ui, let d = ui.dialog("combat.creature") else { return [] }
        let u = b.unit(id)
        let (ox, oy) = infoOrigin
        var out: [Quad] = []
        func image(_ name: String) {
            guard let l = d[name] else { return }
            out.append(Quad(texture: uiTexture("dlg|combatcr|\(name)", { l.bitmap }), x: ox + l.x, y: oy + l.y, w: l.width, h: l.height))
        }
        func icon(_ l: UILayer, key: String, in slot: String) {
            guard let s = d[slot] else { return }
            out.append(Quad(texture: uiTexture(key, { l.bitmap }), x: ox + s.x + (s.width - l.width) / 2, y: oy + s.y + (s.height - l.height) / 2, w: l.width, h: l.height))
        }
        func text(_ s: String, in name: String, font: H4Font) {
            guard let l = d[name], !s.isEmpty else { return }
            let w = font.measure(s)
            out.append(Quad(texture: uiTexture("dlgtext|\(font.size)|\(s)", { font.render(s, colour: (40, 24, 8)) }), x: ox + l.x + (l.width - w) / 2, y: oy + l.y + (l.height - font.size) / 2, w: w, h: font.size))
        }
        image("Background")
        for n in ["Abilities_Frame", "Damage", "Melee_Attack", "Melee_Defense", "Hit_Points", "Hits_Left", "Shots", "Ranged_Attack", "Ranged_Defense",
                  "Spell_Points", "Movement", "Speed", "Curse_Icon", "Bless_Icon"] { image(n) }
        // the morale picture only when morale struck this round
        if u.goodMorale { image("Good_Morale") } else if u.badMorale { image("Bad_Morale") }
        // the large portrait (layers.icons.creatures.82) centred in the ring
        // (a hero: its portrait, the alignment from its model "hero.<alignment>_...")
        let heroAlign = u.actor.hasPrefix("hero.") ? String(u.actor.dropFirst(5).prefix { $0 != "_" }) : "life"
        if let p = u.stats.isHero ? ui.portrait(keyword: u.keyword, alignment: heroAlign, size: 82) : ui.creatureIcon(u.keyword, size: 82) ?? ui.creatureIcon(u.keyword), let r = d["Portrait_Ring"] {
            out.append(Quad(texture: uiTexture("cicon82|\(u.keyword)", { p.bitmap }), x: ox + r.x + (r.width - p.width) / 2, y: oy + r.y + (r.height - p.height) / 2, w: p.width, h: p.height))
        }
        image("Portrait_Ring")
        let st = u.stats
        let def = game?.tables?.creature(u.keyword)
        func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        let name = st.count == 1 ? (def?.name ?? st.name) : (def?.plural ?? st.name)
        // the title scroll: "24 Bandits" and the alignment under it (a creature has no level or class line)
        text("\(st.count) \(cap(name))", in: "Name", font: ui.font(30))
        if !st.isHero { text(cap(st.alignment), in: "Alignment", font: ui.font(24)) }
        // abilities: the exe's order for the creature
        let list = RuleTables.creatureAbilities[u.keyword.lowercased()] ?? Array(st.abilities).sorted()
        let skills = iconSheet("skills.creature.52")
        for (k, a) in list.prefix(5).enumerated() {
            if let l = skills[a.lowercased()] { icon(l, key: "skill|\(a)", in: "Skill_\(k + 1)") }
        }
        let m = b.morale(u)
        // movement shows in thirds of the move points (heroes4.exe 0x6a5fb6: points / 300); a
        // creature that cannot shoot has N/A for shots and ranged attack
        let na = "N/A"
        let values: [(String, String)] = [
            ("Damage_Value", "\(st.damageLow)-\(st.cursed ? st.damageLow : st.damageHigh)"), ("Melee_Attack_Value", "\(st.attack)"),
            ("Melee_Defense_Value", "\(st.defense)"), ("Hit_Points_Value", "\(st.hitPoints)"), ("Wounds_Value", "\(st.hitPoints - st.wounds)"),
            ("morale_text", m > 0 ? "+\(m)" : "\(m)"), ("luck_text", "0"),
            ("Shots_Value", !st.shooter ? na : st.has("unlimited_shots") ? "-" : "\(u.shots)"), ("Ranged_Attack_Value", st.shooter ? "\(st.attack)" : na),
            ("Ranged_Defense_Value", "\(st.defense)"), ("Spell_Points_Value", "\(def?.spellPoints ?? 0)"),
            ("Movement_Value", "\(u.move / (st.aged ? 2 : 1) / 3)"), ("Speed_Value", "\(st.speed / (st.aged ? 2 : 1))")]
        // every value sits on the small scroll (the layout's one "Value_Background", repeated under each)
        if let vb = d["Value_Background"] {
            for (slot, _) in values {
                guard let l = d[slot] else { continue }
                out.append(Quad(texture: uiTexture("dlg|combatcr|Value_Background", { vb.bitmap }), x: ox + l.x + (l.width - vb.width) / 2, y: oy + l.y + (l.height - vb.height) / 2, w: vb.width, h: vb.height))
            }
        }
        for (slot, v) in values { text(v, in: slot, font: ui.font(22)) }
        // morale and luck pictures (layers.icons.morale.44: "<n> Morale", "<n> Luck")
        let mood = iconSheet("morale.44")
        if let l = mood["\(max(-10, min(10, m))) morale"] { icon(l, key: "morale|\(m)", in: "morale") }
        if let l = mood["0 luck"] { icon(l, key: "luck|0", in: "luck") }
        let spells = unitSpells(u)
        for (k, s) in spells.curses.prefix(4).enumerated() { if let l = spellIcon(s) { icon(l, key: "spell|\(s)", in: "curse_spell_\(k + 1)") } }
        for (k, s) in spells.blessings.prefix(4).enumerated() { if let l = spellIcon(s) { icon(l, key: "spell|\(s)", in: "blessing_spell_\(k + 1)") } }
        if let ok = d["ok_button"], let bt = ui.button("ok") {
            out.append(Quad(texture: uiTexture("button|ok", { bt.bitmap }), x: ox + ok.x + (ok.width - bt.width) / 2, y: oy + ok.y + (ok.height - bt.height) / 2, w: bt.width, h: bt.height))
        }
        return out
    }

    /// The name and help of what is under the pointer in the creature window (ability or spell icon).
    func combatInfoTip(x: Float, y: Float) -> String? {
        guard let cs = combat, let id = cs.info, let b = cs.battle, let ui = ui, let d = ui.dialog("combat.creature") else { return nil }
        let u = b.unit(id)
        let (ox, oy) = infoOrigin
        func inside(_ slot: String) -> Bool {
            guard let l = d[slot] else { return false }
            return x >= Float(ox + l.x) && x < Float(ox + l.x + l.width) && y >= Float(oy + l.y) && y < Float(oy + l.y + l.height)
        }
        let list = RuleTables.creatureAbilities[u.keyword.lowercased()] ?? Array(u.stats.abilities).sorted()
        for (k, a) in list.prefix(5).enumerated() where inside("Skill_\(k + 1)") {
            guard let info = game?.tables?.abilityInfo[a.lowercased()] else { return a }
            return "\(info.name): \(info.help)"
        }
        for (k, s) in unitSpells(u).curses.prefix(4).enumerated() where inside("curse_spell_\(k + 1)") { return s }
        return nil
    }

    /// A right click on the combat field: the creature window for the unit there.
    func combatInspect(x: Float, y: Float) {
        guard let cs = combat, let b = cs.battle else { return }
        cs.info = unitUnder(b, x: x, y: y)?.id
    }
}
