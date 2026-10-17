import XCTest
@testable import H4Engine

/// The movement shadow's cells (heroes4.exe 0x57bae0 over the cover pass 0x60ea14, combat_shading_spec 2).
final class MovementShadowTests: XCTestCase {
    func fighter(_ k: String, size: Int, move: Int) -> Battle.Fighter {
        let c = CreatureDef(keyword: k, name: k, plural: k, level: 1, alignment: "might", hitPoints: 10, damageLow: 1, damageHigh: 1,
                            attack: 1, defense: 1, move: move, speed: 5, growth: 1, gold: 1, experience: 1, shots: 0, spellPoints: 0,
                            shortHelp: "", longHelp: "")
        return Battle.Fighter(stats: Combatant(creature: c, count: 1), keyword: k, actor: k, size: size, move: move, shots: 0)
    }

    /// A big creature shades the whole footprint of every place it can reach, never its own cells.
    func testFootprintsOfReachablePlacesWithoutOwnCells() {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        let b = Battle(field: field, attackers: [fighter("squire", size: 2, move: 1)], defenders: [fighter("peasant", size: 1, move: 1)], seed: 1)
        let u = b.units.first { $0.side == 0 }!, e = b.units.first { $0.side == 1 }!
        u.x = 50; u.y = 50; e.x = 10; e.y = 80
        _ = b.takeEvents()
        let shadow = b.movementShadow(u)
        // Move 1: the four straight neighbours (diagonals cost 1.5); their 2x2 footprints minus its own 2x2
        var expect = Set<Int>()
        for (px, py) in [(49, 50), (51, 50), (50, 49), (50, 51)] { for i in 0..<2 { for j in 0..<2 { expect.insert(Battle.key(px + i, py + j)) } } }
        for i in 0..<2 { for j in 0..<2 { expect.remove(Battle.key(50 + i, 50 + j)) } }
        XCTAssertEqual(shadow, expect)
        XCTAssertEqual(shadow.count, 8)
    }
}
