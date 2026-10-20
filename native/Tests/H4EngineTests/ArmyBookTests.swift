import XCTest
@testable import H4Engine

/// The army screen's spell book button (0x650ed0 / 0x5385d0): when it shows, and potions drunk from the book.
final class ArmyBookTests: XCTestCase {
    func testSpellBookButtonAndPotions() throws {
        let g = try MagiWindowTests().loadGame()
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 20)
        func id(_ k: String) -> Int { RuleTables.artifactIds.firstIndex(of: k)! }
        h.equipped = Array(repeating: nil, count: 14); h.backpack = []
        h.spellPoints = 0
        XCTAssertFalse(g.showsSpellBook(h))   // no points, nothing to cast
        h.backpack = [id("crown"), id("potion_of_mana"), id("telescope")]
        XCTAssertTrue(g.showsSpellBook(h))    // a potion in the backpack
        let pots = g.backpackPotions(h)
        XCTAssertEqual(pots.values.flatMap { $0 }, [1])
        let sp = try XCTUnwrap(pots.keys.first)
        let knew = h.spells.contains(sp)
        XCTAssertTrue(g.drink(h, backpackIndex: 1))
        XCTAssertEqual(h.backpack, [id("crown"), id("telescope")])
        XCTAssertEqual(h.spellPoints, 25)      // Mana: +25, the potion pays for itself
        XCTAssertEqual(h.spells.contains(sp), knew)   // drinking teaches nothing
        h.spellPoints = 5
        XCTAssertTrue(g.showsSpellBook(h))    // spell points left
    }
}
