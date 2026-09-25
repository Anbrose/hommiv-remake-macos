import Foundation

/// A tactical battle on the combat grid: two sides, units acting in Speed order, each
/// occupying size x size cells and walking up to Move cells a turn, melee with retaliation
/// (First Strike, No Retaliation, ...), shooting with the game's range and obstacle
/// divisors, wait and defend. Damage follows the rules read from heroes4.exe.
public final class Battle {
    public final class Unit {
        public let id: Int
        public let side: Int                  // 0 attacker (bottom-left), 1 defender (top-right)
        public var stats: Combatant
        public let keyword: String            // creature keyword (icons), or the hero's keyword
        public let actor: String              // "Squire" / "hero.life_fighter_male"
        public let size: Int                  // footprint in cells (combat_actor byte 2)
        public var move: Int                  // cells per turn (the creature's Move)
        public var shots: Int
        public var x: Int, y: Int             // top corner of the footprint
        public var facing: String
        public var acted = false, waited = false, defended = false, retaliated = false
        public var alive: Bool { stats.alive }
        /// Centre of the footprint in cell units.
        public var centre: (Float, Float) { (Float(x) + Float(size) / 2, Float(y) + Float(size) / 2) }
        init(id: Int, side: Int, stats: Combatant, keyword: String, actor: String, size: Int, move: Int, shots: Int, x: Int, y: Int) {
            self.id = id; self.side = side; self.stats = stats; self.keyword = keyword; self.actor = actor; self.size = size
            self.move = move; self.shots = shots; self.x = x; self.y = y
            facing = side == 0 ? "ne" : "sw"
        }
    }

