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
    /// Floating combat messages: text, where, since when, and the icon of layers.icons.combat_messages
    /// beside it ("damage" the broken heart, "Death" the skull; nil none), and the line (0 top).
    var floaters: [(text: String, x: Float, y: Float, since: Date, icon: String?, line: Int)] = []
    /// The message pair of a blow (heroes4.exe 0x5661f0): "-%i" with the broken heart for the damage
    /// and, when any die, "-%i" with the skull for the creatures killed.
    func blowMessages(damage: Int, killed: Int, at c: (Float, Float), since: Date) {
        if damage > 0 { floaters.append(("-\(damage)", c.0, c.1, since, "damage", 0)) }
        if killed > 0 { floaters.append(("-\(killed)", c.0, c.1, since, "Death", 1)) }
    }
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
    /// The town a retreating hero goes to.
    var retreatTown: Int?
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
        queue = []; playing = nil; unitPos = [:]; unitState = [:]; dead = []; dying = []; pendingDeaths = []; hits = []; pendingCount = []; shownPos = [:]; shownCount = [:]; result = nil; showResults = false; floaters = []; effects = []
        pump()
    }

    /// Pull new events from the battle and let the defender's side act on its own.
    func pump() {
        guard let b = battle else { return }
        take(b.takeEvents())
        if playing == nil, queue.isEmpty, b.finished == nil, let u = b.current, u.side == 1 || u.hypnotized { b.autoAct(); take(b.takeEvents()) }
    }
    /// Queue new events. The battle has already moved the units, so a unit about to move is held
    /// where it starts until its move plays (otherwise it shows at its end for a frame and jumps back).
    func take(_ events: [Battle.Event]) {
        for e in events {
            if case .move(let id, _, let from, _) = e, unitPos[id] == nil, shownPos[id] == nil { shownPos[id] = (Float(from.0), Float(from.1)) }
            if case .die(let id) = e { pendingDeaths.insert(id) }
        }
        queue += events
    }

    /// Advance the animation queue.
    func update(now: Date) {
        guard let b = battle else { return }
        landHits(now)
        if let p = playing {
            if now.timeIntervalSince(p.started) >= p.duration {
                finish(p.event)
                playing = nil
            } else if case .move(let id, let path, let start, let flying) = p.event, !path.isEmpty, let m = moves[id] {
                // prewalk (a flyer's take-off), whole loops of walk, postwalk, each covering its
                // share of the path's length (0x7dec80)
                let elapsed = now.timeIntervalSince(p.started)
                let state: String, d: Float
                if elapsed < m.preTime {
                    state = "prewalk"; d = m.preDist * Float(elapsed / max(0.001, m.preTime))
                } else if elapsed < m.preTime + m.walkTime {
                    state = "walk"; d = m.preDist + (m.length - m.preDist - m.postDist) * Float((elapsed - m.preTime) / max(0.001, m.walkTime))
                } else {
                    state = "postwalk"; d = (m.length - m.postDist) + m.postDist * Float(min(1, (elapsed - m.preTime - m.walkTime) / max(0.001, m.postTime)))
                }
                // a flight is one straight line from where it took off to where it lands
                let pts = flying ? [start, path[path.count - 1]] : [start] + path
                var geo: Float = 0
                for k in 1..<pts.count { let dx = Float(pts[k].0 - pts[k - 1].0), dy = Float(pts[k].1 - pts[k - 1].1); geo += (dx * dx + dy * dy).squareRoot() }
                let (pos, dir) = CombatScreen.along(pts, m.length > 0 ? d / m.length * geo : geo)
                unitPos[id] = pos
                if unitState[id]?.state != state { unitState[id] = (state, now, state != "walk") }
                if dir.0 != 0 || dir.1 != 0 { b.unit(id).facing = Battle.facing(dx: dir.0, dy: dir.1) }
            }
            return
        }
        while playing == nil, !queue.isEmpty {
            let e = queue.removeFirst()
            begin(e, now: now)
        }
        if playing == nil { pump() }
        if playing == nil, queue.isEmpty { shownPos.removeAll(); shownCount.removeAll() }
        landHits(now)
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
        case .move(let id, let path, let start, let flying):
            // flyers take off first (0x7dd400: prewalk, walk, postwalk); walkers walk and stop (0x7de960: walk, postwalk)
            let u = b.unit(id)
            let pts = flying ? [start] + (path.last.map { [$0] } ?? []) : [start] + path
            let face = pts.count > 1 ? Battle.facing(dx: Float(pts[1].0 - pts[0].0), dy: Float(pts[1].1 - pts[0].1)) : u.facing
            // the path's length in world units: 16 a straight step, 24 a diagonal one (0x7dec80); a flight is a straight line
            var length: Float = 0
            for k in 1..<max(1, pts.count) {
                let dx = abs(pts[k].0 - pts[k - 1].0), dy = abs(pts[k].1 - pts[k - 1].1)
                length += flying ? 16 * Float(dx * dx + dy * dy).squareRoot() : Float(dx != 0 && dy != 0 ? 24 : 16)
            }
            let a = actor(u.actor)
            let preTime = flying ? stateDuration(u.actor, "prewalk", face) : 0
            let postTime = stateDuration(u.actor, "postwalk", face)
            var preDist = preTime > 0 ? Float(a?.prewalkDistance ?? 16) : 0
            var postDist = postTime > 0 ? Float(a?.postwalkDistance ?? 16) : 0
            if preDist + postDist > length { let k = length / max(1, preDist + postDist); preDist *= k; postDist *= k }
            let loop = Float(a?.walkDistance ?? 64)
            let loops = max(length - preDist - postDist > 0 ? 1 : 0, Int((length - preDist - postDist + loop / 2) / loop))
            let loopTime = stateDuration(u.actor, "walk", face)
            let walkTime = Double(loops) * (loopTime > 0 ? loopTime : Double(loop / 16) / CombatScreen.cellsPerSecond)
            moves[id] = Move(length: length / 16, preDist: preDist / 16, postDist: postDist / 16, preTime: preTime, walkTime: walkTime, postTime: postTime)
            unitPos[id] = (Float(start.0), Float(start.1))   // from this frame on, not only from the next update
            playing = Anim(event: e, started: now, duration: preTime + walkTime + postTime)
        case .melee(let id, let target, let dmg, let killed, let left), .shoot(let id, let target, let dmg, let killed, let left):
            // the blow as it lands now: the striker turns to the target where both are shown
            let ranged: Bool = { if case .shoot = e { return true }; return false }()
            let a = b.unit(id), t = b.unit(target)
            let ac = shownCentre(a), tc = shownCentre(t)
            a.facing = Battle.facing(dx: tc.0 - ac.0, dy: tc.1 - ac.1)
            let state = ranged ? "ranged" : "melee"
            unitState[id] = (state, now, true)
            // the blow lands on the attack's hit frame (combat_actor: the state's hit frame); the target
            // flinches then (unless it dies of it: its die event follows) and the damage shows
            let hitAt = Double(actor(a.actor)?.state(state)?.hitFrame ?? 0) * framePeriod(a.actor, state) + (ranged ? 0.25 : 0)
            let attackTime = max(0.2, stateDuration(a.actor, state, a.facing))
            t.facing = Battle.facing(dx: ac.0 - tc.0, dy: ac.1 - tc.1)
            let flinchTime = left > 0 ? stateDuration(t.actor, "flinch", t.facing) : 0
            hits.append((target: target, at: now.addingTimeInterval(hitAt), left: left))
            playing = Anim(event: e, started: now, duration: max(attackTime, hitAt + flinchTime))
            blowMessages(damage: dmg, killed: killed, at: tc, since: now.addingTimeInterval(hitAt))
            pendingCount.append((target, left, now.addingTimeInterval(hitAt)))
        case .die(let id):
            pendingDeaths.remove(id)
            dying.insert(id)
            unitState[id] = ("die", now, true)
            let du = b.unit(id)
            playing = Anim(event: e, started: now, duration: max(0.2, stateDuration(du.actor, "die", du.facing)))
        case .defend(let id):
            unitState[id] = ("block", now, true)
            let bu = b.unit(id)
            playing = Anim(event: e, started: now, duration: max(0.1, stateDuration(bu.actor, "block", bu.facing)))
        case .morale(let id, let good):
            // bad morale plays the sorrow effect, good morale spiritual fervor (0x5f3710 -> 0x575a70 with 0x91 / 0x94)
            let name = good ? "spiritual fervor" : "sorrow"
            effects.append((name, id, now))
            let u = b.unit(id)
            floaters.append((strings[good ? "combat_action.good_morale" : "combat_action.bad_morale"] ?? (good ? "Good Morale" : "Bad Morale"), u.centre.0, u.centre.1, now, nil, 0))
            playing = Anim(event: e, started: now, duration: effectDuration(name))
        case .effect(let id, let name, let dmg, let killed, let left):
            if effectSprite(name) != nil { effects.append((name, id, now)) }
            let c = shownCentre(b.unit(id))
            shownCount[id] = left
            blowMessages(damage: dmg, killed: killed, at: c, since: now)
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
        case .move(let id, let path, _, _):
            // it stays where this move ended until the queue has played out (the battle may already have moved it on)
            if let last = path.last { shownPos[id] = (Float(last.0), Float(last.1)) }
            unitPos[id] = nil; unitState[id] = nil; moves[id] = nil
        case .melee, .shoot:
            break
        case .die(let id): dead.insert(id)
        case .finished: showResults = true
        default: break
        }
    }

    var busy: Bool { playing != nil || !queue.isEmpty }

    /// Blows waiting for their hit frame: the target flinches and its count drops then.
    var hits: [(target: Int, at: Date, left: Int)] = []
    var pendingCount: [(unit: Int, left: Int, at: Date)] = []
    func landHits(_ now: Date) {
        for h in hits where h.at <= now {
            if h.left > 0, !dying.contains(h.target) { unitState[h.target] = ("flinch", now, true) }
        }
        hits.removeAll { $0.at <= now }
        for p in pendingCount where p.at <= now { shownCount[p.unit] = p.left }
        pendingCount.removeAll { $0.at <= now }
    }

    /// What the screen shows while the queue plays: the battle has already resolved the whole
    /// action, so positions, stack sizes and deaths follow the events as they are played.
    var shownPos: [Int: (Float, Float)] = [:]
    var shownCount: [Int: Int] = [:]
    var dying: Set<Int> = []
    /// Deaths queued but not played yet: those units still stand.
    var pendingDeaths: Set<Int> = []
    func shownAlive(_ u: Battle.Unit) -> Bool { !dying.contains(u.id) && !dead.contains(u.id) && (u.alive || pendingDeaths.contains(u.id)) }
    func shownCentre(_ u: Battle.Unit) -> (Float, Float) {
        let p = unitPos[u.id] ?? shownPos[u.id] ?? (Float(u.x), Float(u.y))
        return (p.0 + Float(u.size) / 2, p.1 + Float(u.size) / 2)
    }

    /// The move being played: its length and the part each phase covers (cells) and lasts (s).
    struct Move { var length, preDist, postDist: Float; var preTime, walkTime, postTime: Double }
    var moves: [Int: Move] = [:]
    /// The point `d` cells along a polyline of cells, and the direction there.
    static func along(_ pts: [(Int, Int)], _ d: Float) -> ((Float, Float), (Float, Float)) {
        var left = max(0, d)
        for k in 1..<max(1, pts.count) {
            let a = (Float(pts[k - 1].0), Float(pts[k - 1].1)), b = (Float(pts[k].0), Float(pts[k].1))
            let dx = b.0 - a.0, dy = b.1 - a.1
            let seg = (dx * dx + dy * dy).squareRoot()
            if left <= seg || k == pts.count - 1 {
                let f = seg > 0 ? min(1, left / seg) : 1
                return ((a.0 + dx * f, a.1 + dy * f), (dx, dy))
            }
            left -= seg
        }
        let p = pts.last.map { (Float($0.0), Float($0.1)) } ?? (0, 0)
        return (p, (0, 0))
    }
    var stateDurations: [String: Double] = [:]
    /// The combat "Animation Speed" option, percent (heroes4.exe keeps it at 0xa7564c, 150 by default).
    var animationSpeed = 150
    /// Seconds a frame of an actor's state shows: 100000 / (the state's frames per second x the
    /// animation speed) ms (the state's speed byte in combat_actor; 0x5d5660 x 0x7c8ea0).
    func framePeriod(_ actorName: String, _ state: String) -> Double {
        let fps = max(1, actor(actorName)?.state(state)?.speed ?? 9)
        return 100.0 / Double(fps * animationSpeed)
    }
    /// How long an actor's one-off state runs (its frames at their own speed, as the renderer plays them).
    func stateDuration(_ actorName: String, _ state: String, _ facing: String) -> Double {
        let key = "\(actorName)|\(state)|\(facing)"
        if let d = stateDurations[key] { return d }
        var d = 0.0
        if let a = actor(actorName), let entry = a.sequenceEntry(state: state, facing: facing), let data = payload(entry), let s = try? Sprite(data: data) {
            let tl = s.timeline
            if !tl.isEmpty { d = Double(tl.count) * framePeriod(actorName, state) }
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
