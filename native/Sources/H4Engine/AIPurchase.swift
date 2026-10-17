import Foundation

/// The computer's creature and hero purchases (t_creature_purchaser, re/ai_purchase_spec.md):
/// a greedy plan over an army's seven places that buys, step by step, the purchase with the best
/// gain in army value per weighted cost, until nothing gains.
final class AIPurchaser {
    struct Option {
        var creature: String?          // nil: a hero
        var hero: Hero?
        var heroClass = -1
        var building: Int?             // the dwelling (or the tavern for a hero) built with it
        var buildingCost: [Int] = Array(repeating: 0, count: 7)
        var unitCost: [Int]
        var count: Int
        var experience: Int
    }
    var slots: [ArmySlot?]
    var second: [ArmySlot?]?
    var remaining: [Int]
    let start: [Int]
    var options: [Option] = []
    var noBuilding: Bool
    var building: Int?
    var hero: Hero?
    var heroClass = -1
    var bought: [String: Int] = [:]
    var spent: [Int] { (0..<7).map { start[$0] - remaining[$0] } }

    init(slots: [ArmySlot?], second: [ArmySlot?]?, money: [Int], noBuilding: Bool) {
        self.slots = slots; self.second = second; self.remaining = money; self.start = money; self.noBuilding = noBuilding
    }
}

extension GameState {
    /// A hero's worth to the computer.
    func heroValue(_ h: Hero) -> Float {
        // 0x7308e0: (1 + morale term) x sqrt(offense x defense); offense from the damage and attack,
        // defense from the hit points and defense [approximated from the remake's combat stats]
        let c = heroCombatant(h)
        let off = Float(c.damageLow + c.damageHigh) * Float(max(1, c.attack)) / 10
        let def = Float(c.hitPoints) * Float(max(1, c.defense)) / 10
        return (off * def).squareRoot()
    }
    /// 0x5197c0 + 1: the heroes' tactics and leadership raise the creatures' worth (the offense and
    /// defense terms are integer divisions that always give 0).
    func armySkillFactor(_ heroes: [Hero]) -> Float {
        guard !heroes.isEmpty else { return 1 }
        let T: [Float] = [0.2, 0.4, 0.6, 0.8, 1.0, 0.3]
        let tac = min(5, heroes.map { $0.skill("tactics") }.max() ?? 0)
        let lead = heroes.max { $0.skill("leadership") < $1.skill("leadership") }
        let ld = min(10, lead?.skill("leadership") ?? 0), lt = min(5, lead?.skill("tactics") ?? 0)
        return 1 + Float(tac) * 0.01 * T[tac] + Float(ld) * 0.007 * T[lt]
    }
    /// The army's worth to the computer (0x642160): creatures count x experience x the heroes' factor,
    /// plus each hero's value.
    func aiArmyValue(_ row: [ArmySlot?]) -> Float {
        let hs = row.compactMap { $0?.hero }
        let f = armySkillFactor(hs)
        var v: Float = 0
        for s in row {
            switch s {
            case .stack(let st)?: v += Float(st.count) * Float(tables?.creature(st.creature)?.experience ?? 0) * f
            case .hero(let h)?: v += heroValue(h)
            case nil: break
            }
        }
        return v
    }

    /// The options (0x4869c0): the town's built dwellings with what waits, and -- when buildings are
    /// allowed -- the dwellings it could build now with half a week's growth and the building's cost.
    func aiPurchaseOptions(_ i: Int, discount d: Int, includeBuildable: Bool) -> [AIPurchaser.Option] {
        guard let t = tables else { return [] }
        var out: [AIPurchaser.Option] = []
        for b in 12...19 {
            let town = towns[i]
            let built = isBuilt(town, b)
            let req = GameState.buildingReq(town.alignment, b)
            let buildable = includeBuildable && !built && met(town, req) && isEnabled(town, b) && possible(town, req)
            guard built || buildable, let def = buildingDef(town, b), let key = def.creature, let c = t.creature(key) else { continue }
            let n = buildable ? (c.growth + 1) / 2 : town.available[key, default: 0]
            guard n > 0 else { continue }
            if let k = out.firstIndex(where: { $0.creature == key }) { out[k].count += n; continue }
            var cost = materialArray(c.cost.isEmpty ? ["Gold": c.gold] : c.cost)
            cost[0] = ((100 - d) * cost[0] + 50) / 100
            out.append(.init(creature: key, building: buildable ? b : nil, buildingCost: buildable ? materialArray(def.cost) : Array(repeating: 0, count: 7),
                             unitCost: cost, count: n, experience: c.experience))
        }
        return out
    }

