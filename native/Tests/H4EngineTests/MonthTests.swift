import XCTest
@testable import H4Engine

/// "Month of the <Creature>" and town growth (re/month_events_spec.md).
final class MonthTests: XCTestCase {
    func testRecordCapsAndWorth() {
        let a = MonthSpawnRecord(alignment: 3, value: 800, field8: 0, bonus: 50, field14: 0, flag11: 0, water: false, x: 0, y: 0, z: 0)
        XCTAssertEqual(a.value, 700); XCTAssertEqual(a.bonus, 0); XCTAssertEqual(a.worth, 700)
        let b = MonthSpawnRecord(alignment: 3, value: 600, field8: 0, bonus: 200, field14: 0, flag11: 0, water: false, x: 0, y: 0, z: 0)
        XCTAssertEqual(b.bonus, 100); XCTAssertEqual(b.worth, 700)
        // an ordinary stack's record (the exe's -1s): ftol(-1 + 0.5) = 0, plus -1
        let c = MonthSpawnRecord(alignment: -1, value: -1, field8: -1, bonus: -1, field14: -1, flag11: 0xff, water: false, x: 0, y: 0, z: 0)
        XCTAssertEqual(c.worth, -1)
    }

    // MARK: on a real map when the game is installed

    func loadGame() throws -> GameState {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        let mapURL = data.deletingLastPathComponent().appendingPathComponent("Maps/A Land without a King.h4c")
        guard FileManager.default.fileExists(atPath: mapURL.path) else { throw XCTSkip("game data not installed") }
        let archive = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let a = try? H4Archive(url: data.appendingPathComponent(f)) { archive.supplement(with: a) } }
        let tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        RandomResolver.creaturePool = (1...4).map { lv in tables.creatures.filter { $0.level == lv && $0.expansion == 0 }.map { $0.keyword } }
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let map = try MapFile(data: Data(contentsOf: mapURL), objectNames: names)
        let masks = try TransitionMasks(data: archive.payload("transition.Transitions.h4d"))
        let scene = try MapScene(map: map, level: 0, archive: archive, masks: masks)
        let g = GameState(map: map, level: 0, scenes: [scene])
        g.tables = tables
        g.registerObjects(townFactions: [:])
        return g
    }
    func levelOne(_ g: GameState) -> [String] {
        let exp = max(0, min(2, g.map.version - 27))
        return RuleTables.creatureIds.filter { g.tables?.creature($0).map { $0.level == 1 && $0.expansion <= exp } ?? false }
    }

    func testOrdinaryStacksGiveTheLevelOneDraw() throws {
        let g = try loadGame()
        XCTAssertFalse(g.monsters.isEmpty)
        g.random.state = 12345
        var r = H4Random(seed: 12345)
        g.setupMonths()
        // every stack's record is (-1, worth -1): no bucket, no level roll, one draw among level 1
        let list = levelOne(g)
        XCTAssertEqual(g.monthCreature, "peasant")
        XCTAssertEqual(g.nextMonthCreature, list[r.next() % list.count])
        XCTAssertEqual(g.random.state, r.state)
    }

    func testRecordsDecideTheBucketAndCreature() throws {
        let g = try loadGame()
        g.monthSpawns = (0..<4).map { MonthSpawnRecord(alignment: 3, value: 60, field8: 0, bonus: 0, field14: 0, flag11: 0, water: false, x: $0, y: 0, z: 0) }
        g.day = 1   // month 1's draw: no level 3 or 4 on the first pass
        g.random.state = 777
        var r = H4Random(seed: 777)
        g.pickNextMonthCreature()
        _ = r.next()   // the bucket roll (only chaos is possible)
        let exp = max(0, min(2, g.map.version - 27))
        let list = RuleTables.creatureIds.filter { kw in
            guard let d = g.tables?.creature(kw) else { return false }
            return d.alignment.lowercased() == "chaos" && d.experience <= 60 && d.level <= 2 && d.expansion <= exp
                && !["mermaid", "pirate", "sea monster"].contains(kw)
        }
        XCTAssertFalse(list.isEmpty)
        XCTAssertEqual(g.nextMonthCreature, list[r.next() % list.count])
    }

    func freeLandCell(_ g: GameState) -> (Int, Int)? {
        for x in 10..<(g.map.size - 10) { for y in 10..<(g.map.size - 10)
            where g.passability.isFree(x, y) && !g.monthCellIsWater(x, y, 0) && !g.monsters.contains(where: { $0.x == x && $0.y == y }) {
            return (x, y)
        } }
        return nil
    }

    func testNewMonthSpawnsOnARecord() throws {
        let g = try loadGame()
        guard let (x, y) = freeLandCell(g), let orc = g.tables?.creature("orc") else { return XCTFail("no free cell") }
        g.monthSpawns = [MonthSpawnRecord(alignment: 3, value: 300, field8: 7, bonus: 0, field14: 2, flag11: 1, water: false, x: x, y: y, z: 0)]
        g.nextMonthCreature = "orc"
        let before = g.monsters.count
        g.day = 29
        g.newMonth()
        XCTAssertEqual(g.monthCreature, "orc")
        XCTAssertTrue(g.monthSpawns.isEmpty)
        XCTAssertEqual(g.monsters.count, before + 1)
        let m = g.monsters.last!
        XCTAssertEqual(m.creature, "orc"); XCTAssertEqual(m.x, x); XCTAssertEqual(m.y, y)
        // two thirds of 300 buys the orcs; the rest goes to the escort picker
        XCTAssertGreaterThanOrEqual(m.count, 200 / orc.experience)
        XCTAssertEqual(m.origin, MonthOrigin(alignment: 3, value: 300, field8: 7, bonus: 0, field14: 2, flag11: 1))
        XCTAssertNotNil(g.monster(for: g.scene.placed.first { $0.cellX == x && $0.cellY == y && $0.name == m.name }!))
        XCTAssertFalse(g.passability.isFree(x, y))
        // beaten, it leaves its record behind
        g.rememberMonthSpawn(m)
        XCTAssertEqual(g.monthSpawns.first?.worth, 300)
        XCTAssertEqual(g.monthSpawns.first?.alignment, 3)
    }

    func testNoSpawnNextToAnArmyOrForTheWrongCreature() throws {
        let g = try loadGame()
        guard let (x, y) = freeLandCell(g) else { return XCTFail("no free cell") }
        let rec = MonthSpawnRecord(alignment: 3, value: 300, field8: 0, bonus: 0, field14: 0, flag11: 0, water: false, x: x, y: y, z: 0)
        g.monthSpawns = [rec]
        let h = Hero(actor: "hero.life_might_male", x: x + 2, y: y - 2)
        g.heroes = [h]
        g.nextMonthCreature = "orc"
        g.newMonth()
        XCTAssertEqual(g.monthSpawns, [rec])
        g.heroes = []
        g.nextMonthCreature = "squire"   // life: not this chaos place
        g.newMonth()
        XCTAssertEqual(g.monthSpawns, [rec])
        // an ordinary stack's record matches no creature
        g.monthSpawns = [g.monthRecord(of: g.monsters[0])]
        g.nextMonthCreature = "peasant"
        g.newMonth()
        XCTAssertEqual(g.monthSpawns.count, 1)
    }

    func testNewMonthAnnouncedOnDay29Only() throws {
        let g = try loadGame()
        g.setupMonths()
        let next = g.nextMonthCreature
        g.day = 28; g.monthsNewDay()
        XCTAssertTrue(g.scripts.messages.isEmpty)
        g.day = 29; g.monthsNewDay()
        XCTAssertEqual(g.monthCreature, next)
        let name = g.tables!.creature(next)!.name
        let text = "Astrologers declare this the Month of the \(name.prefix(1).uppercased() + name.dropFirst())."
        XCTAssertEqual(g.scripts.messages, [text])
        XCTAssertEqual(g.messageTitles[text], "New Month")
    }

    func testTownsGrowDailyAndNewDwellingsHalfAWeek() throws {
        let g = try loadGame()
        guard let i = g.towns.indices.first(where: { i in (12...19).contains { g.isBuiltPublic(g.towns[i], $0) } }) else { return XCTFail("no town dwelling") }
        let b = (12...19).first { g.isBuiltPublic(g.towns[i], $0) }!
        guard let kw = g.buildingDef(g.towns[i], b)?.creature, let c = g.tables?.creature(kw) else { return XCTFail("no creature") }
        g.towns[i].owner = nil
        g.towns[i].available[kw] = 0
        for _ in 0..<7 { g.townsNewDay() }
        XCTAssertEqual(g.towns[i].available[kw], 0)   // unowned towns do not grow
        g.towns[i].owner = 0
        for _ in 0..<7 { g.townsNewDay() }
        let week = g.townWeek700(i, c)
        XCTAssertEqual(g.towns[i].available[kw, default: 0] * 700 + g.towns[i].growthRemainder[kw, default: 0], 7 * (week / 7))
        g.townsNewDay()
        XCTAssertEqual(g.towns[i].available[kw, default: 0] * 700 + g.towns[i].growthRemainder[kw, default: 0], 8 * (week / 7))
        g.dwellingBuilt(i, kw, c)
        XCTAssertEqual(g.towns[i].available[kw], (c.growth + 1) / 2)
    }
}
