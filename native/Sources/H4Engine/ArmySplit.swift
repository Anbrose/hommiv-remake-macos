import Foundation

/// Splitting and trading armies (army_split_spec.md): the army screen's two rows, the empty new
/// army it makes next to the army (0x528c90), the movement a transfer between the rows costs
/// (0x528e80 / 0x646380 / 0x646680), and what closing it does (0x529050 -> 0x4bada0 / 0x4bb0f0).
extension GameState {
    /// A player has at most 8 armies on the map (0x7e1a70).
    public static let maxArmies = 8
    /// The 8 neighbours in heroes4.exe's direction order (0x705b80): northeast, east, southeast,
    /// south, southwest, west, northwest, north.
    public static let directions: [(Int, Int)] = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]
    /// Raw terrain movement per cell in hundredths (table 0x985378; 100 for the rest).
    static let terrainCost100: [UInt8: Int] = [2: 125, 3: 200, 4: 125, 5: 175, 6: 150, 9: 150, 11: 150, 15: 125, 16: 125, 18: 125]

    /// The player's armies in their list order (the selected one is heroes[0]).
    public var armyList: [Hero] { heroes.enumerated().sorted { ($0.element.listRank, $0.offset) < ($1.element.listRank, $1.offset) }.map(\.element) }
    /// A rank after every army's (a new army goes to the end of the list).
    public func nextListRank() -> Int { (heroes.map(\.listRank).max() ?? 0) + 1 }
    /// Select an army (0x4b5eb0): it becomes the one acting; the list keeps its order.
    public func select(_ h: Hero) {
        guard let k = heroes.firstIndex(where: { $0 === h }), k != 0 else { return }
        if heroes.allSatisfy({ $0.listRank == 0 }) { for (r, a) in heroes.enumerated() { a.listRank = r } }
        heroes.remove(at: k); heroes.insert(h, at: 0)
        level = h.z
    }

    /// Walk up to a friendly army and meet it (0x522560 -> 0x522c6a): the army screen of the two.
    func meet(_ f: Hero, with hero: Hero) {
        hero.attackTarget = nil
        if GameState.adjacent((hero.x, hero.y), (f.x, f.y)) {   // two clicks, as any route (0x4f5c80)
            if hero.tradeTarget === f, hero.plan.isEmpty { hero.tradeTarget = nil; pendingTrade = (hero, f); moveEnded(hero) }
            else { hero.plan = []; hero.tradeTarget = f; hero.target = nil; hero.planGoal = (f.x, f.y) }
            return
        }
        let cells = GameState.directions.map { (f.x + $0.0, f.y + $0.1) }.filter { isVacant($0, for: hero) && enemyAt($0.0, $0.1) == nil }
        var best: [(x: Int, y: Int)]? = nil, bestN = Int.max
        for c in cells {
            if c == (hero.x, hero.y) { best = []; bestN = 0; continue }
            if let p = passability.path(from: (hero.x, hero.y), to: c), p.count < bestN { best = p; bestN = p.count }
        }
        guard let route = best else { return }
        if hero.tradeTarget === f, !hero.plan.isEmpty { hero.path = hero.plan; hero.plan = []; hero.progress = 0; return }
        hero.plan = route; hero.tradeTarget = f; hero.target = nil; hero.planGoal = (f.x, f.y)
    }

    /// The first free neighbour of the army's cell in the direction order (0x4f9be0 with the filter
    /// 0x4fa120): on the map, one step away, the same land / water kind, nothing standing there.
    public func splitCell(for h: Hero) -> (Int, Int)? {
        let l = min(h.z, passabilities.count - 1)
        let p = passabilities[l]
        let from = standingCell(h)
        return GameState.firstNeighbour(of: from) { c in
            p.isFree(c.0, c.1) && p.canStep(from: from.0, from.1, to: c.0, c.1)
                && !heroes.contains(where: { $0 !== h && $0.z == h.z && standingCell($0) == c })
                && !enemyHeroes.contains(where: { $0.z == h.z && $0.x == c.0 && $0.y == c.1 })
                && !boats.contains(where: { $0.z == h.z && $0.x == c.0 && $0.y == c.1 })
        }
    }
    /// The first of the 8 neighbours, in the exe's direction order, that `ok` accepts.
    static func firstNeighbour(of c: (Int, Int), _ ok: ((Int, Int)) -> Bool) -> (Int, Int)? {
        GameState.directions.lazy.map { (c.0 + $0.0, c.1 + $0.1) }.first(where: ok)
    }
    /// Can the army screen offer a new army next to this one (0x528c90): on land, fewer than 8
    /// armies, a free neighbour.
    public func canSplit(_ h: Hero) -> Bool {
        h.boat == nil && heroes.count < GameState.maxArmies && heroes.contains { $0 === h } && splitCell(for: h) != nil
    }
    /// Movement (in cells) a stack pays to join the army standing on `a` and on `b` (0x528e80):
    /// the raw terrain cost of that army's cell, both x1.5 when the cells are diagonal neighbours.
    public func transferCosts(_ a: (Int, Int), _ b: (Int, Int), level l: Int) -> (intoA: Float, intoB: Float) {
        GameState.transferCosts(a, b) { c in
            guard l < map.cells.count, c.0 >= 0, c.1 >= 0, c.0 < map.size, c.1 < map.size else { return nil }
            return map.cells[l][c.0 * map.size + c.1]?.type
        }
    }
    static func transferCosts(_ a: (Int, Int), _ b: (Int, Int), terrain: ((Int, Int)) -> UInt8?) -> (intoA: Float, intoB: Float) {
        func raw(_ c: (Int, Int)) -> Int { terrain(c).flatMap { GameState.terrainCost100[$0] } ?? 100 }
        var ca = raw(a), cb = raw(b)
        if a.0 != b.0 && a.1 != b.1 { ca += ca >> 1; cb += cb >> 1 }
        return (Float(ca) / 100, Float(cb) / 100)
    }

    /// A heroless army's map figure: its strongest creature (highest level, then most hit points in all).
    public func strongestCreature(_ stacks: [Hero.Stack]) -> String? {
        stacks.max { a, b in
            let ca = tables?.creature(a.creature), cb = tables?.creature(b.creature)
            let ka = (ca?.level ?? 0, (ca?.hitPoints ?? 0) * a.count), kb = (cb?.level ?? 0, (cb?.hitPoints ?? 0) * b.count)
            return ka < kb
        }.map { tables?.creature($0.creature)?.name ?? $0.creature }
    }
    /// A new army carrier for creatures without a hero, standing where `at` stands.
    func heroless(like at: Hero) -> Hero {
        let h = Hero(actor: "", x: at.x, y: at.y, movement: at.movement)
        h.heroless = true; h.name = ""; h.z = at.z; h.owner = at.owner; h.facing = at.facing
        h.alignment = at.alignment; h.home = at.home; h.listRank = at.listRank
        return h
    }
    /// After a heroless army's creatures changed: its figure is its strongest creature.
    func refreshHeroless(_ h: Hero) {
        guard h.heroless else { return }
        if let c = strongestCreature(h.army) { h.actor = c }
        if let c = h.army.first.flatMap({ tables?.creature($0.creature) }) { h.alignment = c.alignment }
    }
}

