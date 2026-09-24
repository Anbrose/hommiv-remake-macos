import Foundation

/// Which cells a hero can walk on, and what a step costs, for one map level.
public struct Passability {
    public let size: Int
    public private(set) var blocked: [Bool]     // [x * size + y]
    public private(set) var cost: [Float]       // movement points to enter the cell

    /// Decorative categories that do not block movement even though their footprint says so.
    static let walkable: Set<String> = ["flowers", "moss", "Mushrooms", "Cracks-Holes", "Dunes", "Lava flows-mud", "Stumps", "Logs", "Skeletons"]

    public init(map: MapFile, level: Int, objects: [MapScene.Placed]) {
        size = map.size
        blocked = [Bool](repeating: true, count: size * size)
        cost = [Float](repeating: 1, count: size * size)
        let cells = map.cells[level]
        for x in 0..<size {
            for y in 0..<size {
                guard let c = cells[x * size + y] else { continue }
                let i = x * size + y
                switch c.type {
                case 0, 9, 10, 11: blocked[i] = true; continue   // water (no boats yet) and rivers (need a bridge)
                case 2, 6: cost[i] = 1.25                     // rough, sand
                case 3, 5: cost[i] = 1.5                      // swamp, snow
                default: cost[i] = 1
                }
                if !c.roads.isEmpty { cost[i] = 0.67 }
                blocked[i] = false
            }
        }
        let debug = ProcessInfo.processInfo.environment["H4DEBUG"] != nil
        for p in objects where !Passability.walkable.contains(p.category) {
            if debug, p.sprite.footprint.w * p.sprite.footprint.h > 1 || p.category == "mine" {
                print("footprint \(p.name) @(\(p.cellX),\(p.cellY)) \(p.sprite.footprint) blocked \(p.sprite.blocked) visitable \(p.sprite.visitable)")
            }
            // the second mask marks the cell a pickup lets you step on; for bigger objects its bits
            // do not line up with the footprint yet (layout still unknown), so only 1x1 objects use it
            let pickup = p.sprite.footprint.w * p.sprite.footprint.h == 1 && !p.sprite.visitable.isEmpty
            for b in p.sprite.blocked where !pickup {
                let x = p.cellX + b.x, y = p.cellY + b.y
                if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = true }
            }
        }
        // bridges (and their ramps) are walkable over the river they span: their whole footprint is a deck
        for p in objects where p.category == "movement modifiers" && p.name.lowercased().contains("bridge") {
            for i in 0..<p.sprite.footprint.w {
                for j in 0..<p.sprite.footprint.h {
                    let x = p.cellX + i, y = p.cellY + j
                    if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = false; cost[x * size + y] = 1 }
                }
            }
        }
    }

    public func isFree(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size && !blocked[x * size + y]
    }

    /// Cost of stepping from (x0, y0) onto (x1, y1): the target cell's cost, x1.4 diagonally.
    public func stepCost(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Float {
        cost[x1 * size + y1] * (x0 != x1 && y0 != y1 ? 1.4 : 1)
    }

    /// A* over the 8 neighbours; the path excludes the start and includes the goal, or nil.
    public func path(from start: (Int, Int), to goal: (Int, Int)) -> [(x: Int, y: Int)]? {
        guard isFree(goal.0, goal.1), start != goal else { return nil }
        let n = size * size
        var g = [Float](repeating: .infinity, count: n)
        var prev = [Int32](repeating: -1, count: n)
        var closed = [Bool](repeating: false, count: n)
        var open: [(f: Float, i: Int)] = []
        func h(_ i: Int) -> Float {
            let dx = abs(i / size - goal.0), dy = abs(i % size - goal.1)
            return Float(max(dx, dy)) * 0.67
        }
        let s = start.0 * size + start.1, t = goal.0 * size + goal.1
        g[s] = 0
        open.append((h(s), s))
        while !open.isEmpty {
            var best = 0
            for k in 1..<open.count where open[k].f < open[best].f { best = k }
            let (_, i) = open.remove(at: best)
            if closed[i] { continue }
            if i == t { break }
            closed[i] = true
            let x = i / size, y = i % size
            for dx in -1...1 {
                for dy in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard isFree(nx, ny) else { continue }
                    let j = nx * size + ny
                    if closed[j] { continue }
                    let ng = g[i] + stepCost(from: x, y, to: nx, ny)
                    if ng < g[j] {
                        g[j] = ng
                        prev[j] = Int32(i)
                        open.append((ng + h(j), j))
                    }
                }
            }
        }
        guard g[t] < .infinity else { return nil }
        var out: [(x: Int, y: Int)] = []
        var i = t
        while i != s { out.append((i / size, i % size)); i = Int(prev[i]) }
        return out.reversed()
    }
}

