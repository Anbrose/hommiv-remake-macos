import XCTest
@testable import H4Engine

/// The Thieves Guild graphs (re/thieves_guild_spec.md): every player always shown (no information
/// levels), bar heights, placement, and the values and full-bar maxima heroes4.exe computes.
final class ThievesGuildTests: XCTestCase {
    func testBarHeightScalesClampsAndKeepsASliver() {
        XCTAssertEqual(ThievesGuild.barHeight(value: 1, max: 3), 86)            // 259 * 1 / 3, integer
        XCTAssertEqual(ThievesGuild.barHeight(value: 3, max: 3), 259)
        XCTAssertEqual(ThievesGuild.barHeight(value: 0, max: 3), 1)             // an empty player still gets 1 row
        XCTAssertEqual(ThievesGuild.barHeight(value: 9000, max: 6000), 259)     // never above the image
        XCTAssertEqual(ThievesGuild.Graph(colours: [0, 1], values: [0, 0], max: 0).heights(), [])   // no towns on the map: no bars
        XCTAssertEqual(ThievesGuild.Graph(colours: [0, 1, 2], values: [2, 1, 0], max: 4).heights(), [129, 64, 1])
    }

    func testBarsAreCentredInTheGraphAtTheGreenMinusRedStride() {
        // Town_Graph (86, 210) 196 wide, Red_Bar 16 wide, Green_Bar.x - Red_Bar.x = 31
        XCTAssertEqual(ThievesGuild.barXs(count: 3, graphX: 86, graphW: 196, barW: 16, stride: 31), [145, 176, 207])
        XCTAssertEqual(ThievesGuild.barXs(count: 6, graphX: 86, graphW: 196, barW: 16, stride: 31).first, 99)
        XCTAssertEqual(ThievesGuild.barXs(count: 1, graphX: 302, graphW: 196, barW: 16, stride: 31), [392])
        XCTAssertEqual(ThievesGuild.barXs(count: 0, graphX: 86, graphW: 196, barW: 16, stride: 31), [])
    }

    func testIncomeCountsEachMaterialInWholeUnitsOfItsValue() {
        // gold 1, wood/ore 125, precious 250 (0x98c3a0), integer division per material
        XCTAssertEqual(ThievesGuild.incomeValue([1000, 2, 2, 1, 1, 1, 1]), 1000)
        XCTAssertEqual(ThievesGuild.incomeValue([750, 125, 250, 250, 0, 0, 499]), 750 + 1 + 2 + 1 + 1)
    }

    func testArmyValueIsExperienceTimesCountPlusHundredPerHeroLevelPlusOne() {
        XCTAssertEqual(ThievesGuild.armyValue(stacks: [(experience: 5, count: 20)], heroLevels: [1]), 100 + 200)
        XCTAssertEqual(ThievesGuild.armyValue(stacks: [(experience: 614, count: 2), (experience: 6, count: 10)], heroLevels: [10, 3]), 1228 + 60 + 1100 + 400)
        XCTAssertEqual(ThievesGuild.armyValue(stacks: [], heroLevels: []), 0)
    }

    func testTownIncomeWeightKeepsTheHallLoopQuirk() {
        // ids 0 village, 1 town, 2 city hall, 3 fort; the loop stops at the first impossible one
        XCTAssertEqual(ThievesGuild.townIncomeWeight { _ in true }, 500)          // every hall possible: k = 3
        XCTAssertEqual(ThievesGuild.townIncomeWeight { $0 != 3 }, 500)            // the fort is looked at, k = 3 all the same
        XCTAssertEqual(ThievesGuild.townIncomeWeight { $0 < 2 }, 1000)            // no city hall: k = 2
        XCTAssertEqual(ThievesGuild.townIncomeWeight { $0 < 1 }, 750)             // no town hall: k = 1
        XCTAssertEqual(ThievesGuild.townIncomeWeight { _ in false }, 500)
    }

    func testOtherIncomeSourcesWeights() {
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.mine, gold: true), 1000)
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.mine, gold: false), 500)
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.abandonedMine, gold: false), 500)
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.vein, gold: true), 1000)
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.weeklyGenerator, gold: true), 142)
        XCTAssertEqual(ThievesGuild.sourceIncomeWeight(.weeklyGenerator, gold: false), 75)
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

    func testEveryPlayerIsShownWithTheExeValues() throws {
        let g = try loadGame()
        let tg = g.thievesGuild()
        // all the scenario's players, in its order, in all three graphs
        XCTAssertEqual(tg.towns.colours, g.map.playerSpecs.map { $0.colour })
        XCTAssertEqual(tg.armies.colours, tg.towns.colours)
        XCTAssertEqual(tg.income.colours, tg.towns.colours)
        XCTAssertEqual(tg.towns.max, g.towns.count)
        XCTAssertEqual(tg.towns.values.reduce(0, +), g.towns.filter { g.townColour($0) != nil }.count)
        XCTAssertGreaterThanOrEqual(tg.armies.max, ThievesGuild.armyFloor)
        // a human army of 20 imps under its level-1 hero: 20 x 5 + 100 x 2
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0)
        h.owner = g.map.humanColour
        h.army = [Hero.Stack(creature: "imp", count: 20)]
        g.heroes = [h]
        XCTAssertEqual(g.armyStrength(of: g.map.humanColour) - g.towns.filter { g.townColour($0) == g.map.humanColour }
            .reduce(0) { s, t in s + t.garrison.reduce(0) { $0 + (g.tables?.creature($1.creature)?.experience ?? 0) * $1.count } + t.garrisonHeroes.reduce(0) { $0 + 100 * ($1.level + 1) } },
            100 + 100 * (h.level + 1))
        // a town's hall income is in its owner's income bar
        for (k, c) in tg.income.colours.enumerated() {
            let halls = g.towns.filter { g.townColour($0) == c }.reduce(0) { $0 + g.hallIncome($1) }
            XCTAssertGreaterThanOrEqual(tg.income.values[k], halls)
        }
    }
}
