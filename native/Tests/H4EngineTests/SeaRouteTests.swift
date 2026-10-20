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

    /// On land a step onto open water enters only an army aboard a ship (0x4fea80 at 0x4fee2d:
    /// t_army vtable+0x38 = its ship set, 0x525b60): a hero on the beach gets no route into the
    /// sea cartographer (31,135) from (30,136), nor into a sea chest or flotsam moved next to a
    /// beach; the empty ship (189,108) is still walked to and boarded.
    func testLandArmyEntersNoWaterObjectFromTheShore() throws {
        let g = try pirateDaughter()
        let h = Hero(actor: "hero.life_might_male", x: 30, y: 136, movement: 30)
        h.owner = g.map.humanColour
        h.army = [Hero.Stack(creature: "peasant", count: 50)]
        g.heroes = [h]
        let p0 = g.passability
        let carto = try XCTUnwrap(g.scene.placed.first { $0.type == "cartographer" && $0.cellX == 31 && $0.cellY == 135 })
        XCTAssertTrue(p0.isSea(31, 135)); XCTAssertTrue(p0.enters(from: 30, 136, to: 31, 135))
        XCTAssertNil(p0.routeInto(g.entryCells(carto), from: (30, 136)))
        g.click(hero: h, pickup: carto)
        XCTAssertTrue(h.plan.isEmpty); XCTAssertNil(h.target)

        // a sea chest and a flotsam moved beside a beach (the first spot where the whole footprint is free open water)
        for kind in ["sea_chest", "flotsam"] {
            let o = try XCTUnwrap(g.scene.placed.first { $0.subtype == kind || $0.type == kind })
            let fw = o.sprite.footprint.w, fh = o.sprite.footprint.h, ps = g.passability
            var spot: (c: (Int, Int), beach: (Int, Int))? = nil
            search: for x in 1..<(ps.size - fw - 1) { for y in 1..<(ps.size - fh - 1) {
                let cells = (0..<fw).flatMap { i in (0..<fh).map { (x + i, y + $0) } }
                guard cells.allSatisfy({ ps.isFreeWater($0.0, $0.1) && ps.isSea($0.0, $0.1) }) else { continue }
                for e in cells { for d in Passability.directions where ps.isFree(e.0 + d.dx, e.1 + d.dy) && !ps.isWater(e.0 + d.dx, e.1 + d.dy) {
                    spot = ((x, y), (e.0 + d.dx, e.1 + d.dy)); break search
                } }
            } }
            let (c, beach) = try XCTUnwrap(spot, kind)
            h.x = beach.0; h.y = beach.1; h.plan = []; h.target = nil
            g.passability.free(o.cellX, o.cellY)
            let q = g.scene.relocate(o, toX: c.0, y: c.1)
            for i in 0..<fw { for j in 0..<fh { g.passability.block(c.0 + i, c.1 + j) } }
            g.passability.addEntries(try XCTUnwrap(o.sprite.entryEdges), at: c.0, c.1, object: 0)
            XCTAssertTrue(g.entryCells(q).contains { g.passability.enters(from: beach.0, beach.1, to: $0.0, $0.1) }, kind)   // the step the exe refuses
            XCTAssertNil(g.passability.routeInto(g.entryCells(q), from: beach), kind)
            g.click(hero: h, pickup: q)
            g.click(hero: h, pickup: q)
            XCTAssertTrue(h.plan.isEmpty, kind); XCTAssertNil(h.target, kind); XCTAssertFalse(h.isWalking, kind)
            XCTAssertTrue(g.scene.placed.contains { $0.cellX == c.0 && $0.cellY == c.1 && $0.name == o.name }, kind)
        }

        // boarding: walk to the shore beside the ship, then aboard
        h.x = 188; h.y = 110; h.plan = []; h.target = nil
        if g.boat(at: 189, 108) == nil { g.boats.append(Boat(x: 189, y: 108, z: 0, alignment: "chaos", owner: nil)); g.passability.block(189, 108) }
        g.click(hero: h, x: 189, y: 108)
        XCTAssertFalse(h.plan.isEmpty)
        g.click(hero: h, x: 189, y: 108)
        walk(g, h)
        XCTAssertEqual(h.boat, "chaos"); XCTAssertEqual([h.x, h.y], [189, 108])
    }
}
