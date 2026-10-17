import Foundation

/// The computer players' economy as heroes4.exe runs it (re/ai_economy_spec.md, re/ai_buildings_spec.md,
/// re/ai_purchase_spec.md): starting treasuries by difficulty, the computer's income handicap, the
/// shared town purchase path, the emergency defence of threatened towns and the difficulty factors
/// of its battle predictions.
extension GameState {
    // MARK: starting treasuries (0x7e1030, table 0x98e9e8)

    /// Gold, wood, ore and each precious material, row = difficulty for a human, difficulty + 5
    /// for a computer player (0x4cf785: is_computer = no human player of the colour, 0x4d8760).
    static let startingTable: [[Int]] = [
        [20000, 20, 20, 10], [15000, 15, 15, 7], [10000, 10, 10, 5], [5000, 10, 10, 5], [0, 10, 10, 5],
        [0, 10, 10, 5], [5000, 10, 10, 5], [10000, 10, 10, 5], [15000, 15, 15, 7], [20000, 20, 20, 10],
    ]
    public static func startingResources(difficulty: Int, computer: Bool) -> [String: Int] {
        let r = startingTable[min(4, max(0, difficulty)) + (computer ? 5 : 0)]
        var out: [String: Int] = [:]
        for (k, m) in materialNames.enumerated() { out[m] = r[min(3, k)] }
        return out
    }
    public func startingResources(computer: Bool) -> [String: Int] { GameState.startingResources(difficulty: difficulty, computer: computer) }
    /// A computer player's treasury (its starting one until it has been used).
    public func aiTreasury(_ colour: Int) -> [String: Int] { aiResources[colour] ?? startingResources(computer: true) }
    /// The game starts: the human's treasury from the table, the computer players' with theirs.
    public func setupTreasuries() {
        resources = startingResources(computer: false)
        for c in aiPlayers { aiResources[c] = startingResources(computer: true) }
    }

    // MARK: the computer's income (new day 0x4d8910)

    /// The handicap factor by difficulty (0x979acc): the computer earns this much of its income.
    public static let aiIncomeFactor: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    /// Does a computer player get the handicap? 0x4d8a53 marks the colours of human players in a
    /// byte array, then 0x4d8aeb tests the entry at index `colour == 0` -- colour 0 looks at
    /// colour 1, every other colour at colour 0 [observed]. With the human as red (0) every computer
    /// player gets it; with the human elsewhere only red does.
    public func aiHandicapApplies(_ colour: Int) -> Bool { GameState.handicapApplies(colour: colour, human: map.humanColour) }
    public static func handicapApplies(colour: Int, human: Int) -> Bool { (colour == 0 ? 1 : 0) == human }

    /// The extra (or, on Easy, missing) income of one day (0x4d8b31..0x4d8bcb), in material order:
    /// x = income x (factor - 1), n = trunc(x); one more when (day - i + 6) % 7 < trunc(7x - 7n + 0.5)
    /// (the fraction spread over the week); a loss never takes the funds below 0.
    /// `day` is the exe's 0-based day after the increment.
    public static func incomeHandicap(income: [Int], funds: [Int], difficulty: Int, day: Int) -> [Int] {
        let f = Double(Float(aiIncomeFactor[min(4, max(0, difficulty))])) - 1
        return income.indices.map { i in
            let x = Double(income[i]) * f
            var n = Int(x)
            let spread = Int(7 * x - Double(7 * n) + 0.5)
            if (day - i + 6) % 7 < spread { n += 1 }
            let have = i < funds.count ? funds[i] : 0
            if -n > have { n = -have }
            return n
        }
    }

    /// The new day for the computer players: their full income (the same 0x7e10f0 as everyone's:
    /// mines, towns, heroes' estates and income artifacts, the grail) and the handicap.
    func aiNewDay() {
        for c in aiPlayers {
            var funds = aiTreasury(c)
            let income = incomeByMaterial(of: c)
            for (k, m) in GameState.materialNames.enumerated() { funds[m, default: 0] += income[k] }
            if aiHandicapApplies(c) {
                let have = GameState.materialNames.map { funds[$0] ?? 0 }
                let extra = GameState.incomeHandicap(income: income, funds: have, difficulty: difficulty, day: day - 1)
                for (k, m) in GameState.materialNames.enumerated() { funds[m] = max(0, funds[m, default: 0] + extra[k]) }   // 0x7e3dd0 clamps at 0
            }
            aiResources[c] = funds
        }
    }