/// The army screen's working rows (t_army_dialog with its second army): the army on top, the
/// second army (a trade partner, or the empty new army next to it) below. Each place's movement
/// already spent today rides with it; moving a stack into the other row costs that row's
/// entry cost, refunded when it goes back (the slot keeps what it paid, window+0x154).
public final class ArmyExchange {
    public let main: Hero
    /// The trade partner; nil for the new army.
    public let other: Hero?
    /// Where the new army will stand (nil for a trade).
    public let newCell: (Int, Int)?
    public var rows: [[ArmySlot?]]
    /// Movement already spent (cells) by each place's occupant, and what it paid to come in.
    public var spent: [[Float]]
    public var credit: [[Float]]
    /// Movement to come into row 0 / row 1.
    public let entry: [Float]
    /// The rows' armies' per-day movement before the exchange.
    let base: [Float]

    public var isNewArmy: Bool { other == nil && newCell != nil }
    /// One row only (no new army possible, Single_Ring_Background).
    public var isSingle: Bool { other == nil && newCell == nil }
    /// Rows without movement rules (the town variant's garrison and visiting army).
    public static func rows(_ h: Hero, _ rows: [[ArmySlot?]]) -> ArmyExchange {
        ArmyExchange(main: h, other: nil, newCell: nil, rows: rows, spent: rows.map { $0.map { _ in 0 } }, entry: [0, 0], base: [0, 0])
    }

