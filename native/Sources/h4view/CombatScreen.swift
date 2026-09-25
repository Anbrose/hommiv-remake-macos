import Foundation
import Metal
import H4Engine

/// The tactical combat screen: the battlefield scaled into the 885x768 battle scene of
/// layers.combat.1024, the units as their combat actors, the side panel with the acting
/// creature and the action buttons, and the results dialog at the end.
final class CombatScreen {
    let archive: H4Archive
    let frame: LayerFile
    var fields: [String: Battlefield] = [:]
    var actors: [String: CombatActor] = [:]
    var battle: Battle?
    var field: Battlefield?
    var fieldName = ""
    /// Who fights: the hero and the monster index, to apply the result on the map.
    var hero: Hero?
    var monsterIndex = 0
    var placed: MapScene.Placed?

    // animation state
    struct Anim { var event: Battle.Event; var started: Date; var duration: Double }
    var queue: [Battle.Event] = []
    var playing: Anim?
    var unitPos: [Int: (Float, Float)] = [:]     // visual lattice positions while moving
    var moveStart: [Int: (Float, Float)] = [:]
    var unitState: [Int: (state: String, since: Date, once: Bool)] = [:]
    var dead: Set<Int> = []
    var result: (won: Bool, rounds: Int)?
    var showResults = false
    var floaters: [(text: String, x: Float, y: Float, since: Date)] = []

    static let sceneScale: Float = 0.75
    /// Cells walked per second (the original crosses a diamond in about a fifth of a second).
    static let cellsPerSecond: Double = 5

    init(archive: H4Archive) throws {
        self.archive = archive
        frame = try LayerFile(data: archive.payload("layers.combat.1024.h4d"))
    }

    func hotspot(_ name: String) -> UILayer? { frame[name] }