    // MARK: the town purchase (0x894470 / 0x894500), the human's dialog and the computer alike

    /// Buy up to `count` creatures of a town's dwelling into its garrison: no more than wait
    /// (population / 700) and than the treasury pays for in every material, the gold price
    /// replaced by `gold` when given (the discounted price); nothing when the garrison has no room.
    /// Returns how many were bought.
    @discardableResult
    public func townRecruit(_ i: Int, _ creature: String, count: Int, gold: Int? = nil) -> Int {
        guard towns.indices.contains(i), let c = tables?.creature(creature),
              c.alignment.lowercased() == towns[i].alignment.lowercased() else { return 0 }   // 0x894494
        var cost = GameState.recruitCost(c, discount: 0)
        if let g = gold, g >= 0, let k = cost.firstIndex(where: { $0.0 == "Gold" }) { cost[k].1 = g }
        guard towns[i].garrison.contains(where: { $0.creature == creature }) || garrisonCount(i) < GameState.rowSlots else { return 0 }   // 0x63fc50
        let n = min(count, recruitMost(available: towns[i].available[creature, default: 0], cost: cost))
        guard n > 0, addToGarrison(i, creature, n) else { return 0 }
        for (m, v) in cost { resources[m, default: 0] -= v * n }
        towns[i].available[creature, default: 0] -= n
        return n
    }

    // MARK: battle prediction (0x479000) and the garrison test (0x489d00)

    /// The damage factors the computer's battle prediction gives the two sides (0x479000):
    /// against a neutral army its own side gets 1.0 / 1.3 / 1.37 / 1.44 / 1.5 by difficulty and
    /// the neutrals 1.0; with a human side, two owned sides or two neutral ones, the first side
    /// 0.85 and the second 1.15.
    public static func predictionFactors(first: Int?, second: Int?, human: Int, difficulty: Int) -> (Double, Double) {
        let humanInvolved = first == human || second == human
        if humanInvolved || (first != nil) == (second != nil) { return (Double(Float(0.85)), Double(Float(1.15))) }
        let f = Double([Float(1.0), 1.3, 1.37, 1.44, 1.5][min(4, max(0, difficulty))])
        return first != nil ? (f, 1) : (1, f)
    }
    /// The simulated battle the computer plans by: does the first army beat the second?
    public func predictWin(_ a: [Combatant], owner ao: Int?, against b: [Combatant], owner bo: Int?, seed: Int) -> Bool {
        guard !a.isEmpty else { return false }
        guard !b.isEmpty else { return true }
        let f = GameState.predictionFactors(first: ao, second: bo, human: map.humanColour, difficulty: difficulty)
        return QuickCombat.fight(attackers: a, defenders: b, seed: seed, factors: (f.0, f.1)).attackerWon
    }

    func combatants(monster m: Monster) -> [Combatant] {
        guard let t = tables else { return [] }
        return ([(m.creature, m.count)] + m.extra.map { ($0.creature, $0.count) }).compactMap { s in t.creature(s.0).map { Combatant(creature: $0, count: s.1) } }
    }
    func garrisonCombatants(_ i: Int) -> [Combatant] {
        towns[i].garrisonHeroes.map { heroCombatant($0) } + towns[i].garrison.compactMap { s in tables?.creature(s.creature).map { Combatant(creature: $0, count: s.count) } }
    }

    /// 0x489d00: the garrison fights each threatening army in turn, its survivors going on to the
    /// next (plain simulation, no difficulty factors); enough when something of it is left.
    public func garrisonHolds(_ i: Int, against threats: [Hero]) -> Bool {
        var g = garrisonCombatants(i)
        for (k, h) in threats.enumerated() {
            guard g.contains(where: { $0.alive }) else { return false }
            let r = QuickCombat.fight(attackers: combatants(of: h), defenders: g.filter { $0.alive }, seed: day * 31 + i * 7 + k)
            g = r.defenders
        }
        return g.contains { $0.alive }
    }