    /// The hero options (0x4880f0): a tavern (built, or buildable now with the plan), no hero in the
    /// army, fewer heroes than min(4, 2 + (day + 1) / 7), the tavern not used this week, a free
    /// place; then one candidate of each class the town offers that the money pays for (two draws
    /// each: the gender, then the least used hero of it).
    func aiHeroOptions(_ i: Int, _ p: AIPurchaser, heroCount: Int, colour: Int) -> [AIPurchaser.Option] {
        guard let t = tables else { return [] }
        let town = towns[i]
        var tavernCost: [Int]? = nil
        if !isBuilt(town, 9) {
            let req = GameState.buildingReq(town.alignment, 9)
            guard !p.noBuilding, town.tavernDays == 0, !town.builtToday, let def = buildingDef(town, 9),
                  !def.cost.contains(where: { resources[$0.key, default: 0] < $0.value }), met(town, req),
                  isEnabled(town, 9) && possible(town, req) else { return [] }
            tavernCost = materialArray(def.cost)
        }
        guard !p.slots.contains(where: { $0?.hero != nil }) else { return [] }
        let exeDay = day - 1
        guard heroCount < min(4, 2 + (exeDay + 1) / 7), town.tavernDays == 0 else { return [] }
        guard p.slots.contains(where: { $0 == nil }) || (p.second?.contains { $0 == nil } ?? false) else { return [] }
        let prices = GameState.hirePrices(alignment: town.alignment)
        var out: [AIPurchaser.Option] = []
        for c in 0...10 where prices[c] > 0 && p.remaining[0] >= prices[c] {
            let female = random.next() % 2 == 0
            let list = heroPool(c, female: female)
            let r = random.next()
            guard !list.isEmpty else { continue }
            let def = t.heroes[list[r % list.count]]
            var mh = MapHero(); mh.heroClass = c; mh.level = 1; mh.portrait = def.portrait ?? -1; mh.gender = female ? 1 : 0; mh.name = def.name
            let h = Hero.fromMap(mh, alignment: RuleTables.heroClasses[c].alignment, x: 0, y: 0, tables: tables, random: &random)
            h.owner = colour; h.z = town.z
            var cost = [Int](repeating: 0, count: 7); cost[0] = prices[c]
            out.append(.init(creature: nil, hero: h, heroClass: c, building: tavernCost == nil ? nil : 9,
                             buildingCost: tavernCost ?? Array(repeating: 0, count: 7), unitCost: cost, count: 1, experience: 0))
        }
        return out
    }

    /// One greedy step (0x488a90): the best (option, place, count) by gain / weighted cost; applied
    /// (0x489230) when it gains. Returns the gain.
    func aiPurchaseStep(_ p: AIPurchaser, weights w: [Float]) -> Float {
        var best: (o: Int, s: Int, n: Int, gain: Float)? = nil, bestScore: Float = 0
        let before = aiArmyValue(p.slots)
        for (k, o) in p.options.enumerated() {
            if p.hero != nil && o.hero != nil { continue }
            var n: Int
            var money = p.remaining
            if o.building != nil {
                if p.noBuilding { continue }
                if (0..<7).contains(where: { p.remaining[$0] <= o.buildingCost[$0] }) { n = 0 }
                else { for r in 0..<7 { money[r] -= o.buildingCost[r] }; n = 1_000_000_000 }
            } else { n = 1_000_000_000 }
            if n > 0 { for r in 0..<7 where o.unitCost[r] > 0 { n = min(n, money[r] / o.unitCost[r]) } }
            n = min(n, o.count)
            guard n > 0 else { continue }
            var cost = (0..<7).map { o.unitCost[$0] * n }
            if o.building != nil { for r in 0..<7 { cost[r] += o.buildingCost[r] } }
            let cv = Float(costValue(cost, w))
            let cand: ArmySlot = o.hero.map { .hero($0) } ?? .stack(Hero.Stack(creature: o.creature!, count: n))
            var triedEmpty = false
            for s in 0..<GameState.rowSlots {
                var trial = p.slots
                switch p.slots[s] {
                case nil:
                    if triedEmpty { continue }
                    triedEmpty = true; trial[s] = cand
                case .stack(let st)? where o.creature == st.creature:
                    trial[s] = .stack(Hero.Stack(creature: st.creature, count: st.count + n))
                case .stack(let st)?:
                    guard let sec = p.second, sec.contains(where: { $0 == nil || $0?.stack?.creature == st.creature }) else { continue }
                    trial[s] = cand
                default: continue
                }
                let gain = aiArmyValue(trial) - before, score = gain / cv
                if best == nil || score > bestScore { best = (k, s, n, gain); bestScore = score }
            }
        }
        guard let b = best, b.gain > 0 else { return 0 }
        aiPurchaseApply(p, b.o, b.s, b.n)
        return b.gain
    }

