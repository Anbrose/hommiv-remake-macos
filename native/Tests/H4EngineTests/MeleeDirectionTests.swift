import XCTest
@testable import H4Engine

/// Where a melee blow goes from (heroes4.exe 0x50c4e0 / 0x56f600) and what a breath strikes (0x56d620 / 0x56cda0).
final class MeleeDirectionTests: XCTestCase {
    func creature(_ keyword: String, hp: Int = 50, speed: Int = 5) -> CreatureDef {
        CreatureDef(keyword: keyword, name: keyword, plural: keyword, level: 1, alignment: "might", hitPoints: hp, damageLow: 1, damageHigh: 1,
                    attack: 10, defense: 10, move: 10, speed: speed, growth: 1, gold: 1, experience: 1, shots: 0, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func fighter(_ k: String, size: Int, move: Int = 60, speed: Int = 5) -> Battle.Fighter {
        Battle.Fighter(stats: Combatant(creature: creature(k, speed: speed), count: 5), keyword: k, actor: k, size: size, move: move, shots: 0)
    }
    let field = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)

    /// The places round the target are those whose centre is within 16 x 2 + 8 x (sizes) + 8 of its
    /// centre; the aim picks the first with the nearest angle (x then y order: on a straight line the
    /// far one on the low side, the near one on the high side).
    func testAimPicksTheSide() {
        let b = Battle(field: field, attackers: [fighter("squire", size: 2)], defenders: [fighter("peasant", size: 2, speed: 1)], seed: 1)
        let u = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        u.x = 30; u.y = 50; t.x = 50; t.y = 50
        let low = b.attackPlace(u, t, aim: 180)!
        XCTAssertEqual([low.x, low.y, low.angle], [46, 50, 180])        // 2 cells of gap on the -x side
        let high = b.attackPlace(u, t, aim: 0)!
        XCTAssertEqual([high.x, high.y, high.angle], [52, 50, 0])       // touching on the +x side
        let side = b.attackPlace(u, t, aim: 90)!
        XCTAssertEqual(side.angle, 90); XCTAssertEqual(side.x, 50); XCTAssertLessThan(side.y, 50)
        // touching corners are in range (45 <= 72); two cells of gap on both axes is not (91)
        XCTAssertTrue(Battle.inMeleeRange(48, 48, 2, t, range: 2))
        XCTAssertFalse(Battle.inMeleeRange(46, 46, 2, t, range: 2))
        XCTAssertTrue(b.attack(t.id, aim: 0))
        XCTAssertEqual([u.x, u.y], [52, 50])
    }

    /// A place beyond this turn's move: the frame says the turns and the unit walks towards it.
    func testTurnsToTheAimedPlace() {
        let b = Battle(field: field, attackers: [fighter("squire", size: 2, move: 10)], defenders: [fighter("peasant", size: 2, speed: 1)], seed: 1)
        let u = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        u.x = 30; u.y = 50; t.x = 50; t.y = 50
        XCTAssertEqual(b.turnsToAttack(u, t, aim: 180), 2)    // 16 cells
        XCTAssertGreaterThan(b.turnsToAttack(u, t, aim: 0)!, 2)      // round to the far side
        XCTAssertTrue(b.attack(t.id, aim: 180))
        XCTAssertEqual([u.x, u.y], [40, 50])
    }

    /// Breath: the line from the dragon's centre through the target's hits every stack on it, either
    /// side, up to 8 x size + 16 x 2 + 144 units; a Fire Resistant one resists (the hover leaves it out).
    func testBreathLine() {
        let b = Battle(field: field, attackers: [fighter("black dragon", size: 3), fighter("squire", size: 2, speed: 1)],
                       defenders: [fighter("peasant", size: 2, speed: 1), fighter("orc", size: 2, speed: 1), fighter("phoenix", size: 2, speed: 1), fighter("goblin", size: 2, speed: 1)], seed: 1)
        let d = b.units.first { $0.keyword == "black dragon" }!
        let t = b.units.first { $0.keyword == "peasant" }!, behind = b.units.first { $0.keyword == "orc" }!
        let friend = b.units.first { $0.keyword == "squire" }!, phoenix = b.units.first { $0.keyword == "phoenix" }!
        let far = b.units.first { $0.keyword == "goblin" }!
        d.x = 40; d.y = 50; t.x = 45; t.y = 50; behind.x = 48; behind.y = 50; friend.x = 51; friend.y = 50
        phoenix.x = 53; phoenix.y = 50; far.x = 54; far.y = 60
        XCTAssertEqual(b.breathLine(d, t, at: (d.x, d.y)).map { $0.keyword }, ["orc", "squire", "phoenix"])
        XCTAssertEqual(b.breathLine(d, t, at: (d.x, d.y), preview: true).map { $0.keyword }, ["orc", "squire"])
        phoenix.x = 54
        XCTAssertEqual(b.breathLine(d, t, at: (d.x, d.y)).map { $0.keyword }, ["orc", "squire"])   // 14 cells: past the end
    }

    /// Arc Breath: the 135-degree sector of the disc of radius size / 2 + 11 round the attacker,
    /// friend or foe, never a Fire Resistant one.
    func testArcBreathSector() {
        let b = Battle(field: field, attackers: [fighter("mega dragon", size: 4)],
                       defenders: [fighter("peasant", size: 2, speed: 1), fighter("orc", size: 2, speed: 1), fighter("goblin", size: 2, speed: 1), fighter("phoenix", size: 2, speed: 1)], seed: 1)
        let d = b.units.first { $0.keyword == "mega dragon" }!
        let t = b.units.first { $0.keyword == "peasant" }!, aside = b.units.first { $0.keyword == "orc" }!
        let back = b.units.first { $0.keyword == "goblin" }!, phoenix = b.units.first { $0.keyword == "phoenix" }!
        d.x = 40; d.y = 50; t.x = 45; t.y = 51; aside.x = 47; aside.y = 56; back.x = 35; back.y = 51; phoenix.x = 48; phoenix.y = 51
        XCTAssertEqual(b.extraTargets(d, t, ranged: false).map { $0.keyword }, ["orc"])
    }
}
