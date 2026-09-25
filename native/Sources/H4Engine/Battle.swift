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
        /// Morale this round (0x5f3080 / 0x5f3710): a roll of 0...9; checked once when the unit comes up.
        public var moraleRoll = 0, moraleChecked = false, goodMorale = false, badMorale = false
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
        /// The army slot (0...6) the stack sits in; it picks the deployment cell.
        public var slot: Int
        public init(stats: Combatant, keyword: String, actor: String, size: Int, move: Int, shots: Int, slot: Int = -1) {
            self.stats = stats; self.keyword = keyword; self.actor = actor; self.size = size; self.move = move; self.shots = shots; self.slot = slot
        }
    }

    /// What just happened, for the screen to animate in order.
    public enum Event {
        case move(unit: Int, path: [(Int, Int)])
        case melee(unit: Int, target: Int, damage: Int, killed: Int)
        case shoot(unit: Int, target: Int, damage: Int, killed: Int)
        case die(unit: Int)
        case morale(unit: Int, good: Bool)
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

    /// Army formations (t_creature_array +0x2c, set by the army dialog's buttons).
    public enum Formation: Int { case loose = 0, tight = 1, square = 2 }

    /// Deployment cells, heroes4.exe 0xaae8b8 (filled by the initializer at 0x6246f0):
    /// [formation][side][army slot] = (x, y). Formations 3 and 4 are the siege ones and 5
    /// the ship deck; side 0 attacks from the bottom left, side 1 defends at the top right.
    public static let deployment: [[[(Int, Int)]]] = [
        [[(76, 51), (85, 55), (76, 60), (85, 64), (76, 69), (85, 73), (76, 78)],
         [(33, 32), (24, 37), (33, 41), (24, 46), (33, 50), (24, 55), (33, 59)]],
        [[(77, 54), (84, 57), (77, 61), (84, 64), (77, 68), (84, 71), (77, 75)],
         [(32, 35), (25, 39), (32, 42), (25, 46), (32, 49), (25, 53), (32, 56)]],
        [[(77, 57), (84, 57), (77, 64), (84, 64), (77, 71), (84, 71), (91, 64)],
         [(32, 39), (25, 39), (32, 46), (25, 46), (32, 53), (25, 53), (18, 46)]],
        [[(76, 51), (85, 55), (76, 60), (85, 64), (76, 69), (85, 73), (76, 78)],
         [(43, 23), (43, 31), (43, 40), (43, 49), (43, 57), (43, 67), (43, 74)]],
        [[(76, 51), (85, 55), (76, 60), (85, 64), (76, 69), (85, 73), (76, 78)],
         [(43, 23), (36, 38), (43, 40), (25, 50), (43, 57), (36, 61), (43, 74)]],
        [[(71, 41), (78, 48), (71, 48), (78, 55), (71, 55), (78, 62), (71, 62)],
         [(31, 62), (24, 55), (31, 55), (24, 48), (31, 48), (24, 41), (31, 41)]]]

    public init(field: Battlefield, attackers: [Fighter], defenders: [Fighter], seed: Int, formations: (Formation, Formation) = (.loose, .loose)) {
        self.field = field
        rng = GameRandom(seed: seed)
        var id = 0
        // deployment (heroes4.exe 0x62df10): each army slot has its cell in the formation's
        // table, the stack's footprint centred on it ((size - 1) / 2 back on both axes)
        for (side, list) in [(0, attackers), (1, defenders)] {
            let formation = side == 0 ? formations.0 : formations.1
            let table = Battle.deployment[formation.rawValue][side]
            var bySlot: [Int: Int] = [:]
            for (k, f) in list.enumerated() {
                let slot = f.slot >= 0 ? f.slot : k
                let (sx, sy) = table[min(slot, 6)]
                let tx = sx - (f.size - 1) / 2, ty = sy - (f.size - 1) / 2
                var placed = false
                for r in 0..<24 where !placed {
                    for dx in -r...r { for dy in -r...r where !placed && max(abs(dx), abs(dy)) == r {
                        let x = tx + dx, y = ty + dy
                        if field.fits(x, y, size: f.size), !overlaps(x, y, f.size, except: -1) {
                            units.append(Unit(id: id, side: side, stats: f.stats, keyword: f.keyword, actor: f.actor, size: f.size, move: f.move, shots: f.shots, x: x, y: y))
                            bySlot[slot] = units.count - 1
                            placed = true
                        }
                    } }
                }
                id += 1
            }
            // tight and square close the ranks: stacks slide toward a neighbour (0x62e830)
            func pull(_ a: Int, _ b: Int, _ limit: Int) -> Bool {
                guard let i = bySlot[a], let j = bySlot[b] else { return false }
                return slide(units[i], toward: units[j], limit: limit)
            }
            switch formation {
            case .tight:
                if pull(2, 4, 1) { while pull(4, 2, 1) && pull(2, 4, 1) {} }
                _ = pull(0, 2, 100); _ = pull(6, 4, 100); _ = pull(1, 3, 100); _ = pull(5, 3, 100)
            case .square:
                _ = pull(2, 3, 100); _ = pull(0, 2, 100); _ = pull(4, 2, 100); _ = pull(1, 3, 100)
                _ = pull(5, 3, 100); _ = pull(6, 3, 100); _ = pull(0, 1, 100); _ = pull(4, 5, 100)
            case .loose: break
            }
        }
        for side in 0..<2 { initialHealth[side] = units.filter { $0.side == side }.reduce(0) { $0 + $1.stats.totalHealth } }
        startRound()
    }

    /// heroes4.exe 0x62e830: the direction is the sign of the centre difference (whole cells,
    /// truncated), fixed at the start; the stack steps that way while it still fits, at most
    /// `limit` steps. Reports whether it moved.
    func slide(_ m: Unit, toward t: Unit, limit: Int) -> Bool {
        let dxw = (t.x * 16 + t.size * 8) - (m.x * 16 + m.size * 8), dyw = (t.y * 16 + t.size * 8) - (m.y * 16 + m.size * 8)
        let dx = (dxw / 16).signum(), dy = (dyw / 16).signum()
        guard dx != 0 || dy != 0 else { return false }
        var steps = 0
        while steps < limit, field.fits(m.x + dx, m.y + dy, size: m.size), !overlaps(m.x + dx, m.y + dy, m.size, except: m.id) {
            m.x += dx; m.y += dy; steps += 1
        }
        return steps > 0
    }

    func overlaps(_ x: Int, _ y: Int, _ s: Int, except id: Int) -> Bool {
        units.contains { u in u.alive && u.id != id && x < u.x + u.size && u.x < x + s && y < u.y + u.size && u.y < y + s }
    }

    func startRound() {
        round += 1
        for u in units {
            u.acted = false; u.waited = false; u.defended = false; u.retaliated = false
            u.moraleRoll = rng.next() % 10; u.moraleChecked = false; u.goodMorale = false; u.badMorale = false
        }
        order = turnOrder(units.filter { $0.alive })
        events.append(.newRound(round))
        checkMorale()
    }

    /// Morale (heroes4.exe 0x5f0020): mechanical and undead creatures have none; otherwise the
    /// stack's morale from its army plus the side's loss penalty, clamped to -10...10.
    func morale(_ u: Unit) -> Int {
        if u.stats.has("mechanical") || u.stats.has("undead") { return 0 }
        return min(10, max(-10, u.stats.morale + lossPenalty[u.side]))
    }

    /// Alignments in the game's order (life, order, death, chaos, nature, might).
    public static let alignments = ["life", "order", "death", "chaos", "nature", "might"]
    /// How two alignments get on (0x51ecf0): 0 the same, 1 neighbours on the wheel of the first
    /// five, 2 when either is might, 3 opposed; morale for each is 0, -1, -2, -5 (0xa643f8).
    static func relation(_ a: Int, _ b: Int) -> Int {
        if a == b { return 0 }
        if a == 5 || b == 5 { return 2 }
        let d = ((a - b + 5) % 5 + 5) % 5
        return d == 1 || d == 4 ? 1 : 3
    }
    /// A stack's morale from the army it is in (0x640310): +1, then for every alignment present
    /// (heroes included) the relation's penalty, and -2 with undead in the army unless it is death.
    public static func armyMorale(own: String, army: [(alignment: String, undead: Bool)]) -> Int {
        let me = alignments.firstIndex(of: own.lowercased()) ?? 0
        var m = 1
        for a in Set(army.compactMap { alignments.firstIndex(of: $0.alignment.lowercased()) }) { m += [0, -1, -2, -5][relation(me, a)] }
        if army.contains(where: { $0.undead }) && me != 2 { m -= 2 }
        return m
    }

    /// Losses sap morale (0x576390): each side's loss is -(10 x hit points lost / hit points at the
    /// start), and a side that has lost more than the enemy takes the difference.
    var initialHealth = [0, 0]
    var lossPenalty = [0, 0]
    func updateLossMorale() {
        var loss = [0, 0]
        for side in 0..<2 where initialHealth[side] > 0 {
            let now = units.filter { $0.side == side && $0.alive }.reduce(0) { $0 + $1.stats.totalHealth }
            if now < initialHealth[side] { loss[side] = (now - initialHealth[side]) * 10 / initialHealth[side] }
        }
        for side in 0..<2 { lossPenalty[side] = min(0, loss[side] - loss[1 - side]) }
    }
    /// The unit coming up checks its morale once a round (0x5f3710): bad when 9 - roll < -morale,
    /// and it falls behind everyone who kept their +1000; good when roll < morale.
    func checkMorale() {
        updateLossMorale()
        while finished == nil, let u = current, !u.moraleChecked {
            u.moraleChecked = true
            let m = morale(u)
            if 9 - u.moraleRoll < -m {
                u.badMorale = true
                events.append(.morale(unit: u.id, good: false))
                order = turnOrder(order.map { unit($0) })
            } else if u.moraleRoll < m {
                u.goodMorale = true
                events.append(.morale(unit: u.id, good: true))
            }
        }
        // a unit that defended keeps its doubled defence until its own next turn (0x567ef0)
        current?.stats.defending = false
    }

    /// The turn key (heroes4.exe 0x5f3110): Speed, +1000 unless morale failed, +1000 for good
    /// morale (before the check: when the roll is under the morale), and negated for a unit that
    /// waited. The highest key acts next (0x56f3b0), so waiting units come last, slowest first.
    func turnKey(_ u: Unit) -> Int {
        var k = u.stats.speed + (u.badMorale ? 0 : 1000)
        if u.moraleChecked ? u.goodMorale : u.moraleRoll < morale(u) { k += 1000 }
        return u.waited ? -k : k
    }
    func turnOrder(_ list: [Unit]) -> [Int] {
        list.sorted { a, b in
            let ka = turnKey(a), kb = turnKey(b)
            return ka != kb ? ka > kb : (a.side != b.side ? a.side < b.side : a.id < b.id)
        }.map { $0.id }
    }

    static let steps: [(dx: Int, dy: Int, cost: Float)] = [(1, 0, 1), (-1, 0, 1), (0, 1, 1), (0, -1, 1), (1, 1, 1.5), (-1, -1, 1.5), (1, -1, 1.5), (-1, 1, 1.5)]
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
        if a.stats.has("long_range") { div = 1 }
        else if a.stats.has("short_range") { div = d >= 40 ? 4 : d >= 20 ? 2 : 1 }
        else { div = d >= 40 ? 2 : 1 }
        if field.obstructed(a.centre, b.centre), !a.stats.has("siege_machine") { div *= 2 }
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
        if finished == nil, order.isEmpty { startRound() } else { checkMorale() }
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
        t.alive && !a.stats.has("no_retaliation") && (!t.retaliated || t.stats.has("unlimited_retaliation"))
    }
    func strikesFirst(_ x: Unit, over y: Unit) -> Bool {
        x.stats.has("first_strike") && !y.stats.has("first_strike_immunity") && !y.stats.has("first_strike")
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
        if u.alive, t.alive, u.stats.has("strikes_twice") || u.stats.has("two attacks") { hit(u, t, ranged: false) }
    }

    /// Can the unit shoot now (it has shots and no enemy touches it)?
    public func canShoot(_ u: Unit) -> Bool { u.shots > 0 && !units.contains { $0.alive && $0.side != u.side && Battle.adjacent(u, $0) } }

    public func shoot(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, t.side != u.side else { return false }
        guard canShoot(u) else { return attack(targetId) }
        Battle.face(u, towards: t)
        // a shooter that is shot at shoots back (once per round, like melee retaliation);
        // Ranged First Strike shoots first; Shoots Twice fires again after the retaliation
        let shootsBack = canRetaliate(t, against: u) && canShoot(t)
        if shootsBack, t.stats.has("ranged_first_strike"), !u.stats.has("ranged_first_strike") {
            t.retaliated = true; t.shots -= 1; Battle.face(t, towards: u); hit(t, u, ranged: true)
            if u.alive { u.shots -= 1; hit(u, t, ranged: true) }
        } else {
            u.shots -= 1; hit(u, t, ranged: true)
            if shootsBack, t.alive { t.retaliated = true; t.shots -= 1; Battle.face(t, towards: u); hit(t, u, ranged: true) }
        }
        if u.alive, t.alive, u.stats.has("shoots_twice"), u.shots > 0 { u.shots -= 1; hit(u, t, ranged: true) }
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
        guard finished == nil, let u = current, !u.waited else { return }   // once a round: the flag clears only at the next round (0x5ed400)
        u.waited = true
        events.append(.wait(unit: u.id))
        order = turnOrder(order.map { unit($0) })
        checkMorale()
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
