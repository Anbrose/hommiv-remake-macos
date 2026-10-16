import XCTest
@testable import H4Engine

/// Map creature dwellings (re/map_dwelling_spec.md).
final class DwellingTests: XCTestCase {
    func creature(_ kw: String, level: Int, growth: Int, gold: Int, xp: Int, cost: [String: Int] = [:]) -> CreatureDef {
        CreatureDef(keyword: kw, name: kw, plural: kw + "s", level: level, alignment: "Life", hitPoints: 10, damageLow: 1, damageHigh: 2, attack: 5, defense: 5,
                    move: 20, speed: 5, growth: growth, gold: gold, experience: xp, cost: cost, shots: 0, spellPoints: 0, shortHelp: "", longHelp: "")
    }

    func testGuardsByLevel() {
        // (budget + xp / 2) / xp with budgets 0 / 166 / 750 / 2000 (0xa4cc24)
        XCTAssertEqual(GameState.dwellingGuards(creature("peasant", level: 1, growth: 30, gold: 15, xp: 1)), 0)
        XCTAssertEqual(GameState.dwellingGuards(creature("mage", level: 2, growth: 8, gold: 200, xp: 40)), 4)        // (166 + 20) / 40
        XCTAssertEqual(GameState.dwellingGuards(creature("griffin", level: 3, growth: 5, gold: 400, xp: 63)), 12)    // (750 + 31) / 63
        XCTAssertEqual(GameState.dwellingGuards(creature("black dragon", level: 4, growth: 1, gold: 8000, xp: 1233)), 2) // (2000 + 616) / 1233
    }

    func testPriceDiscountRoundsAndKeepsOtherMaterials() {
        let d = creature("black dragon", level: 4, growth: 1, gold: 8000, xp: 1233, cost: ["Gold": 8000, "Sulfur": 4])
        XCTAssertEqual(GameState.recruitCost(d, discount: 0).map { "\($0.0)\($0.1)" }, ["Gold8000", "Sulfur4"])
        XCTAssertEqual(GameState.recruitCost(d, discount: 10).map { "\($0.0)\($0.1)" }, ["Gold7200", "Sulfur4"])
        let cheap = creature("troglodyte", level: 1, growth: 14, gold: 28, xp: 5)
        XCTAssertEqual(GameState.recruitCost(cheap, discount: 10).first?.1, 25)   // (28 x 90 + 50) / 100 = 25.7 -> 25
    }

    func testOwnedPopulationGrowsHalfAWeekAWeek() {
        var a = 0, f = 0
        for _ in 0..<7 { (a, f) = GameState.populationDay(a, f, growth: 14) }
        XCTAssertEqual(a, 7); XCTAssertEqual(f, 0)
        (a, f) = (0, 0)
        for _ in 0..<7 { (a, f) = GameState.populationDay(a, f, growth: 3) }   // 21 fourteenths
        XCTAssertEqual(a, 1); XCTAssertEqual(f, 7)
    }

    func testUnownedGuardsGrowTenPercentCappedByGrowth() {
        var g = 40, f = 0
        for _ in 0..<7 { (g, f) = GameState.guardsDay(g, f, growth: 8) }   // min(4, 8) a week
        XCTAssertEqual(g, 44)
        (g, f) = (200, 0)
        for _ in 0..<7 { (g, f) = GameState.guardsDay(g, f, growth: 5) }   // min(20, 5) a week, 1280 / 7 = 182 256ths a day
        XCTAssertEqual(g, 204); XCTAssertEqual(f, 1274 & 0xff)
    }

    // MARK: the visit, on a real map when the game is installed

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
        g.quickCombatOnly = true
        return g
    }

    func testGuardedDwellingFightsThenFlagsAndOffers() throws {
        let g = try loadGame()
        guard let i = g.dwellings.indices.first(where: { g.dwellings[$0].guards > 0 }),
              let p = g.scene.placed.first(where: { g.dwelling(for: $0) == i }), let c = g.tables?.creature(g.dwellings[i].creature) else { return XCTFail("no guarded dwelling") }
        XCTAssertEqual(g.dwellings[i].guards, GameState.dwellingGuards(c))
        XCTAssertEqual(g.dwellings[i].available, c.growth)
        let h = Hero(actor: "hero.life_might_male", x: p.cellX, y: p.cellY + 1)
        h.owner = g.map.humanColour
        h.army = [Hero.Stack(creature: "Black Dragon", count: 50)]
        // a question first, nothing flagged yet
        XCTAssertTrue(g.debugVisitDwelling(hero: h, p))
        XCTAssertNotNil(g.question)
        XCTAssertNil(g.dwellingOpen)
        XCTAssertNil(g.dwellings[i].owner)
        // fight and win: flagged, guards gone, the recruit dialog offered
        g.question?.yes(); g.question = nil
        XCTAssertEqual(g.dwellings[i].guards, 0)
        XCTAssertEqual(g.dwellings[i].owner, g.map.humanColour)
        XCTAssertEqual(g.dwellingOpen?.dwelling, i)
        // buying: the treasury pays, the population drops, the stack joins
        g.resources["Gold"] = 100_000
        let n = min(2, g.dwellings[i].available)
        let gold = g.recruitCost(c, discount: 0).first { $0.0 == "Gold" }?.1 ?? 0
        XCTAssertTrue(g.recruit(fromDwelling: i, count: n, to: h))
        XCTAssertEqual(g.resources["Gold"], 100_000 - n * gold)
        XCTAssertEqual(g.dwellings[i].available, c.growth - n)
        XCTAssertEqual(h.army.first { $0.creature == c.keyword }?.count, n)
        XCTAssertFalse(g.recruit(fromDwelling: i, count: g.dwellings[i].available + 1, to: h))   // never more than wait
        // emptied: the next visit says so; a full army has no room
        g.dwellings[i].available = 0; g.dwellingOpen = nil; g.scripts.messages = []
        _ = g.debugVisitDwelling(hero: h, p)
        XCTAssertNil(g.dwellingOpen)
        XCTAssertEqual(g.scripts.messages.count, 1)
        g.dwellings[i].available = 3; g.scripts.messages = []
        h.army = ["imp", "sprite", "peasant", "orc", "wolf", "titan", "bandit"].filter { $0 != c.keyword }.prefix(6).map { Hero.Stack(creature: $0, count: 1) }
        _ = g.debugVisitDwelling(hero: h, p)
        XCTAssertNil(g.dwellingOpen)
        XCTAssertTrue(g.scripts.messages.first?.contains("no room") == true)
    }
}
