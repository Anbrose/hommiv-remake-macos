import Foundation

// Wandering stacks' guard zones and when they fall on a hero, as heroes4.exe has them
// (re/adventure_guards_spec.md): the per-cell danger marks of the path finder (0x498460 "mark
// enemies", flooded by 0x4979f0), the route planner's forced exit inside a zone the player sees
// (0x4ff856), the walk cut as the mover starts (0x5439e0) and the attack at the end of every
// move (0x4f81e0).

/// One flood mark of a cell (the record's danger bits): the step toward the stack that marked it
/// (a direction of Passability.directions), the flood distance (2 a straight step, 3 a diagonal;
/// 0 on the stack's own cell) and whether the stack's way here is clean (no corner cut).
public struct GuardMark: Equatable {
    public var dir: Int, dist: Int, clean: Bool
}

/// The danger marks of a level for one army: `a` from every stack that notices it, `b` from the
/// ones the player sees (0x498460's two floods), indexed x * size + y.
public struct GuardMap {
    public let size: Int
    public var a: [GuardMark?], b: [GuardMark?]
    init(size: Int) { self.size = size; a = Array(repeating: nil, count: size * size); b = a }
    public func a(_ x: Int, _ y: Int) -> GuardMark? { x >= 0 && y >= 0 && x < size && y < size ? a[x * size + y] : nil }
    public func b(_ x: Int, _ y: Int) -> GuardMark? { x >= 0 && y >= 0 && x < size && y < size ? b[x * size + y] : nil }
}

extension GameState {
    // MARK: stealth and scouting

    static func isStealthy(_ creature: String) -> Bool {
        (RuleTables.creatureAbilities[creature.lowercased()] ?? []).contains("stealth")
    }
    /// A stack's stealth (0x6428a0): the least of its members', a creature 1 with the Stealth
    /// ability (bandits) else -1; at most 4.
    func stealth(of m: Monster) -> Int {
        var s = 4
        for c in [m.creature] + m.extra.filter({ $0.count > 0 }).map(\.creature) { s = min(s, GameState.isStealthy(c) ? 1 : -1) }
        return s
    }
    /// A stack's scouting (0x642860): the most of its creatures' level - 2.
    func scouting(of m: Monster) -> Int {
        var v = -1
        for c in [m.creature] + m.extra.filter({ $0.count > 0 }).map(\.creature) { v = max(v, (tables?.creature(c)?.level ?? 1) - 2) }
        return v
    }

    // MARK: the flood (0x4979f0)

    /// Flood one stack's zone into `marks` as 0x4979f0 does with the functor of 0x498460: the
    /// stack's own cell (distance 0); then, unless the army's stealth beats the stack's scouting
    /// by two (scouting + 1 < stealth), the 5 x 5 square around it outward over the ground the
    /// stack stands on (land or water), cut by obstacles and objects.
    func flood(_ i: Int, stealth: Int, into marks: inout [GuardMark?], _ p: Passability) {
        let m = monsters[i], n = p.size
        guard m.x >= 0, m.y >= 0, m.x < n, m.y < n else { return }
        // the functor's test (0x4972e0 / 0x497380): a mark gives way to a clean one where it was
        // not clean, else only to a strictly nearer one, never a clean one to one that is not
        func refused(_ old: GuardMark?, _ new: GuardMark) -> Bool {
            guard let o = old else { return false }
            if o.clean != new.clean { return o.clean }
            return new.dist >= o.dist
        }
        struct Entry { var x: Int, y: Int, mark: GuardMark, parent: (Int, Int)? }
        marks[m.x * n + m.y] = GuardMark(dir: 0, dist: 0, clean: true)   // applied without the test
        guard scouting(of: m) + 1 >= stealth else { return }
        let atSea = p.isWater(m.x, m.y) && p.bridgeAxis[m.x * n + m.y] == 0
        var local = [GuardMark?](repeating: nil, count: 25)
        local[12] = GuardMark(dir: 0, dist: 0, clean: true)
        // the open list, kept by distance with the largest first; the last entry is taken next
        var open = [Entry(x: m.x, y: m.y, mark: local[12]!, parent: nil)]
        while let e = open.popLast() {
            let reach = abs(e.y - m.y) + abs(e.x - m.x)
            for (d, step) in Passability.directions.enumerated() {
                let cx = e.x + step.dx, cy = e.y + step.dy
                guard cx >= 0, cy >= 0, cx < n, cy < n else { continue }
                // flagged as 0x497810 does: the step is refused or the cell stops routes
                let flagged = !p.canStep(from: e.x, e.y, to: cx, cy) || p.isTrigger(cx, cy)
                var clean = true
                if flagged {
                    if d % 2 == 1, p.cornerBlocked(from: e.x, e.y, to: cx, cy) { clean = false }
                    if d % 2 == 0, !p.enters(from: e.x, e.y, to: cx, cy) { continue }
                }
                let ox = cx - m.x + 2, oy = cy - m.y + 2
                guard ox >= 0, ox < 5, oy >= 0, oy < 5, abs(cy - m.y) + abs(cx - m.x) >= reach else { continue }
                var c = Entry(x: cx, y: cy, mark: GuardMark(dir: (d + 4) & 7, dist: e.mark.dist + (d % 2 == 1 ? 3 : 2), clean: clean), parent: (e.x, e.y))
                if refused(local[ox * 5 + oy], c.mark) { continue }
                // the stack's own ground: at sea open water, else land or a bridge deck
                if atSea ? !p.isWater(cx, cy) : (p.isWater(cx, cy) && p.bridgeAxis[cx * n + cy] == 0) { continue }
                // a cell next to the stack reached straight from another next to it: it points
                // at the stack itself, diagonally, at distance 3 (0x498096)
                if clean, abs(cx - m.x) <= 1, abs(cy - m.y) <= 1, (e.x, e.y) != (m.x, m.y),
                   let par = e.parent, par == (m.x, m.y), d % 2 == 0 {
                    let cd = c.mark.dir, pd = e.mark.dir
                    if (cd + 2) & 7 == pd || (cd + 6) & 7 == pd {
                        c.parent = (m.x, m.y); c.mark.dist = 3
                        c.mark.dir = (cd + 6) & 7 == pd ? (cd + 7) & 7 : (cd + 1) & 7
                    }
                }
                let k = cx * n + cy
                if refused(marks[k], c.mark) { continue }
                local[ox * 5 + oy] = c.mark
                marks[k] = GuardMark(dir: c.mark.dir, dist: c.mark.dist & 31, clean: c.mark.clean)
                if flagged { continue }   // marked, not spread from
                // insert before the first entry not farther than it (0x49822a)
                var lo = 0, count = open.count
                while count > 0 {
                    let half = count / 2
                    if open[lo + half].mark.dist > c.mark.dist { lo += half + 1; count -= half + 1 } else { count = half }
                }
                open.insert(c, at: lo)
            }
        }
    }

