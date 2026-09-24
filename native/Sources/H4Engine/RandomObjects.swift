import Foundation

/// Stands in for the game's start-of-scenario generation: map placeholders such as
/// "castle.Random Town", "Random creatures.RandomLv3" or "Resources.Random Resource"
/// (record type random_town / random_monster / random_material_pile / ...) are replaced by a
/// concrete sprite, chosen deterministically from the object's position so a map always
/// looks the same. The real game rolls these once when the scenario starts.
public struct RandomResolver {
    /// lower-cased archive entry name -> real entry name
    public let index: [String: String]
    public let archive: H4Archive

    /// Case-insensitive lookup of an archive entry.
    public func entry(_ name: String) -> String? { index[name.lowercased()] }

    /// An actor's sequence entry for a state and facing, e.g. ("hero.life_might_male", "walk", "s")
    /// -> "actor_sequence.hero.life_Might_Male.walk.s.h4d".
    public func sequence(actor: String, state: String, facing: String) -> String? {
        guard let actorName = index["adv_actor.\(actor).h4d".lowercased()],
              let a = try? AdvActor(data: archive.payload(actorName)),
              let seq = a.sequenceEntry(state: state, facing: facing) else { return nil }
        return index[seq.lowercased()]
    }

    public init(archive: H4Archive) {
        self.archive = archive
        var idx: [String: String] = [:]
        for n in archive.names(prefix: "") { idx[n.lowercased()] = n }
        index = idx
    }

    /// The standing ("wait") sequence of an adventure-map creature, facing `facing`.
    public func creatureEntry(_ creature: String, facing: String) -> String? {
        sequence(actor: creature, state: "wait", facing: facing)
    }

    static let factions = ["Haven", "Academy", "Asylum", "Necropolis", "Preserve", "Stronghold"]
    static let creatures: [[String]] = [
        ["Squire", "CrossbowMan", "Dwarf", "Halfling", "bandit", "Orc", "Imp", "Skeleton", "Wolf", "Sprite", "berserker", "Centaur"],
        ["Pikeman", "ballista", "Gold Golem", "Mage", "Medusa", "Minotaur", "Cerberus", "Ghost", "Elf", "White Tiger", "Harpy", "Nomad"],
        ["Crusader", "Monk", "Genie", "Naga", "Efreet", "Nightmare", "Vampire", "Venom Spawn", "Griffin", "Unicorn", "Cyclops", "Ogre Mage"],
        ["archangel", "Champion", "Dragon Golem", "Titan", "black dragon", "Hydra", "bone dragon", "archdevil", "Faerie Dragon", "Phoenix", "behemoth", "Thunderbird"],
    ]
    static let directions = ["s", "sw", "se", "w", "e"]
    static let resources = ["Wood", "Ore", "Wood", "Ore", "Mercury", "Sulfur", "Crystal", "Gem", "Gold"]
    static let schools = ["Life", "Order", "Death", "Chaos", "Nature"]
    static let teachers = ["Combat", "Druid", "Lich", "Noble", "Priest", "Scholar", "Scout", "Sorcerer", "Tactician"]
    static let temples = ["Temple of Light", "Temple of Order", "Temple of Nature", "Temple of Chaos", "Temple of Darkness"]
    static let smallDwellings = ["Archery Range", "Ballista Works", "Barrow Mound", "Berserker Dwelling", "Cemetery", "Centaur Stables", "Crypt",
                                 "Den Of thieves", "Dwarven Mines", "Embalmers Lab", "Fae Trees", "Golem Factory", "Guardhouse", "Halfling Burrow",
                                 "Harpy Nest", "Homestead", "Hovel", "Kennels", "Mage Tower", "Minotaur's Maze", "Nomad Tents", "Orc Camp",
                                 "Squire's Guild", "Tiger Den", "Troglodyte Warren", "Troll Cave", "Wolf Den"]
    static let bigDwellings = ["Barracks", "Behemoth Crag", "Black Wood", "Cliff Nest", "Cloud Castle", "Cyclops Cave", "Dragon Cave", "Dragon Factory",
                               "Dragon Graveyard", "Funeral Pyre", "Golden Pavilion", "Griffin Cliffs", "Hydra Pond", "Ice Gate", "Knight's Chapter",
                               "Lava Tube", "Magic Forest", "Mansion", "Mantis Nest", "Monestary", "Ogre Fort", "Pirates Cove", "Spawning Pit",
                               "Temple of the Damned", "Unicorn Glade"]

    /// A small deterministic hash of the object's position.
    static func seed(_ o: MapObject, _ salt: Int) -> Int {
        var h = UInt64(truncatingIfNeeded: o.x &* 73856093 ^ o.y &* 19349663 ^ o.level &* 83492791 ^ salt &* 2654435761)
        h ^= h >> 33; h = h &* 0xff51afd7ed558ccd; h ^= h >> 33
        return Int(h % 1_000_003)
    }
    static func pick<T>(_ list: [T], _ o: MapObject, _ salt: Int = 0) -> T { list[seed(o, salt) % list.count] }
    static func level(_ subtype: String) -> Int {   // "level_3", "level_1_dwelling" -> 3, 1
        let parts = subtype.split(separator: "_")
        return parts.count >= 2 ? min(max(Int(parts[1]) ?? 1, 1), 4) : 1
    }

    /// Archive entries to draw for this object, best first; empty to draw it as is.
    /// `townOrdinal` counts random towns on the map so the first is Haven, the second Academy, ...
    public func resolve(_ o: MapObject, townOrdinal: Int) -> [String] {
        var name: String?
        switch o.type {
        case "random_town":
            let f = RandomResolver.factions[townOrdinal % RandomResolver.factions.count]
            let r = o.subtype == "right" ? " R" : ""
            // a few Village files are 2-image editor dummies; the caller falls through to the next level
            return ["Village", "Fort", "Citadel", "Castle"].compactMap { index["adv_object.castle.\(f).\($0)\(r).h4d".lowercased()] }
        case "random_monster":
            let c = RandomResolver.pick(RandomResolver.creatures[RandomResolver.level(o.subtype) - 1], o)
            return creatureEntry(c, facing: RandomResolver.pick(RandomResolver.directions, o, 1)).map { [$0] } ?? []
        case "random_material_pile":
            name = "adv_object.Resources.\(RandomResolver.pick(RandomResolver.resources, o)).h4d"
        case "random_artifact":
            // several picks: a few artifact files are unfinished placeholders the caller skips
            let all = index.keys.filter { $0.hasPrefix("adv_object.artifacts.") && !$0.contains("random artifact") }.sorted()
            if !all.isEmpty { return (0..<3).map { index[all[RandomResolver.seed(o, $0) % all.count]]! } }
        case "random_shrine":
            name = "adv_object.shrines.\(RandomResolver.pick(RandomResolver.schools, o)) \(RandomResolver.level(o.subtype)).h4d"
        case "random_teacher":
            name = "adv_object.Scholars.\(RandomResolver.pick(RandomResolver.teachers, o)).h4d"
        case "random_creature_dwelling":
            let list = RandomResolver.level(o.subtype) >= 3 ? RandomResolver.bigDwellings : RandomResolver.smallDwellings
            name = "adv_object.creature generators.\(RandomResolver.pick(list, o)).h4d"
        default:
            if o.name == "moral-luck boosters.Random Temple" {
                name = "adv_object.moral-luck boosters.\(RandomResolver.pick(RandomResolver.temples, o)).h4d"
            }
        }
        guard let n = name, let e = index[n.lowercased()] else { return [] }
        return [e]
    }
}
