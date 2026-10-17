import Foundation

/// The Thieves Guild (t_thieves_guild_window, re/thieves_guild_spec.md): three bar graphs - towns,
/// armies, income - with a bar for every player of the game. HoMM4 has no information levels: all
/// players are always shown; there is no map object and the tavern does not open it.
public enum ThievesGuild {
    /// One graph: a value per player (in the map's player order) and the value of a full bar.
    public struct Graph: Equatable {
        public var colours: [Int]
        public var values: [Int]
        public var max: Int
        public init(colours: [Int], values: [Int], max: Int) { self.colours = colours; self.values = values; self.max = max }
        /// Bar heights; none when the graph's maximum is 0 (0x889bb0 / 0x88a0d0 draw nothing then).
        public func heights(full: Int = ThievesGuild.barFull) -> [Int] {
            max == 0 ? [] : values.map { ThievesGuild.barHeight(value: $0, max: max, full: full) }
        }
    }

    /// The bar image height (Red_Bar 16x259).
    public static let barFull = 259
    /// The armies graph's least full-bar value (0x88a8dd: 0x1770).
    public static let armyFloor = 6000

    /// 0x889239: full * value / max (integer), clamped to 1 ... full - an empty player still gets a sliver.
    public static func barHeight(value: Int, max: Int, full: Int = barFull) -> Int {
        guard max != 0 else { return 1 }
        return Swift.min(full, Swift.max(1, full * value / max))
    }
    /// The bars' left edges: centred in the graph, `stride` apart (0x889f1b).
    public static func barXs(count: Int, graphX: Int, graphW: Int, barW: Int, stride: Int) -> [Int] {
        guard count > 0 else { return [] }
        let first = graphX + graphW / 2 - ((count - 1) * stride + barW) / 2
        return (0..<count).map { first + $0 * stride }
    }
    /// The income bar's value: each material's daily income divided by its unit value (0x98c3a0),
    /// integer division per material (0x88a533) - wood and ore count from 125 a day, the precious ones from 250.
    public static func incomeValue(_ income: [Int]) -> Int {
        zip(income, GameState.materialValue).reduce(0) { $0 + $1.0 / $1.1 }
    }
    /// A creature-array value (0x6411d0): a stack is count x its Experience (0x63d920, record +0x74),
    /// a hero 100 x (level + 1) (0x730890).
    public static func armyValue(stacks: [(experience: Int, count: Int)], heroLevels: [Int]) -> Int {
        stacks.reduce(0) { $0 + $1.experience * $1.count } + heroLevels.reduce(0) { $0 + 100 * ($1 + 1) }
    }
    /// What a town adds to the income graph's full bar when placed (0x89a3ef): count the halls from the
    /// village hall that are built or allowed, looking at ids 0, 1, 2 and - the loop's `cmp esi,2; jg` -
    /// the fort once the city hall passed; 2 gives 1000, 1 gives 750, anything else 500. (Quirk kept:
    /// a town that can reach its city hall adds 500.)
    public static func townIncomeWeight(possible: (Int) -> Bool) -> Int {
        var k = 0
        while k <= 3, possible(k) {
            if k > 2 { break }
            k += 1
        }
        return k == 2 ? 1000 : k == 1 ? 750 : 500
    }
    /// What the other income sources add when placed: mines, abandoned mines and veins 1000 for gold,
    /// else 500 (0x79d7b0, 0x426ce0, 0x79e660); weekly generators 1000 / 7 for gold, else 75 (0x8ccb80).
    public enum Source { case mine, abandonedMine, vein, weeklyGenerator }
    public static func sourceIncomeWeight(_ s: Source, gold: Bool) -> Int {
        switch s {
        case .mine, .abandonedMine, .vein: return gold ? 1000 : 500
        case .weeklyGenerator: return gold ? 1000 / 7 : 75
        }
    }
}

extension GameState {
    /// The players in the map's order (the player vector [map+0x640], built once at game start).
    public var guildPlayers: [Int] {
        let specs = map.playerSpecs.map { $0.colour }
        return specs.isEmpty ? [map.humanColour] : specs
    }
    public func townColour(_ t: Town) -> Int? { t.owned ? map.humanColour : t.owner }
    func mineColour(_ m: Mine) -> Int? { m.owned ? map.humanColour : m.owner }
    /// A colour's armies on the map (the human's own heroes, or the computer's).
    func armies(of colour: Int) -> [Hero] {
        colour == map.humanColour ? heroes : enemyHeroes.filter { $0.owner == colour }
    }

