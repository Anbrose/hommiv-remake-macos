import XCTest
@testable import H4Engine

/// The computer players' economy (re/ai_economy_spec.md, re/ai_buildings_spec.md, re/ai_purchase_spec.md).
final class AIEconomyTests: XCTestCase {
    func testStartingTreasuries() {
        // table 0x98e9e8: human rows 0..4, computer rows 5..9
        let easyHuman = GameState.startingResources(difficulty: 0, computer: false)
        XCTAssertEqual(easyHuman["Gold"], 20000); XCTAssertEqual(easyHuman["Wood"], 20); XCTAssertEqual(easyHuman["Gems"], 10)
        let easyAI = GameState.startingResources(difficulty: 0, computer: true)
        XCTAssertEqual(easyAI["Gold"], 0); XCTAssertEqual(easyAI["Ore"], 10); XCTAssertEqual(easyAI["Mercury"], 5)
        XCTAssertEqual(GameState.startingResources(difficulty: 1, computer: false)["Gold"], 15000)
        XCTAssertEqual(GameState.startingResources(difficulty: 1, computer: true)["Gold"], 5000)
        XCTAssertEqual(GameState.startingResources(difficulty: 3, computer: true)["Crystal"], 7)
        let impossibleAI = GameState.startingResources(difficulty: 4, computer: true)
        XCTAssertEqual(impossibleAI["Gold"], 20000); XCTAssertEqual(impossibleAI["Sulfur"], 10)
        XCTAssertEqual(GameState.startingResources(difficulty: 4, computer: false)["Gold"], 0)
    }

    func testIncomeHandicapSpreadsTheFraction() {
        // Hard (x1.25): 1000 gold -> +250 every day; 2 ore -> 0.5 a day = 4 of 7 days (round(3.5))
        var ore = 0, gold = 0
        for day in 1...7 {
            let e = GameState.incomeHandicap(income: [1000, 0, 2, 0, 0, 0, 0], funds: Array(repeating: 0, count: 7), difficulty: 2, day: day)
            gold += e[0]; ore += e[2]
            XCTAssertEqual(e[0], 250)
        }
        XCTAssertEqual(gold, 1750)
        XCTAssertEqual(ore, 4)
        // material i gets its extra one on the days where (day - i + 6) % 7 < spread
        let d = GameState.incomeHandicap(income: [0, 0, 1, 0, 0, 0, 0], funds: Array(repeating: 0, count: 7), difficulty: 2, day: 0)
        // 0.25 a day: spread = trunc(1.75 + 0.5) = 2; (0 - 2 + 6) % 7 = 4 -> not today
        XCTAssertEqual(d[2], 0)
        let d2 = GameState.incomeHandicap(income: [0, 0, 1, 0, 0, 0, 0], funds: Array(repeating: 0, count: 7), difficulty: 2, day: 3)
        XCTAssertEqual(d2[2], 1)   // (3 - 2 + 6) % 7 = 0 < 2
        // Impossible doubles; Normal adds nothing
        XCTAssertEqual(GameState.incomeHandicap(income: [1500, 2, 0, 0, 0, 0, 0], funds: Array(repeating: 0, count: 7), difficulty: 4, day: 5)[0], 1500)
        XCTAssertEqual(GameState.incomeHandicap(income: [1500, 2, 0, 0, 0, 0, 0], funds: Array(repeating: 0, count: 7), difficulty: 1, day: 5), Array(repeating: 0, count: 7))
    }

    func testEasyHandicapNeverTakesBelowZero() {
        // Easy (x0.75): -250 of 1000 gold, but only 100 in the treasury -> -100; fractions truncate toward zero
        let e = GameState.incomeHandicap(income: [1000, 2, 0, 0, 0, 0, 0], funds: [100, 5, 0, 0, 0, 0, 0], difficulty: 0, day: 2)
        XCTAssertEqual(e[0], -100)
        XCTAssertEqual(e[1], 0)   // -0.5 -> trunc 0, spread trunc(-3.5 + 0.5) = -3: never
    }

