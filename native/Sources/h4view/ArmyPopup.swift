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
    var armyPopupOrigin: (Int, Int) { Renderer.armyInfoOrigin }

    /// An own army: level 4, "Your Army", the members (heroes, then the stacks).
    func armyPopupQuads() -> [Quad] {
        guard let ap = armyPopup, let g = game, ap.hero < g.heroes.count else { return [] }
        let leader = g.heroes[ap.hero]
        var members: [ArmyMember] = ([leader] + leader.companions).map { .hero($0) }
        members += leader.army.compactMap { st in g.tables?.creature(st.creature).map { .stack($0, st.count) } }
        let title = g.tables?.strings["right_click_title.your_army"] ?? "Your Army"
        return armyInfoQuads(members: members, level: 4, title: title, selected: ap.selected, owner: leader)
    }

    /// A left click with the window open: a member, Army, the cross, or outside (closes it).
    func armyPopupClick(x: Float, y: Float) {
        guard var ap = armyPopup, let g = game, ap.hero < g.heroes.count, let ui = ui, let d = ui.dialog("army_right_click") else { armyPopup = nil; return }
        let (ox, oy) = armyPopupOrigin
        let leader = g.heroes[ap.hero]
        let n = 1 + leader.companions.count + leader.army.count
        if let k = armyInfoSlot(x: x, y: y), k < n { ap.selected = k; armyPopup = ap; return }
        if inside(d["Army_Released"], at: ox, oy, x, y) {
            sound?.play("miscellaneous.button")
            heroShown = min(ap.selected, leader.companions.count)
            armyPopup = nil; adventureDialog = .hero(ap.hero); return
        }
        let w = Renderer.armyPopupSize
        if inside(d["Close_Button"], at: ox, oy, x, y) || inside(d["ok_button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + w.w) || y < Float(oy) || y >= Float(oy + w.h) { armyPopup = nil }
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