    /// 0x489230: pay (from the plan's money), place, count down the option.
    func aiPurchaseApply(_ p: AIPurchaser, _ k: Int, _ s: Int, _ n: Int) {
        var o = p.options[k]
        if let b = o.building {
            p.noBuilding = true; p.building = b
            for r in 0..<7 { p.remaining[r] -= o.buildingCost[r] }
        }
        for r in 0..<7 { p.remaining[r] -= o.unitCost[r] * n }
        let new: ArmySlot
        if let h = o.hero { p.hero = h; p.heroClass = o.heroClass; new = .hero(h) }
        else { new = .stack(Hero.Stack(creature: o.creature!, count: n)); p.bought[o.creature!, default: 0] += n }
        if case .stack(let st)? = p.slots[s], st.creature == o.creature {
            p.slots[s] = .stack(Hero.Stack(creature: st.creature, count: st.count + n))
        } else {
            if let old = p.slots[s], var sec = p.second {
                if let st = old.stack, let j = sec.firstIndex(where: { $0?.stack?.creature == st.creature }), let cur = sec[j]?.stack {
                    sec[j] = .stack(Hero.Stack(creature: st.creature, count: cur.count + st.count))
                } else if let j = sec.firstIndex(where: { $0 == nil }) { sec[j] = old }
                p.second = sec
            }
            p.slots[s] = new
        }
        o.count -= n
        if o.count <= 0 || o.hero != nil { p.options.remove(at: k) } else { p.options[k] = o }
    }

    func aiRunPurchase(_ p: AIPurchaser, weights w: [Float]) {
        var guardSteps = 0
        while guardSteps < 64, aiPurchaseStep(p, weights: w) > 0 { guardSteps += 1 }
    }

    /// The commit (0x4887c0): the hero's tavern week, the building, the payment, the population.
    /// `fromBudget`: the start-of-turn plans pay from the budget too (0x7e3b00).
    func aiCommitPurchase(_ p: AIPurchaser, town i: Int, colour: Int, fromBudget: Bool) {
        if p.hero != nil { towns[i].tavernDays = 7 }
        var cost = p.spent
        if let b = p.building, let def = buildingDef(towns[i], b) {
            let snd = sounds.count, lg = log.count
            build(def, in: i)   // pays its own price (the plan's building part)
            if sounds.count > snd { sounds.removeSubrange(snd...) }
            if log.count > lg { log.removeSubrange(lg...) }
            let bc = materialArray(def.cost)
            for r in 0..<7 { cost[r] -= bc[r] }
            if fromBudget, var bud = aiBudget[colour] { for r in 0..<7 { bud[r] -= bc[r] }; aiBudget[colour] = bud }
        }
        for (r, m) in GameState.materialNames.enumerated() { resources[m, default: 0] -= cost[r] }
        if fromBudget, var bud = aiBudget[colour] { for r in 0..<7 { bud[r] -= cost[r] }; aiBudget[colour] = bud }
        for (c, n) in p.bought { towns[i].available[c] = max(0, towns[i].available[c, default: 0] - n) }
        if let h = p.hero { h.home = (towns[i].x, towns[i].y); h.z = towns[i].z }
    }

    // MARK: the turn's purchase passes

    /// May the computer field another army (0x484ad0)? Fewer than 8, and fewer than 2 / 3 / 4 on
    /// small / medium / larger maps.
    func aiCanAddArmy(_ colour: Int) -> Bool {
        let n = enemyHeroes.filter { $0.owner == colour }.count
        let cap = map.size <= 76 ? 2 : map.size <= 152 ? 3 : 4
        return n < GameState.maxArmies && n < cap
    }
    /// The hero count frozen at the start of the turn (AI +0x160, 0x47bfb0): the heroes of its
    /// armies and of its garrisons that hold someone alive.
    func aiHeroCount(_ colour: Int) -> Int {
        var n = enemyHeroes.filter { $0.owner == colour }.reduce(0) { $0 + $1.members.count }
        for i in aiTowns(colour) where towns[i].garrison.contains(where: { $0.count > 0 }) || !towns[i].garrisonHeroes.isEmpty {
            n += towns[i].garrisonHeroes.count
        }
        return n
    }
    func gateFree(_ i: Int) -> (Int, Int)? {
        guard let p = townPlaced(i) else { return nil }
        let back = level; level = towns[i].z; defer { level = back }
        let probe = Hero(actor: "", x: -1, y: -1, movement: 0)
        return gateCells(p).first { isVacant($0, for: probe) && enemyAt($0.0, $0.1) == nil }
    }

