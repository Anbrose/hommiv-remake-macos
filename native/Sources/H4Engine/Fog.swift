import Foundation

/// The shroud and fog of war (fog_spec.md; heroes4.exe keeps 3 bits a team in every cell, 0x413670):
/// a cell is unexplored (0, the black starfield), explored but not seen now (1, grey fog) or seen
/// (2) with a vision level; seeing drops back to fog when nothing sees the cell any more (0x4e0a60).
/// Enemy armies show only on seen cells whose vision level reaches their stealth (0x526110).
extension GameState {
    public static let fogUnexplored: UInt8 = 0, fogExplored: UInt8 = 1, fogSeen: UInt8 = 2

    public func fogState(_ x: Int, _ y: Int, level l: Int? = nil) -> UInt8 {
        let l = l ?? level, n = map.size
        guard fogEnabled, l < fog.count, x >= 0, y >= 0, x < n, y < n else { return GameState.fogSeen }
        return fog[l][x * n + y]
    }
    func ensureFog() {
        let n = map.size
        if fog.count != scenes.count || fog.first?.count != n * n {
            fog = Array(repeating: Array(repeating: GameState.fogUnexplored, count: n * n), count: max(1, scenes.count))
        }
        if fogLevel.count != fog.count { fogLevel = Array(repeating: Array(repeating: -1, count: n * n), count: fog.count) }
    }

    /// Reveal (0x4e1130): the cells whose centres lie within `radius` of the footprint's centre --
    /// (2x+1-(2px+w))^2 + (2y+1-(2py+h))^2 <= 4r^2 -- plus a square ring `edge` wide at one vision
    /// level more; `state` 1 explores only, 2 sees. terrain 1 = land only, 2 = water only.
    func reveal(level l: Int, x px: Int, y py: Int, w: Int = 1, h: Int = 1, radius r: Int, edge: Int = 0,
                state: UInt8, vision: Int = 0, terrain: Int = 0) {
        ensureFog()
        guard l < fog.count, r > 0 else { return }
        let n = map.size, reach = r + edge + max(w, h)
        for x in max(0, px - reach)...min(n - 1, px + w + reach) {
            for y in max(0, py - reach)...min(n - 1, py + h + reach) {
                let dx = 2 * x + 1 - (2 * px + w), dy = 2 * y + 1 - (2 * py + h)
                let inside = dx * dx + dy * dy <= 4 * r * r
                var v = vision
                if !inside {
                    // the ring, `edge` cells beyond the circle
                    let rr = r + edge
                    guard edge > 0, dx * dx + dy * dy <= 4 * rr * rr else { continue }
                    v = min(4, vision + 1)
                }
                if terrain != 0 {
                    let t = map.cells[l][x * n + y]?.type ?? 1
                    let water = t == 0 || t == 9 || t == 10 || t == 11
                    if (terrain == 1) == water { continue }
                }
                let k = x * n + y
                if fog[l][k] < state { fog[l][k] = state }
                if state == GameState.fogSeen, fogLevel[l][k] < Int8(v) { fogLevel[l][k] = Int8(v) }
            }
        }
    }
    /// One-shot exploring (tower, cartographer, hut of the magi): the cells become at least explored.
    public func explore(level l: Int, x: Int, y: Int, w: Int = 1, h: Int = 1, radius: Int, terrain: Int = 0) {
        reveal(level: l, x: x, y: y, w: w, h: h, radius: radius, state: GameState.fogExplored, terrain: terrain)
        visionChanged = true
    }

