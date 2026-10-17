import XCTest
@testable import H4Engine

/// Found, bought and won artifacts are put on when their slot is free (re/auto_equip_spec.md:
/// 0x6402b0 -> leader 0x63ff00 -> hero vtable+4 0x72a6f0 -> 0x72a4f0, else the backpack 0x652850).
final class AutoEquipTests: XCTestCase {
    var tables: RuleTables!
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")
    override func setUpWithError() throws {
        let url = AutoEquipTests.root.appendingPathComponent("Data/text.h4r")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("game data not installed") }
        tables = try RuleTables(archive: H4Archive(url: url))
    }
    func id(_ k: String) -> Int { RuleTables.artifactIds.firstIndex(of: k)! }
    func hero(level: Int = 1) -> Hero {
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 20)
        h.level = level
        return h
    }
    func state() throws -> GameState {
        let h4r = AutoEquipTests.root.appendingPathComponent("Data/heroes4.h4r"), map = AutoEquipTests.root.appendingPathComponent("maps/Beyond the lake.h4c")
        guard FileManager.default.fileExists(atPath: h4r.path), FileManager.default.fileExists(atPath: map.path) else { throw XCTSkip("no game files") }
        let archive = try H4Archive(url: h4r)
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let g = GameState(map: try MapFile(data: Data(contentsOf: map), objectNames: names), level: 0, scenes: [])
        g.tables = tables
        return g
    }

    func testSlotOfItsTypeWhenFreeElseTheBackpack() {
        let h = hero()
        h.receive(id("helm_of_command"), tables: tables)
        XCTAssertEqual(h.equipped[2], id("helm_of_command"))
        h.receive(id("helm_of_power"), tables: tables)       // the head is taken: no swap
        XCTAssertEqual(h.equipped[2], id("helm_of_command"))
        XCTAssertEqual(h.backpack, [id("helm_of_power")])
    }

    func testRingsRightThenLeft() {
        let h = hero(), r = id("ring_of_regeneration")
        for _ in 0..<3 { h.receive(r, tables: tables) }
        XCTAssertEqual(h.equipped[9], r)
        XCTAssertEqual(h.equipped[3], r)
        XCTAssertEqual(h.backpack, [r])
    }

    func testMiscellanyTheFirstFreeOfFour() {
        let h = hero(), t = id("telescope")
        h.equipped[4] = id("telescope")
        for _ in 0..<4 { h.receive(t, tables: tables) }
        XCTAssertEqual(Array(h.equipped[4...7]), [t, t, t, t])
        XCTAssertEqual(h.backpack, [t])
    }

    func testTwoHandedAndShields() {
        let h = hero()
        h.equipped[10] = id("shield")
        h.receive(id("greatsword"), tables: tables)          // needs both hands free
        XCTAssertNil(h.equipped[13])
        XCTAssertEqual(h.backpack, [id("greatsword")])
        let g = hero()
        g.receive(id("greatsword"), tables: tables)
        XCTAssertEqual(g.equipped[13], id("greatsword"))
        g.receive(id("shield"), tables: tables)              // not beside a two-handed weapon
        XCTAssertNil(g.equipped[10])
        XCTAssertEqual(g.backpack, [id("shield")])
    }

    func testPotionsAndBackpackItemsAreNeverPutOn() {
        let h = hero()
        h.receive(id("binding_liquid"), tables: tables)
        h.receive(id("crown"), tables: tables)
        XCTAssertEqual(h.equipped.compactMap { $0 }, [])
        XCTAssertEqual(h.backpack, [id("binding_liquid"), id("crown")])
    }

    func testAParchmentGoesToTheLeftHandUnread() {
        let h = hero()
        let p = RuleTables.artifact(id("parchment"), spell: 0)
        h.receive(p, tables: tables)
        XCTAssertEqual(h.equipped[10], p)                    // 0x72a4f0 does not read it (0x7263a0 is the doll's)
        XCTAssertFalse(h.spells.contains(0))
    }

    func testTheArmyLeaderTakesItAndItWorksAtOnce() throws {
        let g = try state()
        let a = hero(level: 3), b = hero(level: 5), c = hero(level: 5)
        a.companions = [b, c]
        g.heroes = [a]
        let r = id("ring_of_regeneration")
        XCTAssertTrue(b.artifactEffects.isEmpty || !b.equipped.contains(r))
        g.give(artifact: r, to: a)
        XCTAssertEqual(b.equipped[9], r)                     // the highest level, the first of equals
        XCTAssertNil(a.equipped[9]); XCTAssertNil(c.equipped[9])
        XCTAssertFalse(b.artifactEffects.isEmpty)            // worn: its effects work now
        // a heroless army's creatures carry it
        let m = hero(); m.heroless = true
        g.give(artifact: r, to: m)
        XCTAssertEqual(m.backpack, [r])
        XCTAssertNil(m.equipped[9])
    }

    func testBootyGoesToTheFirstHero() throws {
        let g = try state()
        let a = hero(level: 1), b = hero(level: 9)
        a.companions = [b]
        g.giveLoot([id("helm_of_command"), id("helm_of_power"), id("crown")], to: a)
        XCTAssertEqual(a.equipped[2], id("helm_of_command"))
        XCTAssertEqual(a.backpack, [id("helm_of_power"), id("crown")])
        XCTAssertTrue(b.backpack.isEmpty)
    }

    func testBoughtItemsArePutOnByTheChosenHero() throws {
        let g = try state()
        let a = hero(), b = hero()
        a.companions = [b]
        g.resources["Gold"] = 1_000_000
        XCTAssertTrue(g.buy([(id("shield"), 2), (id("binding_liquid"), 1)], for: b))
        XCTAssertEqual(b.equipped[10], id("shield"))
        XCTAssertEqual(b.backpack, [id("shield"), id("binding_liquid")])
        XCTAssertTrue(a.backpack.isEmpty)
    }
}
