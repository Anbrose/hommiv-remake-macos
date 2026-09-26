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
    /// Open sea (terrain 0): where ships sail.
    public private(set) var water: [Bool]
    /// Cells blocked by the ground itself (water, rivers, the map's edge); `blocked` adds what stands there.
    var terrainBlocked: [Bool]

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
        water = [Bool](repeating: false, count: size * size)
        occupied = [Bool](repeating: false, count: size * size)
        terrainBlocked = [Bool](repeating: true, count: size * size)
        let cells = map.cells[level]
        for x in 0..<size {
            for y in 0..<size {
                guard let c = cells[x * size + y] else { continue }
                let i = x * size + y
                switch c.type {
                case 0, 9, 10, 11: blocked[i] = true; water[i] = c.type == 0; continue   // water (by ship) and rivers (need a bridge)
                default: cost[i] = Passability.terrainCost(c.type)
                }
                blocked[i] = false; terrainBlocked[i] = false
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
                if x >= 0, x < size, y >= 0, y < size { blocked[x * size + y] = true; occupied[x * size + y] = true }
            }
        }
        // bridges (and their ramps) are walkable over the river they span: their whole footprint is a deck
        for p in objects where p.category == "movement modifiers" && p.name.lowercased().contains("bridge") {
            let raise: Float = p.name.lowercased().contains("ramp") ? 28 : 56
            for i in 0..<p.sprite.footprint.w {
                for j in 0..<p.sprite.footprint.h {
                    let x = p.cellX + i, y = p.cellY + j
                    if x >= 0, x < size, y >= 0, y < size {
                        blocked[x * size + y] = false; terrainBlocked[x * size + y] = false; cost[x * size + y] = 1; elevation[x * size + y] = raise
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

    /// Something stands on the cell (an object, a monster, an army, a ship).
    public private(set) var occupied: [Bool] = []
    public mutating func free(_ x: Int, _ y: Int) {
        if x >= 0, x < size, y >= 0, y < size { occupied[x * size + y] = false; blocked[x * size + y] = terrainBlocked[x * size + y] }
    }
    public mutating func block(_ x: Int, _ y: Int) {
        if x >= 0, x < size, y >= 0, y < size { occupied[x * size + y] = true; blocked[x * size + y] = true }
    }
    public func isWater(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < size && y < size && water[x * size + y] }
    /// Open water nothing stands on.
    public func isFreeWater(_ x: Int, _ y: Int) -> Bool { isWater(x, y) && !occupied[x * size + y] }

    /// Free edges through gateways, portals and ferries: approach cell -> the destinations'
    /// approach cells (GameState.refreshJumps); a jump costs the one step onto the object.
    public var jumps: [Int: [Int]] = [:]
    /// Pathfinding's relief on rough terrain for the army being routed (GameState sets it).
    public var relief: Float = 0

    public func isFree(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < size && y >= 0 && y < size && !blocked[x * size + y]
    }

    /// Cost of stepping from (x0, y0) onto (x1, y1): the target cell's terrain cost, or the
    /// road's rate when both cells have a road ("road-to-road moves, regardless of the
    /// terrain"); x1.4 diagonally.
    public func stepCost(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Float {
        let i = x1 * size + y1
        let base = roadType[i] > 0 && roadType[x0 * size + y0] > 0 ? Passability.roadRate(roadType[i]) : cost[i] > 1 ? max(1, cost[i] - relief) : cost[i]
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
            for j in jumps[i] ?? [] where !closed[j] && !blocked[j] {
                let ng = g[i] + 1
                if ng < g[j] { g[j] = ng; prev[j] = Int32(i); open.append((ng + h(j), j)) }
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
    /// Secondary skills by family keyword ("stealth", "scouting", "tactics", ...) at level
    /// 1 basic ... 5 grandmaster (table.skills: <family>_<basic|advanced|expert|master|grandmaster>).
    public var skills: [String: Int] = [:]
    public func skill(_ family: String) -> Int { skills[family] ?? 0 }
    public var experience = 0
    /// The hero's level: raised a step at a time as experience allows (Hero.levelUp).
    public var level = 1
    /// The level at which Combat was last offered (heroes4.exe hero+0x69c).
    public var lastCombatOffer = 0
    /// Experience needed for a level: 0, 1000, 2000, then each step grows by 100 x trunc(the
    /// previous step x 0.012) (heroes4.exe 0x72b4e0; levels up to 70).
    public static let experienceTable: [Int] = {
        var e = [0, 0, 1000, 2000]   // index = level
        while e.count <= 70 { let n = e.count; e.append(e[n - 1] + 100 * Int(Double(e[n - 1] - e[n - 2]) * 0.012)) }
        return e
    }()
    /// Worn artifacts by slot (RuleTables.equipSlots order; artifact ids of RuleTables.artifactIds), and the backpack.
    public var equipped: [Int?] = Array(repeating: nil, count: 14)
    public var backpack: [Int] = []
    /// Other heroes travelling in this army (a map can put several heroes in one army).
    public var companions: [Hero] = []
    /// The hero's class (0...47, table.skill_weights order), -1 unknown.
    public var heroClass = -1
    public var home: (x: Int, y: Int) = (0, 0)   // where a beaten hero regroups
    public var z = 0                              // map level (0 surface, 1 underground)
    /// Aboard a ship: the ship's alignment (it draws the hero as adv_actor.ships.<alignment>).
    public var boat: String? = nil
    /// The player (colour) the hero serves.
    public var owner = 0
    /// A ship this hero is walking to, to board.
    public var boardTarget: (Int, Int)? = nil
    /// An enemy hero this hero is on its way to attack.
    public var attackTarget: Hero? = nil
    // What adventure objects gave the hero (heroes4.exe's bonus array at hero+0x10: attack,
    // defense, speed and spell points; the Dream Teachers visited at +0x7a0)
    public var attackBonus = 0, defenseBonus = 0, speedBonus = 0, spellPointBonus = 0
    public var dreamTeachers = 0
    /// The spells the hero knows (spell ids, RuleTables.spells; heroes4.exe's bitset at hero+0x780).
    public var spells: Set<Int> = []
    /// Spell points now (nil: full), and the percent mana sources restored today (hero+0x7e8).
    public var spellPoints: Int? = nil
    public var manaRestoredToday = 0
    /// Once-per-hero objects this hero has used ("z|x|y" keys).
    public var visitedObjects: Set<String> = []
    /// Until the next battle: fountain effects on the hero ("strength", "speed", "vigor").
    public var fountainEffects: Set<String> = []
    /// Until the next battle, for the army: luck and morale by object type, and a temple's alignment.
    public var armyLuck: [String: Int] = [:], armyMorale: [String: Int] = [:]
    public var templeAlignment: String? = nil
    /// Timed army effects by object type (movement boosters, lodges): days left.
    public var timedEffects: [String: Int] = [:]
    public var x: Int, y: Int         // current cell
    public var facing = "s"
    public var movement: Float
    /// Movement per day: the slowest of the hero and the creatures travelling with it.
    public var maxMovement: Float
    /// A hero's own movement (the recording: a level 15 hero shows 22, a low one 20).
    /// A hero's own movement per day: 2256 points, 100 to a cell (heroes4.exe 0x72a260:
    /// 1200 + 11 x 2400 / 25; the recording shows a hero with 22).
    public static let baseMovement: Float = 22.56
    /// Remaining path (next cell first) while walking, and progress 0..1 to its first cell.
    public var path: [(x: Int, y: Int)] = []
    /// The wandering stacks the player could see when this walk began (a walk stops when it
    /// finds its way runs into the guard zone of one not seen before).
    var knownThreats: Set<Int>? = nil
    /// Where each hero and stack of the army stands in its row's seven places (TownArmies).
    public var rowKeys: [String?] = []
    /// The cell the player clicked for the planned route (it may end short, at a gateway).
    public var planGoal: (Int, Int)? = nil
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
    /// The map level in play (0 surface, 1 underground): the active hero's, or the one viewed.
    public var level: Int { didSet { dangerCache = nil; zoneCache = [:] } }
    /// Each level's scene and passability; `scene` and `passability` are the current level's.
    public let scenes: [MapScene]
    public internal(set) var passabilities: [Passability]
    public var scene: MapScene { scenes[min(level, scenes.count - 1)] }
    public internal(set) var passability: Passability {
        get { passabilities[min(level, passabilities.count - 1)] }
        set { passabilities[min(level, passabilities.count - 1)] = newValue }
    }
    public var heroes: [Hero] = []
    /// The computer players' treasuries by colour.
    public var aiResources: [Int: [String: Int]] = [:]
    /// The pending battle with an enemy army was started by the computer (the player defends).
    public var aiAttacking = false
    /// The player acting now (the human, or a computer player during its turn).
    public var acting: Int? = nil
    public var actingColour: Int { acting ?? map.humanColour }
    public var isHumanActing: Bool { acting == nil || acting == map.humanColour }
    /// The other players' heroes on the map (armies led by heroes; companions travel with them).
    public var enemyHeroes: [Hero] = []
    /// Obelisks: visits per colour, the treasures' places once found ([x, y, level]), the colours dug.
    public var obeliskVisits: [String: Int] = [:]
    public var digSites: [String: [Int]] = [:]
    public var dug: Set<String> = []
    /// The puzzle to show (an obelisk just visited).
    public var puzzleOpen: String?
    /// Empty ships on the water.
    public var boats: [Boat] = []
    /// A script's fight: what runs when it is won and when it is lost.
    public var scriptBattle: (win: ScriptNode?, lose: ScriptNode?, context: ScriptContext)?
    /// A siege waiting for the combat screen: the hero and the town.
    public var pendingSiege: (hero: Hero, town: Int)?
    /// A battle with an enemy hero army waiting for the combat screen.
    public var pendingHeroBattle: (hero: Hero, enemy: Hero)?
    /// Each adventure object's rolled contents and state, by "level|x|y".
    public var objectStates: [String: ObjectState] = [:]
    /// Artifacts already handed out by the random picker (it avoids repeats).
    public var usedArtifacts: Set<Int> = []
    /// A yes/no question an object asks (the UI shows it; yes runs the action).
    public var question: (text: String, yes: () -> Void)?
    /// A choice an object offers: the question, the options, what picking one does.
    public var choice: (text: String, options: [String], pick: (Int) -> Void)?
    /// A hire dialog to open (a tavern visited, a town's tavern).
    public var hireOpen: HireOffer?
    /// The keymaster tents' keys the player has (by colour subtype).
    public var keys: Set<String> = []
    /// A hero went through a portal (the view should follow).
    public var jumped = false
    /// The player's shroud and fog per map level (Fog.swift): 0 unexplored, 1 explored, 2 seen, and
    /// the vision level of seen cells; off, everything shows.
    public var fog: [[UInt8]] = []
    public var fogLevel: [[Int8]] = []
    public var fogEnabled = true
    /// The shroud changed (the view redraws it).
    public var visionChanged = false
    /// The planner's gateway edges and which object each approach cell leads through.
    var jumpSources: [Int: MapScene.Placed] = [:]
    var jumpsLevel = -1
    var waterBodies: [[Int]] = []
    /// A blacksmith's or conservatory's shop to open, a sanctuary's dialog.
    public var shopOpen: ShopOffer?
    public var sanctuaryOpen: SanctuaryOffer?
    /// Armies hidden in sanctuaries (by object key), and the sanctuaries paid for today.
    public var sanctuaryGuests: [String: Hero] = [:]
    public var sanctuaryPaid: Set<String> = []
    /// The marketplace to open (its rate class: 3 the panel's Marketplace, 2 a Trading Post).
    public var marketOpen: Int?
    /// Things that happened this frame, for the UI (e.g. "picked up Resources.Gold").
    public var log: [String] = []
    /// Sounds the last actions call for (names under "sound.", e.g. miscellaneous.flag_mine), for the UI to play.
    public var sounds: [String] = []
    /// The map's scripted events and their state.
    public let scripts = ScriptState()
    /// The player's treasury (starting amounts of a normal game).
    public var resources: [String: Int] = ["Wood": 15, "Ore": 15, "Mercury": 7, "Sulfur": 7, "Crystal": 7, "Gems": 7, "Gold": 15000]
    public var tables: RuleTables?
    public struct Town {
        public let x: Int, y: Int
        public var name: String
        public let alignment: String
        public var owned: Bool
        /// The owning player (0 = the human), nil when neutral.
        public var owner: Int? = nil
        public var buildings: Set<String> = []          // building keywords, as in the buildings table
        /// Buildings the map allows (the editor's town settings); nil = all.
        public var allowed: Set<String>? = nil
        public var available: [String: Int] = [:]      // creature keyword -> recruits waiting
        public var builtToday = false
        public var terrain: UInt8 = 1
        public var z = 0                                // map level
        /// The mage guild's spells by guild level (1...5), drawn at the start of the game.
        public var guildSpells: [[Int]] = []
        /// Days before the tavern has a hero to hire again (heroes4.exe town+0x18c).
        public var tavernDays = 0
        /// The town's garrison: the creatures that defend it.
        public var garrison: [Hero.Stack] = []
        /// Heroes stationed in the town (they take garrison slots and defend it).
        public var garrisonHeroes: [Hero] = []
        /// Where each garrison stack and hero stands in the row's seven places (TownArmies).
        public var rowKeys: [String?] = []
        /// 0 no walls, 1 fort, 2 citadel, 3 castle (the siege layout).
        public var castleLevel: Int { buildings.contains("castle") ? 3 : buildings.contains("citadel") ? 2 : buildings.contains("fort") ? 1 : 0 }
    }
    public struct Mine {
        public let x: Int, y: Int, name: String, resource: String, amount: Int; public var owned: Bool; public var z = 0
        /// The player (colour) the mine works for, nil unflagged.
        public var owner: Int? = nil
    }
    /// A creature dwelling on the map: a week's growth waits at the start; once owned it grows by
    /// the weekly growth in fourteenths each day (heroes4.exe 0x43cdb0: half a week's growth a week).
    public struct Dwelling {
        public let x: Int, y: Int, name: String, creature: String; public var available: Int; public var z = 0
        public var owned = false, fourteenths = 0
    }
    public struct Monster {
        public var x: Int, y: Int
        public var z = 0   // map level
        /// The guards of a creature bank being fought (its object key), not a wandering stack.
        public var bank: String? = nil
        public let name: String, creature: String; public var count: Int
        /// The lower-level stack spending what is left of the monster's value (heroes4.exe 0x7f32b0).
        /// The army's other stacks: a random monster's escort, or a placed army's further stacks.
        public var extra: [(creature: String, count: Int)] = []
        public init(x: Int, y: Int, name: String, creature: String, count: Int, extra: [(creature: String, count: Int)] = []) {
            self.x = x; self.y = y; self.name = name; self.creature = creature; self.count = count; self.extra = extra
        }
    }

    /// Wandering monster value per level (heroes4.exe 0x7f4530: 155 x 2, 310 x 2.5, 620 x 3, 1240 x 4)
    /// and the map difficulty factor (0x7f4520: easy 2/3 ... impossible x3).
    public static let monsterBudget = [0, 310, 775, 1860, 4960]
    public static let difficultyFactor = [0.6667, 1.0, 1.5, 2.0, 3.0]
    static let seaCreatures: Set<String> = ["mermaid", "sea monster", "pirate"]

    /// The creature picker (heroes4.exe 0x7f3380): walks the creatures in the exe's id order and
    /// draws one uniformly among those of the alignment (nil: any), between the levels, allowed
    /// by the map's expansion, costing at most `cap` experience, living on water exactly when the
    /// stack stands on water (mermaid, sea monster, pirate); when `exclude` is given, the other
    /// creatures costing exactly `cap` are left out (the excluded one itself stays in).
    func pickCreature(alignment: String?, water: Bool, cap: Int, exclude: String?, levels: ClosedRange<Int>, rng: inout GameRandom) -> CreatureDef? {
        guard let t = tables else { return nil }
        let expansion = max(0, min(2, map.version - 27))
        var pick: CreatureDef? = nil, seen = 0
        for id in RuleTables.creatureIds {
            guard let d = t.creature(id), d.expansion <= expansion, d.experience <= cap else { continue }
            if let ex = exclude, d.keyword.lowercased() != ex.lowercased(), d.experience == cap { continue }
            guard GameState.seaCreatures.contains(d.keyword.lowercased()) == water, levels ~= d.level else { continue }
            if let a = alignment, d.alignment != a { continue }
            seen += 1
            if rng.next() % seen == 0 { pick = d }
        }
        return pick
    }

    /// A wandering monster's army (heroes4.exe 0x7f3910): a value between 0.8 and 1.2 times the
    /// level's budget (or the editor's range in peasants), times the difficulty factor; about two
    /// thirds of it buys the creature ((2V + 3E - 1) / 3E, E its experience; sea monsters and
    /// mermaids spend it all). What is left goes to 0x7f32b0: the picker draws among the same
    /// alignment's creatures a level down to the same level costing at most min(E, left) --
    /// the creature itself included -- and buys left / cost of it; drawing the creature itself
    /// only adds to its own stack, so not every stack has an escort.
    public func monsterArmy(_ c: CreatureDef, level: Int, range: (min: Int, max: Int)?, water: Bool = false, rng: inout GameRandom) -> (count: Int, escort: (creature: String, count: Int)?) {
        guard let t = tables else { return (1, nil) }
        let lo: Int, hi: Int
        if let r = range, let peasant = t.creature("peasant") {
            lo = r.min * peasant.experience; hi = r.max * peasant.experience
        } else {
            let base = Double(GameState.monsterBudget[min(4, max(1, level))])
            lo = Int(base * 0.8); hi = Int(base * 1.2)
        }
        let raw = hi > lo ? rng.next() % (hi - lo + 1) + lo : lo
        let value = Int(Double(raw) * GameState.difficultyFactor[min(4, max(0, map.difficulty))])
        let e = max(1, c.experience)
        let sea = c.keyword.lowercased() == "sea monster" || c.keyword.lowercased() == "mermaid"
        var count = max(1, sea ? value / e : (2 * value + 3 * e - 1) / (3 * e))
        let left = value - count * e
        guard left > 0, !sea else { return (count, nil) }
        guard let p = pickCreature(alignment: c.alignment, water: water, cap: min(e, left), exclude: c.keyword,
                                   levels: (c.level - 1)...c.level, rng: &rng), p.experience > 0, left / p.experience > 0 else { return (count, nil) }
        if p.keyword.lowercased() == c.keyword.lowercased() { count += left / p.experience; return (count, nil) }   // merged into its own stack
        return (count, (p.keyword, left / p.experience))
    }
    public var towns: [Town] = []
    public var mines: [Mine] = []
    public var dwellings: [Dwelling] = []
    public var monsters: [Monster] = [] { didSet { dangerCache = nil; zoneCache = [:] } }

    /// A wandering stack's guard zone (heroes4.exe 0x4979f0): the cells a flood from the stack
    /// reaches within the 5 x 5 square around it (two cells each way), walking over passable
    /// ground -- obstacles and water cut it short.
    var zoneCache: [Int: Set<Int>] = [:]
    public func zone(of i: Int) -> Set<Int> {
        if let z = zoneCache[i] { return z }
        let m = monsters[i], n = map.size
        var seen: Set<Int> = [m.x * n + m.y], out = Set<Int>(), queue = [(m.x, m.y)]
        while !queue.isEmpty {
            let (x, y) = queue.removeFirst()
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard abs(nx - m.x) <= 2, abs(ny - m.y) <= 2, nx >= 0, ny >= 0, nx < n, ny < n, !seen.contains(nx * n + ny) else { continue }
                seen.insert(nx * n + ny)
                guard passability.canStep(from: x, y, to: nx, ny) || (x == m.x && y == m.y && passability.isFree(nx, ny)) else { continue }
                out.insert(nx * n + ny); queue.append((nx, ny))
            } }
        }
        zoneCache[i] = out
        return out
    }
    var dangerCache: Set<Int>?
    /// Cells inside some wandering stack's guard zone.
    public var dangerCells: Set<Int> {
        if let d = dangerCache { return d }
        var out = Set<Int>()
        for i in monsters.indices where monsters[i].z == level && monsters[i].bank == nil { out.formUnion(zone(of: i)) }
        dangerCache = out
        return out
    }
    public func isDangerous(_ x: Int, _ y: Int) -> Bool { dangerCells.contains(x * map.size + y) }

    /// Does a wandering stack notice the hero on a cell? Stealth (table.skills) hides the hero from
    /// creatures up to its level: a stack of a higher level sees him, one of the same level only
    /// when he is next to it (Master Stealth: 4th level creatures when adjacent), lower levels and
    /// anything against Grandmaster Stealth never. Creatures have no Scouting.
    public func notices(_ m: Monster, _ h: Hero, at x: Int, _ y: Int) -> Bool {
        let stealth = h.skill("stealth")
        guard stealth > 0 else { return true }
        guard stealth < 5, let level = tables?.creature(m.creature)?.level else { return stealth == 0 }
        let adjacent = max(abs(m.x - x), abs(m.y - y)) <= 1
        if level > stealth { return true }
        if level == stealth || (stealth == 4 && level == 4) { return adjacent }
        return false
    }
    /// The wandering stack that would fall on the hero on this cell: one whose guard radius holds
    /// the cell and that notices him there.
    public func threat(to h: Hero, at x: Int, _ y: Int) -> Int? {
        guard isDangerous(x, y) else { return nil }
        return monsters.indices.first { i in monsters[i].z == level && monsters[i].bank == nil && zone(of: i).contains(x * map.size + y) && notices(monsters[i], h, at: x, y) }
    }

    /// The movement an army gets per day: the slowest of the hero and its creatures.
    public func armyMovement(_ h: Hero) -> Float {
        if h.boat != nil { return seaMovement(h) }
        var m = Hero.baseMovement
        for s in h.army { if let c = tables?.creature(s.creature), c.move > 0 { m = min(m, Float(c.move)) } }
        // Master / Grandmaster Pathfinding: the whole army +25% / +50% on land (0x6426c0)
        // Master / Grandmaster Pathfinding (125 / 150) and Boots of Speed style items add up
        // (0x6426c0: max(1, 0.01 x (PATH[pathfinding] + items)), the best hero of the army)
        let best = ([h] + h.companions).map { hh -> Int in
            [100, 100, 100, 100, 125, 150][hh.skill("pathfinding")] + hh.artifactEffects.filter { $0.type == 0x00 && $0.land }.reduce(0) { $0 + $1.amount }
        }.max() ?? 100
        return m * max(1, Float(best) / 100)
    }
    /// How much Pathfinding takes off rough terrain (in cells: 0.25, 0.5, then all of it; never
    /// below the plain cost; heroes4.exe's table [0, 25, 50, 100, 100, 100] of 100 a cell).
    public static func terrainRelief(_ h: Hero) -> Float {
        if h.timedEffects["spell.pathfinding"] != nil { return 100 }   // the Pathfinding spell: no penalty at all
        let pf = ([h] + h.companions).map { $0.skill("pathfinding") }.max() ?? 0
        return [0, 0.25, 0.5, 1, 1, 1][pf]
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
        for (r, n) in artifactIncome { out[r, default: 0] += n }   // bags of gold, carts of ore...
        // Estates: 100 gold a day per level of the skill, plus 10% per level of the hero (table.skills)
        for h in heroes.flatMap({ [$0] + $0.companions }) where h.skill("estates") > 0 {
            out["Gold", default: 0] += 100 * h.skill("estates") * (10 + h.level) / 10
        }
        return out
    }
    public var day = 1
    public var week: Int { (day - 1) / 7 % 4 + 1 }
    public var month: Int { (day - 1) / 28 + 1 }
    public var dayOfWeek: Int { (day - 1) % 7 + 1 }
    public static var cellsPerSecond: Float = 4

    public convenience init(map: MapFile, level: Int, scene: MapScene) {
        self.init(map: map, level: level, scenes: [scene])
    }
    /// A game over the map's levels (scenes in level order); `level` is the one in play first.
    public init(map: MapFile, level: Int, scenes: [MapScene]) {
        self.map = map
        self.scenes = scenes
        self.level = min(level, scenes.count - 1)
        passabilities = scenes.map { Passability(map: map, level: $0.level, objects: $0.placed) }
    }

    /// A 1x1 object with a "step here to use" mask: resources, chests, artifacts, campfires.
    public func isPickup(_ p: MapScene.Placed) -> Bool {
        p.sprite.footprint.w * p.sprite.footprint.h == 1 && !p.sprite.visitable.isEmpty && !p.sprite.blocked.isEmpty
    }

    /// The mine record for a placed object, if it is a working mine.
    public func mine(for p: MapScene.Placed) -> Int? {
        mines.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name && $0.z == level }
    }

    public func dwelling(for p: MapScene.Placed) -> Int? {
        dwellings.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name && $0.z == level }
    }

    public func monster(for p: MapScene.Placed) -> Int? {
        monsters.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.name == p.name && $0.z == level && $0.bank == nil }
    }
    public func town(for p: MapScene.Placed) -> Int? {
        p.category == "castle" ? towns.firstIndex { $0.x == p.cellX && $0.y == p.cellY && $0.z == level } : nil
    }

    /// Objects a hero walks up to and uses: pickups, mines, dwellings, monsters and towns.
    public func isVisitable(_ p: MapScene.Placed) -> Bool {
        hasVisit(p) || isPickup(p) || mine(for: p) != nil || dwelling(for: p) != nil || monster(for: p) != nil || town(for: p) != nil
    }

    /// The town screen to open, set when a hero enters a town; the UI clears it.
    public var enteredTown: Int?
    /// A message's title banner and the artifact it hands over (by the message's text).
    public var messageTitles: [String: String] = [:], messageArtifacts: [String: Int] = [:]
    /// The campaign being played (its standard id and this scenario's index).
    public var campaign: (id: Int, index: Int)?
    /// The army that walked into the town now on screen (it is the visiting row, 0x8ac0c0's army).
    public var townVisitor: (town: Int, hero: Hero)?

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
    public func heroStats(_ h: Hero) -> (attack: Int, defense: Int, damage: String, hitPoints: Int, speed: Int, move: Int, ranged: Int, shots: Int, spellPoints: Int) {
        let c = heroCombatant(h)
        // spell points: 10, and 10 per level of Healing, Enchantment, Occultism, Conjuration and Herbalism (0x729ff0)
        let sp = maxSpellPoints(h)
        return (c.attack, c.defense, "\(c.damageLow)-\(c.damageHigh)", c.hitPoints, c.speed, Int(h.maxMovement), c.rangedAttack ?? c.attack, c.shots, sp)
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
        guard let id = buildingId(t.alignment, b.keyword) else { return false }
        return buildState(t, id) == 6
    }

    public func build(_ b: RuleTables.BuildingDef, in i: Int) {
        guard canBuild(b, in: towns[i]) else { return }
        for (r, v) in b.cost { resources[r, default: 0] -= v }
        towns[i].buildings.insert(b.keyword)
        towns[i].builtToday = true
        if let c = b.creature, let def = tables?.creature(c) { towns[i].available[c, default: 0] += def.growth }
        sounds.append("miscellaneous.town_build")
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

    /// The game's random numbers for rules ported from the exe.
    public var random = H4Random()
    /// A hero as a fighter: its level and skills, what objects gave it (attack, defense, speed:
    /// the bonus array, shown 1:1), and until the next battle the fountains' +20% damage (effect
    /// 0x99), +2 speed (0x92) and more hit points (0x39).
    public func heroCombatant(_ h: Hero) -> Combatant {
        var c = Combatant(hero: h.name, level: h.level, skills: h.skills)
        c.attack += h.attackBonus; c.rangedAttack = c.rangedAttack.map { $0 + h.attackBonus }
        c.defense += h.defenseBonus
        c.speed = max(1, c.speed + h.speedBonus + (h.fountainEffects.contains("speed") ? 2 : 0))
        if h.fountainEffects.contains("strength") { c.damageLow += c.damageLow / 5; c.damageHigh += c.damageHigh / 5 }
        if h.fountainEffects.contains("vigor") { c.hitPoints += c.hitPoints / 5 }
        // worn artifacts (tenths of shown points for attack and defense; HP in percent)
        var hpPct = 0, resist = [0, 30, 50, 70, 80, 100][min(5, h.skill("resistance"))]
        for e in h.artifactEffects where e.target == 0 || e.target == 5 {
            switch e.type {
            case 0x37:
                if e.melee { c.attack += e.amount / 10 }
                if e.ranged { c.rangedAttack = (c.rangedAttack ?? c.attack) + e.amount / 10 }
            case 0x0a: c.defense += e.amount / 10
            case 0x10: hpPct += e.amount
            case 0x09:
                let extra = e.amount + e.perLevel * h.level / max(1, e.divisor)
                c.damageLow += extra; c.damageHigh += extra
            case 0x2a: c.speed = max(1, c.speed + e.amount)
            case 0x17: resist += (100 - resist) * e.amount / 100
            case 0x38:
                c.abilities.insert(e.ability)
                if e.ability == "ranged" { c.shooter = true; if c.shots == 0 { c.shots = 12 } }
            case 0x2b: if e.spell >= 0 { c.effects.insert(e.spell) }
            default: break
            }
        }
        c.hitPoints = c.hitPoints * (100 + hpPct) / 100
        c.magicResistance = min(100, resist)
        return c
    }

    /// Experience for an army: each of its heroes gains it, learning a skill per level reached.
    public func giveExperience(_ n: Int, to hero: Hero) {
        share(n, among: [hero] + hero.companions)   // by level + 2 (0x641310)
    }

    /// The player's heroes still to take levels: each level is a choice in the level-up dialog
    /// (layers.dialog.choose_skill), the offer made by Hero.levelUpOffer (heroes4.exe 0x72bca0's
    /// interactive path); a level with nothing to offer is taken at once.
    public var levelUpQueue: [Hero] = []
    /// The level-up waiting for the player's choice.
    public var levelUp: (hero: Hero, offer: [(skill: Int, level: Int)])?
    public func nextLevelUp() {
        guard levelUp == nil else { return }
        while let h = levelUpQueue.first {
            guard h.level < min(70, Hero.level(for: h.experience)) else { levelUpQueue.removeFirst(); continue }
            let offer = h.levelUpOffer(weights: tables?.skillWeights[h.classKeyword] ?? [:], random: &random)
            if offer.isEmpty { h.level += 1; continue }
            levelUp = (h, offer); return
        }
    }
    /// The class a choice would make the hero (for the dialog's "will become a level ..." line).
    public func classAfter(_ h: Hero, choosing e: (skill: Int, level: Int)) -> Int {
        let saved = (h.skills, h.heroClass)
        h.learn(e.skill, level: e.level); h.reconsiderClass()
        let c = h.heroClass
        h.skills = saved.0; h.heroClass = saved.1
        return c
    }
    /// The player picked offer k: the level is gained, the skill learned, the class reconsidered.
    public func chooseSkill(_ k: Int) {
        guard let lu = levelUp, lu.offer.indices.contains(k) else { return }
        let h = lu.hero, e = lu.offer[k]
        h.level += 1
        h.learn(e.skill, level: e.level)
        h.grantSchoolSpells(random: &random)
        h.reconsiderClass()
        let k2 = RuleTables.skillIds[e.skill], lv = RuleTables.skillLevelNames[e.level]
        log.append("\(h.name) reaches level \(h.level): \(tables?.skillTexts["\(k2)_\(lv)"]?.name ?? k2)")
        levelUp = nil
        nextLevelUp()
    }

    /// The hero's army as combatants, its heroes first.
    func combatants(of hero: Hero) -> [Combatant] {
        var out = ([hero] + hero.companions).map { heroCombatant($0) }
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
        let survivors = result.attackers.filter { $0.alive && !$0.isHero }.map { s in Hero.Stack(creature: t.creatures.first { $0.name == s.name }?.keyword ?? s.name, count: s.count) }
        finishBattle(hero: hero, monsterAt: i, p, won: result.attackerWon, army: survivors, monstersLeft: result.defenders.first?.count ?? 0, experience: result.experience, rounds: result.rounds)
    }

    /// Apply a battle's outcome to the map: the army's survivors, the monster removed or
    /// thinned, experience, a beaten hero sent home.
    public func finishBattle(hero: Hero, monsterAt i: Int, _ p: MapScene.Placed, won: Bool, army: [Hero.Stack], monstersLeft: Int, experience: Int, rounds: Int) {
        guard let t = tables, i < monsters.count, let c = t.creature(monsters[i].creature) else { return }
        clearBattleEffects(hero)
        hero.army = army
        refreshMovement(hero)
        if monsters[i].bank == "script", let sb = scriptBattle {   // a script's fight: its win or lose action
            monsters.remove(at: i)
            scriptBattle = nil
            if won { giveExperience(experience, to: hero) }
            else { hero.x = hero.home.x; hero.y = hero.home.y; hero.movement = 0; hero.path = []; hero.plan = [] }
            var r = false
            if let a = won ? sb.win : sb.lose { exec(a, sb.context, &r) }
            hero.target = nil; pendingBattle = nil
            return
        }
        if let key = monsters[i].bank, key.hasPrefix(GameState.garrisonPrefix) {   // a garrison: taken, or it holds
            let real = String(key.dropFirst(GameState.garrisonPrefix.count))
            if won { giveExperience(experience, to: hero); takeGarrison(real) }
            else {
                garrisonHeld(real, leadLeft: monstersLeft)
                hero.x = hero.home.x; hero.y = hero.home.y; hero.movement = 0; hero.path = []; hero.plan = []
            }
            monsters.remove(at: i)
        } else if let key = monsters[i].bank {   // a creature bank: the object stays
            if won { giveExperience(experience, to: hero); bankDefeated(hero, p, key: key) }
            else {
                objectStates[key]?.guardCounts[0] = max(1, monstersLeft)
                hero.x = hero.home.x; hero.y = hero.home.y; hero.movement = 0; hero.path = []; hero.plan = []
            }
            monsters.remove(at: i)
        } else if won {
            giveExperience(experience, to: hero)
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
        runContinuous()
        checkScenario(newDay: false)
    }

    /// Where a hero retreats to: the player's nearest town (none: the hero cannot retreat,
    /// "no_town_after_retreat.combat").
    public func retreatTown(for hero: Hero) -> Int? {
        towns.indices.filter { towns[$0].owned }.min { a, b in
            let da = (towns[a].x - hero.x) * (towns[a].x - hero.x) + (towns[a].y - hero.y) * (towns[a].y - hero.y)
            let db = (towns[b].x - hero.x) * (towns[b].x - hero.x) + (towns[b].y - hero.y) * (towns[b].y - hero.y)
            return da < db
        }
    }
    /// The hero left the battle ("wish_to_retreat.combat": all the troops are lost) and stands
    /// at the gate of the town; the monsters keep what they lost.
    public func retreat(hero: Hero, monsterAt i: Int, monstersLeft: Int, to town: Int) {
        hero.army = []
        if i < monsters.count, let key = monsters[i].bank { objectStates[key]?.guardCounts[0] = max(1, monstersLeft); monsters.remove(at: i) }
        else if i < monsters.count { monsters[i].count = max(1, monstersLeft) }
        if let p = scene.placed.first(where: { self.town(for: $0) == town }) {
            let gate = gateCells(p).first { passability.isFree($0.0, $0.1) } ?? gateCells(p)[0]
            hero.x = gate.0; hero.y = gate.1
        }
        hero.movement = 0; hero.path = []; hero.plan = []; hero.target = nil
        refreshMovement(hero)
        pendingBattle = nil
        log.append("\(hero.name) retreats to \(towns[town].name)")
        runContinuous()
        checkScenario(newDay: false)
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
        let playing = level
        var townIndex = 0
        for l in scenes.indices {
            level = l
            let counts = (towns.count, mines.count, monsters.count, dwellings.count)
            registerObjects(townFactions: townFactions, townIndex: &townIndex)
            for i in counts.0..<towns.count { towns[i].z = l }
            for i in counts.1..<mines.count { mines[i].z = l }
            for i in counts.2..<monsters.count { monsters[i].z = l }
            for i in counts.3..<dwellings.count { dwellings[i].z = l }
        }
        level = playing
    }
    /// The towns, mines, monsters and dwellings of the current level.
    private func registerObjects(townFactions: [String: String], townIndex: inout Int) {
        for p in scene.placed {
            if p.category == "castle" {
                let faction = townFactions[p.name] ?? "life"
                let list = tables?.names["\(faction.prefix(1).uppercased() + faction.dropFirst())_Town"] ?? []
                let custom = map.objects.first { ($0.type == "town" || $0.type == "random_town") && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }?.customName
                let name = custom ?? (list.isEmpty ? "Town" : list[(p.cellX * 7 + p.cellY * 13 + townIndex) % list.count])
                var town = Town(x: p.cellX, y: p.cellY, name: name, alignment: faction, owned: false)
                let record = map.objects.first { ($0.type == "town" || $0.type == "random_town") && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }
                let settings = record?.town
                let ids = RuleTables.buildingIds[faction] ?? [:]
                if let built = settings?.built {
                    town.buildings = RuleTables.buildings(built, alignment: faction)
                } else {
                    // heroes4.exe 0x89a8bb: with a fort the first two dwellings (and mage guild 1 in an owned
                    // town that has guilds), without one a single dwelling; an owned town has a tavern
                    let owned = settings?.owner != nil
                    let last = GameState.shortName(p.name).lowercased()
                    let fort = settings?.hasFort ?? ["fort", "citadel", "castle"].contains(last)
                    var b: Set<Int> = []
                    if fort { b.formUnion([3, 12, 13]); if owned && faction != "might" { b.insert(20) } }
                    else { b.insert(12 + (p.cellX + p.cellY) % 2) }
                    if owned { b.insert(9) }
                    town.buildings = Set(b.compactMap { ids[$0] })
                    // walls beyond the fort follow the sprite ("castle.Haven.Citadel R" -> citadel)
                    if last == "citadel" || last == "castle" { town.buildings.formUnion(["fort", "citadel"]) }
                    if last == "castle" { town.buildings.insert("castle") }
                }
                town.buildings.formUnion(["village hall", "prison"])   // always (0x89a97b)
                town.owner = settings?.owner
                town.owned = settings?.owner == map.humanColour
                // the garrison the editor set (a count of 0: the creature's level budget, as for placed armies)
                if let g = settings?.garrison, let t = tables {
                    var rng = GameRandom(seed: p.cellX * 4481 + p.cellY * 7907)
                    for case let (id, n)? in g where id < RuleTables.creatureIds.count {
                        guard let c = t.creature(RuleTables.creatureIds[id]) else { continue }
                        var count = n
                        if count <= 0 {
                            let base = Double(GameState.monsterBudget[min(4, max(1, c.level))])
                            count = max(1, (rng.next() % (Int(base * 0.4) + 1) + Int(base * 0.8)) / max(1, c.experience))
                        }
                        town.garrison.append(Hero.Stack(creature: c.keyword, count: count))
                    }
                }
                town.allowed = settings?.allowed.map { RuleTables.buildings($0, alignment: faction) }
                if let t = tables {
                    for b in t.buildings(for: faction) where town.buildings.contains(b.keyword) {
                        if let c = b.creature, let def = t.creature(c) { town.available[c] = def.growth }
                    }
                }
                if ProcessInfo.processInfo.environment["H4DEBUG"] != nil {
                    print("town \(name) (\(faction)) owner \(settings?.owner.map(String.init) ?? "none"): \(town.buildings.sorted()) allowed \(town.allowed.map { "\($0.count)" } ?? "all")")
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
                    // a mine the map gives a player (its record's owner byte)
                    let rec = map.objects.first { $0.type == "mine" && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }
                    mines.append(Mine(x: p.cellX, y: p.cellY, name: p.name, resource: res, amount: amount, owned: rec?.owner == map.humanColour, owner: rec?.owner))
                }
            } else if p.category == "Random creatures", let t = tables, p.name.hasPrefix("actor_sequence.") {
                // "actor_sequence.<creature>.wait.<facing>.h4d" -> the creature; the stack size follows its level
                let parts = p.name.dropFirst("actor_sequence.".count).split(separator: ".")
                if let kw = parts.first, let c = t.creature(String(kw)) {
                    let record = map.objects.first { $0.type == "random_monster" && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }
                    var rng = GameRandom(seed: p.cellX * 7919 + p.cellY * 104729 + level * 1299709)
                    let water = map.cells[level][p.cellX * map.size + p.cellY]?.type == 0
                    let army = monsterArmy(c, level: RandomResolver.level(p.subtype), range: record?.monsterRange, water: water, rng: &rng)
                    monsters.append(Monster(x: p.cellX, y: p.cellY, name: p.name, creature: c.keyword, count: army.count, extra: army.escort.map { [$0] } ?? []))
                    let count = army.count
                    passability.block(p.cellX, p.cellY)
                    if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("monster: \(count) \(c.plural) at (\(p.cellX),\(p.cellY)) escort: \(army.escort.map { "\($0.count) \($0.creature)" } ?? "none")") }
                }
            } else if p.type == "army", let t = tables,
                      let record = map.objects.first(where: { $0.type == "army" && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }) {
                // a placed army (t_army): its stacks; a count of 0 is the game's random size for the
                // creature's level (0x63e1d7: 0.8-1.2 x the level budget / experience, at least 1)
                var rng = GameRandom(seed: p.cellX * 6151 + p.cellY * 92821 + level * 3079)
                var stacks: [(creature: String, count: Int)] = []
                for case let (id, n)? in record.army ?? [] where id < RuleTables.creatureIds.count {
                    guard let c = t.creature(RuleTables.creatureIds[id]) else { continue }
                    var count = n
                    if count <= 0 {
                        let base = Double(GameState.monsterBudget[min(4, max(1, c.level))])
                        let lo = Int(base * 0.8), hi = Int(base * 1.2)
                        count = max(1, (rng.next() % (hi - lo + 1) + lo) / max(1, c.experience))
                    }
                    stacks.append((c.keyword, count))
                }
                // the one shown on the map leads (the highest level, as the resolver drew it)
                let shown = stacks.max { (t.creature($0.creature)?.level ?? 0) < (t.creature($1.creature)?.level ?? 0) }
                if let lead = shown, let k = stacks.firstIndex(where: { $0.creature == lead.creature }) {
                    var rest = stacks; rest.remove(at: k)
                    monsters.append(Monster(x: p.cellX, y: p.cellY, name: p.name, creature: lead.creature, count: lead.count, extra: rest))
                    passability.block(p.cellX, p.cellY)
                    if ProcessInfo.processInfo.environment["H4DEBUG"] != nil { print("army: \(stacks) at (\(p.cellX),\(p.cellY))") }
                }
            } else if p.category == "creature generators", let t = tables {
                var short = p.name.replacingOccurrences(of: "adv_object.creature generators.", with: "").replacingOccurrences(of: ".h4d", with: "").lowercased()
                if short.hasSuffix(" r") { short.removeLast(2) }
                if let kw = t.dwellingCreature[short], let c = t.creature(kw) {
                    var dw = Dwelling(x: p.cellX, y: p.cellY, name: p.name, creature: c.keyword, available: c.growth)
                    dw.owned = map.objects.first { $0.type == "creature_dwelling" && $0.x == p.cellX && $0.y == p.cellY && $0.level == level }?.owner == map.humanColour
                    dwellings.append(dw)
                }
            }
        }
    }

    /// Use an object the hero stands next to.
    func interact(hero: Hero, _ p: MapScene.Placed) {
        if isPickup(p) { take(hero: hero, p); return }
        if visitObject(hero: hero, p) { return }
        if let i = monster(for: p) { fight(hero: hero, monsterAt: i, p); return }
        if let i = town(for: p) {
            if !towns[i].owned, !towns[i].garrison.isEmpty {   // a garrison defends it: a siege (0x896480)
                runTownEvent(i, slot: 0, hero: hero)                            // "attacked"
                pendingSiege = (hero, i)
                hero.target = nil
                return
            }
            if !towns[i].owned {
                let previous = towns[i].owner
                towns[i].owner = actingColour; towns[i].owned = actingColour == map.humanColour
                if towns[i].owned { log.append("\(towns[i].name) is yours") }
                runTownEvent(i, slot: 1, previousOwner: previous, hero: hero)   // "captured"
                checkScenario(newDay: false)
            } else {
                runTownEvent(i, slot: 3, hero: hero)                            // "visited"
            }
            learnFromGuild(hero, town: i)
            enteredTown = i; townVisitor = (i, hero)
            hero.target = nil
            return
        }
        if let i = mine(for: p) {
            if mines[i].owner == actingColour { if isHumanActing { log.append("\(mines[i].resource) mine already yours") } }
            else {
                mines[i].owner = actingColour; mines[i].owned = isHumanActing
                if isHumanActing { sounds.append("miscellaneous.flag_mine"); log.append("captured a mine: +\(mines[i].amount) \(mines[i].resource) per day") }
            }
            hero.target = nil
        }
        if let i = dwelling(for: p), let c = tables?.creature(dwellings[i].creature) {
            if !dwellings[i].owned { dwellings[i].owned = true; sounds.append("miscellaneous.flag_mine") }
            sounds.append("dialogue.recruit")
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
        passability.isFree(c.0, c.1) && !heroes.contains { $0 !== hero && $0.z == level && standingCell($0) == c }
    }

    /// Click on a visitable object: use it if the hero stands next to it, otherwise plan (then
    /// walk) to the cheapest neighbouring cell; it is used on arrival. A town is entered through
    /// the middle gate cell; when that is taken, through the nearer of the other two.
    public func click(hero: Hero, pickup p: MapScene.Placed) {
        passability.relief = GameState.terrainRelief(hero)
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
        if hasVisit(p) { hero.movement -= 1; visitObject(hero: hero, p); return }
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
        sounds.append("miscellaneous.pick_up.0\((p.cellX + p.cellY) % 6 + 1)")
        log.append("picked up \(p.name) at (\(p.cellX),\(p.cellY))")
    }

    /// Short texts floating up over a cell (resources picked up), for the renderer to show.
    public var floaters: [(text: String, x: Int, y: Int)] = []
    /// A treasure chest waiting for the gold-or-experience choice (the UI resolves it).
    public var chestOffer: (hero: Hero, gold: Int, experience: Int)?
    public func resolveChest(gold: Bool) {
        guard let c = chestOffer else { return }
        if gold { resources["Gold", default: 0] += c.gold; floaters.append(("+\(c.gold) gold", c.hero.x, c.hero.y)) }
        else {   // shared equally by the army's heroes (0x641310 with the equal split)
            let hs = [c.hero] + c.hero.companions
            for h in hs { giveExperience(c.experience / hs.count, toOnly: h) }
        }
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
        passability.relief = GameState.terrainRelief(hero)
        if let e = enemyAt(x, y) { attack(e, with: hero); return }
        hero.attackTarget = nil
        if hero.boat != nil {   // at sea: sail over water; a coast cell to land on
            let from = standingCell(hero)
            var route: [(x: Int, y: Int)]? = nil
            if passability.isFreeWater(x, y) { route = seaPath(from: from, to: (x, y)) }
            else if passability.isFree(x, y) {
                var best: [(x: Int, y: Int)]? = nil
                for dx in -1...1 { for dy in -1...1 where passability.isFreeWater(x + dx, y + dy) || (x + dx, y + dy) == from {
                    if let r = (x + dx, y + dy) == from ? [] : seaPath(from: from, to: (x + dx, y + dy)), best == nil || r.count < best!.count { best = r }
                } }
                route = best.map { $0 + [(x, y)] }
            }
            guard let r = route else { return }
            if let last = hero.plan.last, last.x == x, last.y == y { hero.path = hero.plan; hero.plan = []; hero.progress = 0 }
            else { hero.plan = r }
            return
        }
        if let b = boat(at: x, y) {   // an empty ship: walk to the shore beside it, then board
            if GameState.adjacent((hero.x, hero.y), (x, y)) { board(hero, b); return }
            var best: [(x: Int, y: Int)]? = nil
            for dx in -1...1 { for dy in -1...1 where (dx != 0 || dy != 0) && isVacant((x + dx, y + dy), for: hero) {
                if let r = passability.path(from: (hero.x, hero.y), to: (x + dx, y + dy)), best == nil || r.count < best!.count { best = r }
            } }
            guard let r = best else { return }
            if hero.boardTarget.map({ $0 == (x, y) }) == true, !hero.plan.isEmpty { hero.path = hero.plan; hero.plan = []; hero.progress = 0 }
            else { hero.plan = r; hero.boardTarget = (x, y) }
            return
        }
        if jumpsLevel != level { refreshJumps(); jumpsLevel = level }
        // a route through a gateway, portal or ferry ends at it (it then asks where to go)
        func plan(from: (Int, Int)) {
            let r = passability.path(from: from, to: (x, y)) ?? []
            let cut = cutAtJump(r, from: from)
            hero.plan = cut.route
            hero.planGoal = (x, y)
            hero.target = cut.via.map { ($0.cellX, $0.cellY, $0.name) }
        }
        if hero.isWalking {
            interrupt(hero)
            plan(from: standingCell(hero))
            return
        }
        if let g = hero.planGoal, g == (x, y), !hero.plan.isEmpty || hero.target != nil {
            if hero.plan.isEmpty, let t = hero.target, let p = scene.placed.first(where: { $0.cellX == t.x && $0.cellY == t.y && $0.name == t.name }), canUse(from: (hero.x, hero.y), p) {
                interact(hero: hero, p); return
            }
            hero.path = hero.plan
            hero.plan = []
            hero.progress = 0
        } else {
            plan(from: (hero.x, hero.y))
        }
    }

    /// Go on along the route kept from before (the panel's "Continue Moving Army").
    public func continueMoving(_ h: Hero) {
        guard !h.isWalking, !h.plan.isEmpty else { return }
        h.path = h.plan; h.plan = []; h.progress = 0
    }

    /// A wandering stack walking up to a hero it fell on: its route (inside its guard square) to
    /// a cell next to the hero; the battle starts when it gets there.
    public var charge: (monster: Int, hero: Hero, path: [(x: Int, y: Int)], progress: Float)?
    func startCharge(_ i: Int, at h: Hero) {
        let m = monsters[i], n = map.size
        // the nearest cell next to the hero the stack can walk to within its square
        var prev: [Int: Int] = [:], queue = [(m.x, m.y)], goal: (Int, Int)? = nil
        prev[m.x * n + m.y] = -1
        if max(abs(m.x - h.x), abs(m.y - h.y)) <= 1 { goal = (m.x, m.y) }
        while goal == nil, !queue.isEmpty {
            let (x, y) = queue.removeFirst()
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard prev[nx * n + ny] == nil, abs(nx - m.x) <= 2, abs(ny - m.y) <= 2, !(nx == h.x && ny == h.y),
                      passability.canStep(from: x, y, to: nx, ny) || (x == m.x && y == m.y && passability.isFree(nx, ny)) else { continue }
                prev[nx * n + ny] = x * n + y
                if max(abs(nx - h.x), abs(ny - h.y)) <= 1 { goal = (nx, ny); break }
                queue.append((nx, ny))
            }; if goal != nil { break } }
        }
        var path: [(x: Int, y: Int)] = []
        if let g = goal {
            var k = g.0 * n + g.1
            while k != m.x * n + m.y, let p = prev[k], p >= 0 { path.append((k / n, k % n)); k = p }
            path.reverse()
        }
        charge = (i, h, path, 0)
        if path.isEmpty { finishCharge() }
    }
    func finishCharge() {
        guard let c = charge else { return }
        charge = nil
        guard c.monster < monsters.count, let p = scene.placed.first(where: { monster(for: $0) == c.monster }) else { return }
        var placed = p
        if let end = c.path.last {
            passability.free(monsters[c.monster].x, monsters[c.monster].y)
            monsters[c.monster].x = end.x; monsters[c.monster].y = end.y
            passability.block(end.x, end.y)
            placed = scene.relocate(p, toX: end.x, y: end.y)
            dangerCache = nil; zoneCache = [:]
        }
        fight(hero: c.hero, monsterAt: c.monster, placed)
    }
    /// Where a charging stack is drawn now (fractional cell), for the renderer.
    public var chargePosition: (monster: Int, x: Float, y: Float)? {
        guard let c = charge, c.monster < monsters.count else { return nil }
        let m = monsters[c.monster]
        let pts = [(x: m.x, y: m.y)] + c.path
        let t = min(Float(pts.count - 1), c.progress)
        let k = min(pts.count - 2, Int(t)), f = t - Float(max(0, k))
        guard pts.count > 1 else { return (c.monster, Float(m.x), Float(m.y)) }
        let a = pts[max(0, k)], b = pts[max(0, k) + 1]
        return (c.monster, Float(a.x) + Float(b.x - a.x) * f, Float(a.y) + Float(b.y - a.y) * f)
    }

    /// Advance walking heroes by dt seconds.
    public func update(dt: Float) {
        if var c = charge {   // a stack walking up to a hero: nothing else moves meanwhile
            c.progress += dt * GameState.cellsPerSecond
            charge = c
            if c.progress >= Float(c.path.count) { finishCharge() }
            return
        }
        for h in heroes where !h.isWalking { h.knownThreats = nil }
        for h in heroes where h.isWalking && h.z == level {
            if h.knownThreats == nil {
                // the walk is checked once as it starts (0x5439e0), against where the stacks really
                // are: it ends a step before the guard zone of a stack the player had not seen
                // (one that notices the hero); the rest of the route is kept to go on with
                let known = seenMonsters()
                h.knownThreats = known
                if let k = h.path.firstIndex(where: { c in threat(to: h, at: c.x, c.y).map { !known.contains($0) } ?? false }) {
                    h.plan = Array(h.path[k...]); h.path = Array(h.path[..<k]); h.target = nil
                    if h.path.isEmpty { continue }
                }
            }
            let next = h.path[0]
            passability.relief = GameState.terrainRelief(h)
            let stepCost = passability.stepCost(from: h.x, h.y, to: next.x, next.y)
            // out of movement: stop here, keeping the rest of the route (red) to go on with later
            if h.movement + 0.001 < stepCost { h.plan = h.path; h.path = []; continue }
            // at sea, the last step onto land is the landing
            if h.boat != nil, !passability.isWater(next.x, next.y) {
                land(h, at: (next.x, next.y)); continue
            }
            h.facing = Hero.facing(dx: next.x - h.x, dy: next.y - h.y)
            h.progress += dt * GameState.cellsPerSecond
            h.distance += dt * GameState.cellsPerSecond
            if h.progress >= 1 {
                h.x = next.x; h.y = next.y
                h.movement -= stepCost
                h.path.removeFirst()
                h.progress = 0
                stepped(h, onto: h.x, h.y)
                // stepping into a wandering stack's guard radius where it notices the hero: it falls on
                // him and the walk ends there (unless he is on his way to fight that very stack)
                if let i = threat(to: h, at: h.x, h.y), !(h.target.map { $0.x == monsters[i].x && $0.y == monsters[i].y } ?? false) {
                    h.plan = h.path; h.path = []
                    log.append("\(tables?.creature(monsters[i].creature)?.plural ?? monsters[i].creature) attack \(h.name)!")
                    startCharge(i, at: h)
                    continue
                }

                if h.path.isEmpty, let bt = h.boardTarget {
                    h.boardTarget = nil
                    if let b = boat(at: bt.0, bt.1), GameState.adjacent((h.x, h.y), bt) { board(h, b); continue }
                }
                if h.path.isEmpty, let e = h.attackTarget, GameState.adjacent((h.x, h.y), (e.x, e.y)) {
                    h.attackTarget = nil
                    pendingHeroBattle = (h, e)
                    continue
                }
                if h.path.isEmpty, let t = h.target,
                   let p = scene.placed.first(where: { $0.cellX == t.x && $0.cellY == t.y && $0.name == t.name }), canUse(from: (h.x, h.y), p) {
                    interact(hero: h, p)
                }
            }
        }
    }

    /// The scenario's outcome: true won, false lost, nil still playing.
    public var outcome: Bool? = nil
    /// Days left for the standard victory: when one side owns every owned town it must hold
    /// them 3 days (heroes4.exe 0x4c57c6); the same count is the losers' time to take one back.
    public var victoryDays: Int? = nil

    func text(_ key: String, _ fallback: String) -> String { tables?.strings[key] ?? fallback }

    /// The standard conditions: lose with no towns and no armies ("Lose all towns and
    /// armies."); win by being the only side to own towns for 3 days.
    public func checkScenario(newDay: Bool) {
        guard outcome == nil else { return }
        let me = map.humanColour, myTeam = map.teams[me]
        func ally(_ p: Int) -> Bool { p == me || (myTeam != nil && map.teams[p] == myTeam) }
        let held = towns.compactMap { $0.owner }
        if heroes.isEmpty && sanctuaryGuests.isEmpty && !held.contains(where: ally) {
            outcome = false
            log.append(map.lossText ?? text("default_loss_condition", "Lose all towns and armies."))
            return
        }
        guard map.standardVictory && scripts.standardVictoryOn else { return }
        if !held.isEmpty && held.allSatisfy(ally) {
            if let d = victoryDays {
                guard newDay else { return }
                if d <= 1 { victoryDays = 0; outcome = true; log.append(map.victoryText ?? text("default_victory_condition", "Be the only player to own towns.")); return }
                victoryDays = d - 1
                log.append(d - 1 == 1 ? text("victory_pending_singular.adventure_map", "Hold your towns for one more day to win the game!")
                           : text("victory_pending_plural.adventure_map", "Hold your towns for another %days days to win the game!").replacingOccurrences(of: "%days", with: "\(d - 1)"))
            } else {
                victoryDays = 3
                log.append(text("victory_initiated.adventure_map", "Victory is at hand!  Hold your towns for 3 days and your foes will be defeated!"))
            }
        } else if victoryDays != nil {
            victoryDays = nil
            log.append(text("victory_terminated.adventure_map", "Your opponent has taken steps to undermine your victory.  A town has been reclaimed!"))
        }
    }

    public func endTurn() {
        defer { runDayEvents(); checkScenario(newDay: true) }
        for c in aiPlayers { aiTurn(c) }   // the computer players move before the new day
        day += 1
        for h in heroes { h.maxMovement = armyMovement(h); h.movement = h.maxMovement; h.path = []; h.plan = [] }
        for (res, amount) in income { resources[res, default: 0] += amount }
        objectsNewDay()
        sanctuariesNewDay()
        for i in dwellings.indices where dwellings[i].owned {
            dwellings[i].fourteenths += tables?.creature(dwellings[i].creature)?.growth ?? 0
            dwellings[i].available += dwellings[i].fourteenths / 14; dwellings[i].fourteenths %= 14
        }
        for i in towns.indices { towns[i].builtToday = false; if towns[i].tavernDays > 0 { towns[i].tavernDays -= 1 } }
        if dayOfWeek == 1, let t = tables {   // a new week: dwellings restock, in towns too
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
    /// Days a hero needs to reach a cell (1 = today), as the path arrows split the route: a step
    /// is taken while its cost fits what is left, otherwise the next day starts with full
    /// movement. The adventure cursors show it (their frames are 1, 2, 3 and 4+ days). nil: no way there.
    public func daysToReach(_ h: Hero, _ goal: (Int, Int)) -> Int? {
        passability.relief = GameState.terrainRelief(h)
        if jumpsLevel != level { refreshJumps(); jumpsLevel = level }
        guard let route = passability.path(from: (h.x, h.y), to: goal) else { return nil }
        var left = h.movement, days = 1, px = h.x, py = h.y
        for c in route {
            let step = GameState.adjacent((px, py), (c.x, c.y)) ? passability.stepCost(from: px, py, to: c.x, c.y) : 1
            if left + 0.001 < step { days += 1; left = h.maxMovement }
            left -= step; px = c.x; py = c.y
        }
        return days
    }

    /// the last cell gets the destination marker.
    public func arrows(for h: Hero) -> [(x: Int, y: Int, name: String)] {
        passability.relief = GameState.terrainRelief(h)
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
            let colour = left + 0.001 < stepCost ? "red_arrow" : threat(to: h, at: c.x, c.y) != nil ? "yellow_arrow" : "green_arrow"
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
