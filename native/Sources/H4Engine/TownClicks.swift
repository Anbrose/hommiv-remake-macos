import Foundation

/// The town view's building buttons (heroes4.exe t_town_window, re/town_clicks_spec.md): which
/// buildings have a button, which one is under the pointer, and what a click on it opens.
public enum TownView {
    /// The buttons per alignment in creation order (table 0x996488 via 0x8a32b0): later ones are
    /// drawn over, and hit before, earlier ones.
    public static let drawOrder: [String: [Int]] = [
        "life": [0, 1, 2, 11, 3, 4, 5, 7, 8, 14, 15, 16, 17, 18, 19, 10, 28, 29, 27, 20, 21, 22, 23, 24, 25, 26, 12, 13, 6, 9],
        "order": [3, 4, 5, 0, 1, 2, 11, 8, 7, 18, 19, 16, 17, 14, 15, 31, 10, 20, 21, 22, 23, 24, 25, 26, 9, 30, 12, 13, 6],
        "death": [0, 1, 2, 3, 4, 5, 7, 8, 11, 14, 15, 16, 17, 18, 19, 10, 20, 21, 22, 23, 24, 25, 26, 12, 13, 32, 33, 9, 6],
        "chaos": [11, 0, 1, 2, 3, 4, 5, 14, 15, 16, 17, 18, 19, 7, 8, 13, 35, 10, 26, 20, 21, 22, 23, 24, 25, 34, 12, 9, 6, 36],
        "nature": [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 38, 17, 16, 19, 18, 15, 14, 20, 21, 22, 23, 24, 25, 26, 39, 12, 13, 9, 37],
        "might": [11, 0, 1, 2, 3, 4, 5, 6, 7, 8, 18, 19, 16, 17, 14, 15, 40, 35, 42, 12, 13, 10, 41, 9],
    ]
    /// A built building hides the one it replaces (0xa85d08, applied transitively by 0x8a31f0).
    public static let supersedes: [Int: Int] = [1: 0, 2: 1, 4: 3, 5: 4, 21: 20, 22: 21, 23: 22, 24: 23]

    /// The shown buttons in creation order: built, not superseded, with a layout layer (0x8ae890
    /// makes no button when the layer is missing; 0x8af5f0 hides the rest).
    /// `keep`: replaced buildings still shown (a purchase's fade-out, re/town_build_fade_spec.md §3).
    public static func shown(alignment: String, built: (Int) -> Bool, layer: (Int) -> UILayer?, keep: Set<Int> = []) -> [(id: Int, layer: UILayer)] {
        let order = drawOrder[alignment] ?? []
        let isBuilt = Set(order.filter(built))
        var hidden = Set<Int>()
        for b in isBuilt { var x = b; while let lower = supersedes[x] { hidden.insert(lower); x = lower } }
        hidden.subtract(keep)
        return order.compactMap { b in
            guard isBuilt.contains(b), !hidden.contains(b), let l = layer(b), l.width > 0 else { return nil }
            return (b, l)
        }
    }

    // MARK: a purchase's fade (re/town_build_fade_spec.md)

    /// The town window's idle tick (0x748b00(0, 50) -> 0x8b4f30): every 50 ms.
    public static let fadeTickSeconds = 0.05
    /// The bought building's level (0..15) after `ticks` ticks (0x8b4c90 starts it at 0, each tick +1).
    public static func fadeLevel(ticks: Int) -> Int { max(0, min(15, ticks)) }
    /// The buildings it replaces stay at full until the first tick, which hides them (the fade-out
    /// branch at 0x8b5030 hides as soon as the level is above 0).
    public static func replacedShown(ticks: Int) -> Bool { ticks < 1 }
    /// The building's animation is created when its level reaches 15 (0x8b3c60).
    public static func animates(ticks: Int) -> Bool { fadeLevel(ticks: ticks) >= 15 }
    /// The blend weight of a level for an opaque pixel (0x592370): (L + ((L >> 3) & 1)) / 16.
    public static func fadeWeight(level: Int) -> Float {
        let l = max(0, min(15, level))
        return l >= 15 ? 1 : Float(l + ((l >> 3) & 1)) / 16
    }

    /// Is a layer's picture solid at a point of the 1280x825 view (0x5906a0: 4-bit alpha != 0)?
    public static func opaque(_ l: UILayer, _ x: Int, _ y: Int) -> Bool {
        let px = x - l.x, py = y - l.y
        guard px >= 0, py >= 0, px < l.width, py < l.height, px < l.bitmap.width, py < l.bitmap.height else { return false }
        return l.bitmap.pixels[(py * l.bitmap.width + px) * 4 + 3] > 0
    }

