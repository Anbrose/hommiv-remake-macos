import Foundation
import H4Engine

/// The right-click window of an army, a town's garrison or a garrison object
/// (t_army_info_window, re/town_popup_spec.md): the seven places of its creature array in the
/// row of circles, and under them the chosen member: name, level and class, alignment, its five
/// primary skills (a hero) or abilities (a creature), and its numbers -- what is shown depends on
/// the information level (GameState.infoLevel, 0x4faf40). At level 4 an army gets "Army" (the
/// army screen) and a town "Town" (the town screen); the cross closes it.
struct ArmyPopup {
    enum Source {
        case army(Hero)            // the player's or another colour's army
        case town(Int)             // index in game.towns: its garrison
        case garrison(MapScene.Placed)
    }
    var source: Source
    var selected: Int? = nil     // the place shown below; nil = the first filled place (0x64fb00)

    init(army: Hero, selected: Int? = nil) { source = .army(army); self.selected = selected }
    init(town: Int) { source = .town(town) }
    init(garrison: MapScene.Placed) { source = .garrison(garrison) }
}

extension Renderer {
    static let armyPopupSize = (w: 464, h: 494)
    var armyPopupOrigin: (Int, Int) { Renderer.armyInfoOrigin }

    /// What the window shows: the array's places, the information level, the title, the army
    /// (morale, luck, movement), the town (the Town button).
    struct ArmyPopupContent {
        var slots: [ArmyMember?]
        var level: Int
        var title: String
        var army: Hero?
        var town: Int?
        /// Whose alignment morale is reckoned from (nil: the shown member's).
        var moraleAlignment: String?
        /// The place shown below: the chosen one, else the first filled one.
        func shown(_ selected: Int?) -> Int? {
            if let k = selected, slots.indices.contains(k), slots[k] != nil { return k }
            return slots.firstIndex { $0 != nil }
        }
    }

    func armyMembers(_ row: [ArmySlot?]) -> [ArmyMember?] {
        row.map { s -> ArmyMember? in
            switch s {
            case .hero(let h)?: return .hero(h)
            case .stack(let st)?: return game?.tables?.creature(st.creature).map { .stack($0, st.count) }
            case nil: return nil
            }
        }
    }

    func armyPopupContent(_ ap: ArmyPopup) -> ArmyPopupContent? {
        guard let g = game else { return nil }
        let strings = g.tables?.strings ?? [:]
        switch ap.source {
        case .army(let h):
            // 0x53c480: your_army for the player's colour, else "%Color Army" with the owner's colour
            let own = g.heroes.contains { $0 === h }
            let title: String
            if own { title = strings["right_click_title.your_army"] ?? "Your Army" }
            else {
                let colour = Renderer.colourKeys[min(max(0, h.owner), Renderer.colourKeys.count - 1)]
                let name = strings["\(colour).color"] ?? colour.capitalized
                title = (strings["right_click_title.other_army"] ?? "%Color Army").replacingOccurrences(of: "%Color", with: name).replacingOccurrences(of: "%color", with: name.lowercased())
            }
            return ArmyPopupContent(slots: armyMembers(g.armySlots(h)), level: g.infoLevel(army: h), title: title, army: h, town: nil, moraleAlignment: h.alignment)
        case .town(let i):
            guard g.towns.indices.contains(i) else { return nil }
            // a town's array has no owning army: the title is the town's name (0x53c6ac, t_town vt+4)
            return ArmyPopupContent(slots: armyMembers(g.garrisonSlots(i)), level: g.infoLevel(town: i), title: g.towns[i].name, army: nil, town: i,
                                    moraleAlignment: g.towns[i].garrisonHeroes.first?.alignment)
        case .garrison(let p):
            let st = g.objectStates["\(g.level)|\(p.cellX)|\(p.cellY)"] ?? ObjectState()
            let row: [ArmyMember?] = zip(st.troopCreatures, st.troopCounts).filter { $0.1 > 0 }.map { c, n in g.tables?.creature(c).map { .stack($0, n) } }
            let title = g.describe(p).title
            return ArmyPopupContent(slots: Array((row + Array(repeating: nil, count: 7)).prefix(7)), level: g.infoLevel(p, owner: g.flagOwner(of: p)), title: title, army: nil, town: nil,
                                    moraleAlignment: nil)
        }
    }