    init(main: Hero, other: Hero?, newCell: (Int, Int)?, rows: [[ArmySlot?]], spent: [[Float]], entry: [Float], base: [Float]) {
        self.main = main; self.other = other; self.newCell = newCell; self.rows = rows; self.spent = spent
        self.credit = rows.map { $0.map { _ in 0 } }; self.entry = entry; self.base = base
    }

    public enum Refusal: Equatable { case needsMovement(plural: Bool), nothing }

    /// Movement the place's occupant still has (its row army's day minus what it spent).
    func remaining(_ row: Int, _ k: Int) -> Float { max(0, base[row] - spent[row][k]) }

    /// What moving from -> to would cost the stacks that change rows (nil when staying in a row),
    /// with the refund for one going back: (cost for the moving one, cost for one swapped back).
    func transfer(from: (row: Int, k: Int), to: (row: Int, k: Int)) -> (go: Float, back: Float)? {
        guard from.row != to.row else { return nil }
        let go = credit[from.row][from.k] > 0 ? -credit[from.row][from.k] : entry[to.row]
        let back = credit[to.row][to.k] > 0 ? -credit[to.row][to.k] : entry[from.row]
        return (go, back)
    }

    /// A drop in the army screen (0x646d40): an empty place takes the stack (or `split` of it), the
    /// same creature merges, anything else swaps; a stack changing rows needs the movement (0x646380).
    @discardableResult
    public func move(from: (row: Int, k: Int), to: (row: Int, k: Int), split: Int? = nil) -> Refusal? {
        guard from != to, let src = rows[from.row][from.k] else { return .nothing }
        let dst = rows[to.row][to.k]
        let merge = src.stack != nil && (dst == nil || dst?.stack?.creature == src.stack?.creature)
        let n = src.stack.map { min($0.count, split ?? $0.count) } ?? 1
        if let t = transfer(from: from, to: to) {
            if t.go > 0, t.go > remaining(from.row, from.k) + 0.0001 { return .needsMovement(plural: n != 1) }
            if !merge, dst != nil, t.back > 0, t.back > remaining(to.row, to.k) + 0.0001 {
                return .needsMovement(plural: (dst?.stack?.count ?? 1) != 1)
            }
        }
        let t = transfer(from: from, to: to)
        let goSpent = max(0, spent[from.row][from.k] + (t?.go ?? 0)), goCredit = t.map { $0.go > 0 ? $0.go : 0 } ?? credit[from.row][from.k]
        if merge, let a = src.stack {
            guard n > 0 else { return .nothing }
            let have = dst?.stack?.count ?? 0
            rows[to.row][to.k] = .stack(Hero.Stack(creature: a.creature, count: have + n))
            // a merged stack moves at its slower part's pace
            spent[to.row][to.k] = dst == nil ? goSpent : max(spent[to.row][to.k], goSpent)
            credit[to.row][to.k] = dst == nil ? goCredit : min(credit[to.row][to.k], goCredit)
            if n >= a.count { rows[from.row][from.k] = nil; credit[from.row][from.k] = 0 }
            else { rows[from.row][from.k] = .stack(Hero.Stack(creature: a.creature, count: a.count - n)) }
            return nil
        }
        let backSpent = max(0, spent[to.row][to.k] + (t?.back ?? 0)), backCredit = t.map { $0.back > 0 ? $0.back : 0 } ?? credit[to.row][to.k]
        rows[to.row][to.k] = src; rows[from.row][from.k] = dst
        spent[to.row][to.k] = goSpent; credit[to.row][to.k] = goCredit
        spent[from.row][from.k] = dst == nil ? spent[from.row][from.k] : backSpent
        credit[from.row][from.k] = dst == nil ? 0 : backCredit
        return nil
    }
    /// Move Army Down / Up (0x530f80 / 0x531010 -> 0x647280): everything that can pay its way.
    public func moveAll(from: Int, to: Int) {
        for k in 0..<GameState.rowSlots where rows[from][k] != nil {
            let s = rows[from][k]!
            if let a = s.stack, let j = rows[to].firstIndex(where: { $0?.stack?.creature == a.creature }) {
                move(from: (from, k), to: (to, j))
            } else if let j = rows[to].firstIndex(where: { $0 == nil }) {
                move(from: (from, k), to: (to, j))
            }
        }
    }

}