    /// 0x7e2de0: everything a colour has under arms - its armies, its towns' garrisons, the adventure
    /// garrisons it holds, its heroes waiting in sanctuaries.
    public func armyStrength(of colour: Int) -> Int {
        let exp: (String) -> Int = { [tables] in tables?.creature($0)?.experience ?? 0 }
        var stacks: [(Int, Int)] = [], levels: [Int] = []
        for a in armies(of: colour) {
            levels += a.members.map { $0.level }
            stacks += a.army.map { (exp($0.creature), $0.count) }
        }
        for t in towns where townColour(t) == colour {
            stacks += t.garrison.map { (exp($0.creature), $0.count) }
            levels += t.garrisonHeroes.map { $0.level }
        }
        for st in objectStates.values where st.isGarrison && st.garrisonOwner == colour {
            stacks += zip(st.troopCreatures, st.troopCounts).map { (exp($0.0), $0.1) }
        }
        if colour == map.humanColour { levels += sanctuaryGuests.values.flatMap { $0.members.map { $0.level } } }
        return ThievesGuild.armyValue(stacks: stacks.map { (experience: $0.0, count: $0.1) }, heroLevels: levels)
    }

    /// 0x7e10f0: a colour's daily income by material - its mines, its towns, its heroes' estates and
    /// income artifacts.
    public func incomeByMaterial(of colour: Int) -> [Int] {
        var out = [Int](repeating: 0, count: GameState.materialNames.count)
        for m in mines where mineColour(m) == colour {
            if let k = GameState.materialNames.firstIndex(of: m.resource) { out[k] += m.amount }
        }
        for t in towns where townColour(t) == colour { out[0] += hallIncome(t) }
        for h in armies(of: colour).flatMap({ $0.members }) {
            for e in h.artifactEffects where e.type == 0x12 {
                for (m, n) in e.income.enumerated() where m < out.count { out[m] += n }
            }
            if h.skill("estates") > 0 { out[0] += 100 * h.skill("estates") * (10 + h.level) / 10 }
        }
        return out
    }

    /// The income graph's full bar ([map+0x9e8]): what every town, mine, abandoned mine, vein and weekly
    /// generator on the map added when it was placed.
    public var guildIncomeMax: Int {
        var total = 0
        for t in towns {
            total += ThievesGuild.townIncomeWeight { id in isBuilt(t, id) || isEnabled(t, id) }
        }
        for s in scenes {
            for p in s.placed {
                let gold = p.subtype.lowercased().contains("gold") || p.name.lowercased().contains("gold")
                switch p.type {
                case "mine", "random_mine": total += ThievesGuild.sourceIncomeWeight(.mine, gold: gold)
                case "abandoned_mine": total += ThievesGuild.sourceIncomeWeight(.abandonedMine, gold: gold)
                case "vein": total += ThievesGuild.sourceIncomeWeight(.vein, gold: p.subtype == "gold_vein")
                case "weekly_material_generator", "random_weekly_material_generator":
                    total += ThievesGuild.sourceIncomeWeight(.weeklyGenerator, gold: p.subtype == "water_wheel")
                default: break
                }
            }
        }
        return total
    }

    /// The three graphs as the window builds them (0x889bb0, 0x88a5c0, 0x88a0d0).
    public func thievesGuild() -> (towns: ThievesGuild.Graph, armies: ThievesGuild.Graph, income: ThievesGuild.Graph) {
        let players = guildPlayers
        let townCounts = players.map { c in towns.filter { townColour($0) == c }.count }
        let strengths = players.map { armyStrength(of: $0) }
        let incomes = players.map { ThievesGuild.incomeValue(incomeByMaterial(of: $0)) }
        return (ThievesGuild.Graph(colours: players, values: townCounts, max: towns.count),
                ThievesGuild.Graph(colours: players, values: strengths, max: max(ThievesGuild.armyFloor, strengths.max() ?? 0)),
                ThievesGuild.Graph(colours: players, values: incomes, max: guildIncomeMax))
    }
}
