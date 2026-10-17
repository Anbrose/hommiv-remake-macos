import Foundation
import H4Engine

/// A creature ability's icon in a creature window (t_skill_icon, vtable 0x994494; set_ability
/// 0x851c90): the ability's keyword and the icon's place on the canvas.
struct AbilitySlot {
    let keyword: String
    let rect: DRect
}

/// The ability icons of the creature windows and what they tell (re/ability_help_spec.md).
/// Resting the pointer on one: its name in the help balloon (t_skill_icon's help text +0x44 =
/// table.creature_abilities Name, 0x63eec0). Pressing the right button on one (vtable slot 20,
/// 0x852260): its Help Text (0x63f040) alone, first letter raised, in a basic dialog (0x844fd0:
/// t_basic_dialog, font 18) centred under the icon (0x845290: x = the icon's centre, y = its
/// bottom), kept on screen; it goes with the right button's release or any left press.
extension Renderer {
    /// A creature's abilities as the windows list them (the static lists 0x654820).
    func abilityKeywords(_ creature: String) -> [String] { RuleTables.creatureAbilities[creature.lowercased()] ?? [] }

    /// The army right-click window (and a neutral stack's): the abilities that have an icon, packed
    /// into Skill_1..5 (0x539f80).
    func armyInfoAbilities(_ creature: String) -> [String] {
        let sheet = iconSheet("skills.creature.52")
        return Array(abilityKeywords(creature).filter { sheet[$0.lowercased()] != nil }.prefix(5))
    }

    /// The icons of every creature window open now, the topmost window's only.
    func abilitySlots() -> [AbilitySlot] {
        guard let ui = ui, let g = game else { return [] }
        func slots(_ list: [String], _ rect: (Int, String) -> DRect?) -> [AbilitySlot] {
            list.enumerated().compactMap { k, a in rect(k, a).map { AbilitySlot(keyword: a, rect: $0) } }
        }
        // combat: the creature window over the field
        if inCombat {
            guard let cs = combat, let id = cs.info, let b = cs.battle, let d = ui.dialog("combat.creature") else { return [] }
            let u = b.unit(id)
            guard !u.stats.isHero else { return [] }
            let (ox, oy) = infoOrigin
            return slots(infoAbilities(u).map(\.key)) { k, _ in layer(d, "skill_\(k + 1)").map { DRect($0).offset(ox, oy) } }
        }
        // the army screen (on the map or in a town): the shown stack's abilities
        if let s = armySession {
            guard let d = ui.dialog("army.layout"), let st = armyScreenShown(s).item?.stack else { return [] }
            let (ox, oy) = armyOrigin
            let sheet = iconSheet("skills.creature.52")
            return slots(Array(abilityKeywords(st.creature).prefix(4))) { k, a in
                guard sheet[a.lowercased()] != nil, d["Abilities_Frame"] != nil else { return nil }
                return DRect(ox + Renderer.armyScreenAbilityColumns[k], oy + Renderer.armyScreenAbilityTop, 52, 52)
            }
        }
        // the town's dialogs: a recruit dialog over the castle window, or the castle window
        if townOpen != nil, let dlg = townDialog {
            switch dlg {
            case .recruit(let c, _, _): return recruitAbilitySlots(c)
            case .castle:
                guard let d = ui.dialog("Castle_Screen") else { return [] }
                let (ox, oy) = castleOrigin
                let base = d["Monster_1"].map { ($0.x, $0.y) } ?? (6, 4)
                let sheet = iconSheet("skills.creature.52")
                var out: [AbilitySlot] = []
                for (k, c) in castleCreatures().enumerated() where k < 5 {
                    guard let place = d[Renderer.castlePlaces[k]] else { continue }
                    let dx = place.x - base.0, dy = place.y - base.1
                    out += slots(Array(abilityKeywords(c).prefix(4))) { a, name in
                        sheet[name.lowercased()] == nil ? nil : castleRect(d, "Ability_\(a + 1)", dx, dy)?.offset(ox, oy)
                    }
                }
                return out
            default: return []
            }
        }
        // the map: a dwelling's recruit dialog, the army right-click window, a neutral stack's
        if let r = mapRecruit, let o = g.dwellingOffer(r.dwelling, for: r.hero) { return recruitAbilitySlots(o.creature.keyword) }
        guard let d = ui.dialog("army_right_click") else { return [] }
        let (ox, oy) = Renderer.armyInfoOrigin
        var shown: String? = nil
        if let ap = armyPopup, ap.hero < g.heroes.count {
            // the members are the heroes, then the stacks; one out of range shows the first (armyInfoQuads)
            let leader = g.heroes[ap.hero]
            let n = leader.members.count + leader.army.count
            let k = (0..<n).contains(ap.selected) ? ap.selected : 0
            if k >= leader.members.count, k - leader.members.count < leader.army.count { shown = leader.army[k - leader.members.count].creature }
        } else if let cd = creatureDialog { shown = cd.creature.keyword }
        guard let c = shown else { return [] }
        return slots(armyInfoAbilities(c)) { k, _ in d["Skill_\(k + 1)"].map { DRect($0).offset(ox, oy) } }
    }
    /// The recruit dialog's icons (Ability_1..4; an ability without an icon leaves its place).
    func recruitAbilitySlots(_ creature: String) -> [AbilitySlot] {
        guard let d = ui?.dialog("recruit") else { return [] }
        let (ox, oy) = recruitOrigin
        let sheet = iconSheet("skills.creature.52")
        return abilityKeywords(creature).prefix(4).enumerated().compactMap { k, a in
            guard sheet[a.lowercased()] != nil, let l = dLayer(d, "Ability_\(k + 1)") else { return nil }
            return AbilitySlot(keyword: a, rect: DRect(l).offset(ox, oy))
        }
    }

    /// The ability icon under a canvas point.
    func abilityAt(x: Float, y: Float) -> AbilitySlot? { abilitySlots().first { $0.rect.contains(x, y) } }
    /// Its name (the balloon) and its help (the right-click box).
    func abilityName(_ a: String) -> String { game?.tables?.abilityInfo[a.lowercased()]?.name ?? a }
    func abilityHelp(_ a: String) -> String {
        let t = game?.tables?.abilityInfo[a.lowercased()]?.help ?? ""
        return t.prefix(1).uppercased() + t.dropFirst()   // (0x845126)
    }

    /// A right press: on an ability icon, its help box opens (true).
    func abilityPress(x: Float, y: Float) -> Bool {
        guard let s = abilityAt(x: x, y: y) else { return false }
        let t = abilityHelp(s.keyword)
        guard !t.isEmpty else { return false }
        abilityPopup = (t, s.rect)
        return true
    }
    /// The help box: centred on the icon's middle, its top at the icon's bottom, on screen (0x5595d0).
    func abilityPopupQuads() -> [Quad] {
        guard let p = abilityPopup, let d = basicDialog(text: p.text) else { return [] }
        let x = min(max(0, p.rect.x + p.rect.w / 2 - d.W / 2), AdventureUI.width - d.W)
        let y = min(max(0, p.rect.y + p.rect.h), AdventureUI.height - d.H)
        return basicDialogQuads(d, x: x, y: y)
    }
}
