import Foundation

/// A rule table from text.h4r (format: tools/h4table.py): rows of strings, the first row
/// usually naming the columns.
public struct RuleTable {
    public let header: [String]
    public let rows: [[String]]

    public init(data d: Data) {
        var r = ByteReader(d)
        _ = r.u32()   // row count
        let a = r.peekU16(at: 4), c = r.peekU16(at: 6)
        if c == 0, a < 256 {   // u32 column count + (columns - 1) group labels
            r.pos = 8
            for _ in 0..<max(0, Int(a) - 1) { _ = r.string16() }
        }
        var rows: [[String]] = []
        while r.remaining >= 2 {
            let n = Int(r.u16())
            var row: [String] = []
            for _ in 0..<n { guard r.remaining >= 2 else { break }; row.append(r.string16()) }
            rows.append(row)
        }
        if let first = rows.first, first.contains("Keyword") { header = first; rows.removeFirst() } else { header = [] }
        self.rows = rows
    }

    public func column(_ name: String) -> Int? { header.firstIndex(of: name) }
    public func value(_ row: [String], _ name: String) -> String {
        guard let i = column(name), i < row.count else { return "" }
        return row[i]
    }
}

public struct CreatureDef {
    public let keyword: String, name: String, plural: String, level: Int, alignment: String
    public let hitPoints: Int, damageLow: Int, damageHigh: Int, attack: Int, defense: Int, move: Int, speed: Int, growth: Int, gold: Int
    public let experience: Int
    /// 0 for the original creatures, 1 and 2 below the table's "Expansion N Creatures below" rows.
    public var expansion = 0
    public let shots: Int, spellPoints: Int
    public let shortHelp: String, longHelp: String   // "Flying, Spellcaster" and the paragraph about it
}

public struct HeroDef {
    public let keyword: String, name: String, sex: String, heroClass: String
}

/// The game's rule tables: creatures, heroes, random town names, mine incomes.
public final class RuleTables {
    public private(set) var creatures: [CreatureDef]
    public let heroes: [HeroDef]
    /// "Life_Town" -> ["Angel Point", ...]
    public let names: [String: [String]]
    /// dwelling sprite name (lower-cased, e.g. "squire's guild") -> creature keyword ("squire")
    public let dwellingCreature: [String: String]

    public struct BuildingDef {
        public let keyword: String, name: String, help: String
        public let cost: [String: Int]
        /// creature keyword for dwellings ("Generates Squires."), else nil
        public let creature: String?
    }
    /// buildings per town section: "Life Town" -> [BuildingDef] (in the table's order)
    public let buildings: [String: [BuildingDef]]
    /// The Adventure Object texts: "major|minor|keyword" (all lower-cased) -> text, e.g.
    /// "mine|sawmill|name" -> "Sawmill", "mine|sawmill|help" -> "This Sawmill earns 2 wood per day...".
    public let objectTexts: [String: String]
    /// Lower-cased object name -> (major, minor), to find the rows of an object known only by its sprite.
    public let objectNames: [String: (String, String)]
    public struct ArtifactDef { public let keyword: String, name: String, article: String, slot: String, level: String, help: String }
    public let artifacts: [String: ArtifactDef]   // by keyword
    /// Creature ability display names ("Normal Melee", "No Obstacle Penalty") -> the game's
    /// keywords ("normal_melee", "siege_machine"), from table.creature_abilities.
    public let abilityKeywords: [String: String]
    /// Ability keyword (lower-cased) -> its display name and help text (table.creature_abilities).
    public let abilityInfo: [String: (name: String, help: String)]
    /// table.combat_obstacles: how often an obstacle group appears on a terrain, and how often
    /// a group is placed next to another; frequencies usually/common/seldom/rare/never.
    public let obstacleFrequency: [String: [String: String]]   // terrain -> group -> frequency
    public let obstacleAdjacency: [String: [String: String]]   // group -> group -> frequency
    /// The general string table (strings.Text.h4d): key -> text, e.g. "grass_1" -> "Grass, Dry",
    /// "grass_1.description" -> "Dry Grass terrain has a movement cost of 1 per tile...".
    public let strings: [String: String]

