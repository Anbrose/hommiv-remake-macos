import XCTest
@testable import H4Engine

/// Ability rules read from heroes4.exe (damage 0x5ee380 / 0x5ee990, aftermath 0x553440).
final class BattleAbilityTests: XCTestCase {
    func creature(_ keyword: String, level: Int = 1, alignment: String = "might", hp: Int = 10, low: Int = 2, high: Int = 2,
                  attack: Int = 10, defense: Int = 10, shots: Int = 0, speed0: Bool = false) -> CreatureDef {
        CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: level, alignment: alignment, hitPoints: hp, damageLow: low, damageHigh: high,
                    attack: attack, defense: defense, move: 10, speed: speed0 ? 1 : 5, growth: 1, gold: 1, experience: 1, shots: shots, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func stack(_ c: CreatureDef, _ n: Int) -> Combatant { Combatant(creature: c, count: n) }

    func testAbilitiesComeFromTheExeTable() {
        XCTAssertEqual(stack(creature("crusader"), 1).abilities, ["strikes_twice", "death_protection"])
        XCTAssertTrue(stack(creature("orc"), 1).noMeleePenalty)
        XCTAssertTrue(stack(creature("centaur"), 1).shooter)
    }

    func testGiantslayerDoublesAgainstLevel4() {
        let h = stack(creature("halfling"), 10), titan = stack(creature("titan", level: 4), 1), orc = stack(creature("orc", level: 1), 1)
        XCTAssertEqual(QuickCombat.damage(h, titan, base: 100, ranged: true), 2 * QuickCombat.damage(h, orc, base: 100, ranged: true))
    }

    func testChargeScalesWithCellsMoved() {
        let ch = stack(creature("champion"), 1), t = stack(creature("peasant"), 1)
        XCTAssertEqual(QuickCombat.damage(ch, t, base: 100, ranged: false, moved: 5), 100)        // 500 points: no charge yet
        XCTAssertEqual(QuickCombat.damage(ch, t, base: 100, ranged: false, moved: 30), 170)       // 85 + 3000 / 35
    }

    func testWardsFireAndBlock() {
        let angel = stack(creature("squire", alignment: "life"), 1), crusader = stack(creature("crusader"), 1)
        XCTAssertEqual(QuickCombat.damage(angel, stack(creature("orc"), 1), base: 90, ranged: false), 90)
        XCTAssertEqual(QuickCombat.damage(stack(creature("vampire", alignment: "death"), 1), crusader, base: 90, ranged: false), 60)
        XCTAssertEqual(QuickCombat.damage(stack(creature("efreet"), 1), stack(creature("phoenix"), 1), base: 90, ranged: false), 45)
        XCTAssertEqual(QuickCombat.damage(stack(creature("squire"), 1), stack(creature("minotaur"), 1), base: 100, ranged: false), 70)
    }

    func testDefenseAbilities() {
        let a = stack(creature("squire"), 1)
        XCTAssertEqual(QuickCombat.damage(a, stack(creature("ghost"), 1), base: 100, ranged: false), 50)   // Insubstantial
        let archer = stack(creature("crossbowman", shots: 10), 1)
        XCTAssertEqual(QuickCombat.damage(archer, stack(creature("skeleton"), 1), base: 100, ranged: true), 50)   // Skeletal vs shots
        XCTAssertEqual(QuickCombat.damage(a, stack(creature("skeleton"), 1), base: 100, ranged: false), 100)
    }

    func testCurseRollsMinimum() {
        var c = stack(creature("squire", low: 1, high: 9), 5)
        c.cursed = true
        var rng = GameRandom(seed: 7)
        XCTAssertEqual(QuickCombat.rollBase(c, rng: &rng), 5)
    }

    func testWholeBattlesWithSpecialCreaturesFinish() {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        let kinds = ["hydra", "cerberus", "black dragon", "medusa", "vampire", "mantis", "mermaid", "ice demon", "venom spawn",
                     "thunderbird", "efreet", "sea monster", "troll", "pikeman", "harpy", "squire", "cyclops", "archdevil", "unicorn", "mummy"]
        for seed in 0..<kinds.count {
            func f(_ k: String, _ n: Int) -> Battle.Fighter {
                let c = creature(k, level: 2, hp: 30, low: 3, high: 6, shots: ["medusa", "venom spawn", "cyclops"].contains(k) ? 12 : 0)
                return Battle.Fighter(stats: stack(c, n), keyword: k, actor: k, size: 3, move: 12, shots: c.shots)
            }
            let a = [f(kinds[seed], 12), f(kinds[(seed + 3) % kinds.count], 12)]
            let d = [f(kinds[(seed + 7) % kinds.count], 12), f(kinds[(seed + 11) % kinds.count], 12)]
            let b = Battle(field: field, attackers: a, defenders: d, seed: seed)
            b.autoResolve()
            XCTAssertNotNil(b.finished, "\(kinds[seed]) battle did not finish")
        }
    }

    /// A harpy's attack plays: fly there, strike, the target dies, fly back.
    func testStrikeAndReturnOrder() {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        let harpy = Battle.Fighter(stats: stack(creature("harpy", hp: 20, low: 50, high: 50, attack: 30), 10), keyword: "harpy", actor: "harpy", size: 3, move: 60, shots: 0)
        let peasant = Battle.Fighter(stats: stack(creature("peasant", hp: 1, speed0: true), 1), keyword: "peasant", actor: "peasant", size: 3, move: 1, shots: 0)
        let b = Battle(field: field, attackers: [harpy], defenders: [peasant], seed: 3)
        _ = b.takeEvents()
        let h = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        let start = (h.x, h.y)
        XCTAssertTrue(b.attack(t.id))
        let kinds = b.takeEvents().compactMap { e -> String? in
            switch e { case .move: return "move"; case .melee: return "melee"; case .die: return "die"; default: return nil }
        }
        XCTAssertEqual(Array(kinds.prefix(4)), ["move", "melee", "die", "move"])
        XCTAssertTrue(h.x == start.0 && h.y == start.1)
    }
}
