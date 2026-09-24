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
    /// Road type on the cell (0 none, 1 stone, 2 dirt, 3 cobble); road-to-road moves cost the road's rate.
    public private(set) var roadType: [UInt8]

    /// Decorative categories that do not block movement even though their footprint says so.
    static let walkable: Set<String> = ["flowers", "moss", "Mushrooms", "Cracks-Holes", "Dunes", "Lava flows-mud", "Stumps", "Logs", "Skeletons"]

    /// Movement cost per tile by terrain type, from the game's terrain descriptions
    /// (grass/dirt/subterranean 1, rough/volcanic 1.25, sand 1.5, snow 1.75, swamp 2, ice river 1.5).
    public static func terrainCost(_ type: UInt8) -> Float {
        switch type {
        case 2, 4, 15, 16: return 1.25
        case 6, 11: return 1.5
        case 5: return 1.75
        case 3: return 2
        default: return 1
        }
    }
    /// Movement rate of a road type for road-to-road moves.
    public static func roadRate(_ type: UInt8) -> Float { type == 2 ? 1 : 0.75 }

    public init(map: MapFile, level: Int, objects: [MapScene.Placed]) {
        size = map.size
        blocked = [Bool](repeating: true, count: size * size)
        cost = [Float](repeating: 1, count: size * size)
        elevation = [Float](repeating: 0, count: size * size)
        bridgeAxis = [UInt8](repeating: 0, count: size * size)
        roadType = MapScene.roadTypes(map: map, level: level)
        let cells = map.cells[level]
        for x in 0..<size {
            for y in 0..<size {
                guard let c = cells[x * size + y] else { continue }
                let i = x * size + y
                switch c.type {
                case 0, 9, 10, 11: blocked[i] = true; continue   // water (no boats yet) and rivers (need a bridge)
                default: cost[i] = Passability.terrainCost(c.type)
                }
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
    public mutating func block(_ x: Int, _ y: Int) {
        if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = true }
    }

    public func isFree(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size && !blocked[x * size + y]
    }

    /// Cost of stepping from (x0, y0) onto (x1, y1): the target cell's terrain cost, or the
    /// road's rate when both cells have a road ("road-to-road moves, regardless of the
    /// terrain"); x1.4 diagonally.
    public func stepCost(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Float {
        let i = x1 * size + y1
        let base = roadType[i] > 0 && roadType[x0 * size + y0] > 0 ? Passability.roadRate(roadType[i]) : cost[i]
        return base * (x0 != x1 && y0 != y1 ? 1.4 : 1)
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
    public var name = "Hero"
    public var keyword = ""           // heroes table keyword, also the portrait layer name
    public var alignment = "life"
    /// The army travelling with the hero (the hero is a stack of his own, drawn first).
    public struct Stack {
        public var creature: String; public var count: Int
        public init(creature: String, count: Int) { self.creature = creature; self.count = count }
    }
    public var army: [Stack] = []
    public static let armySlots = 7   // the hero plus six stacks
    public var experience = 0
    public var level: Int { 1 + experience / 1000 }
    public var home: (x: Int, y: Int) = (0, 0)   // where a beaten hero regroups
    public var x: Int, y: Int         // current cell
    public var facing = "s"
    public var movement: Float
    /// Movement per day: the slowest of the hero and the creatures travelling with it.
    public var maxMovement: Float
    /// A hero's own movement (the recording: a level 15 hero shows 22, a low one 20).
    public static let baseMovement: Float = 20
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
    public var tables: RuleTables?
    public struct Town {
        public let x: Int, y: Int
        public var name: String
        public let alignment: String
        public var owned: Bool
        public var buildings: Set<String> = []          // building keywords, as in the buildings table
        public var available: [String: Int] = [:]      // creature keyword -> recruits waiting
        public var builtToday = false
        public var terrain: UInt8 = 1
    }
    public struct Mine { public let x: Int, y: Int, name: String, resource: String, amount: Int; public var owned: Bool }
    public struct Dwelling { public let x: Int, y: Int, name: String, creature: String; public var available: Int }
    public struct Monster { public let x: Int, y: Int, name: String, creature: String; public var count: Int }
    public var towns: [Town] = []
    public var mines: [Mine] = []
    public var dwellings: [Dwelling] = []
    public var monsters: [Monster] = [] { didSet { dangerCache = nil } }

    /// How far a wandering stack guards: cells within this straight-line distance (in cells)
    /// of the stack. Measured on the original ("the path turns yellow [when] the route passes
    /// within the guard radius of an enemy army", manual): cells at distance 5.0 were yellow,
    /// at 5.1 green, whatever the terrain in between.
    public static let guardRadius: Float = 5
    var dangerCache: Set<Int>?
    /// Cells inside some wandering stack's guard radius.
    public var dangerCells: Set<Int> {
        if let d = dangerCache { return d }
        var out = Set<Int>()
        let n = map.size
        let r = Int(GameState.guardRadius)
        for m in monsters {
            for dx in -r...r { for dy in -r...r where Float(dx * dx + dy * dy).squareRoot() <= GameState.guardRadius + 0.001 {
                let x = m.x + dx, y = m.y + dy
                if x >= 0, x < n, y >= 0, y < n { out.insert(x * n + y) }
            } }
        }
        dangerCache = out
        return out
    }
    public func isDangerous(_ x: Int, _ y: Int) -> Bool { dangerCells.contains(x * map.size + y) }

    /// The movement an army gets per day: the slowest of the hero and its creatures.
    public func armyMovement(_ h: Hero) -> Float {
        var m = Hero.baseMovement
        for s in h.army { if let c = tables?.creature(s.creature), c.move > 0 { m = min(m, Float(c.move)) } }
        return m
    }
    /// Recompute a hero's daily movement after its army changed (spent points stay spent).
    public func refreshMovement(_ h: Hero) {
        let spent = h.maxMovement - h.movement
        h.maxMovement = armyMovement(h)
        h.movement = max(0, h.maxMovement - spent)
    }
    /// Income per day from everything the player owns.
    public var income: [String: Int] {
        var out: [String: Int] = [:]
        for t in towns where t.owned { out["Gold", default: 0] += hallIncome(t) }
        for m in mines where m.owned { out[m.resource, default: 0] += m.amount }
        return out
    }
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

    /// The mine record for a placed object, if it is a working mine.
    public func mine(for p: MapScene.Placed) -> Int? {
        mines.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name }
    }

    public func dwelling(for p: MapScene.Placed) -> Int? {
        dwellings.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name }
    }

    public func monster(for p: MapScene.Placed) -> Int? {
        monsters.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name }
    }
    public func town(for p: MapScene.Placed) -> Int? {
        p.category == "castle" ? towns.firstIndex { $0.x == p.cellX && $0.y == p.cellY } : nil
    }

    /// Objects a hero walks up to and uses: pickups, mines, dwellings, monsters and towns.
    public func isVisitable(_ p: MapScene.Placed) -> Bool {
        isPickup(p) || mine(for: p) != nil || dwelling(for: p) != nil || monster(for: p) != nil || town(for: p) != nil
    }

    /// The town screen to open, set when a hero enters a town; the UI clears it.
    public var enteredTown: Int?

    /// The last name component of a sprite entry: "adv_object.castle.Haven.Village R.h4d" -> "Village".
    static func shortName(_ entry: String) -> String {
        var parts = entry.split(separator: ".").map(String.init)
        if parts.last?.lowercased() == "h4d" { parts.removeLast() }
        var s = parts.last ?? entry
        if s.lowercased().hasSuffix(" r") { s.removeLast(2) }
        return s
    }

    /// What a right click on an object shows: a title and paragraphs, from the Adventure Object
    /// table (by the map record's type, or by name for resolved random objects), the artifact
    /// table, or the creature table; decorations get their name only.
    public func describe(_ p: MapScene.Placed) -> (title: String, body: [String]) {
        let short = GameState.shortName(p.name)
        guard let t = tables else { return (short, []) }
        func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        if let i = monster(for: p), let c = t.creature(monsters[i].creature) {
            let n = monsters[i].count
            return ("\(n) \(n == 1 ? c.name : c.plural)", ["Level \(c.level) \(capitalised(c.alignment)) creature", "Attack \(c.attack), Defense \(c.defense), Damage \(c.damageLow)-\(c.damageHigh), Hit Points \(c.hitPoints)"])
        }
        if let i = town(for: p) {
            let town = towns[i]
            let kind = t.objectText("town", town.alignment, "name") ?? capitalised(town.alignment)
            let names = t.buildings(for: town.alignment).filter { town.buildings.contains($0.keyword) }.map { $0.name }
            return (town.name, ["\(kind) (\(town.owned ? "yours" : "unowned"))", "Buildings: " + (names.isEmpty ? "none" : names.joined(separator: ", "))])
        }
        if p.category.lowercased() == "artifacts" || p.type == "artifact" || p.type == "random_artifact" {
            let a = t.artifacts[p.subtype.lowercased()] ?? t.artifacts.values.first { $0.name.lowercased() == short.lowercased() }
            guard let a = a else { return (short, ["An artifact."]) }
            return (a.name, [a.help, "\(a.level) artifact" + (a.slot.isEmpty ? "" : ", worn as \(a.slot.lowercased())")])
        }
        var major = p.type, minor = p.subtype
        if major.isEmpty || major.hasPrefix("random") || major == "nothing", let byName = t.objectNames[short.lowercased()] { (major, minor) = byName }
        if major == "random_shrine" { major = "shrine" }
        if major == "random_monster" || major == "random_town" { return (short, []) }
        var title = t.objectText(major, minor, "name") ?? short
        var body: [String] = []
        if let help = t.objectText(major, minor, "help") { body.append(help) }
        // fill the table's placeholders with what we know
        var creature: CreatureDef? = nil
        var count = 0
        if let i = dwelling(for: p) { creature = t.creature(dwellings[i].creature); count = dwellings[i].available }
        let level = minor.hasPrefix("level_") ? String(minor.dropFirst(6)) : p.subtype.hasPrefix("level_") ? String(p.subtype.dropFirst(6)) : "1"
        func fill(_ s: String) -> String {
            var s = s
            let subs: [(String, String)] = [("%object_name", title), ("%material_name", title), ("%Creature_name", creature?.plural ?? "creatures"),
                                            ("%creature_name", creature?.plural.lowercased() ?? "creatures"), ("%the_creatures", "the " + (creature?.plural.lowercased() ?? "creatures")),
                                            ("%Creatures", "\(count) " + (creature?.plural.lowercased() ?? "creatures")), ("%creatures", "\(count) " + (creature?.plural.lowercased() ?? "creatures")),
                                            ("%spell_level", level), ("%magic_type ", ""), ("%magic_type", "Magic"), ("%skill_type", "primary"), ("%skill_name", "a skill"), ("%spell_name", "a spell")]
            for (k, v) in subs { s = s.replacingOccurrences(of: k, with: v) }
            return s
        }
        title = fill(title)
        body = body.map(fill)
        if let i = mine(for: p) { body.append(mines[i].owned ? "Owned by you." : "Not owned by anyone.") }
        if let c = creature { body.append("\(count) \(count == 1 ? c.name : c.plural) available, \(c.gold) gold each.") }
        if p.type == "decorative", body.isEmpty { body = [] }
        return (title, body)
    }

    /// What a right click on bare ground shows: the road there, else the terrain, with the
    /// strings table's description (movement cost per tile).
    public func describe(cellX x: Int, cellY y: Int) -> (title: String, body: [String])? {
        guard x >= 0, x < map.size, y >= 0, y < map.size, let c = map.cells[level][x * map.size + y], let t = tables else { return nil }
        let road = passability.roadType[x * map.size + y]
        if road > 0, let r = t.roadText(road) { return (r.name, r.description.isEmpty ? [] : [r.description]) }
        guard let tt = t.terrainText(type: c.type, variant: c.variant) else { return nil }
        return (tt.name, tt.description.isEmpty ? [] : [tt.description])
    }

    /// A hero's combat numbers as the hero screen shows them (the quick-combat formulas).
    public func heroStats(_ h: Hero) -> (attack: Int, defense: Int, damage: String, hitPoints: Int, speed: Int, move: Int) {
        let c = Combatant(hero: h.name, level: h.level)
        return (c.attack, c.defense, "\(c.damageLow)-\(c.damageHigh)", c.hitPoints, c.speed, Int(h.maxMovement))
    }

    /// What a right click on a hero shows.
    public func describe(hero h: Hero) -> (title: String, body: [String]) {
        var body = ["Level \(h.level) " + (RuleTables.classes[h.alignment]?.might.capitalized ?? "Hero"), "Movement \(Int(h.movement.rounded()))/\(Int(h.maxMovement)), Experience \(h.experience)"]
        for s in h.army {
            let c = tables?.creature(s.creature)
            body.append("\(s.count) \(s.count == 1 ? (c?.name ?? s.creature) : (c?.plural ?? s.creature))")
        }
        return (h.name, body)
    }

    /// Daily income of a town from its hall.
    public func hallIncome(_ t: Town) -> Int {
        t.buildings.contains("city hall") ? 1000 : t.buildings.contains("town hall") ? 750 : 500
    }

    /// Can the town build this now? One building per day; halls and walls in order; mage guilds in order.
    public func canBuild(_ b: RuleTables.BuildingDef, in t: Town) -> Bool {
        guard !t.buildings.contains(b.keyword), !t.builtToday, !b.cost.isEmpty || b.keyword == "prison" else { return false }
        for (r, v) in b.cost where resources[r, default: 0] < v { return false }
        let chain: [String: String] = ["town hall": "village hall", "city hall": "town hall", "citadel": "fort", "castle": "citadel",
                                       "mage guild 2": "mage guild 1", "mage guild 3": "mage guild 2", "mage guild 4": "mage guild 3", "mage guild 5": "mage guild 4"]
        if let req = chain[b.keyword], !t.buildings.contains(req) { return false }
        return true
    }

    public func build(_ b: RuleTables.BuildingDef, in i: Int) {
        guard canBuild(b, in: towns[i]) else { return }
        for (r, v) in b.cost { resources[r, default: 0] -= v }
        towns[i].buildings.insert(b.keyword)
        towns[i].builtToday = true
        if let c = b.creature, let def = tables?.creature(c) { towns[i].available[c, default: 0] += def.growth }
        log.append("built \(b.name) in \(towns[i].name)")
    }

    /// Recruit from a town's dwelling into the hero's army: as many as available and affordable.
    public func recruit(_ creature: String, in i: Int, to hero: Hero) {
        guard let c = tables?.creature(creature) else { return }
        let n = min(towns[i].available[creature, default: 0], c.gold > 0 ? resources["Gold", default: 0] / c.gold : 0)
        if n <= 0 { log.append("no \(c.plural) to recruit / not enough gold"); return }
        guard add(c.keyword, n, to: hero) else { log.append("no room in the army for \(c.plural)"); return }
        towns[i].available[creature, default: 0] -= n
        resources["Gold", default: 0] -= n * c.gold
        log.append("recruited \(n) \(n == 1 ? c.name : c.plural) for \(n * c.gold) gold")
    }

    /// The hero's army as combatants, the hero first.
    func combatants(of hero: Hero) -> [Combatant] {
        var out = [Combatant(hero: hero.name, level: hero.level)]
        for s in hero.army { if let c = tables?.creature(s.creature) { out.append(Combatant(creature: c, count: s.count)) } }
        return out
    }

    /// A battle waiting for the combat screen: the hero, the monster and its map object.
    public var pendingBattle: (hero: Hero, monster: Int, placed: MapScene.Placed)?
    /// Use the quick-combat rules instead of the combat screen (tests, --walk snapshots).
    public var quickCombatOnly = false

    /// Fight a wandering monster stack next to the hero: hand it to the combat screen, or
    /// resolve it at once with the quick-combat rules.
    func fight(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed) {
        guard let t = tables, let c = t.creature(monsters[i].creature) else { return }
        hero.target = nil
        if !quickCombatOnly { pendingBattle = (hero, i, p); return }
        let result = QuickCombat.fight(attackers: combatants(of: hero), defenders: [Combatant(creature: c, count: monsters[i].count)],
                                       seed: day * 131 + hero.x * 17 + hero.y)
        if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { for l in result.log.prefix(12) { print("  " + l) } }
        let survivors = result.attackers.dropFirst().filter { $0.alive }.map { s in Hero.Stack(creature: t.creatures.first { $0.name == s.name }?.keyword ?? s.name, count: s.count) }
        finishBattle(hero: hero, monsterAt: i, p, won: result.attackerWon, army: survivors, monstersLeft: result.defenders.first?.count ?? 0, experience: result.experience, rounds: result.rounds)
    }

    /// Apply a battle's outcome to the map: the army's survivors, the monster removed or
    /// thinned, experience, a beaten hero sent home.
    public func finishBattle(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed, won: Bool, army: [Hero.Stack], monstersLeft: Int, experience: Int, rounds: Int) {
        guard let t = tables, i < monsters.count, let c = t.creature(monsters[i].creature) else { return }
        hero.army = army
        refreshMovement(hero)
        if won {
            hero.experience += experience
            scene.remove(p)
            passability.free(p.cellX, p.cellY)
            monsters.remove(at: i)
            log.append("Victory over \(c.plural) after \(rounds) rounds: +\(experience) experience (level \(hero.level))")
        } else {
            monsters[i].count = max(1, monstersLeft)
            hero.x = hero.home.x; hero.y = hero.home.y; hero.movement = 0; hero.path = []; hero.plan = []
            log.append("Defeated by \(c.plural) after \(rounds) rounds; \(hero.name) limps home")
        }
        hero.target = nil
        pendingBattle = nil
    }

    /// Give a hero the usual starting army: the two cheapest level-1 creatures of his alignment,
    /// half a week's growth each.
    public func giveStartingArmy(_ hero: Hero) {
        guard let t = tables else { return }
        let l1 = t.creatures.filter { $0.level == 1 && $0.alignment == hero.alignment }.sorted { $0.gold < $1.gold }
        hero.army = l1.prefix(2).map { Hero.Stack(creature: $0.keyword, count: max(1, $0.growth / 2)) }
        hero.maxMovement = armyMovement(hero); hero.movement = hero.maxMovement
    }

    /// Add creatures to a hero's army, merging with a stack of the same kind.
    public func add(_ creature: String, _ count: Int, to hero: Hero) -> Bool {
        if let i = hero.army.firstIndex(where: { $0.creature == creature }) { hero.army[i].count += count; return true }
        guard hero.army.count < Hero.armySlots - 1 else { return false }
        hero.army.append(Hero.Stack(creature: creature, count: count))
        refreshMovement(hero)
        return true
    }

    /// Register the towns and mines on the map (names from the rule tables).
    public func registerObjects(townFactions: [String: String]) {
        var townIndex = 0
        for p in scene.placed {
            if p.category == "castle" {
                let faction = townFactions[p.name] ?? "life"
                let list = tables?.names["\(faction.prefix(1).uppercased() + faction.dropFirst())_Town"] ?? []
                let custom = map.objects.first { ($0.type == "town" || $0.type == "random_town") && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }?.customName
                let name = custom ?? (list.isEmpty ? "Town" : list[(p.cellX * 7 + p.cellY * 13 + townIndex) % list.count])
                var town = Town(x: p.cellX, y: p.cellY, name: name, alignment: faction, owned: false)
                // a new town: village hall, walls matching the sprite, and the first dwelling
                town.buildings = ["village hall"]
                // the walls from the sprite's last name component ("castle.Haven.Citadel R" -> citadel)
                let last = GameState.shortName(p.name).lowercased()
                for wall in ["fort", "citadel", "castle"] where last == wall { town.buildings.insert(wall) }
                if let t = tables, let first = t.buildings(for: faction).first(where: { $0.creature != nil }) {
                    town.buildings.insert(first.keyword)
                    if let c = first.creature, let def = t.creature(c) { town.available[c] = def.growth }
                }
                // the town screen's landscape follows the terrain most of the footprint stands on
                var counts: [UInt8: Int] = [:]
                for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h {
                    if let c = map.cells[level][(p.cellX + i) * map.size + p.cellY + j] { counts[c.type, default: 0] += 1 }
                } }
                town.terrain = counts.max { $0.value < $1.value }?.key ?? 1
                towns.append(town)
                townIndex += 1
            } else if p.category == "mine" {
                let short = p.name.replacingOccurrences(of: "adv_object.mine.", with: "").replacingOccurrences(of: ".h4d", with: "").replacingOccurrences(of: " R", with: "")
                if let (res, amount) = RuleTables.mineIncome[short] {
                    mines.append(Mine(x: p.cellX, y: p.cellY, name: p.name, resource: res, amount: amount, owned: false))
                }
            } else if p.category == "Random creatures", let t = tables, p.name.hasPrefix("actor_sequence.") {
                // "actor_sequence.<creature>.wait.<facing>.h4d" -> the creature; the stack size follows its level
                let parts = p.name.dropFirst("actor_sequence.".count).split(separator: ".")
                if let kw = parts.first, let c = t.creature(String(kw)) {
                    let sizes = [0, 16, 7, 3, 1]   // typical guard stacks by creature level
                    let base = sizes[min(4, max(1, c.level))]
                    let count = base + (p.cellX * 3 + p.cellY * 5) % max(1, base / 2 + 1)
                    monsters.append(Monster(x: p.cellX, y: p.cellY, name: p.name, creature: c.keyword, count: count))
                    passability.block(p.cellX, p.cellY)
                    if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("monster: \(count) \(c.plural) at (\(p.cellX),\(p.cellY))") }
                }
            } else if p.category == "creature generators", let t = tables {
                var short = p.name.replacingOccurrences(of: "adv_object.creature generators.", with: "").replacingOccurrences(of: ".h4d", with: "").lowercased()
                if short.hasSuffix(" r") { short.removeLast(2) }
                if let kw = t.dwellingCreature[short], let c = t.creature(kw) {
                    dwellings.append(Dwelling(x: p.cellX, y: p.cellY, name: p.name, creature: c.keyword, available: c.growth))
                }
            }
        }
    }

    /// Use an object the hero stands next to.
    func interact(hero: Hero, _ p: MapScene.Placed) {
        if isPickup(p) { take(hero: hero, p); return }
        if let i = monster(for: p) { fight(hero: hero, monsterAt: i, p); return }
        if let i = town(for: p) {
            if !towns[i].owned { towns[i].owned = true; log.append("\(towns[i].name) is yours") }
            enteredTown = i
            hero.target = nil
            return
        }
        if let i = mine(for: p) {
            if mines[i].owned { log.append("\(mines[i].resource) mine already yours") }
            else { mines[i].owned = true; log.append("captured a mine: +\(mines[i].amount) \(mines[i].resource) per day") }
            hero.target = nil
        }
        if let i = dwelling(for: p), let c = tables?.creature(dwellings[i].creature) {
            // recruit everything you can afford (a proper dialog comes later)
            let affordable = c.gold > 0 ? resources["Gold", default: 0] / c.gold : dwellings[i].available
            let n = min(dwellings[i].available, affordable)
            if n <= 0 { log.append("\(c.plural): none to recruit / not enough gold") }
            else if add(c.keyword, n, to: hero) {
                dwellings[i].available -= n
                resources["Gold", default: 0] -= n * c.gold
                log.append("recruited \(n) \(n == 1 ? c.name : c.plural) for \(n * c.gold) gold")
            } else { log.append("no room in the army for \(c.plural)") }
            hero.target = nil
        }
    }

    static func adjacent(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { max(abs(a.0 - b.0), abs(a.1 - b.1)) == 1 }

    /// Is the cell next to any cell of the object's footprint?
    func nextTo(_ c: (Int, Int), _ p: MapScene.Placed) -> Bool {
        for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h where GameState.adjacent(c, (p.cellX + i, p.cellY + j)) { return true } }
        return false
    }

    /// The three cells in front of a town's gate, the middle one first. The gate is in the
    /// middle of the lower-right wall of a right-facing (" R") town, of the lower-left wall
    /// otherwise; a hero enters the town from these cells only.
    public func gateCells(_ p: MapScene.Placed) -> [(Int, Int)] {
        let w = p.sprite.footprint.w, h = p.sprite.footprint.h
        if p.name.lowercased().hasSuffix(" r.h4d") {
            let mid = w / 2
            return [(p.cellX + mid, p.cellY + h), (p.cellX + mid - 1, p.cellY + h), (p.cellX + mid + 1, p.cellY + h)]
        }
        let mid = h / 2
        return [(p.cellX + w, p.cellY + mid), (p.cellX + w, p.cellY + mid - 1), (p.cellX + w, p.cellY + mid + 1)]
    }

    /// Can a hero standing on the cell use the object? Towns only from their gate cells,
    /// everything else from any neighbouring cell.
    func canUse(from c: (Int, Int), _ p: MapScene.Placed) -> Bool {
        if town(for: p) != nil { return gateCells(p).contains { $0 == c } }
        return nextTo(c, p)
    }

    /// Is the cell free to stand on: passable and no other hero on it?
    func isVacant(_ c: (Int, Int), for hero: Hero) -> Bool {
        passability.isFree(c.0, c.1) && !heroes.contains { $0 !== hero && standingCell($0) == c }
    }

    /// Click on a visitable object: use it if the hero stands next to it, otherwise plan (then
    /// walk) to the cheapest neighbouring cell; it is used on arrival. A town is entered through
    /// the middle gate cell; when that is taken, through the nearer of the other two.
    public func click(hero: Hero, pickup p: MapScene.Placed) {
        let walking = hero.isWalking
        if walking { interrupt(hero) }
        let from = standingCell(hero)
        let isTown = town(for: p) != nil
        var candidates: [(Int, Int)] = []
        if isTown {
            let gate = gateCells(p)
            candidates = isVacant(gate[0], for: hero) ? [gate[0]] : Array(gate.dropFirst())
        } else {
            let fw = p.sprite.footprint.w, fh = p.sprite.footprint.h
            for dx in -1...fw { for dy in -1...fh where dx == -1 || dy == -1 || dx == fw || dy == fh { candidates.append((p.cellX + dx, p.cellY + dy)) } }
        }
        if !walking, candidates.contains(where: { $0 == from }), canUse(from: from, p) { interact(hero: hero, p); return }
        if !walking, let t = hero.target, t.x == p.cellX, t.y == p.cellY, !hero.plan.isEmpty {
            hero.path = hero.plan; hero.plan = []; hero.progress = 0
            return
        }
        var best: [(x: Int, y: Int)]? = nil
        var bestCost = Float.infinity
        for c in candidates {
            guard isVacant(c, for: hero) else { continue }
            if c == from { best = []; bestCost = 0; continue }
            guard let path = passability.path(from: from, to: c) else { continue }
            var cost: Float = 0
            var px = from.0, py = from.1
            for s in path { cost += passability.stepCost(from: px, py, to: s.x, s.y); px = s.x; py = s.y }
            if cost < bestCost { bestCost = cost; best = path }
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
        func gain(_ r: String, _ n: Int) { resources[r, default: 0] += n; floaters.append(("+\(n) \(r.lowercased())", hero.x, hero.y)) }
        switch kind {
        case "Gold": gain("Gold", 750)
        case "Wood", "Ore": gain(kind, 8)
        case "Mercury", "Sulfur", "Crystal", "Gems": gain(kind, 4)
        case "Treasure Chest":   // the choice comes in a dialog: 1000/1500/2000 gold or 500/1000/1500 experience
            let tier = (p.cellX * 7 + p.cellY * 3) % 3
            chestOffer = (hero, 1000 + tier * 500, 500 + tier * 500)
        case "Campfire": gain("Gold", 500); gain("Wood", 5)
        default: break
        }
        log.append("picked up \(p.name) at (\(p.cellX),\(p.cellY))")
    }

    /// Short texts floating up over a cell (resources picked up), for the renderer to show.
    public var floaters: [(text: String, x: Int, y: Int)] = []
    /// A treasure chest waiting for the gold-or-experience choice (the UI resolves it).
    public var chestOffer: (hero: Hero, gold: Int, experience: Int)?
    public func resolveChest(gold: Bool) {
        guard let c = chestOffer else { return }
        if gold { resources["Gold", default: 0] += c.gold; floaters.append(("+\(c.gold) gold", c.hero.x, c.hero.y)) }
        else { c.hero.experience += c.experience; floaters.append(("+\(c.experience) experience", c.hero.x, c.hero.y)) }
        chestOffer = nil
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
                if h.path.isEmpty, let t = h.target,
                   let p = scene.placed.first(where: { $0.cellX == t.x && $0.cellY == t.y && $0.name == t.name }), canUse(from: (h.x, h.y), p) {
                    interact(hero: h, p)
                }
            }
        }
    }

    public func endTurn() {
        day += 1
        for h in heroes { h.maxMovement = armyMovement(h); h.movement = h.maxMovement; h.path = []; h.plan = [] }
        for (res, amount) in income { resources[res, default: 0] += amount }
        for i in towns.indices { towns[i].builtToday = false }
        if dayOfWeek == 1, let t = tables {   // a new week: dwellings restock, in towns too
            for i in dwellings.indices { dwellings[i].available += t.creature(dwellings[i].creature)?.growth ?? 0 }
            for i in towns.indices {
                for b in t.buildings(for: towns[i].alignment) where towns[i].buildings.contains(b.keyword) {
                    if let c = b.creature, let def = t.creature(c) { towns[i].available[c, default: 0] += def.growth }
                }
            }
        }
    }

    public var dateText: String { "Month \(month), Week \(week), Day \(dayOfWeek)" }

    /// Screen directions clockwise, as the arrow sprites name them.
    static let compass = ["n", "ne", "e", "se", "s", "sw", "w", "nw"]

    /// The path arrows to draw for a hero's planned route: (cell, sprite name such as
    /// "green_arrow.left.ne"). Green while the hero can still afford the step this turn, red after;
    /// the last cell gets the destination marker.
    public func arrows(for h: Hero) -> [(x: Int, y: Int, name: String)] {
        var plan = h.plan
        guard !plan.isEmpty else { return [] }
        // a route to an object ends on the object itself (as in the game), though the hero stops
        // on the cell before it: the last arrow points into it and the X sits on it
        var visiting = false
        if let t = h.target, let last = plan.last, let p = scene.placed.first(where: { $0.cellX == t.x && $0.cellY == t.y && $0.name == t.name }) {
            var cell = (x: t.x, y: t.y)
            var best = Int.max
            for i in 0..<p.sprite.footprint.w { for j in 0..<p.sprite.footprint.h {
                let d = max(abs(p.cellX + i - last.x), abs(p.cellY + j - last.y))
                if d < best { best = d; cell = (p.cellX + i, p.cellY + j) }
            } }
            plan.append(cell); visiting = true
        }
        var out: [(Int, Int, String)] = []
        var left = h.movement
        var px = h.x, py = h.y
        for (k, c) in plan.enumerated() {
            let stepCost = visiting && k == plan.count - 1 ? 0 : passability.stepCost(from: px, py, to: c.x, c.y)
            // green while affordable, yellow inside a wandering stack's guard radius, red beyond this turn
            let colour = left + 0.001 < stepCost ? "red_arrow" : isDangerous(c.x, c.y) ? "yellow_arrow" : "green_arrow"
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
