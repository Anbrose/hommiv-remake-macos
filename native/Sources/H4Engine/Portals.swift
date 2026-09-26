import Foundation

/// Gateways, portals and ferries in route planning (teleport_spec §3a; heroes4.exe 0x4ff180): each
/// adds a free edge from its approach cells to every destination's approach cells, so a click
/// beyond one plans through it -- the walk ends at the object, which then asks where to go.
extension GameState {
    /// The free cells round an object's footprint, in the landing order (0x723e70: NE, E, SE, S,
    /// SW, W, NW, N round it, nearest ring first).
    func approachCells(_ p: MapScene.Placed, water: Bool = false) -> [(Int, Int)] {
        let fw = p.sprite.footprint.w, fh = p.sprite.footprint.h
        var out: [(Int, Int)] = []
        // (map x runs down-right and y down-left on screen: NE = (-1, 0) ... as the compass turns)
        let order = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]
        for (dx, dy) in order {
            let xs = dx < 0 ? [-1] : dx > 0 ? [fw] : Array(0..<fw), ys = dy < 0 ? [-1] : dy > 0 ? [fh] : Array(0..<fh)
            for x in xs { for y in ys {
                let c = (p.cellX + x, p.cellY + y)
                if water ? passability.isFreeWater(c.0, c.1) : (passability.isFree(c.0, c.1) && !passability.isWater(c.0, c.1)) { out.append(c) }
            } }
        }
        return out
    }
    /// The destinations an object sends an army to on this level (the planner's edges).
    func destinations(of p: MapScene.Placed) -> [MapScene.Placed] {
        switch p.type {
        case "gateway": return scene.placed.filter { $0.type == "gateway" && $0.subtype == p.subtype && !($0.cellX == p.cellX && $0.cellY == p.cellY) }
        case "teleporter_entrance": return scene.placed.filter { $0.type == "teleporter_exit" && $0.subtype == p.subtype }
        case "ferry": return ferries(from: p)
        default: return []
        }
    }
    /// Every other ferry on the same body of water (0x4dc1d0, the water flood-filled 0x4daff0).
    func ferries(from p: MapScene.Placed) -> [MapScene.Placed] {
        let all = scene.placed.filter { $0.type == "ferry" }
        guard all.count > 1 else { return [] }
        let n = map.size
        if waterBodies.count != scenes.count { waterBodies = Array(repeating: [], count: scenes.count) }
        if waterBodies[level].isEmpty {
            var body = [Int](repeating: -1, count: n * n), next = 0
            for s in 0..<(n * n) where body[s] < 0 && passability.isWater(s / n, s % n) {
                var stack = [s]; body[s] = next
                while let i = stack.popLast() {
                    for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                        let x = i / n + dx, y = i % n + dy
                        guard passability.isWater(x, y), body[x * n + y] < 0 else { continue }
                        body[x * n + y] = next; stack.append(x * n + y)
                    } }
                }
                next += 1
            }
            waterBodies[level] = body
        }
        let body = waterBodies[level]
        func bodies(_ q: MapScene.Placed) -> Set<Int> {
            var out = Set<Int>()
            for dx in -1...q.sprite.footprint.w { for dy in -1...q.sprite.footprint.h {
                let x = q.cellX + dx, y = q.cellY + dy
                if x >= 0, y >= 0, x < n, y < n, body[x * n + y] >= 0 { out.insert(body[x * n + y]) }
            } }
            return out
        }
        let mine = bodies(p)
        return all.filter { !($0.cellX == p.cellX && $0.cellY == p.cellY) && !bodies($0).isDisjoint(with: mine) }
    }
    /// Give the planner this level's edges: approach cell -> destination approach cells.
    func refreshJumps() {
        var jumps: [Int: [Int]] = [:], sources: [Int: MapScene.Placed] = [:]
        let n = map.size
        for p in scene.placed where p.type == "gateway" || p.type == "teleporter_entrance" || p.type == "ferry" {
            let to = destinations(of: p).flatMap { approachCells($0) }.map { $0.0 * n + $0.1 }
            guard !to.isEmpty else { continue }
            for c in approachCells(p) { jumps[c.0 * n + c.1, default: []] += to; sources[c.0 * n + c.1] = p }
        }
        passability.jumps = jumps
        jumpSources = sources
    }
    /// A planned route that goes through a gateway ends at it: (the route to the object, the object).
    func cutAtJump(_ route: [(x: Int, y: Int)], from start: (Int, Int)) -> (route: [(x: Int, y: Int)], via: MapScene.Placed?) {
        var prev = start
        for (k, c) in route.enumerated() {
            if !GameState.adjacent((prev.0, prev.1), (c.x, c.y)) {
                return (Array(route[..<k]), jumpSources[prev.0 * map.size + prev.1])
            }
            prev = (c.x, c.y)
        }
        return (route, nil)
    }
}