extension GameState {
    /// The army screen for one army (0x527e70 / 0x528c90): with the empty new army below when a
    /// split is possible, else nil (one row).
    public func exchange(for h: Hero) -> ArmyExchange? {
        guard canSplit(h), let cell = splitCell(for: h) else { return nil }
        let costs = transferCosts(standingCell(h), cell, level: h.z)
        let s = h.maxMovement - h.movement
        return ArmyExchange(main: h, other: nil, newCell: cell, rows: [armySlots(h), [ArmySlot?](repeating: nil, count: GameState.rowSlots)],
                            spent: [[Float](repeating: s, count: GameState.rowSlots), [Float](repeating: s, count: GameState.rowSlots)],
                            entry: [costs.intoA, costs.intoB], base: [h.maxMovement, h.maxMovement])
    }
    /// The army screen with one row (on a ship, 8 armies, no free neighbour).
    public func singleRow(_ h: Hero) -> ArmyExchange {
        let s = h.maxMovement - h.movement
        return ArmyExchange(main: h, other: nil, newCell: nil, rows: [armySlots(h), [ArmySlot?](repeating: nil, count: GameState.rowSlots)],
                            spent: [[Float](repeating: s, count: GameState.rowSlots), [Float](repeating: s, count: GameState.rowSlots)],
                            entry: [0, 0], base: [h.maxMovement, h.maxMovement])
    }
    /// The army screen of a trade: the moving army on top, the one it met below (0x522c6a).
    public func exchange(_ a: Hero, with b: Hero) -> ArmyExchange {
        let costs = transferCosts(standingCell(a), standingCell(b), level: a.z)
        return ArmyExchange(main: a, other: b, newCell: nil, rows: [armySlots(a), armySlots(b)],
                            spent: [[Float](repeating: a.maxMovement - a.movement, count: GameState.rowSlots), [Float](repeating: b.maxMovement - b.movement, count: GameState.rowSlots)],
                            entry: [costs.intoA, costs.intoB], base: [a.maxMovement, b.maxMovement])
    }


    /// The army screen closes (0x529050): the new army is placed next to the army (0x4bada0) and
    /// selected, a trade's armies take their rows, armies left empty leave the map (0x4bb0f0).
    /// Returns the army now selected.
    @discardableResult
    public func finishExchange(_ x: ArmyExchange) -> Hero? {
        // the army then selected may stand in a stack's zone: it may be attacked (0x529306 -> 0x4f81e0)
        let selected = placeExchange(x)
        if let s = selected { moveEnded(s) }
        return selected
    }
    func placeExchange(_ x: ArmyExchange) -> Hero? {
        let mainRank = x.main.listRank
        func spentOf(_ row: Int) -> Float { (0..<GameState.rowSlots).filter { x.rows[row][$0] != nil }.map { x.spent[row][$0] }.max() ?? 0 }
        func settle(_ h: Hero?, _ row: Int) {
            guard let h = h else { return }
            h.maxMovement = armyMovement(h); h.movement = max(0, h.maxMovement - spentOf(row))
        }
        if let o = x.other {
            let a = setArmy(x.main, x.rows[0]), b = setArmy(o, x.rows[1])
            settle(a, 0); settle(b, 1)
            if let a = a { select(a); return a }
            if let b = b { select(b); return b }
            return nil
        }
        var rows = x.rows
        let cell = x.isSingle ? nil : splitCell(for: x.main) ?? x.newCell
        if rows[1].contains(where: { $0 != nil }), cell == nil {   // nowhere to stand: the creatures stay
            GameState.moveAll(&rows, from: 1, to: 0)
        }
        let a = setArmy(x.main, rows[0])
        settle(a, 0)
        guard rows[1].contains(where: { $0 != nil }), let c = cell else { return a }
        let carrier = heroless(like: x.main)
        carrier.x = c.0; carrier.y = c.1; carrier.listRank = nextListRank()
        carrier.facing = Hero.facing(dx: c.0 - x.main.x, dy: c.1 - x.main.y)
        heroes.append(carrier)
        let b = setArmy(carrier, rows[1])
        settle(b, 1)
        if a == nil, let b = b { b.listRank = mainRank }
        if let b = b { select(b) }
        updateVision()
        return b ?? a
    }
}