    func testHandicapPlayerFilter() {
        // 0x4d8aeb: colour 0 looks at colour 1's human mark, every other colour at colour 0's
        XCTAssertTrue(GameState.handicapApplies(colour: 1, human: 0)); XCTAssertTrue(GameState.handicapApplies(colour: 3, human: 0))
        XCTAssertTrue(GameState.handicapApplies(colour: 0, human: 1)); XCTAssertFalse(GameState.handicapApplies(colour: 2, human: 1))
        XCTAssertFalse(GameState.handicapApplies(colour: 0, human: 2))
    }

    func testPredictionFactors() {
        // 0x479000: with a human side 0.85 / 1.15; an AI against neutrals gets 1.0 .. 1.5 by difficulty
        let h = GameState.predictionFactors(first: 1, second: 0, human: 0, difficulty: 4)
        XCTAssertEqual(h.0, 0.85, accuracy: 1e-6); XCTAssertEqual(h.1, 1.15, accuracy: 1e-6)
        let two = GameState.predictionFactors(first: 1, second: 2, human: 0, difficulty: 3)
        XCTAssertEqual(two.0, 0.85, accuracy: 1e-6)
        for (d, f) in [(0, 1.0), (1, 1.3), (2, 1.37), (3, 1.44), (4, 1.5)] {
            let n = GameState.predictionFactors(first: 2, second: nil, human: 0, difficulty: d)
            XCTAssertEqual(n.0, f, accuracy: 1e-6); XCTAssertEqual(n.1, 1)
            let r = GameState.predictionFactors(first: nil, second: 2, human: 0, difficulty: d)
            XCTAssertEqual(r.0, 1); XCTAssertEqual(r.1, f, accuracy: 1e-6)
        }
    }

    // MARK: on a real map when the game is installed

