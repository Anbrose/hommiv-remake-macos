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
        /// Cells walked this turn (Charge counts them), and the creatures at the start (Life Draining restores no more).
        public var moved: Float = 0
        public let initialCount: Int
        /// Turns lost to Stun / Freeze / Blind / Terror (the unit skips its action while any is left).
        public var stunned = 0, frozen = 0, blind = 0
        /// Poison damage taken at every new round, and who holds the unit Bound.
        public var poison = 0
        public var boundBy: Int? = nil
        /// Hypnotized: its next action is for the other side.
        public var hypnotized = false
        public var disabled: Bool { stunned > 0 || frozen > 0 || blind > 0 }
        public var alive: Bool { stats.alive }
        /// Centre of the footprint in cell units.
        public var centre: (Float, Float) { (Float(x) + Float(size) / 2, Float(y) + Float(size) / 2) }
        init(id: Int, side: Int, stats: Combatant, keyword: String, actor: String, size: Int, move: Int, shots: Int, x: Int, y: Int) {
            self.id = id; self.side = side; self.stats = stats; self.keyword = keyword; self.actor = actor; self.size = size
            self.move = move; self.shots = shots; self.x = x; self.y = y
            initialCount = stats.count
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
        /// `path` excludes `from`; `flying` moves take off, fly straight and land (t_play_combat_flight).
        case move(unit: Int, path: [(Int, Int)], from: (Int, Int), flying: Bool)
        case melee(unit: Int, target: Int, damage: Int, killed: Int)
        case shoot(unit: Int, target: Int, damage: Int, killed: Int)
        case die(unit: Int)
        case morale(unit: Int, good: Bool)
        /// A creature ability or its spell took hold: `name` is the spell animation
        /// (animation.spell.<name>), with any damage it did.
        case effect(unit: Int, name: String, damage: Int, killed: Int)
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

    /// A stack in an army slot, as the split leaves it.
    public struct ArmySlot {
        public var creature: String; public var count: Int; public var backRow: Bool
        public init(creature: String, count: Int, backRow: Bool) { self.creature = creature; self.count = count; self.backRow = backRow }
    }
    /// Preferred slots (heroes4.exe 0x9842a8): melee stacks take the front line (0, 2, 4, 6 face
    /// the enemy in every formation), ranged stacks and heroes the back line.
    public static let slotOrder = [[2, 4, 0, 6, 3, 1, 5], [3, 1, 5, 2, 4, 0, 6]]

    /// An army without a hero before battle (heroes4.exe 0x62da90): its stacks move to their
    /// preferred slots, then while the enemy has more stacks each stack of more than one creature
    /// splits into up to 4 (melee) or 3 (back row) even parts, no more than the enemy's excess + 1,
    /// the free preferred slots allow, or that kind's share; the original keeps the remainder.
    public static func splitArmy(_ stacks: [ArmySlot], enemyStacks: Int) -> [ArmySlot?] {
        var slots = [ArmySlot?](repeating: nil, count: 7)
        var kinds = [0, 0]
        for st in stacks where st.count > 0 {
            let c = st.backRow ? 1 : 0
            kinds[c] += 1
            if let slot = slotOrder[c].first(where: { slots[$0] == nil }) { slots[slot] = st }
        }
        let own = slots.compactMap { $0 }.count
        var excess = enemyStacks - own
        guard excess > 0, own > 0 else { return slots }
        var done = [Bool](repeating: false, count: 7)
        for s in 0..<7 where !done[s] {
            guard let st = slots[s] else { continue }
            let c = st.backRow ? 1 : 0
            if st.count > 1 {
                let most = min(c == 1 ? 3 : 4, excess + 1)
                var pieces = 1
                for k in 0..<most where slotOrder[c][k] != s && slots[slotOrder[c][k]] == nil { pieces += 1 }
                pieces = min(pieces, st.count, most / max(1, kinds[c]))
                if pieces > 1 {
                    excess -= pieces - 1
                    var left = pieces, k = 0
                    for _ in 1..<pieces {
                        while k < 7, slotOrder[c][k] == s || slots[slotOrder[c][k]] != nil { k += 1 }
                        guard k < 7 else { break }
                        let target = slotOrder[c][k]
                        let n = slots[s]!.count / left
                        slots[target] = ArmySlot(creature: st.creature, count: n, backRow: st.backRow)
                        slots[s]!.count -= n
                        done[target] = true
                        left -= 1
                    }
                }
            }
            done[s] = true
            kinds[c] -= 1
        }
        return slots
    }

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
            u.moved = 0
        }
        events.append(.newRound(round))
        // Poison hurts at every new round until the battle ends
        for u in units where u.alive && u.poison > 0 {
            let killed = u.stats.take(u.poison)
            events.append(.effect(unit: u.id, name: "Poison", damage: u.poison, killed: killed))
            if !u.alive { events.append(.die(unit: u.id)) }
        }
        checkEnd()
        guard finished == nil else { return }
        order = turnOrder(units.filter { $0.alive })
        checkMorale()
    }

    /// Morale (heroes4.exe 0x5f0020): mechanical and undead creatures have none; otherwise the
    /// stack's morale from its army plus the side's loss penalty, clamped to -10...10.
    public func morale(_ u: Unit) -> Int {
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
        // a stunned, frozen or blinded unit loses its action
        while finished == nil, let u = current, u.disabled {
            if u.stunned > 0 { u.stunned -= 1 } else if u.frozen > 0 { u.frozen -= 1 } else { u.blind -= 1 }
            u.acted = true
            order.removeFirst()
            if u.stats.has("regeneration") { u.stats.wounds = 0 }
            if order.isEmpty { startRound(); return }
        }
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
        if finished == nil, current?.disabled == true { checkMorale(); return }
        // a unit that defended keeps its doubled defence until its own next turn (0x567ef0)
        current?.stats.defending = false
    }

    /// The turn key (heroes4.exe 0x5f3110): Speed, +1000 unless morale failed, +1000 for good
    /// morale (before the check: when the roll is under the morale), and negated for a unit that
    /// waited. The highest key acts next (0x56f3b0), so waiting units come last, slowest first.
    func turnKey(_ u: Unit) -> Int {
        var k = u.stats.speed / (u.stats.aged ? 2 : 1) + (u.badMorale ? 0 : 1000)
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
        if u.stats.has("teleport"), u.boundBy == nil {   // Teleport: any free place on the field
            var out: [Int: Float] = [:]
            for x in 0..<Battlefield.size { for y in 0..<Battlefield.size where field.fits(x, y, size: u.size) && !overlaps(x, y, u.size, except: u.id) {
                let dx = Float(x - u.x), dy = Float(y - u.y)
                out[Battle.key(x, y)] = (dx * dx + dy * dy).squareRoot()
            } }
            return out
        }
        let all = explore(u, budget: budget)
        guard u.stats.has("flying") else { return all }
        return all.filter { k, _ in
            let x = k / Battlefield.size, y = k % Battlefield.size
            return field.fits(x, y, size: u.size) && !overlaps(x, y, u.size, except: u.id)
        }
    }
    /// The unit's Move: halved by Aging; nothing while Bound.
    func moveBudget(_ u: Unit) -> Float {
        if u.boundBy != nil { return 0 }
        return Float(u.move) / (u.stats.aged ? 2 : 1)
    }
    /// Path costs; Flying (and Teleport) pass over obstacles and creatures, landing only on free cells.
    func explore(_ u: Unit, budget: Float? = nil) -> [Int: Float] {
        let limit = budget ?? moveBudget(u)
        let flies = u.stats.has("flying")
        func free(_ x: Int, _ y: Int) -> Bool {
            flies ? x >= 0 && y >= 0 && x + u.size <= Battlefield.size && y + u.size <= Battlefield.size
                  : field.fits(x, y, size: u.size) && !overlaps(x, y, u.size, except: u.id)
        }
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
                guard nc <= limit + 0.001, free(nx, ny) else { continue }
                if s.cost > 1, !flies, !(field.fits(x + s.dx, y, size: u.size) || field.fits(x, y + s.dy, size: u.size)) { continue }
                let k = Battle.key(nx, ny)
                if nc < dist[k, default: .infinity] { dist[k] = nc; open.append((nc, nx, ny)) }
            }
        }
        return dist
    }

    /// Cells of movement needed to reach a position ignoring this turn's limit (for the turns shown by the walk cursor).
    public func cost(_ u: Unit, to x: Int, _ y: Int) -> Float? {
        reachable(u, budget: moveBudget(u) * 12)[Battle.key(x, y)]
    }

    public func path(_ u: Unit, to gx: Int, _ gy: Int) -> [(Int, Int)]? {
        if u.stats.has("teleport") {   // Teleport: straight there
            return reachable(u)[Battle.key(gx, gy)] != nil ? [(gx, gy)] : nil
        }
        if u.stats.has("flying") {   // a flight (t_play_combat_flight) goes straight over everything
            guard reachable(u)[Battle.key(gx, gy)] != nil else { return nil }
            let n = max(abs(gx - u.x), abs(gy - u.y))
            var line: [(Int, Int)] = []
            for i in stride(from: 1, through: n, by: 1) {
                let f = Float(i) / Float(n)
                let x = u.x + Int((Float(gx - u.x) * f).rounded()), y = u.y + Int((Float(gy - u.y) * f).rounded())
                line.append((x, y))
            }
            return line
        }
        let reach = explore(u)
        guard reachable(u)[Battle.key(gx, gy)] != nil else { return nil }
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

    /// Living creatures: what Stun, Weakness, Poison, Aging and the mind spells work on.
    static func living(_ u: Unit) -> Bool { !u.stats.has("undead") && !u.stats.has("mechanical") && !u.stats.has("elemental") }

    /// One blow of `a` on `b`, then what the attacker's and target's abilities add (heroes4.exe
    /// 0x553440, the attack's aftermath). `secondary` blows (3-headed, multiple, breath, area)
    /// only do damage.
    @discardableResult
    func hit(_ a: Unit, _ b: Unit, ranged: Bool, secondary: Bool = false) -> Int {
        let before = b.stats.totalHealth
        var dmg = QuickCombat.damage(a.stats, b.stats, rng: &rng, ranged: ranged, moved: ranged ? 0 : Int(a.moved))
        if ranged { dmg = max(1, dmg / rangeDivisor(a, b)) }
        // Stone Gaze (0x5ee990): 250/100/50/20 thousandths of a target of level 1/2/3/4 per
        // attacking creature are turned to stone, once that makes half a creature
        if !secondary, a.stats.has("stone_gaze"), Battle.living(b), !b.stats.has("blind"), !b.stats.has("magic_immunity") {
            let per = [250, 100, 50, 20][min(3, max(0, b.stats.level - 1))]
            if per * a.stats.count >= 500 { dmg += Int((Double(b.stats.hitPoints) * Double(per * a.stats.count) * 0.001).rounded()) }
        }
        dmg = min(dmg, before)
        let killed = b.stats.take(dmg)
        if a.side == 0 { experience += killed * b.stats.experience }
        events.append(ranged ? .shoot(unit: a.id, target: b.id, damage: dmg, killed: killed) : .melee(unit: a.id, target: b.id, damage: dmg, killed: killed))
        if b.blind > 0 { b.blind = 0 }   // Blind breaks when the target is hurt
        if !b.alive { events.append(.die(unit: b.id)); b.boundBy = nil }
        if !secondary { aftermath(a, b, ranged: ranged, damage: dmg, healthBefore: before) }
        return dmg
    }

    func effect(_ u: Unit, _ name: String, damage: Int = 0) {
        var killed = 0
        if damage > 0 { killed = u.stats.take(damage) }
        events.append(.effect(unit: u.id, name: name, damage: damage, killed: killed))
        if damage > 0, !u.alive { events.append(.die(unit: u.id)) }
    }

    /// The abilities that act after a blow lands (0x553440), in the exe's order.
    func aftermath(_ a: Unit, _ b: Unit, ranged: Bool, damage: Int, healthBefore: Int) {
        let magic = !b.stats.has("magic_immunity")
        // Fire Shield: a quarter of a melee blow burns the attacker, half again with Fire Resistance
        if !ranged, b.stats.has("fire_shield"), a.alive {
            var burn = (damage + 3) >> 2
            if a.stats.has("fire_resistance") { burn = (burn + 1) >> 1 }
            if burn > 0 { effect(a, "fire shield", damage: burn) }
        }
        // Life Draining heals the attacker and brings back its dead
        if a.stats.has("vampire"), Battle.living(b), a.alive {
            let cap = a.initialCount * a.stats.hitPoints
            let now = a.stats.totalHealth, gain = min(damage, cap - now)
            if gain > 0 {
                let total = now + gain
                a.stats.count = (total + a.stats.hitPoints - 1) / a.stats.hitPoints
                a.stats.wounds = a.stats.count * a.stats.hitPoints - total
                events.append(.effect(unit: a.id, name: "Vampiric Touch", damage: 0, killed: 0))
            }
        }
        guard b.alive else { return }
        // Weakness: the Weakness spell with every attack
        if a.stats.has("weakness"), Battle.living(b), magic, !b.stats.weakened { b.stats.weakened = true; effect(b, "Weakness") }
        // Poison: from now on the target takes the poisoner's damage every round
        if a.stats.has("poison"), Battle.living(b), b.poison == 0 {
            b.poison = max(1, QuickCombat.rollBase(a.stats, rng: &rng))   // a fresh roll of its base damage (0x575fe0 -> 0x5ee690)
            effect(b, "poison attack")
        }
        // Stun (melee) / ranged stun: chance = damage as a percentage of the target's health, less 5
        if a.stats.has(ranged ? "ranged_stun" : "stunning"), Battle.living(b) {
            let chance = damage * 100 / max(1, healthBefore) - 5
            if rng.next() % 100 < chance { b.stunned = max(b.stunned, 1); effect(b, "stun") }
        }
        guard !ranged else { return }
        // the rest works in melee only
        if a.stats.has("aging"), Battle.living(b), magic, !b.stats.aged { b.stats.aged = true; effect(b, "aging") }
        if a.stats.has("blinding"), !b.stats.has("blind"), Battle.living(b), magic, rng.next() % 100 < 30 { b.blind = 3; effect(b, "blind") }
        if a.stats.has("curse"), magic, !b.stats.cursed { b.stats.cursed = true; effect(b, "Curse") }
        if a.stats.has("freeze"), !b.stats.has("cold_resistance"), magic, rng.next() % 100 < 30 { b.frozen = 2; effect(b, "cold_potion") }
        // Devouring: each attacker has a 1 in 10 chance to swallow a creature, at most a tenth of the attackers
        if a.stats.has("devouring") {
            var eaten = 0
            for _ in 0..<min(a.stats.count, 100) where rng.next() % 10 == 0 { eaten += 1 }
            if a.stats.count > 100 { eaten = eaten * a.stats.count / 100 }
            eaten = min(eaten, (a.stats.count + 9) / 10, b.stats.count)
            if eaten > 0 { effect(b, "acid", damage: eaten * b.stats.hitPoints - (b.stats.count == eaten ? b.stats.wounds : 0)) }
        }
        guard b.alive else { return }
        if a.stats.has("hypnotize"), Battle.living(b), magic, rng.next() % 10 < 3 { b.hypnotized = true; effect(b, "hypnotize_effect") }
        if a.stats.has("binding"), !b.stats.has("insubstantial"), b.boundBy == nil { b.boundBy = a.id; b.stats.bound = true; effect(b, "binding_potion") }
        // Lightning: 30 damage per attacking creature right after the blow
        if a.stats.has("lightning"), magic { effect(b, "Lightning", damage: 30 * a.stats.count) }
    }

    /// The other creatures a blow also strikes: Multiple Attack every adjacent enemy, 3-Headed
    /// the enemies beside the target, Breath the creature right behind it (friend or foe), an
    /// Area Attack everything around the target.
    func extraTargets(_ a: Unit, _ t: Unit, ranged: Bool) -> [Unit] {
        let others = units.filter { $0.alive && $0.id != a.id && $0.id != t.id }
        if ranged {
            guard a.stats.has("area_effect") || a.stats.has("large_area_effect") else { return [] }
            return others.filter { Battle.adjacent($0, t) }
        }
        if a.stats.has("hydra_strike") { return others.filter { side(of: $0) != side(of: a) && Battle.adjacent(a, $0) } }
        if a.stats.has("3_headed_attack") {
            return Array(others.filter { side(of: $0) != side(of: a) && Battle.adjacent(a, $0) && Battle.adjacent(t, $0) }
                .sorted { Battle.distance($0, t) < Battle.distance($1, t) }.prefix(2))
        }
        if a.stats.has("breath_attack") || a.stats.has("arc_breath_attack") {
            let dx = t.centre.0 - a.centre.0, dy = t.centre.1 - a.centre.1
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let reach = Float(t.size) / 2 + 1.5
            let px = t.centre.0 + dx / len * reach, py = t.centre.1 + dy / len * reach
            return others.filter { u in
                !u.stats.has("fire_resistance") &&
                px >= Float(u.x) - 0.5 && px <= Float(u.x + u.size) + 0.5 && py >= Float(u.y) - 0.5 && py <= Float(u.y + u.size) + 0.5
            }
        }
        return []
    }

    /// The side a unit fights for now (a hypnotized one fights for the other).
    public func side(of u: Unit) -> Int { u.hypnotized ? 1 - u.side : u.side }

    func endAction(_ u: Unit) {
        u.acted = true
        u.hypnotized = false
        if u.stats.has("regeneration"), u.alive { u.stats.wounds = 0 }   // heals all its wounds at the end of its turn
        order.removeAll { $0 == u.id }
        checkEnd()
        if finished == nil, order.isEmpty { startRound() } else { checkMorale() }
    }

    func checkEnd() {
        let a = units.contains { $0.side == 0 && $0.alive }, d = units.contains { $0.side == 1 && $0.alive }
        if !(a && d) || round > 60 { finished = a; events.append(.finished(attackerWon: a)) }
    }

    /// Moving frees what the unit held Bound.
    func release(by u: Unit) {
        for v in units where v.boundBy == u.id { v.boundBy = nil; v.stats.bound = false }
    }

    // MARK: actions of the current unit

    public func move(to x: Int, _ y: Int) -> Bool {
        guard finished == nil, let u = current, let p = path(u, to: x, y), !p.isEmpty else { return false }
        u.moved += reachable(u)[Battle.key(x, y)] ?? 0
        events.append(.move(unit: u.id, path: p, from: (u.x, u.y), flying: u.stats.has("flying")))
        let prev = p.count > 1 ? p[p.count - 2] : (u.x, u.y)
        u.facing = Battle.facing(dx: Float(x - prev.0), dy: Float(y - prev.1))
        u.x = x; u.y = y
        release(by: u)
        endAction(u)
        return true
    }

    /// How far a unit strikes in melee: Long Weapon reaches one cell further.
    static func reach(_ u: Unit) -> Int { u.stats.has("long_weapon") ? 1 : 0 }
    static func inReach(_ x: Int, _ y: Int, _ s: Int, _ b: Unit, reach: Int) -> Bool {
        x <= b.x + b.size + reach && b.x <= x + s + reach && y <= b.y + b.size + reach && b.y <= y + s + reach
    }

    /// The reachable footprint position from which the unit can strike the target that costs least, or nil.
    public func attackPosition(_ u: Unit, _ t: Unit) -> (Int, Int)? {
        let r = Battle.reach(u)
        if Battle.inReach(u.x, u.y, u.size, t, reach: r) { return (u.x, u.y) }
        var best: (Int, Int)? = nil, bestCost = Float.infinity
        for (k, c) in reachable(u) where c < bestCost {
            let x = k / Battlefield.size, y = k % Battlefield.size
            if Battle.inReach(x, y, u.size, t, reach: r) { bestCost = c; best = (x, y) }
        }
        return best
    }

    public func attack(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, side(of: t) != side(of: u),
              let pos = attackPosition(u, t) else { return false }
        let start = (u.x, u.y)
        if pos != (u.x, u.y), let p = path(u, to: pos.0, pos.1) {
            u.moved += reachable(u)[Battle.key(pos.0, pos.1)] ?? 0
            events.append(.move(unit: u.id, path: p, from: (u.x, u.y), flying: u.stats.has("flying"))); u.x = pos.0; u.y = pos.1
            release(by: u)
        }
        Battle.face(u, towards: t); Battle.face(t, towards: u)
        meleeExchange(u, t)
        // Strike and Return: back to where it started
        if u.alive, u.stats.has("strike_and_return"), (u.x, u.y) != start, !overlaps(start.0, start.1, u.size, except: u.id) {
            let back = u.stats.has("flying") ? (path(u, to: start.0, start.1) ?? [start]) : [start]
            events.append(.move(unit: u.id, path: back, from: (u.x, u.y), flying: u.stats.has("flying"))); u.x = start.0; u.y = start.1
        }
        endAction(u)
        return true
    }

    /// Does the target strike back? Not against No Retaliation or Fear, not when stunned, frozen
    /// or blind, once a round unless Unlimited Retaliation, and only if the attacker is within its reach.
    func canRetaliate(_ t: Unit, against a: Unit) -> Bool {
        t.alive && !t.disabled && !a.stats.has("no_retaliation") && !a.stats.has("panic")
            && (!t.retaliated || t.stats.has("unlimited_retaliation"))
            && Battle.inReach(t.x, t.y, t.size, a, reach: Battle.reach(t))
    }
    func strikesFirst(_ x: Unit, over y: Unit) -> Bool {
        x.stats.has("first_strike") && !y.stats.has("first_strike_immunity") && !y.stats.has("first_strike")
    }
    /// The attacker's blow (and what it also strikes), the target's strike back, and Two
    /// Attacks' second blow after it; First Strike turns the first two around.
    func blow(_ u: Unit, _ t: Unit) {
        let extra = extraTargets(u, t, ranged: false)
        hit(u, t, ranged: false)
        for e in extra where e.alive { hit(u, e, ranged: false, secondary: true) }
    }
    func meleeExchange(_ u: Unit, _ t: Unit) {
        let retaliates = canRetaliate(t, against: u)
        if retaliates, strikesFirst(t, over: u) {
            t.retaliated = true
            blow(t, u)
            if u.alive { blow(u, t) }
        } else {
            blow(u, t)
            if retaliates, canRetaliate(t, against: u) { t.retaliated = true; blow(t, u) }
        }
        if u.alive, t.alive, u.stats.has("strikes_twice") { blow(u, t) }
        checkEnd()
    }

    /// Can the unit shoot now (it has shots and no enemy touches it)?
    public func canShoot(_ u: Unit) -> Bool {
        (u.shots > 0 || u.stats.has("unlimited_shots")) && u.stats.shooter && !units.contains { $0.alive && side(of: $0) != side(of: u) && Battle.adjacent(u, $0) }
    }
    func spendShot(_ u: Unit) { if !u.stats.has("unlimited_shots") { u.shots -= 1 } }
    func volley(_ u: Unit, _ t: Unit) {
        let extra = extraTargets(u, t, ranged: true)
        spendShot(u); hit(u, t, ranged: true)
        for e in extra where e.alive { hit(u, e, ranged: true, secondary: true) }
    }

    public func shoot(_ targetId: Int) -> Bool {
        guard finished == nil, let u = current, let t = units.first(where: { $0.id == targetId }), t.alive, side(of: t) != side(of: u) else { return false }
        guard canShoot(u) else { return attack(targetId) }
        Battle.face(u, towards: t)
        // a shooter that is shot at shoots back (once per round, like melee retaliation);
        // Ranged First Strike shoots first; Shoots Twice fires again after the retaliation
        let shootsBack = canRetaliate(t, against: u) || (t.alive && !t.disabled && !u.stats.has("no_retaliation") && (!t.retaliated || t.stats.has("unlimited_retaliation")))
        let back = shootsBack && canShoot(t)
        if back, t.stats.has("ranged_first_strike"), !u.stats.has("ranged_first_strike") {
            t.retaliated = true; Battle.face(t, towards: u); volley(t, u)
            if u.alive { volley(u, t) }
        } else {
            volley(u, t)
            if back, t.alive, !t.disabled { t.retaliated = true; Battle.face(t, towards: u); volley(t, u) }
        }
        if u.alive, t.alive, u.stats.has("shoots_twice"), canShoot(u) { volley(u, t) }
        checkEnd()
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

    /// Berserk creatures cannot wait.
    public func canWait(_ u: Unit) -> Bool { !u.waited && !u.stats.has("berserk") }
    public func wait() {
        guard finished == nil, let u = current, canWait(u) else { return }   // once a round: the flag clears only at the next round (0x5ed400)
        u.waited = true
        events.append(.wait(unit: u.id))
        order = turnOrder(order.map { unit($0) })
        checkMorale()
    }

    /// A simple opponent: shooters shoot the most dangerous enemy, others attack what they can
    /// reach or walk towards the nearest enemy (a hypnotized unit turns on its own side).
    public func autoAct() {
        guard finished == nil, let u = current else { return }
        let enemies = units.filter { $0.alive && $0.id != u.id && side(of: $0) != side(of: u) }
        guard !enemies.isEmpty else { defend(); return }
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
