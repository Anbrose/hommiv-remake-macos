import Foundation

/// A saved game (our own format, JSON in a .h4s file -- not the original's): the scenario it was
/// started from and everything that has changed since. Loading starts the scenario afresh (its
/// start is deterministic) and puts this state back over it.
public struct SaveGame: Codable {
    public var version = 1
    public var mapPath: String
    public var savedAt = Date()
    public var day: Int
    public var resources: [String: Int]
    public var heroes: [HeroState]
    public var towns: [TownState]
    public var mines: [CellFlag]
    public var dwellings: [CellCount]
    public var monsters: [MonsterState]
    public var removed: [MapScene.SavedObject]
    /// Objects moved on the map (wandering stacks that walked up to a hero), in order.
    public var moved: [MapScene.MovedObject]? = nil
    public var scripts: ScriptSave
    public var outcome: Bool?
    public var victoryDays: Int?
    /// Per map level (saves from before the underground: nil, the surface's are `removed`/`moved`).
    public var removedByLevel: [[MapScene.SavedObject]]? = nil
    public var movedByLevel: [[MapScene.MovedObject]]? = nil
    public var level: Int? = nil
    public var objectStates: [String: ObjectState]? = nil
    public var usedArtifacts: [Int]? = nil

    public struct Stack: Codable { public var creature: String; public var count: Int }
    public struct Cell: Codable { public var x: Int, y: Int }
    public struct HeroState: Codable {
        public var actor, name, keyword, alignment: String
        public var army: [Stack]
        public var skills: [String: Int]
        public var experience: Int
        public var home: Cell
        public var x, y: Int
        public var facing: String
        public var movement, maxMovement: Float
        public var plan: [Cell]
        public var target: Cell?, targetName: String?
        // (added with the hero system; absent in older saves)
        public var level: Int?, heroClass: Int?, lastCombatOffer: Int?
        public var equipped: [Int?]?, backpack: [Int]?
        public var companions: [HeroState]?
        public var z: Int?
        public var bonuses: [Int]?          // attack, defense, speed, spell points, dream teachers, spell points now (-1 full), mana today
        public var visitedObjects: [String]?, fountainEffects: [String]?, timedEffects: [String: Int]?
        public var armyLuck: [String: Int]?, armyMorale: [String: Int]?, templeAlignment: String?
        public var spells: [Int]?
    }
    public struct TownState: Codable {
        public var x, y: Int
        public var name: String
        public var owned: Bool, owner: Int?
        public var buildings: [String]
        public var available: [String: Int]
        public var builtToday: Bool
        public var guildSpells: [[Int]]? = nil
    }
    public struct CellFlag: Codable { public var x, y: Int; public var on: Bool }
    public struct CellCount: Codable { public var x, y: Int; public var count: Int; public var owned: Bool? = nil; public var fourteenths: Int? = nil }
    public struct MonsterState: Codable {
        public var x, y: Int, name, creature: String
        public var count: Int
        public var extra: [Stack]
        public var z: Int? = nil
    }
    public struct ScriptSave: Codable {
        public var numbers: [String: Int], flags: [String: Bool], messages: [String]
        public var victoryText: String?, lossText: String?, standardVictoryOn: Bool
        public var mapEventsEnabled: [Bool]
        public var townEventsEnabled: [String: [Bool]]
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
    public static func read(_ url: URL) throws -> SaveGame {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(SaveGame.self, from: Data(contentsOf: url))
    }
}

extension GameState {
    /// Everything that changed since the scenario started.
    public func snapshot(mapPath: String) -> SaveGame {
        SaveGame(mapPath: mapPath, day: day, resources: resources,
                 heroes: heroes.map { h in
                     SaveGame.state(of: h)
                 },
                 towns: towns.map { .init(x: $0.x, y: $0.y, name: $0.name, owned: $0.owned, owner: $0.owner, buildings: Array($0.buildings).sorted(),
                                          available: $0.available, builtToday: $0.builtToday, guildSpells: $0.guildSpells) },
                 mines: mines.map { .init(x: $0.x, y: $0.y, on: $0.owned) },
                 dwellings: dwellings.map { .init(x: $0.x, y: $0.y, count: $0.available, owned: $0.owned, fourteenths: $0.fourteenths) },
                 monsters: monsters.map { .init(x: $0.x, y: $0.y, name: $0.name, creature: $0.creature, count: $0.count,
                                                extra: $0.extra.map { .init(creature: $0.creature, count: $0.count) }, z: $0.z) },
                 removed: scene.removed, moved: scene.moved,
                 scripts: .init(numbers: scripts.numbers, flags: scripts.flags, messages: scripts.messages,
                                victoryText: scripts.victoryText, lossText: scripts.lossText, standardVictoryOn: scripts.standardVictoryOn,
                                mapEventsEnabled: scripts.mapEvents.map { $0.enabled },
                                townEventsEnabled: Dictionary(uniqueKeysWithValues: scripts.townEvents.map { ("\($0.key)", $0.value.map { $0.enabled }) })),
                 outcome: outcome, victoryDays: victoryDays,
                 removedByLevel: scenes.map { $0.removed }, movedByLevel: scenes.map { $0.moved }, level: level,
                 objectStates: objectStates, usedArtifacts: Array(usedArtifacts).sorted())
    }