    /// The strings table's name and description of a terrain cell (type ids as in the map
    /// file: 0 water, 1 grass, 2 rough, 3 swamp, 4 volcanic, 5 snow, 6 sand, 7 dirt,
    /// 8 subterranean, 9 water river, 10 lava river, 11 ice river, 12..18 magic terrains).
    public func terrainText(type: UInt8, variant: UInt8) -> (name: String, description: String)? {
        let key: String
        switch type {
        case 0...8:
            let names = ["water", "grass", "rough", "swamp", "volcanic", "snow", "sand", "dirt", "subterranean"]
            key = "\(names[Int(type)])_\(min(Int(variant), 1) + 1)"
        case 9: key = "water_river"
        case 10: key = "lava_river"
        case 11: key = "ice_river"
        case 12, 18: key = "all.special"
        case 13: key = "life.special"
        case 14: key = "order.special"
        case 15: key = "death.special"
        case 16: key = "chaos.special"
        case 17: key = "nature.special"
        default: return nil
        }
        guard let name = strings[key] else { return nil }
        return (name, strings["\(key).description"] ?? "")
    }
    /// The strings table's name and description of a road type (1 stone, 2 dirt, 3 cobble).
    public func roadText(_ type: UInt8) -> (name: String, description: String)? {
        let key = ["", "Road_1", "Road_2", "road_3"][Int(min(type, 3))]
        guard let name = strings[key] else { return nil }
        return (name, strings["\(key).description"] ?? "")
    }

    /// A text of an adventure object type, the minor type's row first, then the major type's generic one.
    public func objectText(_ major: String, _ minor: String, _ key: String) -> String? {
        objectTexts["\(major.lowercased())|\(minor.lowercased())|\(key.lowercased())"] ?? objectTexts["\(major.lowercased())||\(key.lowercased())"]
    }
    /// Sprites whose names differ from the table's dwelling names.
    static let dwellingAliases: [String: String] = [
        "minotaur's maze": "minotaur", "altar of air": "air elemental", "altar of water": "water elemental", "altar of earth": "earth elemental",
        "altar of fire": "fire elemental", "funeral pyre": "phoenix", "harpy nest": "harpy", "pirates cove": "pirate", "hot_house": "waspwort",
        "crypt": "zombie", "berserker dwelling": "berserker", "homestead": "elf", "wine_keg": "satyr", "pillarofeyes": "beholder",
        "lava tube": "efreet", "embalmers lab": "mummy", "orc camp": "orc", "monestary": "monk", "troglodyte warren": "troglodyte",
    ]
    /// mine keyword -> (resource, amount per day), from the mine help texts
    public static let mineIncome: [String: (String, Int)] = ["Gold": ("Gold", 1000), "Sawmill": ("Wood", 2), "Ore Pit": ("Ore", 2), "ore pit": ("Ore", 2),
                                                            "Crystal": ("Crystal", 1), "Sulfur": ("Sulfur", 1), "Gem": ("Gems", 1), "Alchemists Lab": ("Mercury", 1)]

