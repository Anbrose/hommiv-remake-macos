import Foundation

/// A tactical battle on a battlefield lattice: two sides, units acting in speed order,
/// movement by diamond cells, melee with retaliation, shooting, wait and defend. Damage
/// follows the rules read from the game; the screen drives it one action at a time.
public final class Battle {
    public final class Unit {
        public let id: Int
        public let side: Int                  // 0 attacker (bottom-left), 1 defender (top-right)
        public var stats: Combatant
        public let keyword: String            // creature keyword (icons), or the hero's keyword
        public let actor: String              // "Squire" / "hero.life_fighter_male"
        public var move: Float                // cells of movement per turn (from Speed)
        public var shots: Int
        public var col: Int, row: Int
        public var facing: String
        public var acted = false, waited = false, defended = false, retaliated = false
        public var alive: Bool { stats.alive }
        init(id: Int, side: Int, stats: Combatant, keyword: String, actor: String, move: Float, shots: Int, col: Int, row: Int) {
            self.id = id; self.side = side; self.stats = stats; self.keyword = keyword; self.actor = actor; self.move = move; self.shots = shots
            self.col = col; self.row = row; facing = side == 0 ? "ne" : "sw"
        }
    }

    /// What just happened, for the screen to animate in order.
    public enum Event {
        case move(unit: Int, path: [(Int, Int)])
        case melee(unit: Int, target: Int, damage: Int, killed: Int)
        case shoot(unit: Int, target: Int, damage: Int, killed: Int)
        case die(unit: Int)
        case defend(unit: Int)
        case wait(unit: Int)
        case newRound(Int)
        case finished(attackerWon: Bool)
    }

    public private(set) var units: [Unit] = []
    public let field: Battlefield
    public private(set) var round = 0
    public private(set) var order: [Int] = []       // unit ids still to act this round
    public private(set) var events: [Event] = []
    public private(set) var experience = 0           // earned by the attacker
    public private(set) var finished: Bool? = nil     // attackerWon once over
    var rng: GameRandom

    /// Cells of movement per point of Speed (a Speed 4 orc reaches about 7 diamonds).
    public static let cellsPerSpeed: Float = 1.75

    public var current: Unit? { order.first.flatMap { id in units.first { $0.id == id } } }
    public func unit(_ id: Int) -> Unit { units.first { $0.id == id }! }

    public init(field: Battlefield, attackers: [(Combatant, keyword: String, actor: String, shots: Int)],
                defenders: [(Combatant, keyword: String, actor: String, shots: Int)], seed: Int) {
        self.field = field
        rng = GameRandom(seed: seed)
        var id = 0
        // the sides deploy in the bottom-left and top-right corners, in two staggered files
        for (side, list) in [(0, attackers), (1, defenders)] {
            let anchor = side == 0 ? (col: 6, row: Battlefield.rows - 10) : (col: Battlefield.columns - 7, row: 10)
            for (k, u) in list.enumerated() {
                let file = k % 2, rank = k / 2
                // along the world diagonal: each rank two cells up-right, the second file one cell down-right
                var col = anchor.col + (side == 0 ? 1 : -1) * (rank * 2 + file), row = anchor.row - rank * 2 + file * 2
                if !Battlefield.valid(col, row) { col += 1 }
                var placed = false
                for r in 0..<12 where !placed {
                    for dc in -r...r { for dr in -r...r where !placed && Battlefield.valid(col + dc, row + dr) {
                        let c = col + dc, rr = row + dr
                        if field.isOpen(c, rr), !units.contains(where: { $0.col == c && $0.row == rr }) {
                            units.append(Unit(id: id, side: side, stats: u.0, keyword: u.keyword, actor: u.actor, move: Float(max(1, u.0.speed)) * Battle.cellsPerSpeed, shots: u.shots, col: c, row: rr))
                            placed = true
                        }
                    } }
                }
                id += 1
            }
        }
        startRound()
    }

    func startRound() {
        round += 1
        for u in units { u.acted = false; u.waited = false; u.defended = false; u.stats.defending = false; u.retaliated = false }
        order = units.filter { $0.alive }.sorted { ($0.stats.speed, -$0.side, -$0.id) > ($1.stats.speed, -$1.side, -$1.id) }.map { $0.id }
        events.append(.newRound(round))
    }

    /// The eight neighbours of a lattice cell with their step cost: along an edge 1 (a world
    /// axis step), across a vertex 1.4 (a world diagonal).
    static let steps: [(dc: Int, dr: Int, cost: Float)] = [(1, 1, 1), (-1, -1, 1), (1, -1, 1), (-1, 1, 1), (2, 0, 1.4), (-2, 0, 1.4), (0, 2, 1.4), (0, -2, 1.4)]

    func occupied(_ col: Int, _ row: Int, except id: Int) -> Bool { units.contains { $0.alive && $0.id != id && $0.col == col && $0.row == row } }