    static let colourKeys = ["red", "blue", "green", "orange", "purple", "teal", "gray"]

    func armyPopupQuads() -> [Quad] {
        guard let ap = armyPopup, let c = armyPopupContent(ap) else { return [] }
        return armyInfoQuads(slots: c.slots, level: c.level, title: c.title, selected: c.shown(ap.selected), army: c.army, moraleAlignment: c.moraleAlignment,
                             button: c.level >= 4 ? (c.town != nil ? "Town_Released" : c.army != nil ? "Army_Released" : nil) : nil)
    }

    /// A left click with the window open: a member, Army / Town, the cross, or outside (closes it).
    func armyPopupClick(x: Float, y: Float) {
        guard var ap = armyPopup, let g = game, let c = armyPopupContent(ap), let ui = ui, let d = ui.dialog("army_right_click") else { armyPopup = nil; return }
        let (ox, oy) = armyPopupOrigin
        if let k = armyInfoSlot(x: x, y: y), c.slots.indices.contains(k), c.slots[k] != nil { ap.selected = k; armyPopup = ap; return }
        if c.level >= 4, let i = c.town, inside(d["Town_Released"], at: ox, oy, x, y) {   // 0x53ecd0: the town screen
            sound?.play("miscellaneous.button")
            armyPopup = nil; townOpen = i; return
        }
        if c.level >= 4, let h = c.army, inside(d["Army_Released"], at: ox, oy, x, y) {
            sound?.play("miscellaneous.button")
            armyPopup = nil
            if g.heroes.contains(where: { $0 === h }) { openArmyScreen(h, item: armyItem(h, place: c.shown(ap.selected) ?? 0)) }
            return
        }
        let w = Renderer.armyPopupSize
        if inside(d["Close_Button"], at: ox, oy, x, y) || inside(d["ok_button"], at: ox, oy, x, y) || x < Float(ox) || x >= Float(ox + w.w) || y < Float(oy) || y >= Float(oy + w.h) { armyPopup = nil }
    }

    /// The army screen's item (heroes, then the stacks) of a place of the army's row.
    func armyItem(_ h: Hero, place k: Int) -> Int {
        guard let g = game else { return 0 }
        let row = g.armySlots(h)
        guard row.indices.contains(k), let s = row[k] else { return 0 }
        if let hero = s.hero { return h.members.firstIndex { $0 === hero } ?? 0 }
        let before = row.prefix(k).compactMap { $0?.stack }.count
        return h.members.count + before
    }

    /// The hero shown in the right-click window, if the shown member is one.
    var armyPopupHero: Hero? {
        guard let ap = armyPopup, let c = armyPopupContent(ap), let k = c.shown(ap.selected), case .hero(let h)? = c.slots[k] else { return nil }
        return h
    }

    /// The name and help of a skill under the pointer, on the hero screen or the right-click window.
    func heroWindowTip(x: Float, y: Float) -> String? {
        guard let ui = ui else { return nil }
        if let ap = armyPopup, let d = ui.dialog("army_right_click") {
            guard let h = armyPopupHero, let c = armyPopupContent(ap), c.level >= 3 else { return nil }
            let (ox, oy) = armyPopupOrigin
            for (k, p) in (0..<9).filter({ h.skill(id: $0) > 0 }).prefix(5).enumerated() where inside(d["Skill_\(k + 1)"], at: ox, oy, x, y) {
                let t = skillName(p, level: h.skill(id: p)); return "\(t.name): \(t.help)"
            }
            return nil
        }
        if armySession != nil, let h = sessionHero, let d = ui.dialog("army.layout") {
            return heroThingTip(h, d, (AdventureUI.width - 800) / 2, (AdventureUI.height - 600) / 2, x: x, y: y)
        }
        return nil
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