    /// The start-of-turn town pass (0x47c170): each town with an empty garrison and a free exit
    /// plans a creature army from its built dwellings with the budget (no discount, no building, no
    /// hero); the plans are committed best first while the budget covers each strictly.
    func aiTownPlans(_ colour: Int) {
        guard aiCanAddArmy(colour) else { return }
        let w = weights(colour)
        var plans: [(town: Int, p: AIPurchaser, value: Float)] = []
        for i in aiTowns(colour) where !towns[i].garrison.contains(where: { $0.count > 0 }) && towns[i].garrisonHeroes.isEmpty {   // 0x63fcb0: empty
            guard gateFree(i) != nil else { continue }
            let p = AIPurchaser(slots: Array(repeating: nil, count: GameState.rowSlots), second: nil, money: aiBudget[colour] ?? funds(), noBuilding: true)
            p.options = aiPurchaseOptions(i, discount: 0, includeBuildable: false)
            aiRunPurchase(p, weights: w)
            guard p.slots.contains(where: { $0 != nil }) else { continue }
            // (0x47dfc0, the goal search, decides; the remake orders by the planned army's worth [approximation])
            let v = aiArmyValue(p.slots)
            let at = plans.firstIndex { $0.value <= v } ?? plans.count
            plans.insert((i, p, v), at: at)
        }
        for plan in plans {
            guard aiCanAddArmy(colour) else { break }
            let budget = aiBudget[colour] ?? funds(), cost = plan.p.spent
            if (0..<7).contains(where: { budget[$0] <= cost[$0] }) { continue }   // strict (0x47c490)
            setGarrison(plan.town, plan.p.slots)
            aiCommitPurchase(plan.p, town: plan.town, colour: colour, fromBudget: true)
        }
    }

    /// A garrison about to leave (0x47d6e0): it buys with the full treasury at the town's discount
    /// -- creatures, at most one building, a hero -- and, unless more than one army threatens the
    /// town, walks out as an army; what the purchase pushed out of its places walks out beside it.
    func aiGarrisonDepartures(_ colour: Int, heroCount: Int) -> [Hero] {
        var out: [Hero] = []
        let w = weights(colour)
        for i in aiTowns(colour) {
            guard towns[i].garrison.contains(where: { $0.count > 0 }) || !towns[i].garrisonHeroes.isEmpty, aiCanAddArmy(colour) else { continue }
            let threats = townThreats(i)
            let exit = gateFree(i)
            let p = AIPurchaser(slots: garrisonSlots(i), second: exit != nil ? Array(repeating: nil, count: GameState.rowSlots) : nil,
                                money: funds(), noBuilding: towns[i].builtToday)
            p.options = aiPurchaseOptions(i, discount: townDiscount(i, owner: colour), includeBuildable: !towns[i].builtToday)
            p.options += aiHeroOptions(i, p, heroCount: heroCount, colour: colour)   // the count frozen at the turn's start
            aiRunPurchase(p, weights: w)
            setGarrison(i, p.slots)
            aiCommitPurchase(p, town: i, colour: colour, fromBudget: false)
            guard let cell = exit, threats.count <= 1 else { continue }
            let row = p.slots + (p.second ?? [])
            if let a = aiFormArmy(i, row, at: cell, colour: colour) {
                setGarrison(i, Array(repeating: nil, count: GameState.rowSlots))
                out.append(a)
            }
        }
        return out
    }

    /// The garrison (and what was pushed out of it) as an army at the exit cell.
    func aiFormArmy(_ i: Int, _ row: [ArmySlot?], at cell: (Int, Int), colour: Int) -> Hero? {
        let hs = row.compactMap { $0?.hero }
        var stacks: [Hero.Stack] = []
        for s in row.compactMap({ $0?.stack }) where s.count > 0 {
            if let k = stacks.firstIndex(where: { $0.creature == s.creature }) { stacks[k].count += s.count } else { stacks.append(s) }
        }
        guard !hs.isEmpty || !stacks.isEmpty, hs.count + stacks.count <= GameState.rowSlots else { return nil }
        let lead: Hero = hs.first ?? { let h = Hero(actor: "", x: 0, y: 0, movement: 0); h.heroless = true; h.name = ""; return h }()
        lead.companions = Array(hs.dropFirst()); lead.army = stacks
        lead.x = cell.0; lead.y = cell.1; lead.z = towns[i].z; lead.owner = colour; lead.home = cell
        lead.path = []; lead.plan = []; lead.target = nil
        refreshHeroless(lead)
        lead.maxMovement = armyMovement(lead); lead.movement = lead.maxMovement
        place(enemy: lead)
        return lead
    }
}