    /// Cells the unit can reach this turn with the movement it has, with the cost.
    public func reachable(_ u: Unit) -> [Int: Float] {
        var dist: [Int: Float] = [Battlefield.key(u.col, u.row): 0]
        var open: [(Float, Int, Int)] = [(0, u.col, u.row)]
        while !open.isEmpty {
            var best = 0
            for k in 1..<open.count where open[k].0 < open[best].0 { best = k }
            let (c, col, row) = open.remove(at: best)
            if c > dist[Battlefield.key(col, row), default: .infinity] { continue }
            for s in Battle.steps {
                let nc = col + s.dc, nr = row + s.dr
                guard field.isOpen(nc, nr), !occupied(nc, nr, except: u.id) else { continue }
                if s.cost > 1 {   // no squeezing between two blocked edge-neighbours
                    let a = (col + (s.dc + s.dr) / 2, row + (s.dr + s.dc) / 2), b = (col + (s.dc - s.dr) / 2, row + (s.dr - s.dc) / 2)
                    if !(field.isOpen(a.0, a.1) && !occupied(a.0, a.1, except: u.id)) && !(field.isOpen(b.0, b.1) && !occupied(b.0, b.1, except: u.id)) { continue }
                }
                let nc2 = c + s.cost
                guard nc2 <= u.move + 0.001 else { continue }
                let key = Battlefield.key(nc, nr)
                if nc2 < dist[key, default: .infinity] { dist[key] = nc2; open.append((nc2, nc, nr)) }
            }
        }
        return dist
    }

    /// The cheapest path to a reachable cell (excluding the start, including the goal).
    public func path(_ u: Unit, to gc: Int, _ gr: Int) -> [(Int, Int)]? {
        let reach = reachable(u)
        guard reach[Battlefield.key(gc, gr)] != nil else { return nil }
        var out: [(Int, Int)] = []
        var col = gc, row = gr
        while !(col == u.col && row == u.row) {
            out.append((col, row))
            let here = reach[Battlefield.key(col, row)]!
            var next: (Int, Int)? = nil
            for s in Battle.steps {
                let pc = col - s.dc, pr = row - s.dr
                if let c = reach[Battlefield.key(pc, pr)], abs(here - c - s.cost) < 0.01 { next = (pc, pr); break }
            }
            guard let n = next else { return nil }
            (col, row) = n
        }
        return out.reversed()
    }

    public static func adjacent(_ a: Unit, _ b: Unit) -> Bool {
        let dc = abs(a.col - b.col), dr = abs(a.row - b.row)
        return (dc == 1 && dr == 1) || (dc == 2 && dr == 0) || (dc == 0 && dr == 2)
    }
    /// The screen facing from one cell towards another.
    public static func facing(dc: Int, dr: Int) -> String {
        switch (dc.signum(), dr.signum()) {
        case (1, 1): return "se"; case (-1, -1): return "nw"; case (1, -1): return "ne"; case (-1, 1): return "sw"
        case (1, 0): return "e"; case (-1, 0): return "w"; case (0, 1): return "s"; case (0, -1): return "n"
        default: return "ne"
        }
    }

    /// The damage range a melee or ranged attack would do (for the attack cursor's text).
    public func damageRange(_ a: Unit, _ b: Unit, ranged: Bool) -> (Int, Int) { QuickCombat.damageRange(a.stats, b.stats, ranged: ranged) }

    func hit(_ a: Unit, _ b: Unit, ranged: Bool) {
        let dmg = QuickCombat.damage(a.stats, b.stats, rng: &rng, ranged: ranged)
        let killed = b.stats.take(dmg)
        if a.side == 0 { experience += killed * b.stats.experience }
        events.append(ranged ? .shoot(unit: a.id, target: b.id, damage: dmg, killed: killed) : .melee(unit: a.id, target: b.id, damage: dmg, killed: killed))
        if !b.alive { events.append(.die(unit: b.id)) }
    }

    func endAction(_ u: Unit) {
        u.acted = true
        order.removeAll { $0 == u.id }
        checkEnd()
        if finished == nil, order.isEmpty { startRound() }
    }

    func checkEnd() {
        let a = units.contains { $0.side == 0 && $0.alive }, d = units.contains { $0.side == 1 && $0.alive }
        if !(a && d) || round > 60 { finished = a; events.append(.finished(attackerWon: a)) }
    }

    // MARK: actions of the current unit

    public func move(to col: Int, _ row: Int) -> Bool {
        guard finished == nil, let u = current, let p = path(u, to: col, row), !p.isEmpty else { return false }
        events.append(.move(unit: u.id, path: p))
        let prev = p.count > 1 ? p[p.count - 2] : (u.col, u.row)
        u.facing = Battle.facing(dc: col - prev.0, dr: row - prev.1)
        u.col = col; u.row = row
        endAction(u)
        return true
    }

