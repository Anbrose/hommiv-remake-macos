import XCTest
@testable import H4Engine

/// The events of towns and heroes (t_ownable_timed_event, 0x7d5750 / 0x7321a0): a due one runs on
/// its owner's turn when its filter takes the owner (0x7d2d70), with the town or hero as "this".
/// "Allies Lost" (campaign 10, scenario 2) hands three of Dogwoggle's towns to Carsas on day 3,
/// reinforces them on the computer's day 4, and feeds Carsas Blacksword every week from day 14.
final class OwnedEventTests: XCTestCase {
    func game(_ scenario: Int) throws -> GameState {
        let g = try EndSequenceTests().loadGame(campaign: (10, scenario), allLevels: true)
        g.loadScripts()
        return g
    }
    func town(_ g: GameState, at x: Int, _ y: Int) throws -> Int { try XCTUnwrap(g.towns.firstIndex { $0.x == x && $0.y == y }) }
    func army(_ g: GameState, _ name: String) throws -> Hero {
        let o = try XCTUnwrap(g.map.objects.first { $0.heroes.contains { $0.name == name } })
        let h = Hero.fromMap(o.heroes[0], alignment: "might", x: o.x, y: o.y, tables: g.tables, random: &g.random)
        h.owner = o.owner ?? 0; h.z = o.level
        return h
    }

    func testCarsasTakesTheTownsOnDayThreeAndTheyFallBackToFog() throws {
        let g = try game(1)
        let human = g.map.humanColour
        let mortis = try town(g, at: 44, 55), austri = try town(g, at: 67, 125), thasos = try town(g, at: 122, 78), keep = try town(g, at: 89, 29)
        for t in [mortis, austri, thasos, keep] { g.towns[t].owner = human; g.towns[t].owned = true }
        g.updateVision()
        XCTAssertEqual(g.fogState(44, 55, level: g.towns[mortis].z), GameState.fogSeen)
        g.day = 2; g.runDayEvents()
        XCTAssertEqual(g.towns[mortis].owner, human)   // not yet
        g.day = 3; g.runDayEvents()
        for t in [mortis, austri, thasos] { XCTAssertEqual(g.towns[t].owner, 1); XCTAssertFalse(g.towns[t].owned) }
        XCTAssertEqual(g.towns[keep].owner, human)
        XCTAssertTrue(g.scripts.messages.contains { $0.hasPrefix("Treachery most foul!") })
        // the lost town no longer sees: its cells drop back to fog (0x4e0a60)
        g.updateVision()
        XCTAssertEqual(g.fogState(44, 55, level: g.towns[mortis].z), GameState.fogExplored)

        // the computer's day 4: "Comp reinforcements" (computer only) fills the garrison and builds
        g.day = 4
        g.runDayEvents()
        XCTAssertTrue(g.towns[austri].garrison.isEmpty)   // the human's turn does not run them
        let built = g.towns[austri].buildings.count
        g.runOwnedTimedEvents(for: 1)
        XCTAssertEqual(g.towns[austri].garrison.map { "\($0.count) \($0.creature)" }, ["40 berserker", "10 Centaur"])
        XCTAssertEqual(g.towns[austri].buildings.count, built + 1)
        XCTAssertTrue(g.heroes.allSatisfy { $0.army.isEmpty })   // nothing went to the human's armies
    }

    func testCarsasIsReinforcedEveryWeekFromDayFourteen() throws {
        let g = try game(1)
        let carsas = try army(g, "Carsas Blacksword")
        g.place(enemy: carsas)
        let before = carsas.army.reduce(0) { $0 + $1.count }
        g.day = 13; g.runOwnedTimedEvents(for: carsas.owner)
        XCTAssertEqual(carsas.experience, 0)
        g.day = 14; g.runOwnedTimedEvents(for: carsas.owner)
        XCTAssertEqual(carsas.experience, 1500)
        XCTAssertEqual(carsas.level, Hero.level(for: 1500))   // a computer hero takes its levels at once
        XCTAssertEqual(carsas.army.reduce(0) { $0 + $1.count }, before + 20 + 10 + 5 + 1)
        XCTAssertNil(g.levelUp)
        g.day = 21; g.runOwnedTimedEvents(for: carsas.owner)
        XCTAssertEqual(carsas.experience, 3000)
        g.runOwnedTimedEvents(for: g.map.humanColour)   // not on another player's turn
        XCTAssertEqual(carsas.experience, 3000)
    }

    // "The Unexpected Prize": Adram Blacksword's army record has "Adram bonus." (computer only, weekly from day 7)
    func testAdramsArmyIsReinforcedOnHisTurns() throws {
        let g = try game(0)
        let adram = try army(g, "Adram Blacksword")
        g.place(enemy: adram)
        let before = adram.army.reduce(0) { $0 + $1.count }
        g.day = 7
        g.runOwnedTimedEvents(for: g.map.humanColour)
        XCTAssertEqual(adram.army.reduce(0) { $0 + $1.count }, before)
        g.runOwnedTimedEvents(for: adram.owner)
        XCTAssertGreaterThan(adram.army.reduce(0) { $0 + $1.count }, before)
    }

    // detonate (0x4df4b0): the objects on the cells of the deletion markers of that name go
    func testDetonateRemovesTheObjectsOnItsMarkers() throws {
        let (a, names) = try StartPlacementTests().archive()
        let c = try CampaignFile.load(3, from: a)
        let k = try XCTUnwrap((0..<c.count).first { k in
            (try? MapFile(data: c.scenario(k), objectNames: names))?.objects.contains { $0.type == "deletion_marker" && $0.text == "Gate" } ?? false
        })
        let g = try EndSequenceTests().loadGame(campaign: (3, k), allLevels: true)
        let m = try XCTUnwrap(g.map.objects.first { $0.type == "deletion_marker" && $0.text == "Gate" })
        func on(_ p: MapScene.Placed) -> Bool { m.x >= p.cellX && m.x < p.cellX + p.sprite.footprint.w && m.y >= p.cellY && m.y < p.cellY + p.sprite.footprint.h }
        XCTAssertTrue(g.scenes[m.level].placed.contains(where: on))
        g.detonate("Gate")
        XCTAssertFalse(g.scenes[m.level].placed.contains(where: on))
    }

    // "The Unexpected Prize": the ambush triggers ask has_hero(this army, "Dogwoggle")
    func testHasHeroLooksAtTheTriggeringArmy() throws {
        let g = try game(0)
        let dog = try army(g, "Dogwoggle")
        g.heroes = [dog]
        g.runPlacedEvents(named: "Ambush if no Dogwoggle.", hero: dog)
        XCTAssertTrue(g.scripts.messages.contains { $0.hasPrefix("Adram Blacksword sees you coming") })
        XCTAssertFalse(g.scripts.messages.contains { $0.hasPrefix("Ambush!") })
    }
}