    public init(archive: H4Archive) throws {
        let cr = RuleTable(data: try archive.payload("table.creatures.h4d"))
        func int(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }
        var exp = 0, expansionOf: [String: Int] = [:]
        for row in cr.rows {
            let k = cr.value(row, "Keyword")
            if k.hasPrefix("Expansion "), let n = Int(k.split(separator: " ")[1]) { exp = n }
            if !cr.value(row, "Level").isEmpty { expansionOf[k] = exp }
        }
        creatures = cr.rows.filter { !cr.value($0, "Level").isEmpty }.map {
            CreatureDef(keyword: cr.value($0, "Keyword"), name: cr.value($0, "Name"), plural: cr.value($0, "Plural Name"), level: int(cr.value($0, "Level")),
                        alignment: cr.value($0, "Alignment").lowercased(), hitPoints: int(cr.value($0, "Hit Points")), damageLow: int(cr.value($0, "Low")),
                        damageHigh: int(cr.value($0, "High")), attack: int(cr.value($0, "Attack")), defense: int(cr.value($0, "Defense")),
                        move: int(cr.value($0, "Move")), speed: int(cr.value($0, "Speed")), growth: int(cr.value($0, "Weekly Growth")), gold: int(cr.value($0, "Gold")),
                        experience: int(cr.value($0, "Experience")), shots: int(cr.value($0, "Shots")), spellPoints: int(cr.value($0, "Spell Points")),
                        shortHelp: cr.value($0, "Short Help Text"), longHelp: cr.value($0, "Long Help Text"))
        }
        for i in creatures.indices { creatures[i].expansion = expansionOf[creatures[i].keyword] ?? 0 }
        let he = RuleTable(data: try archive.payload("table.heroes.h4d"))
        heroes = he.rows.filter { $0.count > 3 && !$0[0].isEmpty }.map { HeroDef(keyword: $0[0], name: $0[1], sex: $0[2].lowercased(), heroClass: $0[3].lowercased()) }
        let rn = RuleTable(data: try archive.payload("table.random_names.h4d"))
        var n: [String: [String]] = [:]
        for row in rn.rows where row.count >= 2 && !row[0].isEmpty { n[row[0], default: []].append(row[1]) }
        names = n
        let ao = RuleTable(data: try archive.payload("table.Adventure Object.h4d"))
        var dc = RuleTables.dwellingAliases
        for row in ao.rows where row.count > 4 && row[0] == "creature_dwelling" && row[3].lowercased() == "name" {
            var kw = row[1].replacingOccurrences(of: "_dwelling", with: "").replacingOccurrences(of: "_", with: " ")
            kw = ["angel": "archangel", "devil": "archdevil", "saytr": "satyr"][kw] ?? kw
            dc[row[4].lowercased()] = kw
        }
        dwellingCreature = dc
        var texts: [String: String] = [:]
        var byName: [String: (String, String)] = [:]
        for row in ao.rows where row.count > 4 && !row[0].isEmpty && !row[3].isEmpty {
            texts["\(row[0].lowercased())|\(row[1].lowercased())|\(row[3].lowercased())"] = row[4]
            if row[3].lowercased() == "name", !row[4].contains("%") { byName[row[4].lowercased()] = (row[0], row[1]) }
        }
        objectTexts = texts
        objectNames = byName
        var arts: [String: ArtifactDef] = [:]
        if let d = try? archive.payload("table.Artifacts.h4d") {
            let at = RuleTable(data: d)
            for row in at.rows where row.count > 7 && !row[0].isEmpty {
                arts[row[0].lowercased()] = ArtifactDef(keyword: row[0], name: at.value(row, "Name"), article: at.value(row, "Name With Article"),
                                                        slot: at.value(row, "Slot"), level: at.value(row, "Level"), help: at.value(row, "Help Text"))
            }
        }
        artifacts = arts
        var ak: [String: String] = [:], info: [String: (name: String, help: String)] = [:]
        if let d = try? archive.payload("table.creature_abilities.h4d") {
            for row in RuleTable(data: d).rows where row.count >= 2 && !row[0].isEmpty {
                ak[row[1].lowercased()] = row[0]
                info[row[0].lowercased()] = (row[1], row.count > 2 ? row[2] : "")
            }
        }
        abilityKeywords = ak
        abilityInfo = info
        var freq: [String: [String: String]] = [:], adj: [String: [String: String]] = [:]
        if let d = try? archive.payload("table.combat_obstacles.h4d") {
            let rows = RuleTable(data: d).rows
            if let head = rows.first {
                let groups = Array(head.dropFirst(2))
                var section = ""
                for row in rows.dropFirst() where row.count > 2 {
                    if !row[0].isEmpty { section = row[0] }
                    let key = row[1]
                    guard !key.isEmpty else { continue }
                    var m: [String: String] = [:]
                    for (i, g) in groups.enumerated() where i + 2 < row.count && !g.isEmpty { m[g] = row[i + 2].lowercased() }
                    if section == "Terrain" { freq[key] = m } else if section == "Adjacent" { adj[key] = m }
                }
            }
        }
        obstacleFrequency = freq; obstacleAdjacency = adj
        var st: [String: String] = [:]
        if let d = try? archive.payload("strings.Text.h4d") {   // u32 rows, rows of u16 n + string16s (key, text, comment)
            var r = ByteReader(d)
            let rows = Int(r.u32())
            for _ in 0..<rows {
                guard r.remaining >= 2 else { break }
                let n = Int(r.u16())
                var row: [String] = []
                for _ in 0..<n { guard r.remaining >= 2 else { break }; row.append(r.string16()) }
                if row.count >= 2, !row[0].isEmpty, st[row[0]] == nil { st[row[0]] = row[1] }
            }
        }
        strings = st
        let bt = RuleTable(data: try archive.payload("table.buildings.h4d"))
        var sections: [String: [BuildingDef]] = [:]
        var section = ""
        let resources = ["Gold", "Wood", "Ore", "Crystal", "Sulfur", "Mercury", "Gems"]
        for row in bt.rows where row.count >= 10 {
            if row[0].isEmpty { section = row[1]; continue }
            var cost: [String: Int] = [:]
            for r in resources { if let v = Int(bt.value(row, r)), v > 0 { cost[r] = v } }
            var creature: String? = nil
            if let range = row[9].range(of: "Generates ") {
                let plural = row[9][range.upperBound...].split(separator: ".").first.map { String($0).lowercased() } ?? ""
                creature = creatures.first { $0.plural.lowercased() == plural }?.keyword
                    ?? creatures.first { plural.contains($0.name.lowercased()) || $0.plural.lowercased().contains(plural) }?.keyword
            }
            sections[section, default: []].append(BuildingDef(keyword: row[0].lowercased(), name: row[1], help: row[9], cost: cost, creature: creature))
        }
        buildings = sections
    }

