import Foundation

/// The end of a battle as heroes4.exe sums it up (re/combat_results_spec.md): each side's
/// casualties for the results dialog and what a surrender costs.
extension Battle {
    /// One entry of a side's losses: `count` creatures of `keyword`, or a fallen hero (`hero` is
    /// its unit id; heroes are never merged).
    public struct Casualty: Equatable {
        public let keyword: String
        public var count: Int
        public let hero: Int?
        public init(keyword: String, count: Int, hero: Int? = nil) { self.keyword = keyword; self.count = count; self.hero = hero }
    }

    /// The losses array has the seven slots of a creature array (0x63faa0 drops what does not fit).
    public static let casualtySlots = 7

    /// A side's casualties (0x572f90 -> 0x40d0a0): for every stack that came from the army (summoned,
    /// raised and phantom stacks never count), in the order the stacks were made, the creatures of
    /// the army stack it came from that are not in it now; a hero that is dead at the end. Creature
    /// losses are merged by type into the first entry of that type, else the next free one, at most
    /// seven entries (0x63faa0). `wholeArmyLost` is the lost fight of 0x633390 (codes 0 / 4), which
    /// sets every stack of the beaten side to none first.
    public func casualties(side: Int, wholeArmyLost: Bool = false) -> [Casualty] {
        var out: [Casualty] = []
        for u in units where u.side == side && !u.summoned {
            let original = u.stats.isHero ? 1 : u.initialCount
            let now = wholeArmyLost ? 0 : (u.stats.isHero ? (u.alive ? 1 : 0) : u.stats.count)
            let lost = original - now
            guard lost > 0 else { continue }
            if u.stats.isHero {
                if out.count < Battle.casualtySlots { out.append(Casualty(keyword: u.keyword, count: 1, hero: u.id)) }
            } else if let i = out.firstIndex(where: { $0.hero == nil && $0.keyword == u.keyword }) {
                out[i].count += lost
            } else if out.count < Battle.casualtySlots {
                out.append(Casualty(keyword: u.keyword, count: lost))
            }
        }
        return out
    }

    /// Charm's and Diplomacy's share of the surrender price by skill level (0 none, 1 basic ...
    /// 5 grandmaster; heroes4.exe tables at 0x9946c0 / 0x9946d8, indexed -1...4).
    public static let surrenderCharmPercent = [100, 90, 80, 75, 70, 65]
    public static let surrenderDiplomacyPercent = [100, 80, 70, 60, 55, 50]

    /// The price of surrendering (0x5798c0): the gold cost of the creatures still alive plus
    /// 500 x (level + 1) for every hero of the army, dead or alive, times the smaller of the Charm and
    /// Diplomacy percentages of the side's best Charm and best Diplomacy, truncated.
    public static func surrenderCost(creatureGold: Int, heroes: [(level: Int, diplomacy: Int, charm: Int)]) -> Int {
        let sum = creatureGold + heroes.reduce(0) { $0 + 500 * ($1.level + 1) }
        let charm = min(max(heroes.map { $0.charm }.max() ?? 0, 0), 5)
        let diplomacy = min(max(heroes.map { $0.diplomacy }.max() ?? 0, 0), 5)
        let pct = min(surrenderCharmPercent[charm], surrenderDiplomacyPercent[diplomacy])
        return Int(Double(sum) * Double(Float(pct)) * 0.01)
    }

    /// The surrender price of `side`: its army stacks alive at their creatures' gold cost (`gold` by
    /// creature keyword), and its heroes.
    public func surrenderCost(side: Int, heroes: [Hero], gold: (String) -> Int) -> Int {
        let creatures = units.filter { $0.side == side && !$0.summoned && !$0.stats.isHero && $0.stats.count > 0 }
            .reduce(0) { $0 + $1.stats.count * gold($1.keyword) }
        return Battle.surrenderCost(creatureGold: creatures, heroes: heroes.map { ($0.level, $0.skill("diplomacy"), $0.skill("charm")) })
    }
}

extension GameState {
    /// A surrender is paid (0x579a30): the gold leaves the player's treasury for the winning
    /// (computer) player's, `to` its colour.
    public func paySurrender(_ cost: Int, to owner: Int) {
        resources["Gold", default: 0] -= cost
        aiResources[owner, default: GameState.startingResources]["Gold", default: 0] += cost
    }
}
