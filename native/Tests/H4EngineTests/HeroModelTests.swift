import XCTest
@testable import H4Engine

/// Hero models as heroes4.exe picks them (hero_model_spec.md): the sex byte (+0x634, 1 male), the
/// class's might/magic flag (0x737ec0) and the records' custom models (0x72e080 / 0x72de50).
final class HeroModelTests: XCTestCase {
    func testMapSexByteOneIsMale() {
        var rng = H4Random(seed: 1)
        var m = MapHero(); m.heroClass = 0; m.gender = 1
        XCTAssertEqual(Hero.fromMap(m, alignment: "life", x: 0, y: 0, tables: nil, random: &rng).actor, "hero.life_might_male")
        m.heroClass = 1; m.gender = 0
        let priest = Hero.fromMap(m, alignment: "life", x: 0, y: 0, tables: nil, random: &rng)
        XCTAssertEqual(priest.actor, "hero.life_magic_female")
        XCTAssertFalse(priest.isMale)
        XCTAssertEqual(priest.combatModel(shooter: false), "hero.life_mage_female")
    }

    func testMagicFlagFollowsTheExeClassList() {
        XCTAssertEqual(Hero.adventureModel(heroClass: 13, alignment: "life", male: true), "hero.life_magic_male")    // prophet
        XCTAssertEqual(Hero.adventureModel(heroClass: 11, alignment: "life", male: true), "hero.life_might_male")    // crusader
        XCTAssertEqual(Hero.adventureModel(heroClass: 34, alignment: "chaos", male: false), "hero.chaos_magic_female") // lich
        XCTAssertEqual(Hero.adventureModel(heroClass: 10, alignment: "might", male: false), "hero.might_might_female") // barbarian
        XCTAssertEqual(Hero.adventureModel(heroClass: 47, alignment: "order", male: true), "hero.might_might_male")   // archmage: none
    }

    func testOldSavesTakeTheRecordsSex() throws {
        let g = try PortraitTests().game()
        let h = Hero(actor: "hero.life_might_female", x: 0, y: 0); h.keyword = "lord_lysander"
        var st = SaveGame.state(of: h)
        XCTAssertEqual(st.male, false)
        XCTAssertEqual(SaveGame.hero(from: st, tables: g.tables).actor, "hero.life_might_female")   // saved after the fix: kept
        st.male = nil
        XCTAssertEqual(SaveGame.hero(from: st, tables: g.tables).actor, "hero.life_might_male")
    }

    func testCustomModels() throws {
        let g = try PortraitTests().game()
        func hero(_ keyword: String) -> Hero {
            var rng = H4Random(seed: 3), m = MapHero()
            m.portrait = try! XCTUnwrap(RuleTables.portraitId(keyword))
            return Hero.fromMap(m, alignment: "life", x: 0, y: 0, tables: g.tables, random: &rng)
        }
        let bohb = hero("bohb")
        XCTAssertEqual(bohb.actor, "hero.order_magic_male")
        XCTAssertEqual(bohb.adventureModel(tables: g.tables), "hero.Archmage")
        XCTAssertEqual(bohb.combatModels(shooter: false, tables: g.tables), ["hero.Archmage", "hero.order_mage_male"])
        let dog = hero("dogwoggle_campaign")
        XCTAssertEqual(dog.combatModels(shooter: true, tables: g.tables).first, "hero.Dogwoggle_archer")
        XCTAssertEqual(dog.adventureModel(tables: g.tables), "hero.Dogwoggle_fighter")
        let lysander = hero("lord_lysander")
        XCTAssertEqual(lysander.actor, "hero.life_might_male")
        XCTAssertEqual(lysander.adventureModel(tables: g.tables), lysander.actor)
        // every custom model is in the archives (looked up without regard to case)
        let names = Set(g.resources.names(prefix: "").map { $0.lowercased() })
        for r in g.tables.heroes {
            for n in [r.customModelFighter, r.customModelArcher] where !n.isEmpty {
                XCTAssertTrue(names.contains("combat_actor.hero.\(n).h4d".lowercased()), n)
            }
            if !r.customModelFighter.isEmpty { XCTAssertTrue(names.contains("adv_actor.hero.\(r.customModelFighter).h4d".lowercased()), r.customModelFighter) }
        }
        XCTAssertEqual(g.tables.heroes.filter { !$0.customModelFighter.isEmpty }.count, 10)
    }

    /// The campaigns' maps give their heroes the sex and class of the portrait's record (byte 1: male).
    func testCampaignHeroesSexMatchesRecords() throws {
        let g = try PortraitTests().game()
        let objectNames = Set(g.resources.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        var checked = 0
        for id in [1, 2] {
            let c = try CampaignFile.load(id, from: g.resources)
            for k in 0..<c.count {
                let m = try MapFile(data: try c.scenario(k), objectNames: objectNames)
                for mh in m.objects.flatMap({ $0.heroes }) where mh.portrait >= 0 && mh.gender >= 0 {
                    guard let r = g.tables.heroes.first(where: { $0.portrait == mh.portrait }) else { continue }
                    XCTAssertEqual(mh.gender == 1, r.sex == "male", "\(id):\(k) \(r.keyword)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 5)
    }
}