    /// The armies threatening a town (the AI's threat record, town+0x11c via 0x8a0e00): other
    /// players' armies that could walk to its gate within one day's movement [inferred].
    public func townThreats(_ i: Int) -> [Hero] {
        guard let owner = towns[i].owner ?? (towns[i].owned ? map.humanColour : nil),
              let p = townPlaced(i) else { return [] }
        let gate = gateCells(p)[0]
        let team = map.teams[owner]
        var out: [Hero] = []
        for h in heroes + enemyHeroes where h.z == towns[i].z {
            let o = h.owner
            guard o != owner, !(team != nil && map.teams[o] == team), !h.army.isEmpty || !h.heroless else { continue }
            let reach = Int(h.maxMovement.rounded(.up)) + 1
            guard max(abs(h.x - gate.0), abs(h.y - gate.1)) <= reach else { continue }
            let pass = passabilities[towns[i].z]
            var free = pass
            free.free(h.x, h.y)
            guard let route = (h.x, h.y) == gate ? [] : free.path(from: (h.x, h.y), to: gate) else { continue }
            var cost: Float = 0, px = h.x, py = h.y
            for c in route { cost += free.stepCost(from: px, py, to: c.x, c.y); px = c.x; py = c.y }
            if cost <= h.maxMovement + 0.001 { out.append(h) }
        }
        return out
    }

    /// The best creature discount of a town's own armies: its garrison's heroes and its owner's
    /// armies at the town (0x47c770 over the town's cells, 0x641cc0 each).
    func townDiscount(_ i: Int, owner: Int) -> Int {
        var best = recruitDiscount(towns[i].garrisonHeroes)
        if let v = visitingArmy(town: i), v.owner == owner { best = max(best, recruitDiscount(v.members)) }
        return best
    }

    /// The emergency defence (0x47c5e0 / 0x47c870), after the computer's moves: each of its towns
    /// with a threat buys from its highest dwelling (building 19) down to 12, as many as the full
    /// treasury pays and wait, at the discounted gold, until the simulation says the garrison holds
    /// (checked before the first purchase when it has a garrison, and after each).
    func aiDefendTowns(_ colour: Int) {
        guard let t = tables else { return }
        for i in towns.indices where towns[i].owner == colour && !towns[i].owned {
            let threats = townThreats(i)
            guard !threats.isEmpty else { continue }
            if garrisonCount(i) > 0, garrisonHolds(i, against: threats) { continue }
            let d = townDiscount(i, owner: colour)
            for b in stride(from: 19, through: 12, by: -1) where isBuilt(towns[i], b) {
                guard let key = buildingDef(towns[i], b)?.creature, let c = t.creature(key),
                      towns[i].available[key, default: 0] > 0 else { continue }
                guard towns[i].garrison.contains(where: { $0.creature == key }) || garrisonCount(i) < GameState.rowSlots else { continue }
                let gold = ((100 - d) * (c.cost["Gold"] ?? c.gold) + 50) / 100
                townRecruit(i, key, count: Int.max, gold: gold)
                if garrisonHolds(i, against: threats) { break }
            }
        }
    }
}

// MARK: - weights, reserve, budget and buildings (re/ai_buildings_spec.md)

/// A creature purchase option of 0x4869c0 / 0x7e3080: one creature, summed over the player's towns.
struct AICreatureOption {
    var creature: String
    var cost: [Int]          // material order, for one creature
    var count: Int
    var experience: Int
    var experienceTotal: Int
}

extension GameState {
    /// What one unit of each material is worth in gold (table 0x98c3a0).
    static let goldEquivalent: [Float] = [1, 125, 125, 250, 250, 250, 250]

    func materialArray(_ cost: [String: Int]) -> [Int] { GameState.materialNames.map { cost[$0] ?? 0 } }
    func funds() -> [Int] { materialArray(resources) }

    /// The computer's towns in its town list order (player +0x2bc; the remake keeps the map's order).
    func aiTowns(_ colour: Int) -> [Int] { towns.indices.filter { towns[$0].owner == colour && !towns[$0].owned } }