    /// heroes4.exe's creature ids (the keyword table next to 0x9856ec), as map files store them.
    public static let creatureIds = ["air elemental", "archangel", "ballista", "bandit", "behemoth", "beholder", "black dragon", "bone dragon",
        "centaur", "cerberus", "champion", "crossbowman", "crusader", "cyclops", "venom spawn", "archdevil", "dragon golem", "dwarf",
        "earth elemental", "efreet", "elf", "faerie dragon", "fire elemental", "gargoyle", "genie", "ghost", "berserker", "gold golem",
        "griffin", "halfling", "harpy", "hydra", "ice demon", "imp", "leprechaun", "mage", "mantis", "medusa", "mermaid", "minotaur",
        "monk", "mummy", "naga", "nightmare", "nomad", "ogre mage", "orc", "peasant", "phoenix", "pikeman", "pirate", "satyr",
        "sea monster", "skeleton", "squire", "sprite", "thunderbird", "titan", "troglodyte", "troll", "unicorn", "vampire",
        "water elemental", "white tiger", "wolf", "zombie", "waspwort", "goblin knight", "evil sorceress", "gargantuan",
        "dark champion", "catapult", "frenzied gnasher", "mega dragon"]

    /// Each creature's abilities as heroes4.exe sets them (the static initialiser at 0x654820:
    /// one call per creature id with its ability ids, OR-ed into the record's bit set at +0xcc by
    /// 0x655f90); the names are the ability keywords of the id table at 0xa63c80. Strength,
    /// Toughness and Stone Skin are never tested: the table's stats already include them.
    public static let creatureAbilities: [String: [String]] = [
        "air elemental": ["flying", "elemental", "insubstantial"], "archangel": ["flying", "resurrection"],
        "ballista": ["ranged", "mechanical", "long_range", "siege_machine"], "bandit": ["stealth"], "beholder": ["ranged", "flying", "random_curse"],
        "behemoth": ["strength"], "black dragon": ["flying", "magic_immunity", "breath_attack"],
        "bone dragon": ["flying", "undead", "skeletal", "panic"], "centaur": ["ranged", "normal_melee", "short_range"],
        "cerberus": ["no_retaliation", "3_headed_attack"], "champion": ["first_strike", "charging"], "crossbowman": ["ranged", "long_range"],
        "crusader": ["strikes_twice", "death_protection"], "cyclops": ["ranged", "area_effect"], "venom spawn": ["ranged", "poison"],
        "archdevil": ["teleport", "summons_demons", "life_protection"], "dragon golem": ["first_strike", "first_strike_immunity", "mechanical"],
        "dwarf": ["magic_resistance"], "earth elemental": ["elemental", "magic_resistance"],
        "efreet": ["flying", "fire_shield", "fire_attack", "fire_resistance"], "elf": ["ranged", "shoots_twice", "ranged_first_strike"],
        "faerie dragon": ["flying", "spellcaster", "magic_mirror"], "fire elemental": ["ranged", "elemental", "fire_attack", "fire_resistance"],
        "gargoyle": ["flying", "elemental", "stone_skin"], "genie": ["flying", "spellcaster"],
        "ghost": ["flying", "undead", "aging", "insubstantial"], "berserker": ["strikes_twice", "berserk"],
        "gold golem": ["mechanical", "magic_resistance"], "griffin": ["flying", "unlimited_retaliation"], "halfling": ["ranged", "giantslayer"],
        "harpy": ["flying", "no_retaliation", "strike_and_return"], "hydra": ["no_retaliation", "hydra_strike"],
        "ice demon": ["freeze", "cold_attack", "cold_resistance"], "imp": ["flying", "mana_leech"], "leprechaun": ["fortune"],
        "mage": ["spellcaster"], "mantis": ["flying", "first_strike", "binding"],
        "medusa": ["ranged", "normal_melee", "unlimited_shots", "stone_gaze"], "mermaid": ["hypnotize"], "minotaur": ["block"],
        "monk": ["ranged", "death_protection"], "mummy": ["undead", "curse"], "naga": ["no_retaliation"], "nightmare": ["terror"],
        "nomad": ["first_strike"], "ogre mage": ["bloodlust"], "orc": ["ranged", "normal_melee", "short_range"], "peasant": ["taxpayer"],
        "phoenix": ["flying", "rebirth", "breath_attack", "fire_resistance"], "pikeman": ["long_weapon", "first_strike_immunity"],
        "pirate": ["sea_bonus"], "satyr": ["mirth"], "sea monster": ["devouring"], "skeleton": ["undead", "skeletal"], "squire": ["stunning"],
        "sprite": ["flying", "no_retaliation"], "thunderbird": ["flying", "lightning"], "titan": ["ranged", "normal_melee", "chaos_protection"],
        "troglodyte": ["blind"], "troll": ["regeneration"], "unicorn": ["blinding"], "vampire": ["undead", "flying", "no_retaliation", "vampire"],
        "waspwort": ["ranged", "weakness"], "water elemental": ["elemental", "spellcaster", "cold_resistance", "cold_attack"],
        "white tiger": ["first_strike"], "wolf": ["strikes_twice"], "zombie": ["undead", "toughness"],
        "goblin knight": ["magic_resistance", "stone_skin", "first_strike_immunity"], "evil sorceress": ["teleport", "spellcaster", "magic_mirror"],
        "gargantuan": ["ranged", "shoots_twice", "area_effect", "normal_melee"], "dark champion": ["charging", "undead", "terror", "regeneration"],
        "catapult": ["ranged", "mechanical", "no_ranged_penalties", "large_area_effect"], "frenzied gnasher": ["magic_immunity", "berserk"],
        "mega dragon": ["arc_breath_attack", "magic_resistance"]
    ]