    public struct Fighter {
        public var stats: Combatant; public var keyword: String; public var actor: String; public var size: Int; public var move: Int; public var shots: Int
        public init(stats: Combatant, keyword: String, actor: String, size: Int, move: Int, shots: Int) {
            self.stats = stats; self.keyword = keyword; self.actor = actor; self.size = size; self.move = move; self.shots = shots
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
    public private(set) var order: [Int] = []
    public private(set) var events: [Event] = []
    public private(set) var experience = 0
    public private(set) var finished: Bool? = nil
    var rng: GameRandom

    public var current: Unit? { order.first.flatMap { id in units.first { $0.id == id } } }
    public func unit(_ id: Int) -> Unit { units.first { $0.id == id }! }

    public init(field: Battlefield, attackers: [Fighter], defenders: [Fighter], seed: Int) {
        self.field = field
        rng = GameRandom(seed: seed)
        var id = 0
        // deployment: the attacker along the bottom-left edge, the defender along the top-right,
        // in a line across the screen diagonal (world: high x / low x, spread along y)
        for (side, list) in [(0, attackers), (1, defenders)] {
            // the group's centre on screen, then the units spread across the screen diagonal
            let (cx, cy) = Battlefield.world(side == 0 ? 250 : 930, side == 0 ? 760 : 270)
            for (k, f) in list.enumerated() {
                let spread = Float(k - (list.count - 1) / 2) * 6
                let tx = Int(cx - spread * 0.5) - f.size / 2, ty = Int(cy + spread) - f.size / 2
                var placed = false
                for r in 0..<24 where !placed {
                    for dx in -r...r { for dy in -r...r where !placed && max(abs(dx), abs(dy)) == r {
                        let x = tx + dx, y = ty + dy
                        if field.fits(x, y, size: f.size), !overlaps(x, y, f.size, except: -1) {
                            units.append(Unit(id: id, side: side, stats: f.stats, keyword: f.keyword, actor: f.actor, size: f.size, move: f.move, shots: f.shots, x: x, y: y))
                            placed = true
                        }
                    } }
                }
                id += 1
            }
        }
        startRound()
    }

    func overlaps(_ x: Int, _ y: Int, _ s: Int, except id: Int) -> Bool {
        units.contains { u in u.alive && u.id != id && x < u.x + u.size && u.x < x + s && y < u.y + u.size && u.y < y + s }
    }

    func startRound() {
        round += 1
        for u in units { u.acted = false; u.waited = false; u.defended = false; u.stats.defending = false; u.retaliated = false }
        order = units.filter { $0.alive }.sorted { ($0.stats.speed, -$0.side, -$0.id) > ($1.stats.speed, -$1.side, -$1.id) }.map { $0.id }
        events.append(.newRound(round))
    }

    static let steps: [(dx: Int, dy: Int, cost: Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1), (1, 1, 1.4), (-1, -1, 1.4), (1, -1, 1.4), (-1, 1, 1.4)]
    static func key(_ x: Int, _ y: Int) -> Int { x * Battlefield.size + y }

    /// Footprint positions the unit can reach, with the cost, within `budget` cells (its Move by default).
    public func reachable(_ u: Unit, budget: Float? = nil) -> [Int: Float] {
        let limit = budget ?? Float(u.move)
        var dist: [Int: Float] = [Battle.key(u.x, u.y): 0]
        var open: [(Float, Int, Int)] = [(0, u.x, u.y)]
        while !open.isEmpty {
            var best = 0
            for k in 1..<open.count where open[k].0 < open[best].0 { best = k }
            let (c, x, y) = open.remove(at: best)
            if c > dist[Battle.key(x, y), default: .infinity] { continue }
            for s in Battle.steps {
                let nx = x + s.dx, ny = y + s.dy
                let nc = c + s.cost
                guard nc <= limit + 0.001, field.fits(nx, ny, size: u.size), !overlaps(nx, ny, u.size, except: u.id) else { continue }
                if s.cost > 1, !(field.fits(x + s.dx, y, size: u.size) || field.fits(x, y + s.dy, size: u.size)) { continue }
                let k = Battle.key(nx, ny)
                if nc < dist[k, default: .infinity] { dist[k] = nc; open.append((nc, nx, ny)) }
            }
        }
        return dist
    }

    /// Cells of movement needed to reach a position ignoring this turn's limit (for the turns shown by the walk cursor).
    public func cost(_ u: Unit, to x: Int, _ y: Int) -> Float? {
        reachable(u, budget: Float(u.move) * 12)[Battle.key(x, y)]
    }

    public func path(_ u: Unit, to gx: Int, _ gy: Int) -> [(Int, Int)]? {
        let reach = reachable(u)
        guard reach[Battle.key(gx, gy)] != nil else { return nil }
        var out: [(Int, Int)] = []
        var x = gx, y = gy
        while !(x == u.x && y == u.y) {
            out.append((x, y))
            let here = reach[Battle.key(x, y)]!
            var next: (Int, Int)? = nil
            for s in Battle.steps {
                let px = x - s.dx, py = y - s.dy
                if let c = reach[Battle.key(px, py)], abs(here - c - s.cost) < 0.01 { next = (px, py); break }
            }
            guard let n = next else { return nil }
            (x, y) = n
        }
        return out.reversed()
    }

    /// Do two footprints touch (share an edge or a corner)?
    public static func adjacent(_ a: Unit, _ b: Unit) -> Bool {
        a.x <= b.x + b.size && b.x <= a.x + a.size && a.y <= b.y + b.size && b.y <= a.y + a.size
    }
    public static func touches(_ x: Int, _ y: Int, _ s: Int, _ b: Unit) -> Bool {
        x <= b.x + b.size && b.x <= x + s && y <= b.y + b.size && b.y <= y + s
    }
    /// Screen facing for a world direction (x runs down-left, y down-right).
    public static func facing(dx: Float, dy: Float) -> String {
        let sx = dy - dx, sy = (dx + dy) / 2
        let a = atan2(sy, sx)   // screen angle, y down
        let dirs = ["e", "se", "s", "sw", "w", "nw", "n", "ne"]
        let k = Int(((a / (.pi / 4)).rounded() + 8).truncatingRemainder(dividingBy: 8))
        return dirs[k]
    }
    static func face(_ a: Unit, towards b: Unit) {
        a.facing = facing(dx: b.centre.0 - a.centre.0, dy: b.centre.1 - a.centre.1)
    }

    /// Distance between two units' centres in cells (the damage code's world distance >> 4).
    public static func distance(_ a: Unit, _ b: Unit) -> Float {
        let dx = a.centre.0 - b.centre.0, dy = a.centre.1 - b.centre.1
        return (dx * dx + dy * dy).squareRoot()
    }
    /// The ranged damage divisor (heroes4.exe 0x650dc0): No Range Penalty none; Short Range /2
    /// from 20 cells and /4 from 40; others /2 from 40 cells; doubled when an obstacle is in
    /// the way unless the shooter has No Obstacle Penalty.
    public func rangeDivisor(_ a: Unit, _ b: Unit) -> Int {
        let d = Int(Battle.distance(a, b))
        var div: Int
        if a.stats.has("no range penalty") { div = 1 }
        else if a.stats.has("short range") { div = d >= 40 ? 4 : d >= 20 ? 2 : 1 }
        else { div = d >= 40 ? 2 : 1 }
        if field.obstructed(a.centre, b.centre), !a.stats.has("no obstacle penalty") { div *= 2 }
        return div
    }

    public func damageRange(_ a: Unit, _ b: Unit, ranged: Bool) -> (Int, Int) {
        let (lo, hi) = QuickCombat.damageRange(a.stats, b.stats, ranged: ranged)
        let div = ranged ? rangeDivisor(a, b) : 1
        return (max(1, lo / div), max(1, hi / div))
    }

    func hit(_ a: Unit, _ b: Unit, ranged: Bool) {
        var dmg = QuickCombat.damage(a.stats, b.stats, rng: &rng, ranged: ranged)
        if ranged { dmg = max(1, dmg / rangeDivisor(a, b)) }
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
        let prev = p.count > 1 ? p[p.count - 2] : (u.x, u.y)
        u.facing = Battle.facing(dx: Float(x - prev.0), dy: Float(y - prev.1))
        u.x = x; u.y = y
        endAction(u)
        return true
    }

    /// The reachable footprint position next to the target that costs least, or nil.
    public func attackPosition(_ u: Unit, _ t: Unit) -> (Int, Int)? {
        if Battle.adjacent(u, t) { return (u.x, u.y) }
        var best: (Int, Int)? = nil, bestCost = Float.infinity
        for (k, c) in reachable(u) where c < bestCost {
            let x = k / Battlefield.size, y = k % Battlefield.size
            if Battle.touches(x, y, u.size, t) { bestCost = c; best = (x, y) }
        }
        return best
    }

    public func attack(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side,
              let pos = attackPosition(u, t) else { return false }
        if pos != (u.x, u.y), let p = path(u, to: pos.0, pos.1) { events.append(.move(unit: u.id, path: p)); u.x = pos.0; u.y = pos.1 }
        Battle.face(u, towards: t); Battle.face(t, towards: u)
        meleeExchange(u, t)
        endAction(u)
        return true
    }

    func canRetaliate(_ t: Unit, against a: Unit) -> Bool {
        t.alive && !a.stats.has("no retaliation") && (!t.retaliated || t.stats.has("unlimited retaliation"))
    }
    func strikesFirst(_ x: Unit, over y: Unit) -> Bool {
        x.stats.has("first strike") && !y.stats.has("negate first strike") && !y.stats.has("first strike")
    }
    /// The attacker strikes, then the target strikes back; a target with First Strike strikes
    /// back before the blow; Two Attacks strike again after the retaliation.
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

    /// Can the unit shoot now (it has shots and no enemy touches it)?
    public func canShoot(_ u: Unit) -> Bool { u.shots > 0 && !units.contains { $0.alive && $0.side != u.side && Battle.adjacent(u, $0) } }

    public func shoot(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        guard canShoot(u) else { return attack(targetId) }
        u.shots -= 1
        Battle.face(u, towards: t)
        hit(u, t, ranged: true)
        if t.alive, u.stats.has("shoots twice"), u.shots > 0 { u.shots -= 1; hit(u, t, ranged: true) }
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

    public func wait() {
        guard finished == nil, let u = current, !u.waited else { defend(); return }
        u.waited = true
        events.append(.wait(unit: u.id))
        order.removeFirst()
        order.append(u.id)
    }

    /// A simple opponent: shooters shoot the most dangerous enemy, others attack what they can
    /// reach or walk towards the nearest enemy.
    public func autoAct() {
        guard finished == nil, let u = current else { return }
        let enemies = units.filter { $0.alive && $0.side != u.side }
        guard !enemies.isEmpty else { return }
        if canShoot(u), let t = enemies.max(by: { QuickCombat.threat($0.stats) < QuickCombat.threat($1.stats) }) { _ = shoot(t.id); return }
        if let t = enemies.filter({ attackPosition(u, $0) != nil }).max(by: { QuickCombat.threat($0.stats) < QuickCombat.threat($1.stats) }) { _ = attack(t.id); return }
        let nearest = enemies.min { Battle.distance(u, $0) < Battle.distance(u, $1) }!
        var best: (Int, Int)? = nil, bestD = Float.infinity
        for (k, _) in reachable(u) {
            let x = k / Battlefield.size, y = k % Battlefield.size
            let dx = Float(x) + Float(u.size) / 2 - nearest.centre.0, dy = Float(y) + Float(u.size) / 2 - nearest.centre.1
            let d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = (x, y) }
        }
        if let b = best, !(b.0 == u.x && b.1 == u.y) { _ = move(to: b.0, b.1) } else { defend() }
    }

    public func autoResolve() {
        var guardCount = 0
        while finished == nil, guardCount < 3000 { autoAct(); guardCount += 1 }
    }

    public func takeEvents() -> [Event] { let e = events; events.removeAll(); return e }
}
