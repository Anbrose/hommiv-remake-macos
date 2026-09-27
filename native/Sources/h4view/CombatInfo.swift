import Foundation
import H4Engine

/// The creature window of the combat screen (layers.dialog.combat.creature; combat_ui_spec §C),
/// opened by a right click on a stack or on the panel's portrait, drawn as heroes4.exe 0x6a2940
/// builds it: at ((W - 575) / 3, (H - 600) / 2); the parchment; the 82 portrait with its top-left
/// at `portrait` under Portrait_Ring; each stat icon followed by a Value_Background plaque at
/// (icon.x - 8, icon.y + 54); morale and luck always the neutral pictures; the ability (or hero
/// skill) icons at skill_1...5 under Abilities_Frame; the texts black without halo, centred both
/// ways in the font of the rect's height (Damage and N/A 16); the curses and blessings on the
/// stack, four at a time with a scrollbar past four; OK at ok_button's top-left.
extension Renderer {
    static let infoSize = (w: 575, h: 600)
    var infoOrigin: (Int, Int) { ((AdventureUI.width - Renderer.infoSize.w) / 3, (AdventureUI.height - Renderer.infoSize.h) / 2) }

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

    /// The spells on a stack (0x6a68b0): every effect flagged a curse (0x1000) or a blessing (0x200)
    /// in id order, the Robe of the Guardian first among the blessings.
    func unitSpells(_ u: Battle.Unit) -> (curses: [Int], blessings: [Int]) {
        var on = u.stats.effects.union(u.durations.keys)
        // the creature abilities' own flags stand for their spells
        let named: [(Bool, String)] = [(u.stats.cursed, "curse"), (u.stats.weakened, "weakness"), (u.stats.aged, "aging"), (u.boundBy != nil || u.stats.bound, "binding"),
                                       (u.poison > 0, "poison"), (u.hypnotized, "hypnotize")]
        for (flag, key) in named where flag { if let i = RuleTables.spells.firstIndex(where: { $0.keyword == key }) { on.insert(i) } }
        let ids = on.filter { $0 >= 0 && $0 < min(188, RuleTables.spells.count) }.sorted()
        var blessings = ids.filter { RuleTables.spells[$0].has("Bless") }
        if on.contains(191) { blessings.insert(191, at: 0) }
        return (ids.filter { RuleTables.spells[$0].has("Curse") }, blessings)
    }
    func spellIcon(id: Int) -> UILayer? {
        guard id >= 0, id < RuleTables.spells.count else { return nil }
        let s = RuleTables.spells[id]
        return iconSheet("spells.\(s.school).52")[s.name.lowercased()] ?? spellIcon(s.name) ?? spellIcon(s.keyword)
    }
    /// The ability row: a hero's skills (up to 5), a creature's abilities.
    func infoAbilities(_ u: Battle.Unit) -> [(key: String, icons: [UILayer])] {
        if u.stats.isHero, let h = combat?.heroFor(u) {
            return (0..<9).filter { h.skill(id: $0) > 0 }.prefix(5).map { ("skill\($0)", skillIcon($0, level: h.skill(id: $0))) }
        }
        let list = RuleTables.creatureAbilities[u.keyword.lowercased()] ?? Array(u.stats.abilities).sorted()
        let sheet = iconSheet("skills.creature.52")
        return list.prefix(5).map { ($0, sheet[$0.lowercased()].map { [$0] } ?? []) }
    }

