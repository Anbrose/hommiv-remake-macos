import Foundation

/// A tactical battle on a battlefield grid: two sides, units acting in speed order, movement
/// by cells, melee with retaliation, shooting, wait and defend. The rules follow the quick
/// combat formulas; the screen drives it one action at a time.
public final class Battle {
    public final class Unit {
        public let id: Int
        public let side: Int                  // 0 attacker (left), 1 defender (right)
        public var stats: Combatant
        public let keyword: String            // creature keyword (icons), or the hero's keyword
        public let actor: String              // "Squire" / "hero.life_fighter_male"
        public var move: Int
        public var shots: Int
        public var x: Int, y: Int
        public var facing: String
        public var acted = false, waited = false, defended = false, retaliated = false
        public var alive: Bool { stats.alive }
        init(id: Int, side: Int, stats: Combatant, keyword: String, actor: String, move: Int, shots: Int, x: Int, y: Int) {
            self.id = id; self.side = side; self.stats = stats; self.keyword = keyword; self.actor = actor; self.move = move; self.shots = shots
            self.x = x; self.y = y; facing = side == 0 ? "e" : "w"
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
    var rng: UInt64

    public var current: Unit? { order.first.flatMap { id in units.first { $0.id == id } } }
    public func unit(_ id: Int) -> Unit { units.first { $0.id == id }! }

    public init(field: Battlefield, attackers: [(Combatant, keyword: String, actor: String, move: Int, shots: Int)],
                defenders: [(Combatant, keyword: String, actor: String, move: Int, shots: Int)], seed: Int) {
        self.field = field
        rng = UInt64(truncatingIfNeeded: seed &* 6364136223846793005 &+ 1442695040888963407)
        var id = 0
        // the sides line up on open cells near the left and right edges, spread over the middle rows
        for (side, list) in [(0, attackers), (1, defenders)] {
            let x0 = side == 0 ? 12 : Battlefield.columns - 13
            let n = list.count
            for (k, u) in list.enumerated() {
                let yTarget = 30 + (k - (n - 1) / 2) * 6
                var placed = false
                for r in 0..<20 where !placed {
                    for (dx, dy) in [(0, r), (0, -r), (side == 0 ? 1 : -1, r), (side == 0 ? 1 : -1, -r), (side == 0 ? -1 : 1, r)] {
                        let x = x0 + dx, y = yTarget + dy
                        if field.isOpen(x, y), !units.contains(where: { $0.x == x && $0.y == y }) {
                            units.append(Unit(id: id, side: side, stats: u.0, keyword: u.keyword, actor: u.actor, move: u.move, shots: u.shots, x: x, y: y))
                            placed = true; break
                        }
                    }
                }
                id += 1
            }
        }
        startRound()
    }

    func rand() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float((rng >> 33) % 1000) / 1000 }

    func startRound() {
        round += 1
        for u in units { u.acted = false; u.waited = false; u.defended = false; u.retaliated = false }
        order = units.filter { $0.alive }.sorted { ($0.stats.speed, -$0.side, -$0.id) > ($1.stats.speed, -$1.side, -$1.id) }.map { $0.id }
        events.append(.newRound(round))
    }