    /// Archive names are looked up without regard to case (the tables say "peasant", the file is "combat_actor.Peasant").
    lazy var lowerIndex: [String: String] = Dictionary(archive.byName.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    func payload(_ name: String) -> Data? {
        guard let real = lowerIndex[name.lowercased()] else { return nil }
        return try? archive.payload(real)
    }
    func loadField(_ name: String) -> Battlefield? {
        if fields[name] == nil, let d = payload("battlefield_preset_map.\(name).h4d") { fields[name] = try? Battlefield(data: d) }
        return fields[name]
    }
    func actor(_ name: String) -> CombatActor? {
        if actors[name] == nil, let d = payload("combat_actor.\(name).h4d") { actors[name] = try? CombatActor(data: d) }
        return actors[name]
    }

    /// Obstacle families per terrain type (combat_object.Obstacles.<family>.<n>).
    static let obstacleFamilies: [UInt8: [String]] = [
        1: ["Trees.Green", "Rocks.Mossy", "Bushes", "Shrubs.Ground", "Flowers.bush"], 2: ["Rocks.Brown", "Rocks.Jagged", "Shrubs.Dry"],
        3: ["Trees.Swamp", "plants.swamp", "logs.swamp"], 4: ["Rocks.Lava", "Cracks.Lava", "Shrubs.burnt"], 5: ["Trees.Snow", "Rocks.Snow", "Shrubs.Snow"],
        6: ["Cactus", "cactus", "Rocks.Sand", "Trees.Palm", "Bones", "Shrubs.Dry"], 7: ["Rocks.Dirt", "Tree_trunks", "Shrubs.orange"], 8: ["Stalagmites", "Mushrooms.Big"]]
    var obstacleSprites: [String: Sprite] = [:]
    func obstacleSprite(_ name: String) -> Sprite? {
        if obstacleSprites[name] == nil, let d = payload(name) { obstacleSprites[name] = try? Sprite(data: d) }
        return obstacleSprites[name]
    }
    /// The ground tiles of a terrain (the adventure patch files), by terrain type and variant.
    var patches: [String: TerrainPatch] = [:]
    func groundPatch(terrain: UInt8, variant: UInt8, alt: Int) -> TerrainPatch? {
        let base = ["water", "grass", "rough", "swamp", "lava", "snow", "sand", "dirt", "subterranean"]
        let t = Int(terrain) < base.count ? base[Int(terrain)] : "grass"
        let key = "\(t).\(min(Int(variant), 1) + 1).\(alt)"
        if patches[key] == nil, let d = payload("terrain.\(key).h4d") { patches[key] = try? TerrainPatch(data: d) }
        return patches[key]
    }
    /// The stack labels (layers.icons.combat_labels.<colour>): waving frames and the "selected" ones.
    var labelSheets: [String: LayerFile] = [:]
    func labels(_ colour: String) -> LayerFile? {
        if labelSheets[colour] == nil, let d = payload("layers.icons.combat_labels.\(colour).h4d") { labelSheets[colour] = try? LayerFile(data: d) }
        return labelSheets[colour]
    }
    var healthSheet: LayerFile? { labels("health") }

    /// A land field for the terrain the hero stands on: open ground with obstacles of its kind.
    func generatedField(terrain: UInt8, variant: UInt8, seed: Int) -> Battlefield {
        var cands: [(name: String, w: Int, h: Int)] = []
        for fam in CombatScreen.obstacleFamilies[terrain] ?? ["Rocks.Dirt"] {
            let prefix = "combat_object.obstacles.\(fam.lowercased())."
            for (lower, real) in lowerIndex where lower.hasPrefix(prefix) && lower.hasSuffix(".h4d") {
                if let d = try? archive.payload(real), d.count > 4, d[d.startIndex] == 2 { cands.append((real, max(1, Int(d[d.startIndex + 2])), max(1, Int(d[d.startIndex + 3])))) }
            }
        }
        cands.sort { $0.name < $1.name }   // a fixed order, so a seed always gives the same field
        return Battlefield(terrain: terrain, variant: variant, obstacles: cands, seed: seed)
    }

    /// Set up a battle between a hero's army and a wandering stack.
    func start(game g: GameState, hero h: Hero, monsterAt i: Int, _ p: MapScene.Placed, terrain: UInt8, variant: UInt8 = 0) {
        guard let t = g.tables, let c = t.creature(g.monsters[i].creature) else { return }
        hero = h; monsterIndex = i; placed = p
        let seed = g.day * 977 + h.x * 31 + h.y
        fieldName = "generated.\(terrain).\(variant).\(seed)"
        field = generatedField(terrain: terrain, variant: variant, seed: seed)
        guard let f = field else { return }
        let classActor = "hero.\(h.alignment)_fighter_male"
        func fighter(_ cd: CreatureDef, _ n: Int) -> Battle.Fighter {
            Battle.Fighter(stats: Combatant(creature: cd, count: n), keyword: cd.keyword, actor: cd.name, size: actor(cd.name)?.size ?? 4, move: cd.move, shots: cd.shots)
        }
        // a hero walks as far as the slowest normal foot soldier (Move 18) until hero movement is read from the game
        var attackers = [Battle.Fighter(stats: Combatant(hero: h.name, level: h.level), keyword: h.keyword, actor: classActor, size: actor(classActor)?.size ?? 4, move: 18, shots: 0)]
        for s in h.army { if let cd = t.creature(s.creature) { attackers.append(fighter(cd, s.count)) } }
        let defenders = [fighter(c, g.monsters[i].count)]
        battle = Battle(field: f, attackers: attackers, defenders: defenders, seed: seed)
        queue = []; playing = nil; unitPos = [:]; unitState = [:]; dead = []; result = nil; showResults = false; floaters = []
        pump()
    }

    /// Pull new events from the battle and let the defender's side act on its own.
    func pump() {
        guard let b = battle else { return }
        queue += b.takeEvents()
        if playing == nil, queue.isEmpty, b.finished == nil, let u = b.current, u.side == 1 { b.autoAct(); queue += b.takeEvents() }
    }

    /// Advance the animation queue.
    func update(now: Date) {
        guard let b = battle else { return }
        if let p = playing {
            if now.timeIntervalSince(p.started) >= p.duration {
                finish(p.event)
                playing = nil
            } else if case .move(let id, let path) = p.event {
                let t = Float(now.timeIntervalSince(p.started) * CombatScreen.cellsPerSecond)
                let k = min(path.count - 1, Int(t)), f = t - Float(k)
                let from = k == 0 ? (moveStart[id] ?? (0, 0)) : (Float(path[k - 1].0), Float(path[k - 1].1))
                let to = (Float(path[k].0), Float(path[k].1))
                unitPos[id] = (from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f)
                unitState[id] = ("walk", p.started, false)
                b.unit(id).facing = Battle.facing(dx: to.0 - from.0, dy: to.1 - from.1)
            }
            return
        }
        while playing == nil, !queue.isEmpty {
            let e = queue.removeFirst()
            begin(e, now: now)
        }
        if playing == nil { pump() }
        floaters.removeAll { now.timeIntervalSince($0.since) > 1.5 }
    }

    func begin(_ e: Battle.Event, now: Date) {
        guard let b = battle else { return }
        switch e {
        case .move(let id, let path):
            let u = b.unit(id)
            // the unit's logical position already moved; animate from where it was
            let start = (Float(u.x), Float(u.y))
            moveStart[id] = unitPos[id] ?? startOfPath(path, end: start)
            playing = Anim(event: e, started: now, duration: Double(path.count) / CombatScreen.cellsPerSecond)
        case .melee(let id, let target, let dmg, let killed):
            unitState[id] = ("melee", now, true)
            playing = Anim(event: e, started: now, duration: 0.6)
            let t = b.unit(target)
            floaters.append(("-\(dmg)" + (killed > 0 ? " (\(killed) killed)" : ""), t.centre.0, t.centre.1, now.addingTimeInterval(0.3)))
        case .shoot(let id, let target, let dmg, let killed):
            unitState[id] = ("ranged", now, true)
            playing = Anim(event: e, started: now, duration: 0.6)
            let t = b.unit(target)
            floaters.append(("-\(dmg)" + (killed > 0 ? " (\(killed) killed)" : ""), t.centre.0, t.centre.1, now.addingTimeInterval(0.3)))
        case .die(let id):
            unitState[id] = ("die", now, true)
            playing = Anim(event: e, started: now, duration: 0.9)
        case .defend(let id):
            unitState[id] = ("block", now, true)
            playing = Anim(event: e, started: now, duration: 0.3)
        case .wait, .newRound:
            break
        case .finished(let won):
            result = (won, b.round)
            playing = Anim(event: e, started: now, duration: 0.6)
        }
    }
    /// Where a path started: one step before its first cell, towards the unit's end cell.
    func startOfPath(_ path: [(Int, Int)], end: (Float, Float)) -> (Float, Float) {
        guard let first = path.first else { return end }
        if path.count > 1 { let second = path[1]; return (Float(2 * first.0 - second.0), Float(2 * first.1 - second.1)) }
        return (end.0 - (Float(first.0) - end.0), end.1 - (Float(first.1) - end.1))
    }

    func finish(_ e: Battle.Event) {
        switch e {
        case .move(let id, _): unitPos[id] = nil; unitState[id] = nil
        case .melee(_, let target, _, _), .shoot(_, let target, _, _):
            if let b = battle, b.unit(target).alive { unitState[target] = ("flinch", Date(), true) }
        case .die(let id): dead.insert(id)
        case .finished: showResults = true
        default: break
        }
    }

    var busy: Bool { playing != nil || !queue.isEmpty }

    // MARK: geometry

    /// World point (cell units) -> canvas point.
    static func point(_ x: Float, _ y: Float) -> (Float, Float) {
        let (sx, sy) = Battlefield.screen(x, y)
        return (sx * sceneScale, sy * sceneScale)
    }
    /// The cell under a canvas point.
    static func cell(at canvasX: Float, _ canvasY: Float) -> (Int, Int) {
        let (x, y) = Battlefield.world(canvasX / sceneScale, canvasY / sceneScale)
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }
}