    /// A hero's sight: 10 + Scouting level (-1..4) + worn bonuses (0x26); a creature stack 9.
    func sightRadius(of h: Hero) -> Int {
        var r = h.army.isEmpty ? 0 : 9
        for m in [h] + h.companions where !m.actor.isEmpty {
            r = max(r, 10 + (m.skill("scouting") - 1) + m.artifactSum(0x26))
        }
        if h.boat != nil { r = max(r, 3) }
        return r
    }
    /// The army's vision level: a hero's Scouting level (at least 3 under Visions), a creature
    /// level L's L - 2.
    func visionLevel(of h: Hero) -> Int {
        var v = -1
        for m in [h] + h.companions where !m.actor.isEmpty {
            var s = m.skill("scouting") - 1
            if m.timedEffects["spell.visions"] != nil { s = max(s, 3) }
            v = max(v, s)
        }
        for s in h.army { v = max(v, (tables?.creature(s.creature)?.level ?? 1) - 2) }
        return min(4, v)
    }
    /// The army's stealth: its least stealthy member (a hero's Stealth level, a creature -1).
    public func stealth(of h: Hero) -> Int {
        var s = h.army.isEmpty ? Int.max : -1
        for m in [h] + h.companions { s = min(s, m.skill("stealth") - 1) }
        return s == Int.max ? -1 : s
    }
    /// Does the player see this enemy army?
    public func isVisible(_ h: Hero) -> Bool {
        guard fogEnabled else { return true }
        guard fogState(h.x, h.y, level: h.z) == GameState.fogSeen else { return false }
        return stealth(of: h) <= Int(fogLevel[h.z][h.x * map.size + h.y])
    }

    func footprint(level l: Int, x: Int, y: Int) -> (Int, Int) {
        guard l < scenes.count, let p = scenes[l].placed.first(where: { $0.cellX == x && $0.cellY == y && $0.type != "decorative" }) else { return (1, 1) }
        return (p.sprite.footprint.w, p.sprite.footprint.h)
    }
    /// Everything the player's side sees now (0x4e0a60): seen cells fall back to explored, then the
    /// armies (edge 2), towns (15), and owned objects (half their size + 3) see again.
    public func updateVision() {
        ensureFog()
        for l in fog.indices {
            for k in fog[l].indices where fog[l][k] == GameState.fogSeen { fog[l][k] = GameState.fogExplored }
            for k in fogLevel[l].indices { fogLevel[l][k] = -1 }
        }
        let me = map.humanColour
        for h in heroes {   // (the player's armies, whatever their colour)
            reveal(level: h.z, x: h.x, y: h.y, radius: sightRadius(of: h), edge: 2, state: GameState.fogSeen, vision: visionLevel(of: h))
        }
        for t in towns where t.owned {
            let (w, h) = footprint(level: t.z, x: t.x, y: t.y)
            reveal(level: t.z, x: t.x, y: t.y, w: w, h: h, radius: 15, state: GameState.fogSeen)
        }
        func owned(_ l: Int, _ x: Int, _ y: Int, extra: Int = 0) {
            let (w, h) = footprint(level: l, x: x, y: y)
            reveal(level: l, x: x, y: y, w: w, h: h, radius: max(max(w, h) / 2 + 3, extra), state: GameState.fogSeen)
        }
        for m in mines where m.owned { owned(m.z, m.x, m.y) }
        for d in dwellings where d.owned { owned(d.z, d.x, d.y) }
        for (k, st) in objectStates where st.owner == me {
            let c = k.split(separator: "|").compactMap { Int($0) }
            if c.count == 3 { owned(c[0], c[1], c[2]) }
        }
        for (k, h) in sanctuaryGuests {
            let c = k.split(separator: "|").compactMap { Int($0) }
            if c.count == 3 { owned(c[0], c[1], c[2], extra: sightRadius(of: h)) }
        }
        visionChanged = true
    }
    /// The wandering stacks of this level on cells the player sees now.
    func seenMonsters() -> Set<Int> {
        Set(monsters.indices.filter { monsters[$0].z == level && fogState(monsters[$0].x, monsters[$0].y) == GameState.fogSeen })
    }
    /// What decides the vision (re-run when it changes).
    public var visionSignature: Int {
        var hs = Hasher()
        for h in heroes { hs.combine(h.x); hs.combine(h.y); hs.combine(h.z); hs.combine(sightRadius(of: h)); hs.combine(h.army.count) }
        hs.combine(towns.filter(\.owned).count); hs.combine(mines.filter(\.owned).count); hs.combine(dwellings.filter(\.owned).count)
        hs.combine(objectStates.values.filter { $0.owner == map.humanColour }.count); hs.combine(sanctuaryGuests.count)
        return hs.finalize()
    }
}