    /// The stacks flooded against an army (0x498460): the wandering stacks of this level, in the
    /// map's order (not the guards of banks, dwellings and garrisons).
    var guardStacks: [Int] { monsters.indices.filter { monsters[$0].z == level && monsters[$0].bank == nil && monsters[$0].count > 0 } }

    /// The danger marks for an army: A over every stack, B over the ones the player sees.
    public func guardMap(for h: Hero) -> GuardMap {
        let s = stealth(of: h), seen = guardStacks.filter { monsterSeen($0) }
        var hs = Hasher()
        hs.combine(s); hs.combine(level); hs.combine(passability.revision); hs.combine(monsterRevision); hs.combine(seen)
        let key = hs.finalize()
        if let c = guardCache, c.key == key { return c.map }
        let p = passability
        var g = GuardMap(size: p.size)
        for i in guardStacks {
            flood(i, stealth: s, into: &g.a, p)
            if seen.contains(i) { flood(i, stealth: s, into: &g.b, p) }
        }
        guardCache = (key, g)
        return g
    }

    /// The stack whose zone holds the cell (0x4fdf80): follow the A marks toward their stacks
    /// down to distance 0, the stack standing there.
    func guardAttacker(at c: (Int, Int), _ g: GuardMap) -> Int? {
        var x = c.0, y = c.1, steps = 0
        while let mk = g.a(x, y), mk.dist > 0 {
            let d = Passability.directions[mk.dir]
            x += d.dx; y += d.dy; steps += 1
            if steps > 64 { return nil }
        }
        guard g.a(x, y)?.dist == 0 else { return nil }
        return monsters.indices.first { monsters[$0].x == x && monsters[$0].y == y && monsters[$0].z == level && monsters[$0].bank == nil && monsters[$0].count > 0 }
    }

    /// The wandering stack that falls on the hero when a move of his ends on the cell (0x4f81e0).
    public func threat(to h: Hero, at x: Int, _ y: Int) -> Int? {
        let g = guardMap(for: h)
        guard let a = g.a(x, y), a.dist > 0 else { return nil }
        return guardAttacker(at: (x, y), g)
    }

    /// The stack the player sees whose zone holds the cell (the B marks): the yellow arrows and
    /// the attack pointer over free ground.
    public func seenThreat(to h: Hero, at x: Int, _ y: Int) -> Int? {
        let g = guardMap(for: h)
        guard let b = g.b(x, y), b.dist > 0, let i = guardAttacker(at: (x, y), g), monsterSeen(i) else { return nil }
        return i
    }

    /// The planner's forced exits for the army (0x4ff856): in a cell of the zone of a stack the
    /// player sees, clean, the only way on is the step toward the stack.
    func forcedExits(for h: Hero) -> [Int: Int] {
        let g = guardMap(for: h)
        var out: [Int: Int] = [:]
        for (k, b) in g.b.enumerated() { if let b = b, b.clean { out[k] = b.dir } }
        return out
    }
    /// Set the planner up for this army: its Pathfinding relief and the forced exits.
    func preparePlanner(for h: Hero) {
        passability.relief = GameState.terrainRelief(h)
        passability.forcedExit = forcedExits(for: h)
    }

    // MARK: the walk (0x5439e0)