    /// Put a saved game's state over this freshly started scenario.
    public func restore(_ s: SaveGame) {
        day = s.day
        resources = s.resources
        let playing = level
        for l in scenes.indices {
            level = l
            let moved = s.movedByLevel.map { l < $0.count ? $0[l] : [] } ?? (l == 0 ? s.moved ?? [] : [])
            let removed = s.removedByLevel.map { l < $0.count ? $0[l] : [] } ?? (l == 0 ? s.removed : [])
            for m in moved {
                if let p = scene.placed.first(where: { $0.cellX == m.fromX && $0.cellY == m.fromY && $0.name == m.name }) {
                    passability.free(m.fromX, m.fromY); passability.block(m.toX, m.toY)
                    scene.relocate(p, toX: m.toX, y: m.toY)
                }
            }
            scene.removeAll(removed)
            for o in removed { passability.free(o.x, o.y) }
        }
        level = s.level ?? playing
        heroes = s.heroes.map { SaveGame.hero(from: $0) }
        for t in s.towns {
            guard let i = towns.firstIndex(where: { $0.x == t.x && $0.y == t.y }) else { continue }
            towns[i].name = t.name; towns[i].owned = t.owned; towns[i].owner = t.owner
            towns[i].buildings = Set(t.buildings); towns[i].available = t.available; towns[i].builtToday = t.builtToday
            if let gs = t.guildSpells { towns[i].guildSpells = gs }
        }
        for m in s.mines { if let i = mines.firstIndex(where: { $0.x == m.x && $0.y == m.y }) { mines[i].owned = m.on } }
        for d in s.dwellings { if let i = dwellings.firstIndex(where: { $0.x == d.x && $0.y == d.y }) { dwellings[i].available = d.count; dwellings[i].owned = d.owned ?? false; dwellings[i].fourteenths = d.fourteenths ?? 0 } }
        // the monsters as saved: the beaten ones are gone (their objects are in `removed`), the rest keep their size
        monsters = s.monsters.map { st in
            var m = Monster(x: st.x, y: st.y, name: st.name, creature: st.creature, count: st.count, extra: st.extra.map { ($0.creature, $0.count) })
            m.z = st.z ?? 0
            return m
        }
        scripts.numbers = s.scripts.numbers; scripts.flags = s.scripts.flags; scripts.messages = s.scripts.messages
        scripts.victoryText = s.scripts.victoryText; scripts.lossText = s.scripts.lossText
        scripts.standardVictoryOn = s.scripts.standardVictoryOn
        for (i, e) in s.scripts.mapEventsEnabled.enumerated() where i < scripts.mapEvents.count { scripts.mapEvents[i].enabled = e }
        for (k, list) in s.scripts.townEventsEnabled {
            guard let t = Int(k), var evs = scripts.townEvents[t] else { continue }
            for (i, e) in list.enumerated() where i < evs.count { evs[i].enabled = e }
            scripts.townEvents[t] = evs
        }
        outcome = s.outcome; victoryDays = s.victoryDays
        if let o = s.objectStates { objectStates = o }
        if let u = s.usedArtifacts { usedArtifacts = Set(u) }
    }
}

extension SaveGame {
    static func state(of h: Hero) -> HeroState {
        var st = HeroState(actor: h.actor, name: h.name, keyword: h.keyword, alignment: h.alignment,
                           army: h.army.map { .init(creature: $0.creature, count: $0.count) }, skills: h.skills,
                           experience: h.experience, home: .init(x: h.home.x, y: h.home.y), x: h.x, y: h.y, facing: h.facing,
                           movement: h.movement, maxMovement: h.maxMovement,
                           plan: (h.path.isEmpty ? h.plan : h.path).map { .init(x: $0.x, y: $0.y) },
                           target: h.target.map { .init(x: $0.x, y: $0.y) }, targetName: h.target?.name)
        st.level = h.level; st.heroClass = h.heroClass; st.lastCombatOffer = h.lastCombatOffer
        st.equipped = h.equipped; st.backpack = h.backpack
        st.companions = h.companions.map { state(of: $0) }
        st.z = h.z
        st.bonuses = [h.attackBonus, h.defenseBonus, h.speedBonus, h.spellPointBonus, h.dreamTeachers, h.spellPoints ?? -1, h.manaRestoredToday]
        st.visitedObjects = Array(h.visitedObjects).sorted(); st.fountainEffects = Array(h.fountainEffects).sorted(); st.timedEffects = h.timedEffects
        st.armyLuck = h.armyLuck; st.armyMorale = h.armyMorale; st.templeAlignment = h.templeAlignment
        st.spells = Array(h.spells).sorted()
        return st
    }
    static func hero(from st: HeroState) -> Hero {
        let h = Hero(actor: st.actor, x: st.x, y: st.y, movement: st.maxMovement)
        h.name = st.name; h.keyword = st.keyword; h.alignment = st.alignment
        h.army = st.army.map { Hero.Stack(creature: $0.creature, count: $0.count) }
        h.skills = st.skills; h.experience = st.experience; h.home = (st.home.x, st.home.y)
        h.level = st.level ?? Hero.level(for: st.experience)
        h.heroClass = st.heroClass ?? -1; h.lastCombatOffer = st.lastCombatOffer ?? 0
        if let e = st.equipped { h.equipped = e }
        h.backpack = st.backpack ?? []
        h.companions = (st.companions ?? []).map { hero(from: $0) }
        h.z = st.z ?? 0
        if let b = st.bonuses, b.count >= 7 {
            h.attackBonus = b[0]; h.defenseBonus = b[1]; h.speedBonus = b[2]; h.spellPointBonus = b[3]; h.dreamTeachers = b[4]
            h.spellPoints = b[5] < 0 ? nil : b[5]; h.manaRestoredToday = b[6]
        }
        h.visitedObjects = Set(st.visitedObjects ?? []); h.fountainEffects = Set(st.fountainEffects ?? []); h.timedEffects = st.timedEffects ?? [:]
        h.armyLuck = st.armyLuck ?? [:]; h.armyMorale = st.armyMorale ?? [:]; h.templeAlignment = st.templeAlignment
        h.spells = Set(st.spells ?? [])
        h.facing = st.facing; h.movement = st.movement; h.maxMovement = st.maxMovement
        h.plan = st.plan.map { ($0.x, $0.y) }
        if let t = st.target, let n = st.targetName { h.target = (t.x, t.y, n) }
        return h
    }
}