    /// Creature options over the player's towns' BUILT dwellings, merged by creature, sorted
    /// ascending by total experience (stable) and cut to `keep` (0: all).
    /// - `discounted` (0x486d70): the gold less the town's best hero discount, only counts > 0, the
    ///   first town's price kept;
    /// - otherwise (0x7e3080's own pass): the raw cost, counts of 0 included.
    func aiCreatureOptions(_ colour: Int, discounted: Bool, keep: Int) -> [AICreatureOption] {
        guard let t = tables else { return [] }
        var out: [AICreatureOption] = []
        for i in aiTowns(colour) {
            let d = discounted ? townDiscount(i, owner: colour) : 0
            for b in 12...19 where isBuilt(towns[i], b) {
                guard let key = buildingDef(towns[i], b)?.creature, let c = t.creature(key) else { continue }
                let n = towns[i].available[key, default: 0]
                if discounted && n <= 0 { continue }
                if let k = out.firstIndex(where: { $0.creature == key }) {
                    out[k].count += n; out[k].experienceTotal += c.experience * n
                } else {
                    var cost = materialArray(c.cost.isEmpty ? ["Gold": c.gold] : c.cost)
                    if discounted { cost[0] = ((100 - d) * cost[0] + 50) / 100 }
                    out.append(AICreatureOption(creature: key, cost: cost, count: n, experience: c.experience, experienceTotal: c.experience * n))
                }
            }
        }
        // insertion sort, strict < (0x497150): equal totals keep their order
        var sorted: [AICreatureOption] = []
        for o in out {
            let at = sorted.firstIndex { o.experienceTotal < $0.experienceTotal } ?? sorted.count
            sorted.insert(o, at: at)
        }
        return keep > 0 ? Array(sorted.prefix(keep)) : sorted
    }

    /// The resource weights at the start of the computer's turn (0x7e3080): how scarce each
    /// material is against what it wants -- the dearest building it could build now in any town,
    /// plus its three smallest creature options -- over funds and two days' income; clamped to
    /// 1...3, times the gold value of the material.
    func aiComputeWeights(_ colour: Int) {
        var need = [Int](repeating: 0, count: 7)
        for i in aiTowns(colour) {
            for b in 0...42 where !isBuilt(towns[i], b) {   // (built dwellings go into the options below)
                guard met(towns[i], GameState.buildingReq(towns[i].alignment, b)), let def = buildingDef(towns[i], b) else { continue }
                for (r, v) in materialArray(def.cost).enumerated() { need[r] = max(need[r], v) }
            }
        }
        for o in aiCreatureOptions(colour, discounted: false, keep: 3) {
            for r in 0..<7 { need[r] += o.cost[r] * o.count }
        }
        let f = funds(), income = incomeByMaterial(of: colour)
        aiWeights[colour] = (0..<7).map { r in
            let avail = f[r] + 2 * income[r]
            let a: Float = avail == 0 ? 1 : Float(avail)
            let w = min(3, max(1, Float(need[r]) / a))
            return w * GameState.goldEquivalent[r]
        }
    }
    func weights(_ colour: Int) -> [Float] { aiWeights[colour] ?? GameState.goldEquivalent }

    /// A cost in weighted gold (0x792090): each material x its weight, truncated, summed.
    func costValue(_ cost: [Int], _ w: [Float]) -> Int {
        (0..<7).reduce(0) { $0 + Int(Float(cost[$1]) * w[$1]) }
    }

    /// Reserve and budget (0x7e3440): the reserve is the full price of the two creature options
    /// with the smallest total experience; budget = funds + one day's income (none at the start of
    /// the turn) - reserve, within 0...funds.
    func aiComputeBudget(_ colour: Int, withIncome: Bool) {
        var reserve = [Int](repeating: 0, count: 7)
        for o in aiCreatureOptions(colour, discounted: true, keep: 2) { for r in 0..<7 { reserve[r] += o.cost[r] * o.count } }
        let f = funds(), income = withIncome ? incomeByMaterial(of: colour) : [Int](repeating: 0, count: 7)
        aiBudget[colour] = (0..<7).map { r in min(f[r], max(0, f[r] + income[r] - reserve[r])) }
    }

