import XCTest
@testable import H4Engine

/// Artifact sets (t_combined_effect, type 0x3b) and campaign carry-over of their pieces
/// (re/artifact_sets_spec.md): the walker 0x731c20 adds a set's effects once every piece is worn;
/// a won map's carry-out artifacts go to the next map's strongest hero (0x4e4920 / 0x4cb680).
final class ArtifactSetTests: XCTestCase {
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")
    func id(_ k: String) -> Int { RuleTables.artifactIds.firstIndex(of: k)! }
    func hero() -> Hero { Hero(actor: "hero.might_barbarian_male", x: 0, y: 0, movement: 20) }

    func testTigerSetNeedsAllThreeWornPieces() {
        let h = hero()
        func dragonPowers() -> Bool {
            h.artifactAbilities.contains("regeneration") && h.artifactEffects.contains { $0.type == 0x2b && $0.spell == 33 }
        }
        h.equipped[12] = id("tiger_armor"); h.equipped[2] = id("tiger_helm")
        XCTAssertFalse(dragonPowers())                    // a partial set: only the pieces' own effects
        XCTAssertTrue(h.artifactAbilities.contains("first_strike_immunity"))
        h.backpack = [id("frost_hammer")]                 // carried, not wielded: still no set
        XCTAssertFalse(dragonPowers())
        XCTAssertTrue(h.equip(backpackIndex: 0, tables: nil) == false)
        h.equipped[13] = h.backpack.removeFirst()
        XCTAssertTrue(dragonPowers())                     // Regeneration and Dragon Strength
        h.unequip(slot: 2)                                // the helm off: the set bonus goes
        XCTAssertFalse(dragonPowers())
        XCTAssertEqual(h.backpack, [id("tiger_helm")])
    }

    func testSetsOfTheExpansionCampaigns() {
        let h = hero()
        // Cloak of Darkness + Ring of Light: one Guardian Angel life at the start of combat (0x3a)
        h.equipped[11] = id("cloak_of_darkness")
        XCTAssertFalse(h.artifactEffects.contains { $0.type == 0x3a && $0.spell == 53 })
        h.equipped[9] = id("ring_of_light")
        XCTAssertTrue(h.artifactEffects.contains { $0.type == 0x3a && $0.spell == 53 && $0.amount == 1 })
        // Harmonic Chainmail + Necklace of Muses + Aiffe's Mandolin: Song of Peace on melee blows (0x31)
        h.equipped = Array(repeating: nil, count: h.equipped.count)
        h.equipped[12] = id("harmonic_chainmail"); h.equipped[8] = id("necklace_of_muses")
        XCTAssertFalse(h.artifactEffects.contains { $0.type == 0x31 })
        h.equipped[10] = id("aiffes_mandolin")
        XCTAssertTrue(h.artifactEffects.contains { $0.type == 0x31 && $0.spell == 144 && $0.melee && !$0.ranged })
        // the five Archmage pieces: ignore magic resistance
        h.equipped = Array(repeating: nil, count: h.equipped.count)
        for (s, k) in [(2, "archmages_hat"), (13, "staff_of_disruption"), (1, "wayfaring_boots"), (9, "ring_of_flares")] { h.equipped[s] = id(k) }
        XCTAssertFalse(h.artifactAbilities.contains("ignore_magic_resistance"))
        h.equipped[11] = id("angelfeather_cloak")
        XCTAssertTrue(h.artifactAbilities.contains("ignore_magic_resistance"))
    }

