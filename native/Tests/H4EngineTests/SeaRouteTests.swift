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

    // MARK: armies meeting across the shore (0x522560)

    func landHero(_ g: GameState, _ x: Int, _ y: Int, owner: Int? = nil) -> Hero {
        let h = Hero(actor: "hero.order_might_male", x: x, y: y, movement: 30)
        h.owner = owner ?? g.map.humanColour; h.maxMovement = 30
        h.army = [Hero.Stack(creature: "peasant", count: 20)]
        return h
    }

    /// A land army routed into its own army aboard the ship (the step onto the ship's water cell,
    /// 0x4fee2d) meets it: the army screen of the two (0x522c6a), a stack changing between the
    /// ship and the shore paying all its movement left (0x646e72); leaders swapping rows keep the
    /// armies' places, the ship staying with its row (army +0xc8), and a row left with nothing
    /// aboard leaves the empty ship.
    func testLandArmyMeetsItsArmyAboardAndTrades() throws {
        let g = try pirateDaughter()
        let a = try aboard(g)
        let b = landHero(g, 188, 110)
        g.heroes = [a, b]
        g.click(hero: b, x: a.x, y: a.y)
        XCTAssertTrue(b.plan.allSatisfy { !g.passability.isWater($0.x, $0.y) })
        g.click(hero: b, x: a.x, y: a.y)
        walk(g, b)
        XCTAssertTrue(GameState.adjacent((b.x, b.y), (a.x, a.y)))
        XCTAssertNil(g.pendingHeroBattle)
        let t = try XCTUnwrap(g.pendingTrade); XCTAssertTrue(t.hero === b && t.other === a)
        g.pendingTrade = nil
        let shore = (b.x, b.y), ship = (a.x, a.y)

        let x = g.exchange(b, with: a)
        XCTAssertTrue(x.crossesMedium)
        let left = b.movement
        XCTAssertGreaterThan(left, 1)
        // the peasants go aboard: all of the stack's movement, more than the water's entry cost
        let k = try XCTUnwrap(x.rows[0].firstIndex { $0?.stack != nil })
        let free = try XCTUnwrap(x.rows[1].firstIndex { $0 == nil })
        XCTAssertNil(x.move(from: (0, k), to: (1, free)))
        XCTAssertEqual(x.remaining(1, free), 0, accuracy: 0.001)
        // the leaders swap rows: the ship's hero ashore, the shore's hero aboard
        XCTAssertNil(x.move(from: (1, 0), to: (0, 0)))
        g.finishExchange(x)
        let ashore = try XCTUnwrap(g.heroes.first { $0 === a }), afloat = try XCTUnwrap(g.heroes.first { $0 === b })
        XCTAssertEqual([ashore.x, ashore.y], [shore.0, shore.1]); XCTAssertNil(ashore.boat)
        XCTAssertEqual([afloat.x, afloat.y], [ship.0, ship.1]); XCTAssertEqual(afloat.boat, "chaos")
        XCTAssertEqual(g.heroes.count, 2)

        // a fresh pair: everything ashore leaves the row aboard empty, and the empty ship stays
        let a2 = try aboard(g), b2 = landHero(g, shore.0, shore.1)
        g.heroes = [a2, b2]
        let y = g.exchange(b2, with: a2)
        for k in 0..<GameState.rowSlots where y.rows[1][k] != nil {
            let j = try XCTUnwrap(y.rows[0].firstIndex { $0 == nil })
            XCTAssertNil(y.move(from: (1, k), to: (0, j)))
        }
        g.finishExchange(y)
        XCTAssertEqual(g.heroes.count, 1)
        XCTAssertTrue(g.heroes[0] === b2); XCTAssertNil(b2.boat); XCTAssertEqual(b2.companions.count, 1)
        XCTAssertEqual(g.boat(at: ship.0, ship.1).map { g.boats[$0].alignment }, "chaos")
        XCTAssertNil(a2.boat)
    }

    /// An enemy army aboard is attacked from the shore and an enemy on the shore from the ship
    /// (0x522560 -> 0x521780; the afloat step onto an army's land cell, 0x4feb64 -> t_army
    /// vtable+0x34 true); the fight is on the one ship's deck.
    func testArmiesFightAcrossTheShore() throws {
        let g = try pirateDaughter()
        let foe = (g.map.humanColour + 1) % 8
        // the enemy aboard at (189,109), the hero on the beach (188,110)
        let e = landHero(g, 189, 109, owner: foe); e.boat = "death"
        g.place(enemy: e)
        let b = landHero(g, 188, 110)
        g.heroes = [b]
        g.click(hero: b, x: 189, y: 109)
        XCTAssertTrue(b.attackTarget === e)
        g.click(hero: b, x: 189, y: 109)
        XCTAssertTrue(try XCTUnwrap(g.pendingHeroBattle).enemy === e)
        XCTAssertEqual(GameState.shipField(attacker: b.boat, defender: e.boat), ["Death.single"])
        g.pendingHeroBattle = nil; g.removeEnemy(e)

        // the ship sails up to an enemy on the beach
        let a = try aboard(g)
        let f = landHero(g, 188, 110, owner: foe)
        g.place(enemy: f)
        g.click(hero: a, x: 188, y: 110)
        XCTAssertFalse(a.plan.isEmpty)
        XCTAssertTrue(a.plan.allSatisfy { g.passability.isSea($0.x, $0.y) })
        // the route's X is on the army it ends on (0x4d8250: element 0), not on the stop before it
        let marks = g.arrows(for: a)
        XCTAssertEqual(marks.count, a.plan.count + 1)
        XCTAssertEqual(marks.last.map { [$0.x, $0.y] }, [188, 110]); XCTAssertTrue(marks.last?.name.hasSuffix(".dest") == true)
        g.click(hero: a, x: 188, y: 110)
        walk(g, a)
        XCTAssertEqual(a.boat, "chaos")
        XCTAssertTrue(GameState.adjacent((a.x, a.y), (188, 110)))
        XCTAssertTrue(try XCTUnwrap(g.pendingHeroBattle).enemy === f)
        XCTAssertEqual(GameState.shipField(attacker: a.boat, defender: f.boat), ["Chaos.single"])
    }

    /// The battlefield by the sides' ships (0x62af00): none the land, one its deck, two the
    /// defender's upper deck then the attacker's lower; a ship of no alignment adds no deck (0x628300
    /// builds "netural.", which no archive holds), so alone it fights on open water.
    func testShipBattlefields() {
        XCTAssertNil(GameState.shipField(attacker: nil, defender: nil))
        XCTAssertEqual(GameState.shipField(attacker: "life", defender: nil), ["Life.single"])
        XCTAssertEqual(GameState.shipField(attacker: nil, defender: "might"), ["Might.single"])
        XCTAssertEqual(GameState.shipField(attacker: "order", defender: "nature"), ["Nature.upper", "Order.lower"])
        XCTAssertEqual(GameState.shipField(attacker: "generic", defender: nil), [])
        XCTAssertEqual(GameState.shipField(attacker: "generic", defender: "death"), ["Death.upper"])
        XCTAssertEqual(GameState.shipField(attacker: "life", defender: "generic"), ["Life.lower"])
        XCTAssertEqual(Battle.deployment[Battle.Formation.ship.rawValue].count, 2)
    }

    /// The decks' cells (0x584400 / 0x562c80 / 0x562e90): the grid's rows are the 102-cell
    /// battle rows clipped to the scene (4838 cells), read last row first; -1 blocks, 1 and 2 are
    /// deck, 0 leaves the cell to the deck before; a row's ends and x + y <= 54 stay blocked.
    func testDeckCells() throws {
        XCTAssertEqual((0..<Battlefield.size).reduce(0) { $0 + Battlefield.rowCells($1).count }, 4838)
        XCTAssertEqual(Battlefield.rowCells(0), 37..<38)
        XCTAssertEqual(Battlefield.rowCells(37), 0..<75)
        XCTAssertFalse(Battlefield.inGrid(37, 0)); XCTAssertFalse(Battlefield.inGrid(37, 74)); XCTAssertFalse(Battlefield.inGrid(27, 27))
        XCTAssertTrue(Battlefield.inGrid(37, 73)); XCTAssertTrue(Battlefield.inGrid(50, 50))
        let a = try StartPlacementTests().archive().0
        func deck(_ n: String) throws -> Data { try a.payload(try XCTUnwrap(a.byName.keys.first { $0.lowercased() == "battlefield_preset_map.\(n).h4d" })) }
        // one ship: its deck all over, the rails (top right, bottom left) blocked
        let single = Battlefield(presets: [try deck("life.single")])
        XCTAssertNotNil(single.backdrop); XCTAssertNil(single.overlay)
        let g = try XCTUnwrap(Battlefield.presetGrid(try deck("life.single")))
        XCTAssertEqual(g[50 * 102 + 50], 1)
        XCTAssertTrue(single.isOpen(50, 50))
        let rails = (0..<102).flatMap { x in Battlefield.rowCells(x).map { (x, $0) } }.filter { g[$0.0 * 102 + $0.1] == 255 }
        XCTAssertFalse(rails.isEmpty)
        XCTAssertTrue(rails.allSatisfy { !single.isOpen($0.0, $0.1) })
        // two ships: the upper deck's hull (-1) under the lower deck (1) is the lower ship's deck;
        // where the lower has nothing (0) the upper's cells hold
        let up = try XCTUnwrap(Battlefield.presetGrid(try deck("life.upper"))), lo = try XCTUnwrap(Battlefield.presetGrid(try deck("life.lower")))
        let two = Battlefield(presets: [try deck("life.upper"), try deck("life.lower")])
        XCTAssertNotNil(two.overlay)
        var checked = 0
        for x in 0..<102 { for y in Battlefield.rowCells(x) where Battlefield.inGrid(x, y) {
            let i = x * 102 + y
            let want: Bool = lo[i] == 0 ? up[i] != 255 && up[i] != 0 || (up[i] == 0) : lo[i] != 255
            XCTAssertEqual(two.isOpen(x, y), want && Battlefield.onField(x, y), "\(x),\(y)")
            if lo[i] == 1 && up[i] == 255 { checked += 1 }
        } }
        XCTAssertGreaterThan(checked, 100)
        // no deck at all: open water
        let water = Battlefield(presets: [])
        XCTAssertNil(water.backdrop)
        XCTAssertTrue(water.isOpen(50, 50)); XCTAssertFalse(water.isOpen(27, 27))
    }
}