    /// A building's worth to the computer (0x483250): halls for their gold, walls and the city
    /// hall for 1% of the town's built worth, dwellings for experience x weekly growth, building 31
    /// (the order treasury) its literal w0 x 1.1^(1/7) - 1; everything else nothing.
    func aiBuildingValue(_ i: Int, _ b: Int, _ w: [Float]) -> Float {
        let w0 = w[0]
        func worth() -> Float {
            var total = 0
            for x in 0...42 where GameState.buildingExists(towns[i].alignment, x) && isBuilt(towns[i], x) {
                if let d = buildingDef(towns[i], x) { total += costValue(materialArray(d.cost), w) }
            }
            return Float(total)
        }
        switch b {
        case 1: return 1750 * w0
        case 2: return 3500 * w0 + 0.01 * worth()
        case 3, 4, 5: return 0.01 * worth()
        case 12...19:
            guard let key = buildingDef(towns[i], b)?.creature, let c = tables?.creature(key) else { return 0 }
            return Float(c.experience) * Float(c.growth)
        case 31: return w0 * Float(pow(1.1, 1.0 / 7.0)) - 1
        default: return 0
        }
    }

    /// The buildings (0x482c90): every unbuilt building of the computer's towns ranked by value /
    /// weighted cost x a town factor (1 for the least built-up town .. 1.5 for the most), best first
    /// (ties: the later entry first); built in that order while the budget covers the cost --
    /// strictly more of every material -- and the town has not built today; one a town a day.
    func aiBuild(_ colour: Int) {
        let w = weights(colour)
        let list = aiTowns(colour)
        var townValue = [Float](repeating: 0, count: list.count)
        var entries: [(town: Int, k: Int, b: Int, ratio: Float)] = []
        for (k, i) in list.enumerated() where !towns[i].builtToday {
            let t = towns[i]
            var value = [Float](repeating: 0, count: 43), cv = [Float](repeating: 0, count: 43)
            for b in 0...42 where GameState.buildingExists(t.alignment, b) {
                cv[b] = Float(buildingDef(t, b).map { costValue(materialArray($0.cost), w) } ?? 0)
                value[b] = aiBuildingValue(i, b, w)
                if isBuilt(t, b) { townValue[k] += value[b] }
            }
            // (0x893390 spreads the values to the prerequisites into a copy nobody reads)
            for b in 0...42 where GameState.buildingExists(t.alignment, b) && !isBuilt(t, b) && buildingDef(t, b) != nil {
                entries.append((i, k, b, value[b] / cv[b]))
            }
        }
        // 0x4831b0: the town factor
        let mn = townValue.min() ?? 0, mx = max(0, townValue.max() ?? 0), range = (mx - mn) * 2
        var sorted: [(town: Int, k: Int, b: Int, ratio: Float)] = []
        for var e in entries {
            e.ratio *= range == 0 ? 1 : (townValue[e.k] - mn) / range + 1
            // lower_bound with "a before b when a.ratio > b.ratio" (0x496e00)
            let at = sorted.firstIndex { !($0.ratio > e.ratio) } ?? sorted.count
            sorted.insert(e, at: at)
        }
        var budget = aiBudget[colour] ?? funds()
        let snd = sounds.count, lg = log.count
        for e in sorted {
            guard let def = buildingDef(towns[e.town], e.b) else { continue }
            let cost = materialArray(def.cost)
            if (0..<7).contains(where: { budget[$0] <= cost[$0] }) { continue }   // strict (0x4830d1)
            let t = towns[e.town]
            guard !t.builtToday, met(t, GameState.buildingReq(t.alignment, e.b)),
                  isEnabled(t, e.b) && possible(t, GameState.buildingReq(t.alignment, e.b)) else { continue }
            build(def, in: e.town)
            guard towns[e.town].builtToday else { continue }
            for r in 0..<7 { budget[r] -= cost[r] }
        }
        aiBudget[colour] = budget
        if sounds.count > snd { sounds.removeSubrange(snd...) }
        if log.count > lg { log.removeSubrange(lg...) }
    }
}