    /// The building under a point of the view (window hit test 0x720910): the view's foreground
    /// layers sit above every button (created after them), so an opaque foreground pixel takes
    /// the click; otherwise the topmost shown building whose picture is solid there.
    public static func building(at x: Int, _ y: Int, shown: [(id: Int, layer: UILayer)], foregrounds: [UILayer]) -> Int? {
        if foregrounds.contains(where: { opaque($0, x, y) }) { return nil }
        return shown.last { opaque($0.layer, x, y) }?.id
    }

    /// What a left click on a building opens (the handlers bound in 0x8aed50).
    public enum Action: Equatable {
        case buyBuilding          // 0x8b4a80 t_buy_building_window
        case castle               // 0x8b8310 t_castle_window (or "town.castle_no_dwellings")
        case buildShip            // 0x8b8f10
        case caravan              // 0x8bc390
        case prison               // 0x8b8680 t_town_prison_window
        case tavern               // 0x8b57a0 t_hire_hero_dialog
        case blacksmith           // 0x8b8060 t_blacksmith_window
        case recruit              // 0x8b50d0 t_recruit_dialog for the building's creature
        case mageGuild            // 0x8b7dd0 t_mage_guild_window (or "no_mage_guild.misc")
        case seminary             // 0x8b87a0 / 0x8b88b0 t_seminary_window (seminary, university)
        case treasury             // 0x8b9550
        case skeletonTransformer  // 0x8b8560 t_skeleton_transformer_window
        case manaVortex           // 0x8b9f40
        case creaturePortal       // 0x8b13b0
        case describe             // 0x8b9360: the building's name and help with OK
    }
    public static func leftClick(_ id: Int) -> Action {
        switch id {
        case 0, 1, 2: return .buyBuilding
        case 3, 4, 5: return .castle
        case 6: return .buildShip
        case 7: return .caravan
        case 8: return .prison
        case 9: return .tavern
        case 10: return .blacksmith
        case 12...19: return .recruit
        case 20...26: return .mageGuild
        case 27, 30: return .seminary
        case 31: return .treasury
        case 32: return .skeletonTransformer
        case 36: return .manaVortex
        case 37: return .creaturePortal
        default: return .describe
        }
    }
    /// A right click on any building describes it (0x8b9360 on every button's +0xd8).
    public static func rightClick(_ id: Int) -> Action { .describe }
}

extension GameState {
    /// The castle opens with any dwelling built, or the creature portal (0x8b8310).
    public func castleOpens(_ t: Town) -> Bool {
        (12...19).contains { isBuilt(t, $0) } || isBuilt(t, 37)
    }
    /// The blacksmith needs creatures or heroes in the garrison or the visiting army (0x8b8060, 0x63fcb0).
    public func blacksmithRefusal(town i: Int) -> String? {
        let t = towns[i]
        if t.garrison.contains(where: { $0.count > 0 }) || !t.garrisonHeroes.isEmpty { return nil }
        if visitingArmy(town: i) != nil { return nil }
        return text("no_armies_for_blacksmith.text", "There are no armies in town to make a purchase.")
    }
    /// Why a town dwelling's recruit dialog does not open (0x8b50d0): another's town, or no room
    /// in the garrison (0x8b1160, "no_room.town").
    public func townRecruitRefusal(town i: Int, creature: String) -> String? {
        let t = towns[i]
        if !t.owned { return text("town.buy_creatures_not_owner", "You can only buy creatures in your own towns.") }
        if !t.garrison.contains(where: { $0.creature == creature }) && garrisonCount(i) >= GameState.rowSlots {
            let name = tables?.creature(creature)?.plural ?? creature
            return text("no_room.town", "There is no room in your garrison to hire %creatures.").replacingOccurrences(of: "%creatures", with: name)
        }
        return nil
    }
    /// The treasury's left-click text (0x8b9550): "treasury_left_click.town" with yesterday's interest.
    public func treasuryText(town i: Int) -> String {
        text("treasury_left_click.town", "Provides an extra 10% gold per week.\n\nYesterday, you earned %material_list in interest.")
            .replacingOccurrences(of: "%material_list", with: towns[i].treasuryInterest > 0 ? materialList([(0, towns[i].treasuryInterest)]) : "0 gold")
    }
}