    static func loadGame() throws -> GameState {
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

    /// A town of the map given to a computer colour, with its first dwelling built and stocked.
    func computerTown(_ g: GameState, colour: Int = 1) -> (Int, String)? {
        guard let i = g.towns.indices.first(where: { g.townPlaced($0) != nil }) else { return nil }
        g.towns[i].owner = colour; g.towns[i].owned = false
        g.towns[i].garrison = []; g.towns[i].garrisonHeroes = []
        guard let def = g.buildingDef(g.towns[i], 12), let c = def.creature else { return nil }
        g.towns[i].buildings.insert(def.keyword)
        g.towns[i].available[c] = 30
        return (i, c)
    }

    func testTownRecruitPaysEveryMaterialAndThePopulation() throws {
        let g = try AIEconomyTests.loadGame()
        guard let (i, c) = computerTown(g), let def = g.tables?.creature(c) else { throw XCTSkip("no town") }
        g.resources = ["Gold": 10 * def.gold + 5, "Wood": 0, "Ore": 0, "Crystal": 0, "Sulfur": 0, "Mercury": 0, "Gems": 0]
        let n = g.townRecruit(i, c, count: 25)
        XCTAssertEqual(n, 10)                                   // limited by the funds
        XCTAssertEqual(g.resources["Gold"], 5)
        XCTAssertEqual(g.towns[i].available[c], 20)              // the population pays too
        XCTAssertEqual(g.towns[i].garrison.first?.count, 10)
        // a discounted gold price replaces the creature's gold
        g.resources["Gold"] = 1000
        XCTAssertEqual(g.townRecruit(i, c, count: 1, gold: 0), 1)
        XCTAssertEqual(g.resources["Gold"], 1000)
    }

    func testEmergencyRecruitStopsWhenTheGarrisonHolds() throws {
        let g = try AIEconomyTests.loadGame()
        let ai = g.map.humanColour == 1 ? 2 : 1
        guard let (i, c) = computerTown(g, colour: ai), let p = g.townPlaced(i), let def = g.tables?.creature(c) else { throw XCTSkip("no town") }
        // a weak human army at the gate
        let gate = g.gateCells(p)[0]
        let h = Hero(actor: "hero.life_might_male", x: gate.0 + 1, y: gate.1 + 1, movement: 20)
        h.heroless = true; h.owner = g.map.humanColour; h.z = g.towns[i].z
        h.army = [Hero.Stack(creature: c, count: 1)]
        h.maxMovement = 20; h.movement = 20
        g.heroes = [h]
        XCTAssertEqual(g.townThreats(i).count, 1)
        g.aiResources[ai] = ["Gold": 100 * def.gold]
        g.acting(as: ai) { g.aiDefendTowns(ai) }
        // bought from the highest built dwelling down (the town may have more than the one set up)
        XCTAssertGreaterThan(g.towns[i].garrison.reduce(0) { $0 + $1.count }, 0)
        XCTAssertLessThan(g.aiResources[ai]?["Gold"] ?? 0, 100 * def.gold)
        XCTAssertTrue(g.garrisonHolds(i, against: [h]))
        // no threat: nothing bought
        g.heroes = []
        let before = g.aiResources[ai]?["Gold"]
        g.acting(as: ai) { g.aiDefendTowns(ai) }
        XCTAssertEqual(g.aiResources[ai]?["Gold"], before)
    }

    func testComputerNewDayIncome() throws {
        let g = try AIEconomyTests.loadGame()
        let human = g.map.humanColour
        guard human <= 1 else { throw XCTSkip("no handicapped colour") }
        let colour = human == 0 ? 1 : 0
        guard let (i, _) = computerTown(g, colour: colour) else { throw XCTSkip("no town") }
        XCTAssertEqual(g.towns[i].owner, colour)
        g.difficulty = 4
        g.aiResources[colour] = GameState.startingResources(difficulty: 4, computer: true)
        let income = g.incomeByMaterial(of: colour)
        g.day = 2
        g.aiNewDay()
        XCTAssertEqual(g.aiResources[colour]?["Gold"], 20000 + 2 * income[0])   // Impossible: twice the income
        g.difficulty = 1
        g.aiResources[colour] = ["Gold": 0]
        g.aiNewDay()
        XCTAssertEqual(g.aiResources[colour]?["Gold"], income[0])
    }

    func testBuildingsOnePerTownWithinTheBudget() throws {
        let g = try AIEconomyTests.loadGame()
        let ai = g.map.humanColour == 1 ? 2 : 1
        guard let (i, _) = computerTown(g, colour: ai) else { throw XCTSkip("no town") }
        for k in g.towns.indices where k != i && g.towns[k].owner == ai { g.towns[k].owner = nil }
        g.towns[i].builtToday = false
        let rich = ["Gold": 100000, "Wood": 100, "Ore": 100, "Crystal": 50, "Sulfur": 50, "Mercury": 50, "Gems": 50]
        g.aiResources[ai] = rich
        let before = g.towns[i].buildings
        g.acting(as: ai) {
            g.aiComputeWeights(ai)
            g.aiComputeBudget(ai, withIncome: true)
            g.aiBuild(ai)
        }
        let added = g.towns[i].buildings.subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(g.towns[i].builtToday)
        // the best ratio was taken: a dwelling (value xp x growth) beats the zero-value buildings
        let def = g.tables?.buildings(for: g.towns[i].alignment).first { added.contains($0.keyword) }
        XCTAssertNotNil(def?.creature ?? (added.contains("town hall") || added.contains("city hall") ? "hall" : nil))
        // a material at 0 blocks every building (budget > cost is strict)
        g.towns[i].builtToday = false
        var poor = rich; poor["Mercury"] = 0
        g.aiResources[ai] = poor
        let now = g.towns[i].buildings
        g.acting(as: ai) { g.aiComputeBudget(ai, withIncome: false); g.aiBuild(ai) }
        XCTAssertEqual(g.towns[i].buildings, now)
    }

    func testCostValueAndWeights() throws {
        let g = try AIEconomyTests.loadGame()
        XCTAssertEqual(g.costValue([1000, 5, 0, 1, 0, 0, 0], [1, 125, 125, 250, 250, 250, 250]), 1000 + 625 + 250)
        XCTAssertEqual(g.costValue([3, 0, 0, 0, 0, 0, 0], [1.5, 1, 1, 1, 1, 1, 1]), 4)   // truncated
    }
}