    func testCombatStartCastAndSpellOnHit() {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        var hs = Combatant(hero: "Dogwoggle", level: 10)
        hs.castAtStart = [(53, 1)]
        hs.spellsOnHit = [(144, true, false)]
        let c = CreatureDef(keyword: "orc", name: "orc", plural: "orcs", level: 1, alignment: "might", hitPoints: 15, damageLow: 2, damageHigh: 3,
                            attack: 10, defense: 10, move: 10, speed: 5, growth: 1, gold: 1, experience: 1, shots: 0, spellPoints: 0, shortHelp: "", longHelp: "")
        let a = Battle.Fighter(stats: hs, keyword: "hero", actor: "hero", size: 2, move: 24, shots: 0)
        let d = Battle.Fighter(stats: Combatant(creature: c, count: 10), keyword: "orc", actor: "orc", size: 2, move: 10, shots: 0)
        let b = Battle(field: field, attackers: [a], defenders: [d], seed: 3)
        let h = b.units.first { $0.stats.isHero }!, o = b.units.first { !$0.stats.isHero }!
        XCTAssertTrue(h.stats.under(53))                  // Guardian Angel from the start
        XCTAssertEqual(h.powers[53], 1)
        b.aftermath(h, o, ranged: true, damage: 5, healthBefore: o.stats.totalHealth)
        XCTAssertFalse(o.stats.under(144))                // a melee-only item: nothing on a shot
        b.aftermath(h, o, ranged: false, damage: 5, healthBefore: o.stats.totalHealth)
        XCTAssertTrue(o.stats.under(144))                 // every melee blow, no roll
    }

    // MARK: carry-over (needs the installed game)

    func game(_ campaign: Int, _ scenario: Int) throws -> GameState {
        let data = ArtifactSetTests.root.appendingPathComponent("Data")
        let h4r = data.appendingPathComponent("heroes4.h4r"), text = data.appendingPathComponent("text.h4r")
        let storm = data.appendingPathComponent("storm.h4r")
        guard FileManager.default.fileExists(atPath: storm.path) else { throw XCTSkip("no game files") }
        let archive = try H4Archive(url: h4r)
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let c = try CampaignFile.load(campaign, from: H4Archive(url: storm))
        let g = GameState(map: try MapFile(data: c.scenario(scenario), objectNames: names), level: 0, scenes: [])
        g.tables = try RuleTables(archive: H4Archive(url: text))
        return g
    }

    func testTigerPiecesFollowTheCampaignToTheStrongestHero() throws {
        // Dogwoggle's campaign (10): its maps name the tiger pieces gathered so far as carry-out
        let first = try game(10, 1), second = try game(10, 2)
        XCTAssertEqual(first.map.carryOutArtifacts, [id("tiger_armor"), id("frost_hammer")])
        XCTAssertEqual(second.map.carryOutArtifacts, [id("tiger_armor"), id("tiger_helm"), id("frost_hammer")])
        XCTAssertTrue(second.map.carryInArtifacts.isSuperset(of: [id("tiger_armor"), id("frost_hammer")]))

        let dog = hero()
        dog.name = "Dogwoggle"; dog.skills = ["combat": 3, "tactics": 2]
        dog.equipped[12] = id("tiger_armor"); dog.equipped[2] = id("helm_of_command")
        dog.backpack = [id("frost_hammer"), id("bag_of_gold")]
        first.heroes = [dog]
        let carry = first.carryOut()
        XCTAssertEqual(Set(carry.artifacts ?? []), [id("tiger_armor"), id("frost_hammer")])
        XCTAssertNil(carry.human[0].equipped?[12] ?? nil)            // taken off for the pool
        XCTAssertEqual(carry.human[0].equipped?[2] ?? nil, id("helm_of_command"))
        XCTAssertEqual(carry.human[0].backpack ?? [], [id("bag_of_gold")])

        // the next map: the carried pool goes to the most skilled hero, put on where it fits
        let weak = hero(), strong = SaveGame.hero(from: carry.human[0])
        weak.skills = ["scouting": 0]
        second.heroes = [weak, strong]
        second.giveCarriedArtifacts(carry.artifacts ?? [])
        XCTAssertEqual(strong.equipped[12], id("tiger_armor"))
        XCTAssertEqual(strong.equipped[13], id("frost_hammer"))
        XCTAssertTrue(weak.equipped.allSatisfy { $0 == nil })
        // with the helm found here too the set works for him
        strong.equipped[2] = id("tiger_helm")
        XCTAssertTrue(strong.artifactAbilities.contains("regeneration"))
    }

    func testHeroCombatantTakesTheSetEffects() throws {
        let g = try game(10, 2)
        let h = hero()
        h.equipped[11] = id("cloak_of_darkness"); h.equipped[9] = id("ring_of_light")
        XCTAssertEqual(g.heroCombatant(h).castAtStart.map(\.spell), [53])
        h.equipped[9] = nil
        XCTAssertTrue(g.heroCombatant(h).castAtStart.isEmpty)
    }
}
