import Foundation

/// Hiring heroes (heroes4.exe 0x743f40 / 0x7373e0 / 0x746610): one candidate of each of the
/// eleven base classes that the place offers -- a town its own alignment's classes for 1500 and
/// its neighbours' for 2000 (a Stronghold its might classes for 2500, barbarians 1500), an
/// adventure tavern every class for 2000 -- the candidate drawn from the least used heroes of the
/// class, the gender with more of them. A town hires one hero a week; the hero comes at level 1
/// with the class skills and nothing else.
public struct HireOffer {
    public var prices: [Int]                 // by base class 0...10, 0 = not offered
    public var candidates: [Int: [Int]]      // class -> rows of table.heroes (the chosen gender's pool)
    public var female: [Int: Bool]
    public var index: [Int: Int]
    public var selected: Int
    public var town: Int?                    // nil: an adventure tavern
    public var tavernKey: String? = nil
}

extension GameState {
    /// The price of each base class for a town alignment (nil: an adventure tavern).
    public static func hirePrices(alignment: String?) -> [Int] {
        let wheel = ["life", "order", "death", "chaos", "nature"]
        return (0...10).map { c -> Int in
            let ca = RuleTables.heroClasses[c].alignment
            guard let a = alignment else { return 2000 }
            if a == "might" { return c == 10 ? 1500 : [0, 2, 4, 6, 8].contains(c) ? 2500 : 0 }
            guard let x = wheel.firstIndex(of: a), let y = wheel.firstIndex(of: ca) else { return 0 }
            let d = (x - y + 5) % 5
            return d == 0 ? 1500 : (d == 1 || d == 4) ? 2000 : 0
        }
    }
    /// Heroes of table.heroes for a class and gender, the least used first (in play counts as used).
    func heroPool(_ c: Int, female: Bool) -> [Int] {
        guard let t = tables else { return [] }
        let key = RuleTables.heroClasses[c].keyword
        let used = Set((heroes + enemyHeroes).flatMap { [$0] + $0.companions }.map { $0.keyword.lowercased() })
        let all = t.heroes.indices.filter { t.heroes[$0].heroClass == key && (t.heroes[$0].sex == "female") == female }
        let unused = all.filter { !used.contains(t.heroes[$0].keyword.lowercased()) }
        return unused.isEmpty ? all : unused
    }
    public func hireOffer(town: Int?) -> HireOffer {
        let prices = GameState.hirePrices(alignment: town.map { towns[$0].alignment })
        var cands: [Int: [Int]] = [:], fem: [Int: Bool] = [:], idx: [Int: Int] = [:]
        for c in 0...10 where prices[c] > 0 {
            let m = heroPool(c, female: false), f = heroPool(c, female: true)
            let female = m.count == f.count ? random.next() & 1 == 1 : f.count > m.count
            let list = female ? f : m
            guard !list.isEmpty else { continue }
            cands[c] = list; fem[c] = female; idx[c] = random.next() % list.count
        }
        let offered = cands.keys.sorted()
        let cheapest = offered.filter { prices[$0] == offered.map { prices[$0] }.min() }
        let sel = cheapest.isEmpty ? (offered.first ?? 0) : cheapest[random.next() % cheapest.count]
        return HireOffer(prices: prices, candidates: cands, female: fem, index: idx, selected: sel, town: town)
    }
    /// The same class, the other gender's pool.
    public func switchGender(_ o: inout HireOffer, female: Bool) {
        let list = heroPool(o.selected, female: female)
        guard !list.isEmpty else { return }
        o.candidates[o.selected] = list; o.female[o.selected] = female; o.index[o.selected] = random.next() % list.count
    }
    /// Why a town cannot hire now, or nil.
    public func tavernRefusal(town i: Int) -> String? {
        let d = towns[i].tavernDays
        guard d > 0 else { return nil }
        return d == 1 ? text("town_tavern_tomorrow.misc", "You can hire another hero from this tavern tomorrow.")
                      : text("town_tavern_empty.misc", "You can hire another hero from this tavern in %days days.").replacingOccurrences(of: "%days", with: "\(d)")
    }
    /// Buy the selected candidate: into the visiting army (a tavern) or at the town's gate.
    @discardableResult
    public func hire(_ o: HireOffer, with visitor: Hero?) -> Hero? {
        let c = o.selected
        guard let list = o.candidates[c], let k = o.index[c], k < list.count, let t = tables else { return nil }
        let price = o.prices[c]
        guard resources["Gold", default: 0] >= price else { return nil }
        let def = t.heroes[list[k]]
        var mh = MapHero(); mh.heroClass = c; mh.level = 1; mh.portrait = list[k]; mh.gender = o.female[c] == true ? 1 : 0; mh.name = def.name
        var x = visitor?.x ?? 0, y = visitor?.y ?? 0
        var z = visitor?.z ?? level
        if let ti = o.town, let p = scenes[towns[ti].z].placed.first(where: { $0.category == "castle" && $0.cellX == towns[ti].x && $0.cellY == towns[ti].y }) {
            let back = level; level = towns[ti].z
            guard let cell = gateCells(p).first(where: { isVacant($0, for: Hero(actor: "", x: -1, y: -1, movement: 0)) && enemyAt($0.0, $0.1) == nil }) ?? freeCell(near: gateCells(p)[0].0, gateCells(p)[0].1) else { level = back; return nil }
            x = cell.0; y = cell.1; z = towns[ti].z
            level = back
        }
        let h = Hero.fromMap(mh, alignment: RuleTables.heroClasses[c].alignment, x: x, y: y, tables: tables, random: &random)
        h.owner = map.humanColour; h.z = z; h.home = (x, y)
        h.maxMovement = armyMovement(h); h.movement = h.maxMovement
        resources["Gold", default: 0] -= price
        if o.town == nil, let v = visitor { v.companions.append(h) }
        else { heroes.append(h) }
        if let ti = o.town { towns[ti].tavernDays = 7 }
        if let key = o.tavernKey { objectStates[key, default: ObjectState()].used = true; objectStates[key]?.countdown = 0 }
        return h
    }
}
