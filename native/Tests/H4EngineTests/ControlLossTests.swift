import XCTest
@testable import H4Engine

/// Who gives a stack its orders when it loses control (0x5737e0 / 0x5740cc, side getter 0x5f3fc0)
/// and the Berserk ability's fear immunity (0x5b3ab4).
final class ControlLossTests: XCTestCase {
    func creature(_ k: String) -> CreatureDef {
        CreatureDef(keyword: k, name: k, plural: k, level: 1, alignment: "might", hitPoints: 10, damageLow: 2, damageHigh: 2,
                    attack: 10, defense: 10, move: 10, speed: 5, growth: 1, gold: 1, experience: 1, shots: 0, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func battle() -> Battle {
        let f = { (k: String) in Battle.Fighter(stats: Combatant(creature: self.creature(k), count: 5), keyword: k, actor: k, size: 2, move: 10, shots: 0) }
        return Battle(field: Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1),
                      attackers: [f("a")], defenders: [f("d")], seed: 1)
    }

    /// Hypnotize and Charm hand the stack to the caster's side: the player commands an enemy stack
    /// they hypnotized, the computer a player's stack it hypnotized.
    func testHypnotizedStackTakesTheCastersOrders() {
        let b = battle()
        let a = b.units.first { $0.side == 0 }!, d = b.units.first { $0.side == 1 }!
        XCTAssertEqual(b.commander(of: a), 0); XCTAssertEqual(b.commander(of: d), 1)
        b.apply(62, to: d, power: 0)
        XCTAssertEqual(b.commander(of: d), 0)
        b.apply(138, to: a, power: 0)
        XCTAssertEqual(b.commander(of: a), 1)
        b.apply(138, to: a, power: 0)   // cast again: freed
        XCTAssertEqual(b.commander(of: a), 0)
    }

    /// Berserk (the spell or the ability) takes the stack out of anyone's hands.
    func testBerserkActsOnItsOwn() {
        let b = battle()
        let a = b.units.first { $0.side == 0 }!, d = b.units.first { $0.side == 1 }!
        b.apply(6, to: a, power: 0)
        XCTAssertNil(b.commander(of: a))
        d.stats.abilities.insert("berserk")
        XCTAssertNil(b.commander(of: d))
        XCTAssertFalse(b.canWait(d))
    }

    /// No Fear spell lands on a stack with the Berserk ability; other Mind spells still do.
    func testBerserkAbilityIsImmuneToFear() {
        let b = battle()
        let a = b.units.first { $0.side == 0 }!, d = b.units.first { $0.side == 1 }!
        XCTAssertTrue(b.canTarget(180, by: a, d, anySide: true))
        d.stats.abilities.insert("berserk")
        XCTAssertFalse(b.canTarget(180, by: a, d, anySide: true))   // Terror
        XCTAssertFalse(b.canTarget(107, by: a, d, anySide: true))   // Panic
        XCTAssertFalse(b.canTarget(37, by: a, d, anySide: true))    // Aura of Fear's effect
        XCTAssertTrue(b.canTarget(62, by: a, d, anySide: true))     // Hypnotize
    }
}
