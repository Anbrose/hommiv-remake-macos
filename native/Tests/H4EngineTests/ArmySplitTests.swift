import XCTest
@testable import H4Engine

/// Army splitting (army_split_spec.md): the new army's cell, the transfer costs, the rows' moves.
final class ArmySplitTests: XCTestCase {
    func row(_ items: [ArmySlot?]) -> [ArmySlot?] { items + [ArmySlot?](repeating: nil, count: GameState.rowSlots - items.count) }
    func exchange(_ top: [ArmySlot?], _ bottom: [ArmySlot?] = [], spent: Float = 0, entry: [Float] = [1, 1.5], base: Float = 10) -> ArmyExchange {
        ArmyExchange(main: Hero(actor: "hero.x", x: 5, y: 5), other: nil, newCell: (4, 5), rows: [row(top), row(bottom)],
                     spent: [[Float](repeating: spent, count: 7), [Float](repeating: spent, count: 7)], entry: entry, base: [base, base])
    }

    func testNeighboursInTheExeDirectionOrder() {
        // northeast, east, southeast, south, southwest, west, northwest, north (0x705b80)
        XCTAssertEqual(GameState.directions.map { [$0.0, $0.1] }, [[-1, 0], [-1, 1], [0, 1], [1, 1], [1, 0], [1, -1], [0, -1], [-1, -1]])
        let c = GameState.firstNeighbour(of: (10, 10)) { $0 != (9, 10) && $0 != (9, 11) }
        XCTAssertEqual(c.map { [$0.0, $0.1] }, [10, 11])   // the third direction once the first two are taken
        XCTAssertNil(GameState.firstNeighbour(of: (0, 0)) { _ in false })
    }

    func testTransferCostsAreTheRawTerrainOfEachArmysCell() {
        let swamp: UInt8 = 3, snow: UInt8 = 5, grass: UInt8 = 1
        // straight neighbours (same x): each row's own cell, no roads, no diagonal factor
        var c = GameState.transferCosts((5, 5), (5, 6)) { $0 == (5, 5) ? swamp : snow }
        XCTAssertEqual(c.intoA, 2, accuracy: 1e-6); XCTAssertEqual(c.intoB, 1.75, accuracy: 1e-6)
        // diagonal neighbours (both coordinates differ): x 1.5 (cost += cost >> 1)
        c = GameState.transferCosts((5, 5), (6, 6)) { _ in grass }
        XCTAssertEqual(c.intoA, 1.5, accuracy: 1e-6); XCTAssertEqual(c.intoB, 1.5, accuracy: 1e-6)
        c = GameState.transferCosts((23, 50), (22, 50)) { _ in grass }
        XCTAssertEqual(c.intoA, 1, accuracy: 1e-6)
        c = GameState.transferCosts((5, 5), (4, 6)) { _ in nil }   // off the map: 100
        XCTAssertEqual(c.intoB, 1.5, accuracy: 1e-6)
    }

    func testMovingIntoTheNewArmyCostsAndMovingBackRefunds() {
        let x = exchange([.stack(Hero.Stack(creature: "squire", count: 10)), .stack(Hero.Stack(creature: "squire", count: 3))], spent: 2)
        XCTAssertNil(x.move(from: (0, 0), to: (1, 2)))
        XCTAssertEqual(x.rows[1][2]?.stack?.count, 10)
        XCTAssertEqual(x.spent[1][2], 3.5, accuracy: 1e-6)   // 2 spent + 1.5 into the bottom row
        XCTAssertNil(x.move(from: (1, 2), to: (0, 4)))       // back to the top: the 1.5 is refunded
        XCTAssertEqual(x.spent[0][4], 2, accuracy: 1e-6)
        XCTAssertNil(x.rows[1][2])
    }

    func testNotEnoughMovementRefusesTheTransfer() {
        let x = exchange([.stack(Hero.Stack(creature: "squire", count: 1)), .stack(Hero.Stack(creature: "dwarf", count: 4))], spent: 9)
        XCTAssertEqual(x.move(from: (0, 0), to: (1, 0)), .needsMovement(plural: false))   // 1 left, 1.5 needed
        XCTAssertEqual(x.move(from: (0, 1), to: (1, 0)), .needsMovement(plural: true))
        XCTAssertEqual(x.rows[0][0]?.stack?.count, 1)
        XCTAssertNil(x.move(from: (0, 0), to: (0, 3)))   // within a row: free
    }

    func testSplitMergeAndSwap() {
        let x = exchange([.stack(Hero.Stack(creature: "squire", count: 10)), .stack(Hero.Stack(creature: "dwarf", count: 4))],
                         [.stack(Hero.Stack(creature: "squire", count: 2))])
        XCTAssertNil(x.move(from: (0, 0), to: (1, 0), split: 3))   // 3 of 10 onto the same creature
        XCTAssertEqual(x.rows[0][0]?.stack?.count, 7); XCTAssertEqual(x.rows[1][0]?.stack?.count, 5)
        XCTAssertNil(x.move(from: (0, 1), to: (1, 0)))              // a different creature: they swap
        XCTAssertEqual(x.rows[1][0]?.stack?.creature, "dwarf"); XCTAssertEqual(x.rows[0][1]?.stack?.creature, "squire")
        x.moveAll(from: 0, to: 1)
        XCTAssertTrue(x.rows[0].allSatisfy { $0 == nil })
        XCTAssertEqual(x.rows[1].compactMap { $0?.stack?.count }.reduce(0, +), 16)
    }

