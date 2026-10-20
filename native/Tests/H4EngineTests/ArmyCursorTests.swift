import XCTest
@testable import H4Engine

/// The pointer over an army or a ship (t_army vtable+0x20, 0x521360): from the shore an empty
/// ship is boarded (activate), from a ship Boat_Activate; an own or allied army, aboard or not,
/// is an exchange, an enemy one -- aboard too -- an attack.
final class ArmyCursorTests: XCTestCase {
    func testShipAndArmyCursorsFromTheShoreAndAfloat() throws {
        let s = SeaRouteTests()
        let g = try s.pirateDaughter()
        // the hero on the beach (188,110) beside the empty chaos ship (189,108)
        let h = s.landHero(g, 188, 110)
        g.heroes = [h]
        if g.boat(at: 189, 108) == nil { g.boats.append(Boat(x: 189, y: 108, z: 0, alignment: "chaos", owner: nil)); g.passability.block(189, 108) }
        XCTAssertFalse(g.passability.isFree(189, 108))   // the ship's water cell: no plain walk
        XCTAssertEqual(g.armyCursor(for: h, at: 189, 108), "activate")
        XCTAssertNil(g.armyCursor(for: h, at: 188, 109))
        // a ship the player owns (left behind by a landing): an exchange, as with an own army
        let b = try XCTUnwrap(g.boat(at: 189, 108))
        g.boats[b].owner = h.owner
        XCTAssertEqual(g.armyCursor(for: h, at: 189, 108), "exchange")
        g.boats[b].owner = nil
        // the click from the shore still walks there and boards
        g.click(hero: h, x: 189, y: 108)
        XCTAssertFalse(h.plan.isEmpty)

        // afloat, another empty ship: Boat_Activate
        let a = try s.aboard(g)
        g.boats.append(Boat(x: 190, y: 107, z: 0, alignment: "life", owner: nil)); g.passability.block(190, 107)
        XCTAssertEqual(g.armyCursor(for: a, at: 190, 107), "Boat_Activate")

        // from the shore: the own army aboard is an exchange, an enemy aboard an attack
        let shore = s.landHero(g, 188, 110)
        g.heroes = [shore, a]
        XCTAssertEqual(g.armyCursor(for: shore, at: a.x, a.y), "exchange")
        let foe = (0..<6).first { $0 != g.map.humanColour && g.team(of: $0) != g.team(of: g.map.humanColour) } ?? 1
        let e = s.landHero(g, 190, 107, owner: foe); e.boat = "death"
        g.enemyHeroes = [e]
        XCTAssertEqual(g.armyCursor(for: shore, at: 190, 107), "attack")
    }

    /// Aboard, the pointer over open water the ship can sail to is Boat_Move (not blocked: the
    /// sea is never free to walk), over the beach it can land on Anchor (0x4f6780), and the
    /// click there plans the same route; a cell no route afloat reaches is blocked.
    func testAfloatMoveCursorsFollowThePlannerAfloat() throws {
        let s = SeaRouteTests()
        let g = try s.pirateDaughter()
        let a = try s.aboard(g)
        let sea = try XCTUnwrap((1...4).lazy.flatMap { r in (-r...r).lazy.flatMap { dx in (-r...r).lazy.map { dy in (a.x + dx, a.y + dy) } } }
            .first { c in c != (a.x, a.y) && g.passability.isSea(c.0, c.1) && g.boat(at: c.0, c.1) == nil && g.passability.path(from: (a.x, a.y), to: c, afloat: true) != nil })
        XCTAssertFalse(g.passability.isFree(sea.0, sea.1))
        XCTAssertNil(g.armyCursor(for: a, at: sea.0, sea.1))
        XCTAssertEqual(g.afloatMoveCursor(for: a, at: sea.0, sea.1), "Boat_Move")
        XCTAssertNotNil(g.daysToReach(a, sea))
        g.click(hero: a, x: sea.0, y: sea.1)
        XCTAssertEqual(a.plan.last.map { [$0.x, $0.y] }, [sea.0, sea.1])
        // the beach the army boarded from: the landing
        XCTAssertEqual(g.afloatMoveCursor(for: a, at: 188, 110), "Anchor")
        // a cell far inland: no route afloat
        let inland = try XCTUnwrap((0..<g.map.size).lazy.flatMap { x in (0..<g.map.size).lazy.map { y in (x, y) } }
            .first { c in !g.passability.isWater(c.0, c.1) && g.passability.isFree(c.0, c.1)
                && (-1...1).allSatisfy { dx in (-1...1).allSatisfy { dy in !g.passability.isWater(c.0 + dx, c.1 + dy) } }
                && g.passability.path(from: (a.x, a.y), to: c, afloat: true) == nil })
        XCTAssertEqual(g.afloatMoveCursor(for: a, at: inland.0, inland.1), "blocked")
    }
}