    func combatInfoQuads() -> [Quad] {
        guard let cs = combat, let id = cs.info, let b = cs.battle, let ui = ui, let d = ui.dialog("combat.creature") else { return [] }
        let u = b.unit(id)
        let (ox, oy) = infoOrigin
        var out: [Quad] = []
        func img(_ name: String) { if let l = layer(d, name) { out.append(image(l, key: "dlg|combatcr|\(l.name)", ox + l.x, oy + l.y)) } }
        img("Background")
        // the 82 portrait, its top-left at `portrait`, the ring over it
        if let p = unitPortrait(u, size: 82) ?? unitPortrait(u, size: 52), let slot = layer(d, "portrait") {
            out.append(image(p, key: "p82|\(p.name)", ox + slot.x, oy + slot.y))
        }
        img("Portrait_Ring")
        // the stat icons, each followed by its plaque; morale and luck neutral (their values are never set)
        let vb = layer(d, "Value_Background")
        func plaque(_ x: Int, _ y: Int) { if let v = vb { out.append(image(v, key: "dlg|combatcr|Value_Background", ox + x - 8, oy + y + 54)) } }
        let mood = iconSheet("morale.44")
        for n in ["Damage", "Melee_Attack", "Melee_Defense", "Hit_Points", "Hits_Left", "morale", "luck", "Ranged_Attack", "Ranged_Defense", "Shots", "Spell_Points", "Movement", "Speed"] {
            guard let l = layer(d, n) else { continue }
            if n == "morale" || n == "luck" {
                if let ic = mood["0 \(n)"] { out.append(image(ic, key: "mood|\(ic.name)", ox + l.x + (l.width - ic.width) / 2, oy + l.y + (l.height - ic.height) / 2)) }
            } else { out.append(image(l, key: "dlg|combatcr|\(l.name)", ox + l.x, oy + l.y)) }
            plaque(l.x, l.y)
        }
        img("Curse_Icon"); img("Bless_Icon")
        // the ability / skill icons at skill_i's top-left, the frame over them
        for (k, a) in infoAbilities(u).enumerated() {
            guard let slot = layer(d, "skill_\(k + 1)") else { continue }
            for l in a.icons { out.append(image(l, key: "infoskill|\(a.key)|\(l.name)", ox + slot.x + l.x, oy + slot.y + l.y)) }
        }
        img("Abilities_Frame")
        // the texts (0x6a7020): black, no halo, centred both ways; font = the rect's height unless given
        func t(_ s: String, _ slot: String, _ size: Int = 0) {
            guard let l = layer(d, slot) else { return }
            out += textWindow(s, in: l, ox, oy, font: proseFont(size > 0 ? size : l.height), centre: true, vcentre: true)
        }
        let st = u.stats
        let def = game?.tables?.creature(u.keyword)
        func signed(_ v: Int) -> String { v == 0 ? "0" : v > 0 ? "+\(v)" : "\(v)" }
        if st.isHero, let h = cs.heroFor(u) {
            t(h.name, "Name", 23)
            t(text("class_level.dialog", "Level %level").replacingOccurrences(of: "%level", with: "\(h.level)"), "Level", 18)
            let k = h.classKeyword
            t(game?.tables?.strings[k] ?? k.split(separator: "_").map { $0.capitalized }.joined(separator: " "), "Class", 18)
        } else {
            let nm = st.count == 1 ? (def?.name ?? st.name) : (def?.plural ?? st.name)
            t("\(st.count) " + nm.prefix(1).uppercased() + nm.dropFirst(), "Name", 23)
            t(text("\(st.alignment.lowercased()).town", st.alignment.capitalized), "Alignment", 18)
        }
        let na = text("not_applicable.dialog", "N/A")
        // hit points, with the change from the creature's own in percent
        let baseHP = def?.hitPoints ?? st.hitPoints
        t(st.hitPoints != baseHP && baseHP > 0 ? "\(st.hitPoints) (\(signed((st.hitPoints - baseHP) * 100 / baseHP))%)" : "\(st.hitPoints)", "Hit_Points_Value", 23)
        t("\(max(0, st.hitPoints - st.wounds))", "Wounds_Value", 23)
        t("\(st.attack)", "Melee_Attack_Value", 23)
        t("\(max(1, st.damageLow))-\(max(1, st.cursed ? st.damageLow : st.damageHigh))", "Damage_Value", 16)
        if st.shooter {
            t("\(st.rangedAttack ?? st.attack)", "Ranged_Attack_Value", 23)
            t(st.has("unlimited_shots") ? text("infinity_abbreviation.misc", "Inf") : " \(u.shots) " + text("shots.dialog", "Shots"), "Shots_Value", 23)
        } else {
            t(na, "Ranged_Attack_Value", 16); t(na, "Shots_Value", 16)
        }
        t("\(st.defense)", "Melee_Defense_Value", 23)
        t("\(st.defense)", "Ranged_Defense_Value", 23)
        // movement in the shown units (points / 300), speed, each with the change from the creature's own
        let move = u.move / (st.aged ? 2 : 1) / 3, baseMove = def.map { $0.move / 3 } ?? move
        t(move != baseMove ? "\(move) (\(signed(move - baseMove)))" : "\(move)", "Movement_Value", 23)
        let speed = b.speed(u), baseSpeed = def?.speed ?? speed
        t(speed != baseSpeed && !st.isHero ? "\(speed) (\(signed(speed - baseSpeed)))" : "\(speed)", "Speed_Value", 23)
        t("\(u.caster?.spellPoints ?? 0)", "Spell_Points_Value", 23)
        t(signed(b.morale(u)), "morale_text", 20)
        t("0", "luck_text", 23)
        // the curses and blessings: slots 1 top-left, 2 bottom-left, 3 top-right, 4 bottom-right; the
        // icons 52x52 at the slots' top-left; past four a scrollbar pages them
        let spells = unitSpells(u)
        for (list, prefix, bar, page) in [(spells.curses, "curse_spell_", "curse_Scrollbar", cs.infoPages.0), (spells.blessings, "blessing_spell_", "blessing_scrollbar", cs.infoPages.1)] {
            for k in 0..<4 {
                let i = page * 4 + k
                guard i < list.count, let slot = layer(d, "\(prefix)\(k + 1)"), let ic = spellIcon(id: list[i]) else { continue }
                out.append(image(ic, key: "spell52|\(ic.name)", ox + slot.x, oy + slot.y))
            }
            if list.count > 4, let l = layer(d, bar) { out += verticalScrollbar(l, ox, oy, position: page, max: list.count - 1) }
        }
        out += buttonAt("ok", "Released", layer(d, "ok_button"), ox, oy)
        return out
    }

