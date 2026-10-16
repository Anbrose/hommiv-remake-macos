import XCTest
@testable import H4Engine

/// Combat spell rules read from heroes4.exe (combat_spell_logic_audit: power 0x865200, creature
/// casters 0x656c20, summons 0x87c750, raising 0x8058f0, areas 0x717030, ...).
final class SpellLogicTests: XCTestCase {
    func creature(_ keyword: String, level: Int = 1, alignment: String = "might", hp: Int = 10, low: Int = 2, high: Int = 2,
                  attack: Int = 10, defense: Int = 10, speed: Int = 5, exp: Int = 1, sp: Int = 0, power: Int = 0, move: Int = 10) -> CreatureDef {
        var c = CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: level, alignment: alignment, hitPoints: hp, damageLow: low, damageHigh: high,
                            attack: attack, defense: defense, move: move, speed: speed, growth: 1, gold: 1, experience: exp, shots: 0, spellPoints: sp,
                            shortHelp: "", longHelp: "")
        c.spellPower = power
        return c
    }
    func fighter(_ c: CreatureDef, _ n: Int, size: Int = 2) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: c, count: n), keyword: c.keyword, actor: c.keyword, size: size, move: c.move, shots: 0)
    }
    var field: Battlefield { Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1) }
    func hero(level: Int = 10, skills: [String: Int] = [:], spells: [Int], sp: Int = 100) -> Battle.Fighter {
        var st = Combatant(hero: "hero", level: level)
        st.speed = 30
        return Battle.Fighter(stats: st, keyword: "hero", actor: "hero", size: 2, move: 10, shots: 0,
                              caster: Caster(level: level, skills: skills, spells: spells, spellPoints: sp))
    }

    // MARK: creature casters

    /// Creature casters come from 0x656c20, with the stack's own spell points (not per creature).
    func testCreatureCastersFromTheExeTable() {
        let mage = creature("mage", hp: 16, speed: 9, sp: 16, power: 24)
        let b = Battle(field: field, attackers: [fighter(mage, 10)], defenders: [fighter(creature("peasant"), 5)], seed: 1)
        let u = b.units.first { $0.side == 0 }!
        XCTAssertEqual(u.caster?.spells, [72, 23, 111, 125, 109])
        XCTAssertEqual(u.caster?.spellPoints, 16)
        XCTAssertEqual(u.caster?.defaultSpell, 72)
        XCTAssertTrue(u.caster?.creature == true)
        // Magic Fist (20 + 2 x level, Dmg): level 0, pct = Spell Power x pct x count / 100 = 240
        XCTAssertEqual(b.power(72, by: u), 48)
        // Curse has no Dmg / Summ flag: plain pct
        XCTAssertEqual(b.power(23, by: u), 0)
        XCTAssertNil(b.units.first { $0.side == 1 }!.caster)
    }

    /// The computer casts with creature casters too (the mages open with a spell).
    func testCreatureCasterAICasts() {
        let mage = creature("mage", hp: 16, low: 1, high: 1, speed: 9, sp: 16, power: 24)
        let b = Battle(field: field, attackers: [fighter(mage, 20)], defenders: [fighter(creature("peasant", speed: 1), 30)], seed: 1)
        _ = b.takeEvents()
        b.autoAct()
        let cast = b.takeEvents().contains { if case .cast = $0 { return true }; return false }
        XCTAssertTrue(cast)
        XCTAssertLessThan(b.units.first { $0.side == 0 }!.caster!.spellPoints, 16)
    }
}
