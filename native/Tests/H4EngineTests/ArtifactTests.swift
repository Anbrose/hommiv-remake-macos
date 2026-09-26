import XCTest
@testable import H4Engine

final class ArtifactTests: XCTestCase {
    func testWornItemsCountAndBackpackDoesNot() {
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 20)
        h.backpack = [0]                           // adamantine armor in the backpack: nothing
        XCTAssertEqual(h.artifactSum(0x0a), 0)
        XCTAssertTrue(h.equip(backpackIndex: 0, tables: nil) == false)   // no table: no slot known
        h.equipped[12] = 0                         // worn on the torso: +50 defense (500 tenths)
        XCTAssertEqual(h.artifactSum(0x0a), 500)
        h.equipped[13] = 29                        // caduceus: +100% power for healing spells
        XCTAssertEqual(h.spellPowerBonus(56), 100)
        XCTAssertEqual(h.spellPowerBonus(71), 0)
    }
    func testSetBonusNeedsEveryPiece() {
        let h = Hero(actor: "hero.life_might_male", x: 0, y: 0, movement: 20)
        guard let set = RuleTables.artifactEffects.values.flatMap({ $0 }).first(where: { $0.type == 59 }) else { return XCTFail() }
        h.equipped[0] = set.required[0]
        let without = h.artifactEffects.count
        for (k, id) in set.required.enumerated() { h.equipped[k] = id }
        XCTAssertGreaterThan(h.artifactEffects.count, without)
    }
}