    /// Cells the unit can reach this turn with the movement points left, with the cost.
    public func reachable(_ u: Unit) -> [Int: Float] {
        var dist: [Int: Float] = [u.y * Battlefield.columns + u.x: 0]
        var open: [(Float, Int, Int)] = [(0, u.x, u.y)]
        let budget = Float(u.move)
        while !open.isEmpty {
            var best = 0
            for k in 1..<open.count where open[k].0 < open[best].0 { best = k }
            let (c, x, y) = open.remove(at: best)
            if c > dist[y * Battlefield.columns + x, default: .infinity] { continue }
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard field.isOpen(nx, ny), !units.contains(where: { $0.alive && $0.id != u.id && $0.x == nx && $0.y == ny }) else { continue }
                if dx != 0, dy != 0, !(field.isOpen(x + dx, y) || field.isOpen(x, y + dy)) { continue }   // no squeezing through corners
                let nc = c + (dx != 0 && dy != 0 ? 1.5 : 1)
                guard nc <= budget + 0.001 else { continue }
                let key = ny * Battlefield.columns + nx
                if nc < dist[key, default: .infinity] { dist[key] = nc; open.append((nc, nx, ny)) }
            } }
        }
        return dist
    }

    /// The cheapest path to a reachable cell (excluding the start, including the goal).
    public func path(_ u: Unit, to gx: Int, _ gy: Int) -> [(Int, Int)]? {
        let reach = reachable(u)
        guard reach[gy * Battlefield.columns + gx] != nil else { return nil }
        var out: [(Int, Int)] = []
        var x = gx, y = gy
        while !(x == u.x && y == u.y) {
            out.append((x, y))
            let here = reach[y * Battlefield.columns + x]!
            var next: (Int, Int)? = nil
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                let px = x + dx, py = y + dy
                if let c = reach[py * Battlefield.columns + px], abs(here - c - (dx != 0 && dy != 0 ? 1.5 : 1)) < 0.01 { next = (px, py) }
            } }
            guard let n = next else { return nil }
            (x, y) = n
        }
        return out.reversed()
    }

    public static func adjacent(_ a: Unit, _ b: Unit) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
    public static func facing(dx: Int, dy: Int) -> String {
        switch (dx.signum(), dy.signum()) {
        case (1, 0): return "e"; case (-1, 0): return "w"; case (0, 1): return "s"; case (0, -1): return "n"
        case (1, 1): return "se"; case (-1, -1): return "nw"; case (1, -1): return "ne"; case (-1, 1): return "sw"
        default: return "e"
        }
    }

    func damage(_ a: Unit, _ b: Unit) -> Int {
        var d = QuickCombat.damage(a.stats, b.stats, roll: rand())
        if b.defended { d = max(1, d / 2) }
        return d
    }

    func hit(_ a: Unit, _ b: Unit, ranged: Bool) {
        let dmg = damage(a, b)
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

    public func move(to x: Int, _ y: Int) -> Bool {
        guard finished == nil, let u = current, let p = path(u, to: x, y), !p.isEmpty else { return false }
        events.append(.move(unit: u.id, path: p))
        if let last = p.last { u.facing = Battle.facing(dx: last.0 - (p.count > 1 ? p[p.count - 2].0 : u.x), dy: last.1 - (p.count > 1 ? p[p.count - 2].1 : u.y)) }
        u.x = x; u.y = y
        endAction(u)
        return true
    }

    /// Walk next to the target (if needed) and strike; the target strikes back once per round.
    public func attack(_ targetId: Int, from cell: (Int, Int)? = nil) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        if !Battle.adjacent(u, t) {
            // the reachable cell next to the target closest to us
            let reach = reachable(u)
            var best: (Int, Int)? = cell
            if best == nil {
                var bestCost = Float.infinity
                for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                    let cx = t.x + dx, cy = t.y + dy
                    if let c = reach[cy * Battlefield.columns + cx], c < bestCost { bestCost = c; best = (cx, cy) }
                } }
            }
            guard let b = best, let p = path(u, to: b.0, b.1) else { return false }
            if !p.isEmpty { events.append(.move(unit: u.id, path: p)); u.x = b.0; u.y = b.1 }
        }
        u.facing = Battle.facing(dx: t.x - u.x, dy: t.y - u.y)
        hit(u, t, ranged: false)
        if t.alive, !t.retaliated {
            t.retaliated = true
            t.facing = Battle.facing(dx: u.x - t.x, dy: u.y - t.y)
            hit(t, u, ranged: false)
        }
        endAction(u)
        return true
    }

    public func shoot(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, u.shots > 0, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        // shooting next to an enemy is not allowed: it becomes a melee
        if units.contains(where: { $0.alive && $0.side != u.side && Battle.adjacent(u, $0) }) { return attack(targetId) }
        u.shots -= 1
        u.facing = Battle.facing(dx: t.x - u.x, dy: t.y - u.y)
        hit(u, t, ranged: true)
        endAction(u)
        return true
    }

    public func defend() {
        guard finished == nil, let u = current else { return }
        u.defended = true
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
        // an enemy we can reach this turn: the most dangerous
        let reachableEnemies = enemies.filter { e in Battle.adjacent(u, e) || (-1...1).contains { dx in (-1...1).contains { dy in reach[(e.y + dy) * Battlefield.columns + e.x + dx] != nil } } }
        if let t = reachableEnemies.max(by: { QuickCombat.threat($0.stats) < QuickCombat.threat($1.stats) }) { _ = attack(t.id); return }
        // otherwise step towards the nearest enemy
        let nearest = enemies.min { abs($0.x - u.x) + abs($0.y - u.y) < abs($1.x - u.x) + abs($1.y - u.y) }!
        var best: (Int, Int)? = nil
        var bestD = Int.max
        for (key, _) in reach {
            let x = key % Battlefield.columns, y = key / Battlefield.columns
            let d = max(abs(x - nearest.x), abs(y - nearest.y))
            if d < bestD { bestD = d; best = (x, y) }
        }
        if let b = best, !(b.0 == u.x && b.1 == u.y) { _ = move(to: b.0, b.1) } else { defend() }
    }

    /// Resolve the rest of the battle instantly with the quick-combat rules.
    public func autoResolve() {
        var guardCount = 0
        while finished == nil, guardCount < 2000 { autoAct(); guardCount += 1 }
    }

    /// Survivors of a side as combatants (for the army after the battle).
    public func survivors(side: Int) -> [Unit] { units.filter { $0.side == side } }

    public func takeEvents() -> [Event] { let e = events; events.removeAll(); return e }
}