    /// Town building ids of map files (0...42) per town alignment, from campaign_editor.exe's
    /// {id, keyword} table at 0x72273c: 0-11 shared, 12-19 the dwellings, 20-24 the mage guilds,
    /// 25-26 the two libraries, the rest the town's own.
    public static let buildingIds: [String: [Int: String]] = {
        let shared = [0: "village hall", 1: "town hall", 2: "city hall", 3: "fort", 4: "citadel", 5: "castle", 6: "shipyard",
                      7: "caravan", 8: "prison", 9: "tavern", 10: "blacksmith", 11: "grail"]
        let guilds = [20: "mage guild 1", 21: "mage guild 2", 22: "mage guild 3", 23: "mage guild 4", 24: "mage guild 5"]
        func town(_ own: [Int: String], guild: Bool = true) -> [Int: String] {
            shared.merging(guild ? guilds : [:]) { a, _ in a }.merging(own) { a, _ in a }
        }
        return [
            "life": town([25: "nature library", 26: "order library", 27: "seminary", 28: "stables", 29: "abbey", 12: "squire guild",
                          13: "archery range", 14: "guardhouse", 15: "ballista works", 16: "barracks", 17: "monastary", 18: "knight chapter", 19: "altar of light"]),
            "order": town([25: "life library", 26: "death library", 30: "university", 31: "treasury", 12: "dwarven mines", 13: "halfling burrow",
                           14: "golem factory", 15: "mage tower", 16: "golden pavilion", 17: "altar of wishes", 18: "dragon factory", 19: "cloud castle"]),
            "death": town([25: "order library", 26: "chaos library", 32: "skeleton transformer", 33: "necromancy amplifier", 12: "cemetery",
                           13: "torture chamber", 14: "barrow mound", 15: "kennels", 16: "mansion", 17: "spawn pit", 18: "dragon graveyard", 19: "temple of the damned"]),
            "chaos": town([25: "death library", 26: "nature library", 34: "academy", 35: "training grounds", 36: "mana vortex", 12: "bandit gen",
                           13: "orc camp", 14: "statuary garden", 15: "labyrinth", 16: "nightmare", 17: "lava tube", 18: "hydra pond", 19: "dragon cave"]),
            "nature": town([25: "chaos library", 26: "life library", 37: "creature portal", 38: "rainbow", 39: "grove", 12: "wolf den",
                            13: "fae trees", 14: "tiger den", 15: "homestead", 16: "griffin cliffs", 17: "unicorn glade", 18: "funeral pyre", 19: "magic forest"]),
            "might": town([40: "breeding pit", 41: "magic dampener", 42: "arena", 35: "training grounds", 12: "berserker", 13: "centaur stables",
                           14: "nomad camp", 15: "harpy nest", 16: "ogre fort", 17: "cyclops cave", 18: "cliff nest", 19: "behemoth crag"], guild: false),
        ]
    }()
    /// The building keywords of a bit set of map building ids.
    public static func buildings(_ bits: UInt64, alignment: String) -> Set<String> {
        guard let ids = buildingIds[alignment] else { return [] }
        return Set(ids.filter { bits & (1 << UInt64($0.key)) != 0 }.map { $0.value })
    }