    /// A t_scrollbar (control.vertical_scroll): the up arrow at the top, the down arrow at the
    /// bottom, the track between and the thumb at the position.
    func verticalScrollbar(_ l: UILayer, _ ox: Int, _ oy: Int, position: Int, max m: Int) -> [Quad] {
        guard let f = combat?.layers("control.vertical_scroll"), let up = f["Up_Released"], let down = f["Down_Released"], let track = f["Background"], let thumb = f["Thumb"] else { return [] }
        let x = ox + l.x, y = oy + l.y
        var out = [Quad(texture: uiTexture("vscroll|track", { track.bitmap }), x: x, y: y + up.height, w: track.width, h: max(1, l.height - up.height - down.height))]
        out.append(image(up, key: "vscroll|up", x, y))
        out.append(image(down, key: "vscroll|down", x, y + l.height - down.height))
        let room = max(0, l.height - up.height - down.height - thumb.height)
        out.append(image(thumb, key: "vscroll|thumb", x + thumb.x, y + up.height + (m > 0 ? room * position / m : 0)))
        return out
    }

    /// A click while the creature window is open: OK closes it, the scrollbars' arrows page the
    /// spell lists, anywhere else closes it (the popup closes on a left release).
    func combatInfoClick(x: Float, y: Float) {
        guard let cs = combat, let id = cs.info, let b = cs.battle, let d = ui?.dialog("combat.creature") else { combat?.info = nil; return }
        let (ox, oy) = infoOrigin
        let spells = unitSpells(b.unit(id))
        for (k, bar, count) in [(0, "curse_Scrollbar", spells.curses.count), (1, "blessing_scrollbar", spells.blessings.count)] where count > 4 {
            guard let l = layer(d, bar), x >= Float(ox + l.x), x < Float(ox + l.x + l.width), y >= Float(oy + l.y), y < Float(oy + l.y + l.height) else { continue }
            let up = y < Float(oy + l.y + l.height / 2)
            var p = k == 0 ? cs.infoPages.0 : cs.infoPages.1
            p = max(0, min(count - 1, p + (up ? -1 : 1)))
            if k == 0 { cs.infoPages.0 = p } else { cs.infoPages.1 = p }
            return
        }
        cs.info = nil
    }

    /// The name and help of what is under the pointer in the creature window (ability or spell icon).
    func combatInfoTip(x: Float, y: Float) -> String? {
        guard let cs = combat, let id = cs.info, let b = cs.battle, let d = ui?.dialog("combat.creature") else { return nil }
        let u = b.unit(id)
        let (ox, oy) = infoOrigin
        func on(_ slot: String) -> Bool {
            guard let l = layer(d, slot) else { return false }
            return x >= Float(ox + l.x) && x < Float(ox + l.x + l.width) && y >= Float(oy + l.y) && y < Float(oy + l.y + l.height)
        }
        if !u.stats.isHero {
            let list = RuleTables.creatureAbilities[u.keyword.lowercased()] ?? Array(u.stats.abilities).sorted()
            for (k, a) in list.prefix(5).enumerated() where on("skill_\(k + 1)") {
                guard let info = game?.tables?.abilityInfo[a.lowercased()] else { return a }
                return "\(info.name): \(info.help)"
            }
        }
        let spells = unitSpells(u)
        for (k, s) in spells.curses.dropFirst(cs.infoPages.0 * 4).prefix(4).enumerated() where on("curse_spell_\(k + 1)") { return RuleTables.spells[s].name }
        for (k, s) in spells.blessings.dropFirst(cs.infoPages.1 * 4).prefix(4).enumerated() where on("blessing_spell_\(k + 1)") { return RuleTables.spells[s].name }
        return nil
    }

    /// A right click on the combat field or on the panel's portrait: the creature window for that stack.
    func combatInspect(x: Float, y: Float) {
        guard let cs = combat, let b = cs.battle else { return }
        cs.infoPages = (0, 0)
        if inside(cs.hotspot("creature_icon"), x, y) {
            cs.info = cs.actionMessage?.unit ?? cs.shownCurrent
            return
        }
        cs.info = x < 885 ? unitUnder(b, x: x, y: y)?.id : nil
    }
}
