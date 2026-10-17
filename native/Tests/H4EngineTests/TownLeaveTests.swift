import XCTest
@testable import H4Engine

/// Garrison troops leaving a town without a visiting army (re/town_army_leave_spec.md).
final class TownLeaveTests: XCTestCase {
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

    /// The human's first surface town (Haven, the exe's cells in front of its two-cell gate known).
    func ownTown(_ g: GameState) throws -> Int {
        guard let i = g.towns.indices.first(where: { g.towns[$0].z == 0 && g.townPlaced($0)?.name.contains("Haven") == true }) else { throw XCTSkip("no Haven town") }
        g.towns[i].owner = g.map.humanColour; g.towns[i].owned = true
        g.heroes = []; g.enemyHeroes = []; g.townVisitor = nil
        return i
    }

    func testCellsInFrontOfTheGateInTheExeOrder() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        let p = g.townPlaced(i)!
        // the gate's trigger cells (5,2) and (5,3) of the 6 x 6 model; each one's neighbours in the
        // direction order (southeast, south, southwest of the table are (+1,+1), (+1,0), (+1,-1))
        XCTAssertEqual(g.entryCells(p).map { [$0.0 - p.cellX, $0.1 - p.cellY] }, [[5, 2], [5, 3]])
        XCTAssertEqual(g.townEntryNeighbours(i).map { [$0.0 - p.cellX, $0.1 - p.cellY] }, [[6, 3], [6, 2], [6, 1], [6, 4]])
        XCTAssertEqual(g.townExitCell(i).map { [$0.0 - p.cellX, $0.1 - p.cellY] }, [6, 3])
    }

    func testEmptyVisitingRowOfferedWithoutAVisitor() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        XCTAssertTrue(g.townOffersVisitingRow(i))           // even with no army at all
        g.towns[i].garrison = []
        XCTAssertTrue(g.townOffersVisitingRow(i))           // and an empty garrison
        // 8 armies: one row only (0x7e1a70)
        g.heroes = (0..<8).map { k in Hero(actor: "x", x: 1, y: k) }
        XCTAssertFalse(g.townOffersVisitingRow(i))
        // an army at the gate visits: its own row, not the empty one
        let front = g.townEntryNeighbours(i)
        let v = Hero(actor: "hero.life_might_male", x: front[1].0, y: front[1].1); v.name = "V"
        g.heroes = [v]
        XCTAssertTrue(g.visitingArmy(town: i) === v)
        XCTAssertFalse(g.townOffersVisitingRow(i))
    }

    func testGarrisonCreaturesLeaveAsAHerolessArmyAndAreSelected() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        let p = g.townPlaced(i)!
        let other = Hero(actor: "hero.life_might_male", x: 1, y: 1, movement: 20); other.name = "Elsewhere"
        g.heroes = [other]
        g.setGarrison(i, [.stack(Hero.Stack(creature: "squire", count: 6)), .stack(Hero.Stack(creature: "crossbowman", count: 4)), nil, nil, nil, nil, nil])
        // drag the squires down into the empty visiting row, then close the screen
        var rows = [g.garrisonSlots(i), [ArmySlot?](repeating: nil, count: GameState.rowSlots)]
        XCTAssertTrue(GameState.move(&rows, from: (0, 0), to: (1, 0)))
        g.setGarrison(i, rows[0])
        let a = g.leaveTown(i, spare: rows[1])
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.heroless ?? false)
        XCTAssertEqual(a.map { [$0.x - p.cellX, $0.y - p.cellY] }, [6, 3])
        XCTAssertEqual(a?.army.map(\.creature), ["squire"])
        XCTAssertTrue(g.heroes.first === a)                      // selected (0x4b5eb0)
        XCTAssertEqual(g.armyList.last.map { $0 === a }, true)   // at the end of the army list
        XCTAssertEqual(a!.movement, a!.maxMovement, accuracy: 0.0001)
        XCTAssertGreaterThan(a!.movement, 0)
        XCTAssertEqual(g.towns[i].garrison.map(\.creature), ["crossbowman"])
        // the next army out takes the next cell in front of the gate
        let b = g.leaveTown(i, spare: [.stack(Hero.Stack(creature: "crossbowman", count: 4)), nil, nil, nil, nil, nil, nil])
        XCTAssertEqual(b.map { [$0.x - p.cellX, $0.y - p.cellY] }, [6, 2])
        // the new army visits the town next time
        g.townVisitor = nil
        XCTAssertTrue(g.visitingArmy(town: i) === a)
    }

    func testAGarrisonHeroLeadsTheCreaturesOut() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 15); h.name = "Garrisoned"; h.maxMovement = 20
        g.towns[i].garrisonHeroes = [h]
        g.towns[i].garrison = [Hero.Stack(creature: "squire", count: 3)]
        let row = g.garrisonSlots(i)
        g.setGarrison(i, [ArmySlot?](repeating: nil, count: GameState.rowSlots))
        let a = g.leaveTown(i, spare: row)
        XCTAssertTrue(a === h)
        XCTAssertFalse(h.heroless)
        XCTAssertEqual(h.army.first?.creature, "squire")
        XCTAssertLessThanOrEqual(h.movement, 15)                  // the hero keeps what it has left
        XCTAssertTrue(g.heroes.first === h)
        XCTAssertTrue(g.towns[i].garrisonHeroes.isEmpty)
    }

    func testBlockedGateFallsBackToTheNearestReachableCellAndAFullListKeepsTheTroops() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        let front = g.townEntryNeighbours(i)
        g.heroes = front.map { c in let h = Hero(actor: "x", x: c.0, y: c.1); h.heroless = true; h.army = [Hero.Stack(creature: "peasant", count: 1)]; return h }
        guard let c = g.townExitCell(i) else { return XCTFail("no wider cell") }
        XCTAssertFalse(front.contains { $0 == c })
        XCTAssertTrue(g.passabilities[0].isFree(c.0, c.1))
        XCTAssertLessThanOrEqual(front.map { max(abs($0.0 - c.0), abs($0.1 - c.1)) }.min() ?? 99, 2)
        // eight armies: nothing leaves, the troops stay in the garrison
        g.heroes += (0..<(GameState.maxArmies - g.heroes.count)).map { k in Hero(actor: "x", x: 1, y: k) }
        g.towns[i].garrison = []
        XCTAssertNil(g.leaveTown(i, spare: [.stack(Hero.Stack(creature: "squire", count: 2)), nil, nil, nil, nil, nil, nil]))
        XCTAssertEqual(g.towns[i].garrison.first?.count, 2)
    }

    func testTheComputerUsesTheSameExitCell() throws {
        let g = try loadGame()
        let i = try ownTown(g)
        XCTAssertEqual(g.gateFree(i).map { [$0.0, $0.1] }, g.townExitCell(i).map { [$0.0, $0.1] })
    }
}
