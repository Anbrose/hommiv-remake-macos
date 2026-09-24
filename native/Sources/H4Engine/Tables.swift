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
}

public struct HeroDef {
    public let keyword: String, name: String, sex: String, heroClass: String
}

/// The game's rule tables: creatures, heroes, random town names, mine incomes.
public final class RuleTables {
    public let creatures: [CreatureDef]
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
        creatures = cr.rows.filter { !cr.value($0, "Level").isEmpty }.map {
            CreatureDef(keyword: cr.value($0, "Keyword"), name: cr.value($0, "Name"), plural: cr.value($0, "Plural Name"), level: int(cr.value($0, "Level")),
                        alignment: cr.value($0, "Alignment").lowercased(), hitPoints: int(cr.value($0, "Hit Points")), damageLow: int(cr.value($0, "Low")),
                        damageHigh: int(cr.value($0, "High")), attack: int(cr.value($0, "Attack")), defense: int(cr.value($0, "Defense")),
                        move: int(cr.value($0, "Move")), speed: int(cr.value($0, "Speed")), growth: int(cr.value($0, "Weekly Growth")), gold: int(cr.value($0, "Gold")),
                        experience: int(cr.value($0, "Experience")))
        }
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