    func testHerolessArmyHasNoHeroMembersAndIsSaved() {
        let h = Hero(actor: "Gold Golem", x: 3, y: 4)
        h.heroless = true; h.listRank = 5; h.army = [Hero.Stack(creature: "gold golem", count: 12)]
        XCTAssertTrue(h.members.isEmpty)
        let led = Hero(actor: "hero.life_might_male", x: 0, y: 0)
        led.companions = [Hero(actor: "hero.order_magic_female", x: 0, y: 0)]
        XCTAssertEqual(led.members.count, 2)
        let back = SaveGame.hero(from: SaveGame.state(of: h))
        XCTAssertTrue(back.heroless); XCTAssertEqual(back.listRank, 5); XCTAssertEqual(back.actor, "Gold Golem")
        XCTAssertFalse(SaveGame.hero(from: SaveGame.state(of: led)).heroless)
    }
}

/// The whole split on a real scenario's ground (skipped without the game's files).
final class ArmySplitMapTests: XCTestCase {
    static let game = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")
    func state() throws -> GameState {
        let h4r = ArmySplitMapTests.game.appendingPathComponent("Data/heroes4.h4r"), map = ArmySplitMapTests.game.appendingPathComponent("maps/Beyond the lake.h4c")
        guard FileManager.default.fileExists(atPath: h4r.path), FileManager.default.fileExists(atPath: map.path) else { throw XCTSkip("no game files") }
        let archive = try H4Archive(url: h4r)
        let names = Set(archive.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) })
        let m = try MapFile(data: Data(contentsOf: map), objectNames: names)
        let g = GameState(map: m, level: 0, scenes: [])
        g.passabilities = [Passability(map: m, level: 0, objects: [])]
        g.level = 0
        return g
    }
    /// A free land cell whose 8 neighbours are free too.
    func openCell(_ g: GameState) -> (Int, Int)? {
        let p = g.passabilities[0], n = g.map.size
        for x in 2..<(n - 2) { for y in 2..<(n - 2) where p.isFree(x, y) && GameState.directions.allSatisfy({ p.isFree(x + $0.0, y + $0.1) }) { return (x, y) } }
        return nil
    }

    func testSplitMakesAHerolessArmyNextToTheArmyAndSelectsIt() throws {
        let g = try state()
        guard let c = openCell(g) else { throw XCTSkip("no open ground") }
        let h = Hero(actor: "hero.life_might_male", x: c.0, y: c.1, movement: 20)
        h.name = "Theodorus"; h.army = [Hero.Stack(creature: "gold golem", count: 10), Hero.Stack(creature: "squire", count: 5)]
        g.heroes = [h]
        guard let x = g.exchange(for: h) else { return XCTFail("no new army offered") }
        XCTAssertEqual(x.newCell.map { [$0.0, $0.1] }, [c.0 - 1, c.1])   // northeast first
        // the golems go down (they pay the new cell's terrain), the hero and squires stay
        let golems = x.rows[0].firstIndex { $0?.stack?.creature == "gold golem" }!
        XCTAssertNil(x.move(from: (0, golems), to: (1, 0)))
        let selected = g.finishExchange(x)
        XCTAssertEqual(g.heroes.count, 2)
        XCTAssertTrue(selected?.heroless ?? false)
        XCTAssertTrue(g.heroes[0] === selected)
        XCTAssertEqual([selected!.x, selected!.y], [c.0 - 1, c.1])
        XCTAssertEqual(selected?.army.map(\.creature), ["gold golem"])
        XCTAssertEqual(h.army.map(\.creature), ["squire"])
        XCTAssertEqual(g.armyList.first.map { $0 === h }, true)   // the list keeps its order: the new army last
        XCTAssertLessThan(selected!.movement, h.movement + 0.0001)
    }

    func testEightArmiesOrAShipLeaveOneRow() throws {
        let g = try state()
        guard let c = openCell(g) else { throw XCTSkip("no open ground") }
        let h = Hero(actor: "hero.life_might_male", x: c.0, y: c.1)
        g.heroes = [h] + (1..<8).map { k in Hero(actor: "x", x: 0, y: k) }
        XCTAssertNil(g.exchange(for: h))
        g.heroes = [h]; h.boat = "life"
        XCTAssertNil(g.exchange(for: h))
    }

    func testEmptiedArmyLeavesTheMapAndCreaturesWithoutAHeroStayAnArmy() throws {
        let g = try state()
        guard let c = openCell(g) else { throw XCTSkip("no open ground") }
        let hero = Hero(actor: "hero.life_might_male", x: c.0, y: c.1)
        hero.army = [Hero.Stack(creature: "squire", count: 5)]
        g.heroes = [hero]
        // the hero walks off into the new army: the squires stay behind as a heroless army
        let x = g.exchange(for: hero)!
        XCTAssertNil(x.move(from: (0, 0), to: (1, 0)))
        g.finishExchange(x)
        XCTAssertEqual(g.heroes.count, 2)
        let left = g.heroes.first { $0.heroless }
        XCTAssertEqual(left?.army.first?.creature, "squire")
        XCTAssertEqual(left.map { [$0.x, $0.y] }, [c.0, c.1])
        XCTAssertTrue(g.heroes.contains { $0 === hero && hero.army.isEmpty })
        // and a trade that gives everything away removes the emptied army
        let t = g.exchange(hero, with: left!)
        t.moveAll(from: 1, to: 0)
        g.finishExchange(t)
        XCTAssertEqual(g.heroes.count, 1)
        XCTAssertEqual(hero.army.first?.count, 5)
    }
}