    /// Cut a walk as the mover does when it starts (0x5439e0); what is cut stays as the route
    /// to go on with. A stack the player does not see but the hero makes out (its stealth not
    /// above the army's scouting) stops the walk before its zone; one hidden from him lets him
    /// step in and the walk ends there. In the zone of a stack the player sees the walk goes on
    /// only straight toward the stack (each cell the one its predecessor points at, or the stack).
    func cutWalk(_ h: Hero) {
        let g = guardMap(for: h), sc = visionLevel(of: h)
        var tracking: (stack: Int, expected: (Int, Int))? = nil
        var cut: Int? = nil
        for (k, c) in h.path.enumerated() {
            var stopAfter = false
            if let a = g.a(c.x, c.y), a.dist > 0 {
                let seenHere = g.b(c.x, c.y).map { $0.dir == a.dir && $0.dist == a.dist } ?? false
                if !seenHere, let i = guardAttacker(at: (c.x, c.y), g) {
                    if stealth(of: monsters[i]) - sc <= 0 { cut = k; break }
                    stopAfter = true   // (a stack has no owner: it always ends the walk here)
                }
            }
            let bClean = g.b(c.x, c.y)?.clean ?? false
            if bClean || tracking != nil {
                if let t = tracking {
                    let s = monsters.indices.contains(t.stack) ? (monsters[t.stack].x, monsters[t.stack].y) : (-1, -1)
                    guard (c.x, c.y) == t.expected || (c.x, c.y) == s else { cut = k; break }
                } else if let i = guardAttacker(at: (c.x, c.y), g) {
                    tracking = (i, (0, 0))
                }
                if tracking != nil {
                    let d = Passability.directions[g.a(c.x, c.y)?.dir ?? 0]
                    tracking!.expected = (c.x + d.dx, c.y + d.dy)
                }
            }
            if let a = g.a(c.x, c.y), a.dist == 0 { cut = k; break }   // a stack's own cell
            if stopAfter { cut = k + 1; break }
        }
        guard let k = cut, k < h.path.count else { return }
        h.plan = Array(h.path[k...]); h.path = Array(h.path[..<k])
        h.walkCut = true
    }

    // MARK: the end of a move (0x546d50 -> 0x4f81e0)

    /// A move of the army ended (its walk done, cut, stopped, or an object next to it used): once
    /// nothing waits for the player, a stack whose zone holds its cell may fall on it.
    func moveEnded(_ h: Hero) {
        if !pendingGuardChecks.contains(where: { $0 === h }) { pendingGuardChecks.append(h) }
    }
    /// Something waits for the player (a dialog, a battle, a stack charging).
    var adventureBusy: Bool {
        charge != nil || pendingBattle != nil || pendingHeroBattle != nil || pendingSiege != nil || pendingTrade != nil
            || chestOffer != nil || question != nil || choice != nil || teleportChoice != nil || hireOpen != nil
            || dwellingOpen != nil || heroPick != nil || skillDialog != nil || shopOpen != nil || sanctuaryOpen != nil || puzzleOpen != nil || levelUp != nil
            || !scripts.messages.isEmpty
    }
    func runGuardChecks() {
        while !pendingGuardChecks.isEmpty, !adventureBusy {
            let h = pendingGuardChecks.removeFirst()
            guardAttack(h)
        }
    }
    /// 0x4f81e0: the stack whose zone holds the army's cell walks its own route (a plain one, no
    /// zones) up to the army and the battle follows; no route, no attack.
    func guardAttack(_ h: Hero) {
        guard heroes.contains(where: { $0 === h }), h.z == level, !h.isWalking,
              !h.army.isEmpty || !h.members.isEmpty, let i = threat(to: h, at: h.x, h.y) else { return }
        var p = passability
        p.forcedExit = [:]; p.relief = 0; p.jumps = [:]
        guard let r = p.path(from: (monsters[i].x, monsters[i].y), to: (h.x, h.y)), !r.isEmpty else { return }
        log.append("\(tables?.creature(monsters[i].creature)?.plural ?? monsters[i].creature) attack \(h.name)!")
        h.target = nil
        charge = (i, h, Array(r.dropLast()), 0)
        if r.count == 1 { finishCharge() }
    }

    /// A click while the army walks only stops it (0x4f5d58 -> 0x546c20): it ends the step it is
    /// on; the rest of the route stays; nothing is used.
    func stopWalk(_ h: Hero) {
        guard h.isWalking else { return }
        h.plan = Array(h.path.dropFirst()) + h.plan
        h.path = [h.path[0]]
        h.walkCut = true
    }
}

extension Passability {
    /// The corner rule of 0x4d7950 for a diagonal step: one of the four edges around the corner
    /// is blocked (here: an object's footprint on one of the four cells, or the map's edge).
    func cornerBlocked(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Bool {
        guard x0 != x1, y0 != y1 else { return false }
        for (x, y) in [(x1, y0), (x0, y1)] where x < 0 || y < 0 || x >= size || y >= size { return true }
        return edgeAt(x1, y0) || edgeAt(x0, y1) || edgeAt(x0, y0) || edgeAt(x1, y1)
    }
}