/// A hero on the adventure map.
public final class Hero {
    public let actor: String          // adv_actor name without prefix, e.g. "hero.life_might_male"
    public var x: Int, y: Int         // current cell
    public var facing = "s"
    public var movement: Float
    public let maxMovement: Float
    /// Remaining path (next cell first) while walking, and progress 0..1 to its first cell.
    public var path: [(x: Int, y: Int)] = []
    public var progress: Float = 0
    /// Cells walked so far (fractional); drives the walk animation so the legs match the ground.
    public var distance: Float = 0
    /// A path shown but not yet confirmed (HoMM style: click once to see, again to go).
    public var plan: [(x: Int, y: Int)] = []

    public init(actor: String, x: Int, y: Int, movement: Float = 20) {
        self.actor = actor; self.x = x; self.y = y; self.movement = movement; maxMovement = movement
    }

    public var isWalking: Bool { !path.isEmpty }

    /// Fractional map position while walking.
    public var position: (x: Float, y: Float) {
        guard let next = path.first else { return (Float(x), Float(y)) }
        return (Float(x) + (Float(next.x) - Float(x)) * progress, Float(y) + (Float(next.y) - Float(y)) * progress)
    }

    public static func facing(dx: Int, dy: Int) -> String {
        switch (dx.signum(), dy.signum()) {
        case (1, 0): return "sw"
        case (-1, 0): return "ne"
        case (0, 1): return "se"
        case (0, -1): return "nw"
        case (1, 1): return "s"
        case (-1, -1): return "n"
        case (1, -1): return "w"
        case (-1, 1): return "e"
        default: return "s"
        }
    }
}

/// Turn state of a scenario in progress.
public final class GameState {
    public let map: MapFile
    public let level: Int
    public let passability: Passability
    public var heroes: [Hero] = []
    public var day = 1
    public var week: Int { (day - 1) / 7 % 4 + 1 }
    public var month: Int { (day - 1) / 28 + 1 }
    public var dayOfWeek: Int { (day - 1) % 7 + 1 }
    public static let cellsPerSecond: Float = 4

    public init(map: MapFile, level: Int, scene: MapScene) {
        self.map = map
        self.level = level
        passability = Passability(map: map, level: level, objects: scene.placed)
    }

    /// The first free cell at or around (x, y), searching outward.
    public func freeCell(near x: Int, _ y: Int) -> (Int, Int)? {
        for r in 0..<8 {
            for dx in -r...r {
                for dy in -r...r where max(abs(dx), abs(dy)) == r {
                    if passability.isFree(x + dx, y + dy) { return (x + dx, y + dy) }
                }
            }
        }
        return nil
    }

    /// Click handling: first click plans a path to the cell, a second click on the same cell walks it.
    public func click(hero: Hero, x: Int, y: Int) {
        guard !hero.isWalking else { return }
        if let last = hero.plan.last, last.x == x, last.y == y {
            hero.path = hero.plan
            hero.plan = []
            hero.progress = 0
        } else {
            hero.plan = passability.path(from: (hero.x, hero.y), to: (x, y)) ?? []
        }
    }

    /// Advance walking heroes by dt seconds.
    public func update(dt: Float) {
        for h in heroes where h.isWalking {
            let next = h.path[0]
            let stepCost = passability.stepCost(from: h.x, h.y, to: next.x, next.y)
            if h.movement + 0.001 < stepCost { h.path = []; continue }   // out of movement: stop here
            h.facing = Hero.facing(dx: next.x - h.x, dy: next.y - h.y)
            h.progress += dt * GameState.cellsPerSecond
            h.distance += dt * GameState.cellsPerSecond
            if h.progress >= 1 {
                h.x = next.x; h.y = next.y
                h.movement -= stepCost
                h.path.removeFirst()
                h.progress = 0
            }
        }
    }

    public func endTurn() {
        day += 1
        for h in heroes { h.movement = h.maxMovement; h.path = []; h.plan = [] }
    }

    public var dateText: String { "Month \(month), Week \(week), Day \(dayOfWeek)" }
}