    /// Walk next to the target (if needed) and strike; the target strikes back once per round.
    public func attack(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        if !Battle.adjacent(u, t) {
            let reach = reachable(u)
            var best: (Int, Int)? = nil
            var bestCost = Float.infinity
            for s in Battle.steps {
                let c = t.col + s.dc, r = t.row + s.dr
                if let cost = reach[Battlefield.key(c, r)], cost < bestCost { bestCost = cost; best = (c, r) }
            }
            guard let b = best, let p = path(u, to: b.0, b.1) else { return false }
            if !p.isEmpty { events.append(.move(unit: u.id, path: p)); u.col = b.0; u.row = b.1 }
        }
        u.facing = Battle.facing(dc: t.col - u.col, dr: t.row - u.row)
        t.facing = Battle.facing(dc: u.col - t.col, dr: u.row - t.row)
        meleeExchange(u, t)
        endAction(u)
        return true
    }

    /// Can the target strike back at this attacker now? Not against No Retaliation attackers,
    /// once per round unless it has Unlimited Retaliation.
    func canRetaliate(_ t: Unit, against a: Unit) -> Bool {
        t.alive && !a.stats.has("no retaliation") && (!t.retaliated || t.stats.has("unlimited retaliation"))
    }
    /// Does the unit strike first in this exchange? First Strike, unless the other side
    /// negates it (Negate First Strike) or has First Strike too.
    func strikesFirst(_ x: Unit, over y: Unit) -> Bool {
        x.stats.has("first strike") && !y.stats.has("negate first strike") && !y.stats.has("first strike")
    }

    /// A melee exchange, as the game plays it: the attacker strikes, then the target strikes
    /// back; a defender with First Strike strikes back before the blow lands. Two Attacks
    /// strike again after the retaliation.
    func meleeExchange(_ u: Unit, _ t: Unit) {
        let retaliates = canRetaliate(t, against: u)
        if retaliates, strikesFirst(t, over: u) {
            t.retaliated = true
            hit(t, u, ranged: false)
            if u.alive { hit(u, t, ranged: false) }
        } else {
            hit(u, t, ranged: false)
            if retaliates, t.alive { t.retaliated = true; hit(t, u, ranged: false) }
        }
        if u.alive, t.alive, u.stats.has("two attacks") { hit(u, t, ranged: false) }
    }

    public func shoot(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, u.shots > 0, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        if units.contains(where: { $0.alive && $0.side != u.side && Battle.adjacent(u, $0) }) { return attack(targetId) }
        u.shots -= 1
        u.facing = Battle.facing(dc: t.col - u.col, dr: t.row - u.row)
        hit(u, t, ranged: true)
        endAction(u)
        return true
    }

    public func defend() {
        guard finished == nil, let u = current else { return }
        u.defended = true
        u.stats.defending = true
        events.append(.defend(unit: u.id))
        endAction(u)
    }

    /// Wait: act at the end of the round instead.
    public func wait() {
        guard finished == nil, let u = current, !u.waited else { defend(); return }
        u.waited = true
        events.append(.wait(unit: u.id))
        order.removeFirst()
        order.append(u.id)
    }

    /// A simple opponent: shooters shoot the most dangerous enemy, others walk at the nearest one.
    public func autoAct() {
        guard finished == nil, let u = current else { return }
        let enemies = units.filter { $0.alive && $0.side != u.side }
        guard !enemies.isEmpty else { return }
        if u.shots > 0, !enemies.contains(where: { Battle.adjacent(u, $0) }),
           let t = enemies.max(by: { QuickCombat.threat($0.stats) < QuickCombat.threat($1.stats) }) { _ = shoot(t.id); return }
        let reach = reachable(u)
        let reachableEnemies = enemies.filter { e in Battle.adjacent(u, e) || Battle.steps.contains { reach[Battlefield.key(e.col + $0.dc, e.row + $0.dr)] != nil } }
        if let t = reachableEnemies.max(by: { QuickCombat.threat($0.stats) < QuickCombat.threat($1.stats) }) { _ = attack(t.id); return }
        let nearest = enemies.min { abs($0.col - u.col) + abs($0.row - u.row) < abs($1.col - u.col) + abs($1.row - u.row) }!
        var best: (Int, Int)? = nil
        var bestD = Int.max
        for (key, _) in reach {
            let c = key % Battlefield.columns, r = key / Battlefield.columns
            let d = abs(c - nearest.col) + abs(r - nearest.row)
            if d < bestD { bestD = d; best = (c, r) }
        }
        if let b = best, !(b.0 == u.col && b.1 == u.row) { _ = move(to: b.0, b.1) } else { defend() }
    }

    /// Resolve the rest of the battle instantly.
    public func autoResolve() {
        var guardCount = 0
        while finished == nil, guardCount < 2000 { autoAct(); guardCount += 1 }
    }

    public func takeEvents() -> [Event] { let e = events; events.removeAll(); return e }
}