    /// The buildings of a town alignment ("life" -> the "Life Town" section).
    public func buildings(for alignment: String) -> [BuildingDef] {
        buildings.first { $0.key.lowercased().hasPrefix(alignment.lowercased()) }?.value ?? []
    }

    /// The classes whose heroes ride the "<alignment>_might" / "<alignment>_magic" models.
    public static let classes: [String: (might: String, magic: String)] = [
        "life": ("knight", "priest"), "order": ("lord", "mage"), "death": ("death_knight", "necromancer"),
        "chaos": ("thief", "sorcerer"), "nature": ("archer", "druid"), "might": ("barbarian", "barbarian"),
    ]

    public func heroes(ofClass c: String) -> [HeroDef] { heroes.filter { $0.heroClass == c.lowercased() } }
    public func creature(_ keyword: String) -> CreatureDef? { creatures.first { $0.keyword.lowercased() == keyword.lowercased() } }
}

/// table.combat_grid_colors (updates.h4r): how the combat grid tints its cells per terrain.
/// Alpha is 0...15 (sixteenths); odd and even cells each have a colour or are left clear.
public struct GridColors {
    public struct Entry {
        public let alpha: Int; public let odd: (UInt8, UInt8, UInt8)?; public let even: (UInt8, UInt8, UInt8)?
        public init(alpha: Int, odd: (UInt8, UInt8, UInt8)?, even: (UInt8, UInt8, UInt8)?) { self.alpha = alpha; self.odd = odd; self.even = even }
    }
    public let byTerrain: [String: Entry]
    public init(data: Data) {
        var out: [String: Entry] = [:]
        for row in RuleTable(data: data).rows {
            guard let i = row.firstIndex(where: { !$0.isEmpty }), i + 9 < row.count, let a = Int(row[i + 1]) else { continue }
            func colour(_ k: Int) -> (UInt8, UInt8, UInt8)? {
                guard row[k].lowercased() == "no", let r = UInt8(row[k + 1]), let g = UInt8(row[k + 2]), let b = UInt8(row[k + 3]) else { return nil }
                return (r, g, b)
            }
            out[row[i].lowercased()] = Entry(alpha: a, odd: colour(i + 2), even: colour(i + 6))
        }
        byTerrain = out
    }
}
