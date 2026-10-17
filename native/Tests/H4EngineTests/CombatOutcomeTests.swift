import XCTest
@testable import H4Engine

/// End-of-battle casualties and the surrender price (heroes4.exe 0x572f90 / 0x40d0a0 / 0x63faa0,
/// 0x5798c0; re/combat_results_spec.md).
final class CombatOutcomeTests: XCTestCase {
    func creature(_ keyword: String, gold: Int = 10) -> CreatureDef {
        CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: 1, alignment: "might", hitPoints: 10, damageLow: 1, damageHigh: 1,
                    attack: 10, defense: 10, move: 10, speed: 5, growth: 1, gold: gold, experience: 1, shots: 0, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func fighter(_ k: String, _ n: Int, slot: Int) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: creature(k), count: n), keyword: k, actor: k, size: 2, move: 6, shots: 0, slot: slot)
    }
    func hero(_ k: String, slot: Int) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(hero: k, level: 1), keyword: k, actor: k, size: 2, move: 6, shots: 0, slot: slot)
    }
    func battle(_ attackers: [Battle.Fighter], _ defenders: [Battle.Fighter] = []) -> Battle {
        let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        let b = Battle(field: field, attackers: attackers, defenders: defenders.isEmpty ? [fighter("orc", 5, slot: 0)] : defenders, seed: 3)
        _ = b.takeEvents()
        return b
    }
    func side0(_ b: Battle) -> [Battle.Unit] { b.units.filter { $0.side == 0 } }

    /// A partly killed stack loses only the dead; untouched stacks are not listed.
    func testPartialStackAndUntouched() {
        let b = battle([fighter("squire", 10, slot: 0), fighter("pikeman", 4, slot: 1)])
        side0(b)[0].stats.count = 7
        XCTAssertEqual(b.casualties(side: 0), [Battle.Casualty(keyword: "squire", count: 3)])
        XCTAssertEqual(b.casualties(side: 1), [])
    }

    /// Losses are tallied per creature type into the first entry of that type (0x63faa0 merges).
    func testSameTypeStacksMerge() {
        let b = battle([fighter("squire", 10, slot: 0), fighter("archer", 6, slot: 1), fighter("squire", 5, slot: 2)])
        let u = side0(b)
        u[0].stats.count = 7; u[1].stats.count = 0; u[2].stats.count = 3
        XCTAssertEqual(b.casualties(side: 0), [Battle.Casualty(keyword: "squire", count: 5), Battle.Casualty(keyword: "archer", count: 6)])
    }

    /// Summoned and raised stacks (no army slot) never count, even when killed; creatures brought
    /// back into their own stack are not lost.
    func testSummonedAndResurrected() {
        let b = battle([fighter("squire", 10, slot: 0), fighter("skeleton", 8, slot: 1)])
        let u = side0(b)
        u[1].summoned = true; u[1].stats.count = 0
        u[0].stats.count = 0; u[0].stats.count = 10   // killed, then all resurrected
        XCTAssertEqual(b.casualties(side: 0), [])
        u[0].stats.count = 9                         // one of them stayed dead
        XCTAssertEqual(b.casualties(side: 0), [Battle.Casualty(keyword: "squire", count: 1)])
    }

    /// A hero is listed (once, never merged) when it is dead at the end.
    func testFallenHeroes() {
        let b = battle([hero("sir_a", slot: 0), hero("sir_b", slot: 1), fighter("squire", 4, slot: 2)])
        let u = side0(b)
        u[1].stats.count = 0; u[2].stats.count = 1
        XCTAssertEqual(b.casualties(side: 0), [Battle.Casualty(keyword: "sir_b", count: 1, hero: u[1].id), Battle.Casualty(keyword: "squire", count: 3)])
        u[0].stats.count = 0
        XCTAssertEqual(b.casualties(side: 0).filter { $0.hero != nil }.count, 2)
    }

    /// Seven entries at most: what does not fit is dropped, a later loss of a listed type still adds up.
    func testSevenEntries() {
        let kinds = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let b = battle(kinds.enumerated().map { fighter($1, 2, slot: $0) } + [fighter("a", 3, slot: 8)])
        for u in side0(b) { u.stats.count = 0 }
        let c = b.casualties(side: 0)
        XCTAssertEqual(c.map { $0.keyword }, ["a", "b", "c", "d", "e", "f", "g"])
        XCTAssertEqual(c[0].count, 5)
    }

    /// A lost fight by 0x633390 (codes 0 / 4) counts the beaten side's whole army.
    func testWholeArmyLost() {
        let b = battle([fighter("squire", 10, slot: 0)])
        side0(b)[0].stats.count = 6
        XCTAssertEqual(b.casualties(side: 0, wholeArmyLost: true), [Battle.Casualty(keyword: "squire", count: 10)])
    }

    /// The price: creature gold + 500 x (level + 1) per hero, x min(Charm %, Diplomacy %) of the
    /// side's best skills, truncated (0x5798c0, tables 0x9946c0 / 0x9946d8).
    func testSurrenderCost() {
        XCTAssertEqual(Battle.surrenderCost(creatureGold: 1234, heroes: []), 1234)
        XCTAssertEqual(Battle.surrenderCost(creatureGold: 1000, heroes: [(level: 3, diplomacy: 0, charm: 0)]), 3000)
        // basic Diplomacy 80% beats basic Charm 90%
        XCTAssertEqual(Battle.surrenderCost(creatureGold: 1000, heroes: [(level: 1, diplomacy: 1, charm: 1)]), 1600)
        // the best of each over the heroes: grandmaster Charm 65% vs advanced Diplomacy 70%
        XCTAssertEqual(Battle.surrenderCost(creatureGold: 999, heroes: [(level: 1, diplomacy: 2, charm: 0), (level: 2, diplomacy: 0, charm: 5)]), 2274)   // 3499 x 0.65
        XCTAssertEqual(Battle.surrenderCost(creatureGold: 7, heroes: [(level: 0, diplomacy: 5, charm: 0)]), 253)   // 507 x 0.5 = 253.5
    }

    /// Only the stacks still alive are paid for; summoned stacks are free; dead heroes cost too.
    func testSurrenderCostOfASide() {
        let b = battle([hero("sir_a", slot: 0), fighter("squire", 10, slot: 1), fighter("skeleton", 5, slot: 2)])
        let u = side0(b)
        u[0].stats.count = 0; u[1].stats.count = 4; u[2].summoned = true
        let h = Hero(actor: "hero", x: 0, y: 0); h.level = 2; h.skills["diplomacy"] = 2
        XCTAssertEqual(b.surrenderCost(side: 0, heroes: [h]) { $0 == "squire" ? 25 : 1000 }, 1120)   // (4 x 25 + 1500) x 70%
    }
}
