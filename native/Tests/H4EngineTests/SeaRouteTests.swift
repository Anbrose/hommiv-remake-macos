import XCTest
@testable import H4Engine

/// Ships routed to water objects and sea stacks (re/adventure_pathing_spec.md §2, §4): the one
/// planner (0x4ff180) with the army afloat -- water cells only, the landing the last step,
/// objects on the water entered across their entry edges.
final class SeaRouteTests: XCTestCase {
    func pirateDaughter() throws -> GameState {
        let t = StartPlacementTests()
        let (a, names) = try t.archive()
        let m = try MapFile(data: CampaignFile.load(4, from: a).scenario(0), objectNames: names)
        let masks = try TransitionMasks(data: a.payload("transition.Transitions.h4d"))
        let g = GameState(map: m, level: 0, scenes: [try MapScene(map: m, level: 0, archive: a, masks: masks)])
        let data = StartPlacementTests.root.appendingPathComponent("Data")
        g.tables = try RuleTables(archive: H4Archive(url: data.appendingPathComponent("text.h4r")))
        g.registerObjects(townFactions: [:])
        g.fogEnabled = false
        return g
    }

    /// A hero's army (the only one) boarding the empty chaos ship at (189,108) from (188,110), with a day's sea movement.
    func aboard(_ g: GameState) throws -> Hero {
        let h = Hero(actor: "hero.life_might_male", x: 188, y: 110, movement: 30)
        h.owner = g.map.humanColour
        h.army = [Hero.Stack(creature: g.tables?.creatures.first { $0.level == 4 }?.keyword ?? "peasant", count: 50)]
        g.heroes = [h]
        if g.boat(at: 189, 108) == nil { g.boats.append(Boat(x: 189, y: 108, z: 0, alignment: "chaos", owner: nil)); g.passability.block(189, 108) }
        g.board(h, try XCTUnwrap(g.boat(at: 189, 108)))
        h.movement = 30; h.maxMovement = 30
        return h
    }
    func walk(_ g: GameState, _ h: Hero) {
        for _ in 0..<1800 where h.isWalking || g.charge != nil {
            g.update(dt: 1.0 / 30)
            if g.pendingBattle != nil { break }
        }
    }

    /// Sailing to a flotsam (196,107), a sea chest (208,106), a mermaid stack (195,98), and landing on the shore: the
    /// first click plans a route over water into the object (the ship stops beside it), the
    /// second walks it and the object is used / the stack attacked.
    func testShipRoutesToWaterObjectsAndStacksAndLands() throws {
        let g = try pirateDaughter()
        var h = try aboard(g)
        let p = g.passability
        XCTAssertEqual([h.x, h.y], [189, 108]); XCTAssertEqual(h.boat, "chaos")

        // the flotsam: routed over water, stopping next to it
        let flotsam = try XCTUnwrap(g.scene.placed.first { $0.type == "flotsam" && $0.cellX == 196 && $0.cellY == 107 })
        g.click(hero: h, pickup: flotsam)
        let plan = h.plan
        XCTAssertFalse(plan.isEmpty)
        XCTAssertTrue(plan.allSatisfy { p.isSea($0.x, $0.y) })
        let end = try XCTUnwrap(plan.last)
        XCTAssertTrue(GameState.adjacent((end.x, end.y), (196, 107)))
        g.click(hero: h, pickup: flotsam)
        XCTAssertTrue(h.isWalking)
        walk(g, h)
        XCTAssertEqual(h.x, end.x); XCTAssertEqual(h.y, end.y)
        XCTAssertEqual(h.boat, "chaos")
        XCTAssertFalse(g.scene.placed.contains { $0.type == "flotsam" && $0.cellX == 196 && $0.cellY == 107 })

        // the sea chest (208,106): the same, picked up from beside it
        h = try aboard(g)
        let chest = try XCTUnwrap(g.scene.placed.first { $0.subtype == "sea_chest" && $0.cellX == 208 && $0.cellY == 106 })
        g.click(hero: h, pickup: chest)
        XCTAssertTrue(h.plan.allSatisfy { p.isSea($0.x, $0.y) })
        let stop = try XCTUnwrap(h.plan.last)
        XCTAssertTrue(GameState.adjacent((stop.x, stop.y), (208, 106)))
        g.click(hero: h, pickup: chest)
        walk(g, h)
        XCTAssertEqual([h.x, h.y], [stop.x, stop.y])
        XCTAssertFalse(g.scene.placed.contains { $0.subtype == "sea_chest" && $0.cellX == 208 && $0.cellY == 106 })
        g.scripts.messages = []; g.question = nil; g.choice = nil; g.chestOffer = nil

        // the mermaids: routed into the stack's cell over water, attacked from beside it
        h = try aboard(g)
        let mermaid = try XCTUnwrap(g.scene.placed.first { g.monster(for: $0) == 98 })
        XCTAssertEqual(g.monsters[98].creature, "mermaid")
        g.click(hero: h, pickup: mermaid)
        XCTAssertFalse(h.plan.isEmpty)
        XCTAssertTrue(h.plan.allSatisfy { p.isSea($0.x, $0.y) })
        g.click(hero: h, pickup: mermaid)
        walk(g, h)
        XCTAssertTrue(GameState.adjacent((h.x, h.y), (195, 98)))
        XCTAssertEqual(g.pendingBattle?.monster, 98)

        // landing on the beach the army came from (one step over water first): the empty ship stays behind
        g.pendingBattle = nil
        h = try aboard(g)
        g.click(hero: h, x: 188, y: 110)
        XCTAssertEqual(h.plan.map { [$0.x, $0.y] }, [[189, 109], [188, 110]])
        g.click(hero: h, x: 188, y: 110)
        walk(g, h)
        XCTAssertNil(h.boat)
        XCTAssertEqual([h.x, h.y], [188, 110])
        XCTAssertNotNil(g.boat(at: 189, 109))
    }
}
