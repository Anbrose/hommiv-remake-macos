import Foundation

/// Which cells a hero can walk on, and what a step costs, for one map level.
public struct Passability {
    public let size: Int
    public private(set) var blocked: [Bool]     // [x * size + y]
    public private(set) var cost: [Float]       // movement points to enter the cell
    /// Pixels a creature standing on the cell is raised: bridge decks are drawn about 56 px above
    /// the river cells they span, their ramps half that.
    public private(set) var elevation: [Float]
    /// 0 = not a bridge, 1 = bridge running along x, 2 = along y: on a bridge you can only walk
    /// along it, and you get on and off at its ends.
    public private(set) var bridgeAxis: [UInt8]

    /// Decorative categories that do not block movement even though their footprint says so.
    static let walkable: Set<String> = ["flowers", "moss", "Mushrooms", "Cracks-Holes", "Dunes", "Lava flows-mud", "Stumps", "Logs", "Skeletons"]

    public init(map: MapFile, level: Int, objects: [MapScene.Placed]) {
        size = map.size
        blocked = [Bool](repeating: true, count: size * size)
        cost = [Float](repeating: 1, count: size * size)
        elevation = [Float](repeating: 0, count: size * size)
        bridgeAxis = [UInt8](repeating: 0, count: size * size)
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
            // pickups block too: the hero stops next to them and takes them from there
            for b in p.sprite.blocked {
                let x = p.cellX + b.x, y = p.cellY + b.y
                if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = true }
            }
        }
        // bridges (and their ramps) are walkable over the river they span: their whole footprint is a deck
        for p in objects where p.category == "movement modifiers" && p.name.lowercased().contains("bridge") {
            let raise: Float = p.name.lowercased().contains("ramp") ? 28 : 56
            for i in 0..<p.sprite.footprint.w {
                for j in 0..<p.sprite.footprint.h {
                    let x = p.cellX + i, y = p.cellY + j
                    if x >= 0, x < size, y >= 0, y < size {
                        blocked[x * size + y] = false; cost[x * size + y] = 1; elevation[x * size + y] = raise
                        bridgeAxis[x * size + y] = 3   // axis decided below
                    }
                }
            }
        }
        for x in 0..<size {
            for y in 0..<size where bridgeAxis[x * size + y] == 3 {
                let alongX = (x > 0 && bridgeAxis[(x - 1) * size + y] != 0) || (x + 1 < size && bridgeAxis[(x + 1) * size + y] != 0)
                bridgeAxis[x * size + y] = alongX ? 1 : 2
            }
        }
    }

    /// May a hero step from one cell to a neighbouring one? Bridges only allow moves along their axis.
    public func canStep(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Bool {
        guard isFree(x1, y1) else { return false }
        let dx = x1 - x0, dy = y1 - y0
        for i in [x0 * size + y0, x1 * size + y1] {
            switch bridgeAxis[i] {
            case 1: if dy != 0 { return false }
            case 2: if dx != 0 { return false }
            default: break
            }
        }
        return true
    }

    public func elevation(_ x: Int, _ y: Int) -> Float {
        x >= 0 && x < size && y >= 0 && y < size ? elevation[x * size + y] : 0
    }

    public mutating func free(_ x: Int, _ y: Int) {
        if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = false }
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
                    guard canStep(from: x, y, to: nx, ny) else { continue }
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
    /// The object the current plan/path leads to (a pickup taken on arrival), by cell and name.
    public var target: (x: Int, y: Int, name: String)?

    public init(actor: String, x: Int, y: Int, movement: Float = 20) {
        self.actor = actor; self.x = x; self.y = y; self.movement = movement; maxMovement = movement
    }

    public var isWalking: Bool { !path.isEmpty }

    /// Fractional map position while walking.
    public var position: (x: Float, y: Float) {
        guard let next = path.first else { return (Float(x), Float(y)) }
        return (Float(x) + (Float(next.x) - Float(x)) * progress, Float(y) + (Float(next.y) - Float(y)) * progress)
    }

    /// Pixels the hero is raised at its current (fractional) position.
    public func elevation(in p: Passability) -> Float {
        let here = p.elevation(x, y)
        guard let next = path.first else { return here }
        return here + (p.elevation(next.x, next.y) - here) * progress
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
    public let scene: MapScene
    public private(set) var passability: Passability
    public var heroes: [Hero] = []
    /// Things that happened this frame, for the UI (e.g. "picked up Resources.Gold").
    public var log: [String] = []
    /// The player's treasury (starting amounts of a normal game).
    public var resources: [String: Int] = ["Wood": 15, "Ore": 15, "Mercury": 7, "Sulfur": 7, "Crystal": 7, "Gems": 7, "Gold": 15000]
    public var day = 1
    public var week: Int { (day - 1) / 7 % 4 + 1 }
    public var month: Int { (day - 1) / 28 + 1 }
    public var dayOfWeek: Int { (day - 1) % 7 + 1 }
    public static let cellsPerSecond: Float = 4

    public init(map: MapFile, level: Int, scene: MapScene) {
        self.map = map
        self.level = level
        self.scene = scene
        passability = Passability(map: map, level: level, objects: scene.placed)
    }

    /// A 1x1 object with a "step here to use" mask: resources, chests, artifacts, campfires.
    public func isPickup(_ p: MapScene.Placed) -> Bool {
        p.sprite.footprint.w * p.sprite.footprint.h == 1 && !p.sprite.visitable.isEmpty && !p.sprite.blocked.isEmpty
    }

    static func adjacent(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { max(abs(a.0 - b.0), abs(a.1 - b.1)) == 1 }

    /// Click on a pickup: take it if the hero stands next to it, otherwise plan (then walk) to the
    /// cheapest neighbouring cell; it is taken on arrival.
    public func click(hero: Hero, pickup p: MapScene.Placed) {
        let walking = hero.isWalking
        if walking { interrupt(hero) }
        let from = standingCell(hero)
        if !walking, GameState.adjacent(from, (p.cellX, p.cellY)) { take(hero: hero, p); return }
        if !walking, let t = hero.target, t.x == p.cellX, t.y == p.cellY, !hero.plan.isEmpty {
            hero.path = hero.plan; hero.plan = []; hero.progress = 0
            return
        }
        var best: [(x: Int, y: Int)]? = nil
        var bestCost = Float.infinity
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let c = (p.cellX + dx, p.cellY + dy)
                guard passability.isFree(c.0, c.1) else { continue }
                if c == from { best = []; bestCost = 0; continue }
                guard let path = passability.path(from: from, to: c) else { continue }
                var cost: Float = 0
                var px = from.0, py = from.1
                for s in path { cost += passability.stepCost(from: px, py, to: s.x, s.y); px = s.x; py = s.y }
                if cost < bestCost { bestCost = cost; best = path }
            }
        }
        hero.plan = best ?? []
        hero.target = best == nil ? nil : (p.cellX, p.cellY, p.name)
    }

    func take(hero: Hero, _ p: MapScene.Placed) {
        guard hero.movement >= 1 else { log.append("no movement left to pick up \(p.name)"); return }
        scene.remove(p)
        passability.free(p.cellX, p.cellY)
        hero.movement -= 1
        hero.target = nil
        // what a pile is worth (rough HoMM IV amounts; the real tables come later)
        let kind = p.name.replacingOccurrences(of: "adv_object.Resources.", with: "").replacingOccurrences(of: ".h4d", with: "")
        switch kind {
        case "Gold": resources["Gold", default: 0] += 750
        case "Wood", "Ore": resources[kind, default: 0] += 8
        case "Mercury", "Sulfur", "Crystal", "Gems": resources[kind, default: 0] += 4
        case "Treasure Chest": resources["Gold", default: 0] += 1500
        case "Campfire": resources["Gold", default: 0] += 500; resources["Wood", default: 0] += 5
        default: break
        }
        log.append("picked up \(p.name) at (\(p.cellX),\(p.cellY))")
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

    /// Where the hero will stand once its current step ends.
    func standingCell(_ hero: Hero) -> (Int, Int) { hero.path.first.map { ($0.x, $0.y) } ?? (hero.x, hero.y) }

    /// A click while walking: finish the current step, then stop and show the new route.
    func interrupt(_ hero: Hero) {
        if hero.isWalking { hero.path = [hero.path[0]] }
        hero.target = nil
    }

    /// Click handling: first click plans a path to the cell, a second click on the same cell walks it.
    public func click(hero: Hero, x: Int, y: Int) {
        if hero.isWalking {
            interrupt(hero)
            let from = standingCell(hero)
            hero.plan = passability.path(from: from, to: (x, y)) ?? []
            return
        }
        if let last = hero.plan.last, last.x == x, last.y == y {
            hero.path = hero.plan
            hero.plan = []
            hero.progress = 0
        } else {
            hero.plan = passability.path(from: (hero.x, hero.y), to: (x, y)) ?? []
            hero.target = nil
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
                if h.path.isEmpty, let t = h.target, GameState.adjacent((h.x, h.y), (t.x, t.y)),
                   let p = scene.placed.first(where: { $0.cellX == t.x && $0.cellY == t.y && $0.name == t.name }) {
                    take(hero: h, p)
                }
            }
        }
    }

    public func endTurn() {
        day += 1
        for h in heroes { h.movement = h.maxMovement; h.path = []; h.plan = [] }
    }

    public var dateText: String { "Month \(month), Week \(week), Day \(dayOfWeek)" }

    /// Screen directions clockwise, as the arrow sprites name them.
    static let compass = ["n", "ne", "e", "se", "s", "sw", "w", "nw"]

    /// The path arrows to draw for a hero's planned route: (cell, sprite name such as
    /// "green_arrow.left.ne"). Green while the hero can still afford the step this turn, red after;
    /// the last cell gets the destination marker.
    public func arrows(for h: Hero) -> [(x: Int, y: Int, name: String)] {
        let plan = h.plan
        guard !plan.isEmpty else { return [] }
        var out: [(Int, Int, String)] = []
        var left = h.movement
        var px = h.x, py = h.y
        for (k, c) in plan.enumerated() {
            let stepCost = passability.stepCost(from: px, py, to: c.x, c.y)
            let colour = left + 0.001 >= stepCost ? "green_arrow" : "red_arrow"
            left -= stepCost
            if k == plan.count - 1 { out.append((c.x, c.y, "\(colour).dest")); break }
            let n = plan[k + 1]
            let din = GameState.compass.firstIndex(of: Hero.facing(dx: c.x - px, dy: c.y - py)) ?? 0
            let dout = GameState.compass.firstIndex(of: Hero.facing(dx: n.x - c.x, dy: n.y - c.y)) ?? 0
            let turn = (dout - din + 8) % 8
            let shape = turn == 7 ? "left" : turn == 1 ? "right" : "straight"
            out.append((c.x, c.y, "\(colour).\(shape).\(GameState.compass[dout])"))
            px = c.x; py = c.y
        }
        return out
    }
}
