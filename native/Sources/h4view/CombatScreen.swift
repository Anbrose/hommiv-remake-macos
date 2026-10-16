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
    /// The enemy hero army being fought (nil: a wandering stack or a bank's guards).
    var enemy: Hero?
    /// The town being besieged.
    var siegeTown: Int?
    var monsterIndex = 0
    var placed: MapScene.Placed?

    // animation state (CombatPlayback.swift / CombatDirector.swift)
    var queue: [Battle.Event] = []
    /// A fixed time to show (the snapshot hooks step the playback on their own clock).
    var clock: Date?
    /// Timers of the animations in flight; those that hold keep the next action waiting.
    var timers: [Timer] = []
    var timerSeq = 0
    var missiles: [Missile] = []
    /// Reactions and fades waiting for a stack's running animation to end.
    var waitingOnUnit: [Int: [(Date) -> Void]] = [:]
    /// The one-shot effect windows playing, the stacks that have one (+0xbfc) and what waits for them.
    var windows: [EffectWindow] = []
    var windowSeq = 0
    var windowBusy: Set<Int> = []
    var windowWaiting: [Int: [(Date) -> Void]] = [:]
    /// Alpha fades, alpha levels other than 15, colour tints, slides, actors on the field.
    var fades: [Int: Fade] = [:]
    var alphaLevel: [Int: Int] = [:]
    var tints: [Int: Tint] = [:]
    var slides: [Int: Slide] = [:]
    var fieldActors: [FieldActor] = []
    var fieldSeq = 0
    var stateToken = 0
    var frameCounts: [String: Int] = [:]
    /// Moves in progress.
    var moving: [Int: MoveAnim] = [:]
    /// Stacks not on the field yet (a summon before its spell is released).
    var hidden: Set<Int> = []
    var unitPos: [Int: (Float, Float)] = [:]     // visual lattice positions while moving
    var unitState: [Int: UnitAnim] = [:]
    var dead: Set<Int> = []
    var result: (won: Bool, rounds: Int)?
    var showResults = false
    /// Floating combat messages (heroes4.exe 0x566b60 / 0x5661f0): one or two lines of text, each
    /// with an icon of layers.icons.combat_messages to its right; anchored at the stack's position
    /// (its footprint's top corner, raised by the actor's height), drifting up-left 1 px per 100 ms
    /// for 300000 / animation speed ms; the text in the stack owner's player colour with a black halo.
    struct Floater {
        var lines: [(text: String, icon: String?)]
        var world: (Float, Float)      // lattice point of the anchor
        var height: Float              // scene px above it
        var since: Date
        var colour: (UInt8, UInt8, UInt8)
    }
    var floaters: [Floater] = []
    /// The options gating the numbers (show_damage_numbers, show_death_numbers, show_other_numbers; on by default).
    var showDamageNumbers = true, showDeathNumbers = true, showOtherNumbers = true
    /// "Show combat grid" (show_grid) and "Show movement shading" (show_movement_grid).
    var showGrid = ProcessInfo.processInfo.environment["H4NOGRID"] == nil
    /// How long a floating message lives: 300000 / animation speed ms (2 s at 150).
    var floaterLife: Double { 300.0 / Double(max(1, animationSpeed)) }
    /// The player colour index of each side's owner (0 red ... 5 teal, 6 gray for neutral).
    func sideColour(_ side: Int) -> Int {
        if side == 0 { return hero.map { max(0, min(5, $0.owner)) } ?? 0 }
        if let e = enemy { return max(0, min(5, e.owner)) }
        return 6
    }
    /// Floating text colours by player colour (table 0xaa6d44).
    static let messageColours: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (32, 62, 255), (100, 255, 48), (255, 160, 33), (255, 39, 255), (3, 217, 255), (217, 217, 217)]
    static let labelColourNames = ["red", "blue", "green", "orange", "purple", "teal", "gray"]
    /// A message about a stack (0x566b60): anchored at its position, in its owner's colour.
    func floatOver(_ u: Battle.Unit, _ lines: [(String, String?)], since: Date) {
        guard !lines.isEmpty else { return }
        let p = unitPos[u.id] ?? shownPos[u.id] ?? (Float(u.x), Float(u.y))
        floaters.append(Floater(lines: lines, world: p, height: actorHeight(u.actor), since: since, colour: CombatScreen.messageColours[sideColour(u.side)]))
    }
    /// The message pair of a blow (heroes4.exe 0x5661f0): "-%i" with the broken heart for the damage
    /// and, when any die, "-%i" with the skull under it, right-aligned.
    func blowMessages(damage: Int, killed: Int, unit u: Battle.Unit, since: Date) {
        guard damage > 0 || killed > 0 else { return }
        var lines: [(String, String?)] = []
        if showDamageNumbers { lines.append(("-\(damage)", "damage")) }
        if killed > 0, showDeathNumbers { lines.append(("-\(killed)", "Death")) }
        floatOver(u, lines, since: since)
    }
    /// The actor's height (combat_actor byte 3: squire 96, titan 140), scene px.
    func actorHeight(_ name: String) -> Float { Float(actor(name)?.height ?? 96) }

    /// The panel's action message (0x5d47c0 / 0x6065b0): one line at a time about one stack, shown
    /// for ms x 100 / animation speed (Defend and Wait post 1500 ms); while it shows, the panel's
    /// three icons and numbers give way to it and the ring shows its stack.
    var actionMessage: (unit: Int, text: String, until: Date)?
    func postAction(_ unit: Int, _ key: String, _ fallback: String, now: Date, ms: Double = 1500, replacing: [String: String] = [:]) {
        var t = strings[key] ?? fallback
        for (k, v) in replacing { t = t.replacingOccurrences(of: k, with: v) }
        actionMessage = (unit, t, now.addingTimeInterval(ms / 10 / Double(max(1, animationSpeed))))
    }
    /// The last blow of the action playing (a blow back at its striker is a retaliation).
    var lastBlow: (attacker: Int, target: Int)?

    /// Each stack's attack mode (+0xb6c): 0 shoot, 1 strike and return, 2 melee, 3 cast spell, 4 move.
    var attackMode: [Int: Int] = [:]
    /// The mode button shown for a stack (0x5655e0): its mode, spell mode only for a caster, shoot
    /// only when it can shoot now (else melee).
    func shownMode(_ u: Battle.Unit) -> Int {
        guard let b = battle else { return 2 }
        var k = attackMode[u.id] ?? 0
        if k == 3, b.castable(u).isEmpty { k = 0 }
        if k == 0, !b.canShoot(u) { k = 2 }
        return k
    }
    /// The modes a stack can choose from, in the menu's order.
    func modes(_ u: Battle.Unit) -> [Int] {
        guard let b = battle else { return [2] }
        var out: [Int] = []
        if u.stats.shooter { out.append(0) }
        if u.stats.has("strike_and_return") { out.append(1) }
        out.append(2)
        if !b.castable(u).isEmpty { out.append(3) }
        out.append(4)
        _ = b
        return out
    }
    /// Auto combat (the toggle): the player's side acts on its own while it is on.
    var autoCombat = false
    /// The battle was ended by surrender (the player's) and what it cost.
    var surrendered = false

    /// Idle creatures stand in their "wait" loop; the battle's idle timer (heroes4.exe 0x563870)
    /// makes one waiting creature at random play "fidget", then waits the fidget's length plus
    /// 1000 + rand % 2001 ms (500 ms when no creature is waiting). Moving the pointer onto a
    /// waiting creature also makes it fidget (0x571b1b).
    var nextFidget = Date()
    var fidgeting: Int?
    var hovered: Int?
    /// The unit whose creature window is open (right click), if any.
    var info: Int?
    /// The creature window's curse and blessing scrollbar positions.
    var infoPages = (0, 0)
    /// The town a retreating hero goes to.
    var retreatTown: Int?
    /// When the results dialog appeared (its movie runs from then).
    var resultShownAt: Date?
    var sound: GameSound?
    var idleRandom = GameRandom(seed: 0x563870)
    var strings: [String: String] = [:]
    /// An animation.spell file (spell_visuals_spec 2.1): u16 image count, the images, then the trailer
    /// u16 version, u16 frame time (ms at 100 % speed), u32 n, n x u32 image order (0: every image in
    /// turn), u8 use anchor x, u8 use anchor y, i32 anchor x, i32 anchor y (canvas coordinates).
    struct EffectInfo {
        let sprite: Sprite
        let frameTime: Int
        let order: [Int]
        let useX: Bool, useY: Bool
        let anchor: (Int, Int)
    }
    var effectFiles: [String: EffectInfo?] = [:]
    /// animation.spell.<name> by the keyword only, whatever its case, aliases followed (no fallback).
    func effectInfo(_ name: String) -> EffectInfo? {
        let key = name.lowercased()
        if let e = effectFiles[key] { return e }
        var info: EffectInfo? = nil
        if let d = payload("animation.spell.\(name).h4d"), let sp = try? Sprite(data: d), !sp.images.isEmpty {
            info = CombatScreen.effectTrailer(d, sprite: sp)
        }
        effectFiles[key] = .some(info)
        return info
    }
    static func effectTrailer(_ d: Data, sprite sp: Sprite) -> EffectInfo {
        let b = [UInt8](d)
        var p = sp.trailerOffset
        func u8() -> Int { guard p < b.count else { return 0 }; p += 1; return Int(b[p - 1]) }
        func u16() -> Int { let v = u8(); return v | u8() << 8 }
        func i32() -> Int { let v = UInt32(u16()) | UInt32(u16()) << 16; return Int(Int32(bitPattern: v)) }
        let version = u16()
        var ms = 0, order: [Int] = [], fx = false, fy = false, ax = 0, ay = 0
        if version <= 10 {
            ms = u16()
            let n = i32()
            if n > 0, n < 4096 { order = (0..<n).map { _ in i32() } }
            if version >= 2 { fx = u8() != 0; fy = u8() != 0; ax = i32(); ay = i32() }
        }
        let count = sp.images.count
        order = order.filter { $0 >= 0 && $0 < count }
        if order.isEmpty { order = Array(0..<count) }
        return EffectInfo(sprite: sp, frameTime: ms, order: order, useX: fx, useY: fy, anchor: (ax, ay))
    }
    /// How long an effect window runs (0x51ef50): every step of its order at frame time x 100 / animation speed ms.
    func effectDuration(_ e: EffectInfo) -> Double { Double(e.order.count * effectStep(e)) / 1000 }
    /// ms a step of an effect shows (integer division, as 0x5754b0 passes it).
    func effectStep(_ e: EffectInfo, speed: Int? = nil) -> Int { max(1, e.frameTime * 100 / max(1, speed ?? animationSpeed)) }

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
    /// Other layer files (layers.<name>), cached.
    var layerFiles: [String: LayerFile] = [:]
    func layers(_ name: String) -> LayerFile? {
        if layerFiles[name] == nil, let d = payload("layers.\(name).h4d") { layerFiles[name] = try? LayerFile(data: d) }
        return layerFiles[name]
    }
    /// The hero a hero stack stands for (its army's heroes are matched by keyword).
    func heroFor(_ u: Battle.Unit) -> Hero? {
        guard u.stats.isHero else { return nil }
        let pool = u.side == 0 ? (hero.map { [$0] + $0.companions } ?? []) : (enemy.map { [$0] + $0.companions } ?? [])
        return pool.first { $0.keyword == u.keyword } ?? (u.side == 0 ? hero : enemy)
    }

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

    /// A hero's army as fighters: its heroes (with their spell books) in the first slots, then the
    /// stacks with the heroes' skill bonuses and morale.
    /// A creature's combat model: combat_actor.<name>, else by its keyword (the devil's is "archdevil").
    func actorName(_ cd: CreatureDef) -> String { actor(cd.name) != nil ? cd.name : cd.keyword }
    func armyFighters(game g: GameState, _ h: Hero, tables t: RuleTables) -> [Battle.Fighter] {
        let heroes = [h] + h.companions
        let army: [(alignment: String, undead: Bool)] = heroes.map { ($0.alignment, false) } + h.army.compactMap { st in t.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        let bonus = ArmyBonuses(heroes: heroes)
        var out: [Battle.Fighter] = []
        for (k, hh) in heroes.enumerated() {
            var st = g.heroCombatant(hh)
            st.morale = Battle.armyMorale(own: hh.alignment, army: army)
            let model = "hero.\(hh.alignment)_fighter_male", fallback = "hero.\(h.alignment)_fighter_male"
            let book = Caster(hero: hh, spellPoints: g.spellPoints(hh))
            let itemMove = hh.artifactEffects.filter { $0.type == 0x05 && ($0.target == 0 || $0.target == 5) }.reduce(0) { $0 + $1.amount } / 300
            out.append(Battle.Fighter(stats: st, keyword: hh.keyword, actor: actor(model) != nil ? model : fallback, size: actor(model)?.size ?? actor(fallback)?.size ?? 4, move: max(1, 24 + itemMove), shots: st.shots, slot: k, caster: book))
        }
        for (k, s) in h.army.enumerated() {
            guard let cd = t.creature(s.creature) else { continue }
            var st = Combatant(creature: cd, count: s.count)
            st.morale = Battle.armyMorale(own: cd.alignment, army: army) + g.objectMorale(h, alignment: cd.alignment, undeadOrMechanical: st.has("undead") || st.has("mechanical"))
            bonus.apply(&st)
            out.append(Battle.Fighter(stats: st, keyword: cd.keyword, actor: actorName(cd), size: actor(actorName(cd))?.size ?? 4, move: cd.move + bonus.moveThirds, shots: cd.shots, slot: k + heroes.count))
        }
        return out
    }
    /// A battle between the player's army (attacking, bottom left) and an enemy hero's army.
    func start(game g: GameState, hero h: Hero, enemy e: Hero, terrain: UInt8, variant: UInt8 = 0) {
        guard let t = g.tables else { return }
        hero = h; enemy = e; placed = nil; siegeTown = nil
        let seed = g.day * 977 + h.x * 31 + h.y
        fieldName = "generated.\(terrain).\(variant).\(seed)"
        field = generatedField(terrain: terrain, variant: variant, seed: seed, tables: t)
        Combatant.abilityKeywords = t.abilityKeywords
        guard let f = field else { return }
        strings = t.strings
        battle = Battle(field: f, attackers: armyFighters(game: g, h, tables: t), defenders: armyFighters(game: g, e, tables: t), seed: seed)
        var pieces = (1...6).map { "combat.music.\($0)" }
        let r = seed % 6; pieces = Array(pieces[r...] + pieces[..<r])
        sound?.playMusic(first: "combat.start", then: pieces)
        resetPlayback(); resultShownAt = nil; result = nil; showResults = false; floaters = []; actionMessage = nil; attackMode = [:]; autoCombat = false; surrendered = false
        pump()
    }

    /// A siege (heroes4.exe 0x560b50 / 0x62d930): the town's walls from castle.<alignment>.<fort|
    /// citadel|castle>, its garrison deployed in formation 3 (4 with towers), the attacker as in the field.
    func startSiege(game g: GameState, hero h: Hero, town i: Int, terrain: UInt8, variant: UInt8 = 0) {
        guard let t = g.tables else { return }
        let town = g.towns[i]
        hero = h; enemy = nil; placed = nil; siegeTown = i
        let seed = g.day * 977 + h.x * 31 + h.y
        fieldName = "siege.\(i).\(seed)"
        field = generatedField(terrain: terrain, variant: variant, seed: seed, tables: t)
        let level = town.castleLevel
        if level > 0, var f = field {
            let names = ["fort", "citadel", "castle"]
            if let d = payload("castle.\(town.alignment).\(names[level - 1]).h4d") {
                let pieces = Battlefield.castlePieces(d) { [weak self] name in self?.payload(name) }
                f.addCastle(pieces, level: level)
                field = f
            }
        }
        Combatant.abilityKeywords = t.abilityKeywords
        guard let f = field else { return }
        strings = t.strings
        let army: [(alignment: String, undead: Bool)] = town.garrison.compactMap { st in t.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        var defenders: [Battle.Fighter] = []
        for (k, st) in town.garrison.enumerated() {
            guard let cd = t.creature(st.creature) else { continue }
            var c = Combatant(creature: cd, count: st.count)
            c.morale = Battle.armyMorale(own: cd.alignment, army: army)
            defenders.append(Battle.Fighter(stats: c, keyword: cd.keyword, actor: actorName(cd), size: actor(actorName(cd))?.size ?? 4, move: cd.move, shots: cd.shots, slot: k))
        }
        let form: Battle.Formation = level == 3 ? .castle : level > 0 ? .siege : .loose
        battle = Battle(field: f, attackers: armyFighters(game: g, h, tables: t), defenders: defenders, seed: seed, formations: (.loose, form))
        var pieces = (1...6).map { "combat.music.\($0)" }
        let r = seed % 6; pieces = Array(pieces[r...] + pieces[..<r])
        sound?.playMusic(first: "combat.start", then: pieces)
        resetPlayback(); resultShownAt = nil; result = nil; showResults = false; floaters = []; actionMessage = nil; attackMode = [:]; autoCombat = false; surrendered = false
        pump()
    }

    /// Set up a battle between a hero's army and a wandering stack.
    func start(game g: GameState, hero h: Hero, monsterAt i: Int, _ p: MapScene.Placed, terrain: UInt8, variant: UInt8 = 0) {
        guard let t = g.tables, let c = t.creature(g.monsters[i].creature) else { return }
        hero = h; monsterIndex = i; placed = p; enemy = nil; siegeTown = nil
        let seed = g.day * 977 + h.x * 31 + h.y
        fieldName = "generated.\(terrain).\(variant).\(seed)"
        field = generatedField(terrain: terrain, variant: variant, seed: seed, tables: t)
        Combatant.abilityKeywords = t.abilityKeywords
        guard let f = field else { return }
        let classActor = "hero.\(h.alignment)_fighter_male"
        // morale from each army's alignments (heroes4.exe 0x640310)
        let heroArmy: [(alignment: String, undead: Bool)] = ([h] + h.companions).map { ($0.alignment, false) } + h.army.compactMap { st in t.creature(st.creature).map { ($0.alignment, Combatant(creature: $0, count: 1).has("undead")) } }
        var monsterArmy: [(alignment: String, undead: Bool)] = [(c.alignment, Combatant(creature: c, count: 1).has("undead"))]
        for e in g.monsters[i].extra { if let ed = t.creature(e.creature) { monsterArmy.append((ed.alignment, Combatant(creature: ed, count: 1).has("undead"))) } }
        let heroes = [h] + h.companions
        let bonus = ArmyBonuses(heroes: heroes)
        func fighter(_ cd: CreatureDef, _ n: Int, army: [(alignment: String, undead: Bool)], bonus: ArmyBonuses? = nil) -> Battle.Fighter {
            var st = Combatant(creature: cd, count: n)
            st.morale = Battle.armyMorale(own: cd.alignment, army: army)
            if bonus != nil { st.morale += g.objectMorale(h, alignment: cd.alignment, undeadOrMechanical: st.has("undead") || st.has("mechanical")) }
            bonus?.apply(&st)
            return Battle.Fighter(stats: st, keyword: cd.keyword, actor: actorName(cd), size: actor(actorName(cd))?.size ?? 4, move: cd.move + (bonus?.moveThirds ?? 0), shots: cd.shots)
        }
        strings = t.strings
        let attackers = armyFighters(game: g, h, tables: t)
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
        // combat.start, then the six combat pieces in turn (heroes4.exe 0x62a720 / 0x62a830)
        var pieces = (1...6).map { "combat.music.\($0)" }
        let r = seed % 6; pieces = Array(pieces[r...] + pieces[..<r])
        sound?.playMusic(first: "combat.start", then: pieces)
        resetPlayback(); resultShownAt = nil; result = nil; showResults = false; floaters = []; actionMessage = nil; attackMode = [:]; autoCombat = false; surrendered = false
        pump()
    }

    /// A test battle (the snapshot hooks): the hero's army against stacks "creature:n,...", on grass.
    func startTest(game g: GameState, hero h: Hero, defenders spec: [(String, Int)], seed: Int = 1) {
        guard let t = g.tables else { return }
        hero = h; enemy = nil; placed = nil; siegeTown = nil
        fieldName = "test.\(seed)"
        field = generatedField(terrain: 1, variant: 0, seed: seed, tables: t)
        Combatant.abilityKeywords = t.abilityKeywords
        guard let f = field else { return }
        strings = t.strings
        var defenders: [Battle.Fighter] = []
        for (k, (name, n)) in spec.enumerated() {
            guard let cd = t.creature(name) else { continue }
            defenders.append(Battle.Fighter(stats: Combatant(creature: cd, count: n), keyword: cd.keyword, actor: actorName(cd), size: actor(actorName(cd))?.size ?? 4, move: cd.move, shots: cd.shots, slot: k))
        }
        battle = Battle(field: f, attackers: armyFighters(game: g, h, tables: t), defenders: defenders, seed: seed)
        resetPlayback(); resultShownAt = nil; result = nil; showResults = false; floaters = []; actionMessage = nil; attackMode = [:]; autoCombat = false; surrendered = false
    }

    /// Pull new events from the battle and let the defender's side act on its own.
    func pump() {
        guard let b = battle else { return }
        take(b.takeEvents())
        if holds == 0, queue.isEmpty, b.finished == nil, let u = b.current, u.side == 1 || u.hypnotized || autoCombat { b.autoAct(); take(b.takeEvents()) }
    }
    /// Forget everything playing (a new battle).
    func resetPlayback() {
        queue = []; timers = []; missiles = []; waitingOnUnit = [:]; windows = []; windowBusy = []; windowWaiting = [:]
        fades = [:]; alphaLevel = [:]; tints = [:]; slides = [:]; fieldActors = []; moving = [:]; hidden = []
        unitPos = [:]; unitState = [:]; dead = []; dying = []; pendingDeaths = []; shownPos = [:]; shownCount = [:]; lastBlow = nil; acting = nil
    }

    var busy: Bool { holds > 0 || !queue.isEmpty }
    /// The unit whose action is playing (the screen shows it as the active one meanwhile).
    var acting: Int?
    /// The unit the screen shows as active: the one acting while its action plays, then the battle's.
    var shownCurrent: Int? { busy ? acting : battle?.current?.id }

    /// What the screen shows while the queue plays: the battle has already resolved the whole
    /// action, so positions, stack sizes and deaths follow the events as they are played.
    var shownPos: [Int: (Float, Float)] = [:]
    var shownCount: [Int: Int] = [:]
    var dying: Set<Int> = []
    /// Deaths queued but not played yet: those units still stand.
    var pendingDeaths: Set<Int> = []
    func shownAlive(_ u: Battle.Unit) -> Bool { !hidden.contains(u.id) && !dying.contains(u.id) && !dead.contains(u.id) && (u.alive || pendingDeaths.contains(u.id)) }
    func shownCentre(_ u: Battle.Unit) -> (Float, Float) {
        let p = unitPos[u.id] ?? shownPos[u.id] ?? (Float(u.x), Float(u.y))
        return (p.0 + Float(u.size) / 2, p.1 + Float(u.size) / 2)
    }

    /// The move being played: its length and the part each phase covers (cells) and lasts (s).
    struct Move { var length, preDist, postDist: Float; var preTime, walkTime, postTime: Double }
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
    func fidget(_ id: Int, now: Date) { unitState[id] = UnitAnim(state: "fidget", since: now, once: true) }
    /// The renderer calls this when a one-off idle animation has played out.
    func idleDone(_ id: Int, now: Date) {
        if unitState[id]?.state == "fidget" { unitState[id] = nil }
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
