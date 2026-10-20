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
}
