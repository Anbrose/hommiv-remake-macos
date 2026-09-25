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
    var unitState: [Int: (state: String, since: Date, once: Bool)] = [:]
    var dead: Set<Int> = []
    var result: (won: Bool, rounds: Int)?
    var showResults = false
    var floaters: [(text: String, x: Float, y: Float, since: Date)] = []
    /// Spell-style effects playing over a unit (morale shows "sorrow" / "spiritual fervor").
    var effects: [(name: String, unit: Int, since: Date)] = []
    /// Idle creatures stand in their "wait" loop; the battle's idle timer (heroes4.exe 0x563870)
    /// makes one waiting creature at random play "fidget", then waits the fidget's length plus
    /// 1000 + rand % 2001 ms (500 ms when no creature is waiting). Moving the pointer onto a
    /// waiting creature also makes it fidget (0x571b1b).
    var nextFidget = Date()
    var fidgeting: Int?
    var hovered: Int?
    /// The unit whose creature window is open (right click), if any.
    var info: Int?
    var idleRandom = GameRandom(seed: 0x563870)
    var strings: [String: String] = [:]
    var effectSprites: [String: Sprite] = [:]
    func effectSprite(_ name: String) -> Sprite? {
        if effectSprites[name] == nil, let d = payload("animation.spell.\(name).h4d") { effectSprites[name] = try? Sprite(data: d) }
        return effectSprites[name]
    }
    /// How long an effect runs: its frames' durations (1/60 s each unit), about 1 s without them.
    func effectDuration(_ name: String) -> Double {
        guard let s = effectSprite(name) else { return 1 }
        let t = s.frames.reduce(0) { $0 + max(1, $1.speed) }
        return t > s.frames.count ? Double(t) / 60 : Double(s.frames.count) / 12
    }

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

    /// Obstacle kinds from combat_header (loaded once).
    lazy var obstacleKinds: [Battlefield.ObstacleKind] = payload("combat_header_table_cache.combat_header.h4d").map(Battlefield.obstacleKinds) ?? []
    /// Grid tints from updates.h4r (set by main when that archive is present).
    var gridColors: GridColors?
    static let terrainKeys: [UInt8: String] = [0: "water", 1: "grass", 2: "rough", 3: "swamp", 4: "volcanic", 5: "snow", 6: "sand", 7: "dirt", 8: "subterranean"]

    /// A land field for the terrain the hero stands on, obstacles as the game's tables say.
    func generatedField(terrain: UInt8, variant: UInt8, seed: Int, tables: RuleTables) -> Battlefield {
        let key = CombatScreen.terrainKeys[terrain] ?? "grass"
        return Battlefield(terrain: terrain, variant: variant, kinds: obstacleKinds, frequency: tables.obstacleFrequency[key] ?? [:], adjacency: tables.obstacleAdjacency, seed: seed)
    }

    /// Set up a battle between a hero's army and a wandering stack.
    func start(game g: GameState, hero h: Hero, monsterAt i: Int, _ p: MapScene.Placed, terrain: UInt8, variant: UInt8 = 0) {
        guard let t = g.tables, let c = t.creature(g.monsters[i].creature) else { return }
        hero = h; monsterIndex = i; placed = p
        let seed = g.day * 977 + h.x * 31 + h.y
        fieldName = "generated.\(terrain).\(variant).\(seed)"
        field = generatedField(terrain: terrain, variant: variant, seed: seed, tables: t)
        Combatant.abilityKeywords = t.abilityKeywords
        guard let f = field else { return }
        let classActor = "hero.\(h.alignment)_fighter_male"
        // morale from each army's alignments (heroes4.exe 0x640310)
        let heroArmy: [(alignment: String, undead: Bool)] = [(h.alignment, false)] + h.army.compactMap { st in t.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        var monsterArmy: [(alignment: String, undead: Bool)] = [(c.alignment, Combatant(creature: c, count: 1).has("undead"))]
        for e in g.monsters[i].extra { if let ed = t.creature(e.creature) { monsterArmy.append((ed.alignment, Combatant(creature: ed, count: 1).has("undead"))) } }
        func fighter(_ cd: CreatureDef, _ n: Int, army: [(alignment: String, undead: Bool)]) -> Battle.Fighter {
            var st = Combatant(creature: cd, count: n)
            st.morale = Battle.armyMorale(own: cd.alignment, army: army)
            return Battle.Fighter(stats: st, keyword: cd.keyword, actor: cd.name, size: actor(cd.name)?.size ?? 4, move: cd.move, shots: cd.shots)
        }
        strings = t.strings
        // a hero moves 24 cells (heroes4.exe: 2400 movement, 100 a cell) at Speed 6 plus skill bonuses
        var heroStats = Combatant(hero: h.name, level: h.level)
        heroStats.speed = 6
        heroStats.morale = Battle.armyMorale(own: h.alignment, army: heroArmy)
        var attackers = [Battle.Fighter(stats: heroStats, keyword: h.keyword, actor: classActor, size: actor(classActor)?.size ?? 4, move: 24, shots: 0, slot: 0)]
        for (k, s) in h.army.enumerated() { if let cd = t.creature(s.creature) { var f = fighter(cd, s.count, army: heroArmy); f.slot = k + 1; attackers.append(f) } }
        // a wandering stack has no hero: it splits against the attacker's stacks (0x62da90)
        func backRow(_ d: CreatureDef) -> Bool { d.shots > 0 || Combatant(creature: d, count: 1).has("ranged") }
        var stacks = [Battle.ArmySlot(creature: c.keyword, count: g.monsters[i].count, backRow: backRow(c))]
        for e in g.monsters[i].extra { if let ed = t.creature(e.creature) { stacks.append(Battle.ArmySlot(creature: ed.keyword, count: e.count, backRow: backRow(ed))) } }
        let split = Battle.splitArmy(stacks, enemyStacks: attackers.count)
        var defenders: [Battle.Fighter] = []
        for (k, st) in split.enumerated() {
            if let st = st, let d = t.creature(st.creature) { var f = fighter(d, st.count, army: monsterArmy); f.slot = k; defenders.append(f) }
        }
        battle = Battle(field: f, attackers: attackers, defenders: defenders, seed: seed)
        queue = []; playing = nil; unitPos = [:]; unitState = [:]; dead = []; result = nil; showResults = false; floaters = []; effects = []
        pump()
    }

    /// Pull new events from the battle and let the defender's side act on its own.
    func pump() {
        guard let b = battle else { return }
        queue += b.takeEvents()
        if playing == nil, queue.isEmpty, b.finished == nil, let u = b.current, u.side == 1 || u.hypnotized { b.autoAct(); queue += b.takeEvents() }
    }

    /// Advance the animation queue.
    func update(now: Date) {
        guard let b = battle else { return }
        if let p = playing {
            if now.timeIntervalSince(p.started) >= p.duration {
                finish(p.event)
                playing = nil
            } else if case .move(let id, let path, let start, _) = p.event, !path.isEmpty {
                // prewalk (a flyer's take-off) in place, walk / fly along the path, postwalk at the end
                let elapsed = now.timeIntervalSince(p.started)
                let (pre, walk) = moveTimes[id] ?? (0, 0)
                let begin = (Float(start.0), Float(start.1)), last = (Float(path[path.count - 1].0), Float(path[path.count - 1].1))
                if elapsed < pre {
                    unitPos[id] = begin
                    if unitState[id]?.state != "prewalk" { unitState[id] = ("prewalk", now, true) }
                    b.unit(id).facing = Battle.facing(dx: Float(path[0].0) - begin.0, dy: Float(path[0].1) - begin.1)
                } else if elapsed < pre + walk {
                    let t = Float((elapsed - pre) * CombatScreen.cellsPerSecond)
                    let k = min(path.count - 1, Int(t)), f = t - Float(k)
                    let from = k == 0 ? begin : (Float(path[k - 1].0), Float(path[k - 1].1))
                    let to = (Float(path[k].0), Float(path[k].1))
                    unitPos[id] = (from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f)
                    if unitState[id]?.state != "walk" { unitState[id] = ("walk", now, false) }
                    b.unit(id).facing = Battle.facing(dx: to.0 - from.0, dy: to.1 - from.1)
                } else {
                    unitPos[id] = last
                    if unitState[id]?.state != "postwalk" { unitState[id] = ("postwalk", now, true) }
                }
            }
            return
        }
        while playing == nil, !queue.isEmpty {
            let e = queue.removeFirst()
            begin(e, now: now)
        }
        if playing == nil { pump() }
        if fidgeting == nil, now >= nextFidget {
            let waiting = b.units.filter { $0.alive && unitState[$0.id] == nil && unitPos[$0.id] == nil && !$0.disabled }
            if waiting.isEmpty { nextFidget = now.addingTimeInterval(0.5) }
            else { fidget(waiting[idleRandom.next() % waiting.count].id, now: now); fidgeting = unitState.first { $0.value.state == "fidget" }?.key }
        }
        floaters.removeAll { now.timeIntervalSince($0.since) > 1.5 }
        effects.removeAll { now.timeIntervalSince($0.since) > effectDuration($0.name) }
    }

    func begin(_ e: Battle.Event, now: Date) {
        guard let b = battle else { return }
        switch e {
        case .move(let id, let path, _, let flying):
            // flyers take off first (0x7dd400: prewalk, walk, postwalk); walkers only stop (0x7de960: walk, postwalk)
            let u = b.unit(id), face = u.facing
            let pre = flying ? stateDuration(u.actor, "prewalk", face) : 0
            let walk = Double(path.count) / CombatScreen.cellsPerSecond
            let post = stateDuration(u.actor, "postwalk", face)
            moveTimes[id] = (pre, walk)
            playing = Anim(event: e, started: now, duration: pre + walk + post)
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
        case .morale(let id, let good):
            // bad morale plays the sorrow effect, good morale spiritual fervor (0x5f3710 -> 0x575a70 with 0x91 / 0x94)
            let name = good ? "spiritual fervor" : "sorrow"
            effects.append((name, id, now))
            let u = b.unit(id)
            floaters.append((strings[good ? "combat_action.good_morale" : "combat_action.bad_morale"] ?? (good ? "Good Morale" : "Bad Morale"), u.centre.0, u.centre.1, now))
            playing = Anim(event: e, started: now, duration: effectDuration(name))
        case .effect(let id, let name, let dmg, let killed):
            if effectSprite(name) != nil { effects.append((name, id, now)) }
            let u = b.unit(id)
            if dmg > 0 { floaters.append(("-\(dmg)" + (killed > 0 ? " (\(killed) killed)" : ""), u.centre.0, u.centre.1, now)) }
            playing = Anim(event: e, started: now, duration: min(1.2, effectSprite(name) != nil ? effectDuration(name) : 0.4))
        case .wait, .newRound:
            break
        case .finished(let won):
            result = (won, b.round)
            playing = Anim(event: e, started: now, duration: 0.6)
        }
    }
    func finish(_ e: Battle.Event) {
        switch e {
        case .move(let id, _, _, _): unitPos[id] = nil; unitState[id] = nil; moveTimes[id] = nil
        case .melee(_, let target, _, _), .shoot(_, let target, _, _):
            if let b = battle, b.unit(target).alive { unitState[target] = ("flinch", Date(), true) }
        case .die(let id): dead.insert(id)
        case .finished: showResults = true
        default: break
        }
    }

    var busy: Bool { playing != nil || !queue.isEmpty }

    /// Phase lengths of the move being played: take-off, then the walk or flight.
    var moveTimes: [Int: (Double, Double)] = [:]
    var stateDurations: [String: Double] = [:]
    /// How long an actor's one-off state runs (its frames at their own speed, as the renderer plays them).
    func stateDuration(_ actorName: String, _ state: String, _ facing: String) -> Double {
        let key = "\(actorName)|\(state)|\(facing)"
        if let d = stateDurations[key] { return d }
        var d = 0.0
        if let a = actor(actorName), let entry = a.sequenceEntry(state: state, facing: facing), let data = payload(entry), let s = try? Sprite(data: data) {
            let tl = s.timeline
            if !tl.isEmpty { d = Double(tl.count) * (tl[0].frame.speed > 0 ? Double(tl[0].frame.speed) / 60 : 0.1) }
        }
        stateDurations[key] = d
        return d
    }

    /// Play a unit's fidget once (it returns to "wait" when done).
    func fidget(_ id: Int, now: Date) { unitState[id] = ("fidget", now, true) }
    /// The renderer calls this when a one-off idle animation has played out.
    func idleDone(_ id: Int, now: Date) {
        unitState[id] = nil
        if fidgeting == id { fidgeting = nil; nextFidget = now.addingTimeInterval(1 + Double(idleRandom.next() % 2001) / 1000) }
    }
    /// The pointer moved onto a unit (nil: onto none).
    func hover(_ id: Int?, now: Date) {
        guard id != hovered else { return }
        hovered = id
        if let id = id, let b = battle, b.unit(id).alive, unitState[id] == nil, unitPos[id] == nil, !b.unit(id).disabled { fidget(id, now: now) }
    }

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
