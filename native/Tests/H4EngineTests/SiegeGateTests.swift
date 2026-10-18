import XCTest
@testable import H4Engine

/// The castle gate in a siege (heroes4.exe t_castle_gate 0x5bfe60 / 0x5bff70, the melee user action
/// on it 0x627350, re/siege_gate_spec.md).
final class SiegeGateTests: XCTestCase {
    /// A castle as every layout has it around the gate: the 2 x 10 gate at (48, 46), its posts (wall
    /// pieces) sharing its end rows, the wall running on along x = 48...49.
    func field(level: Int) -> Battlefield {
        var f = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        var pieces = [Battlefield.CastlePiece(name: "combat_object.castle.life.castle.gate.intact.h4d", x: 48, y: 46, w: 2, h: 10, blocks: true, kind: "castle_gate"),
                      Battlefield.CastlePiece(name: "post_L", x: 48, y: 45, w: 2, h: 2, blocks: true, kind: "castle_wall"),
                      Battlefield.CastlePiece(name: "post_R", x: 48, y: 55, w: 2, h: 2, blocks: true, kind: "castle_wall")]
        for y in stride(from: 10, to: 45, by: 9) { pieces.append(Battlefield.CastlePiece(name: "wall", x: 48, y: y, w: 2, h: 9, blocks: true, kind: "castle_wall")) }
        for y in stride(from: 57, to: 95, by: 9) { pieces.append(Battlefield.CastlePiece(name: "wall", x: 48, y: y, w: 2, h: 9, blocks: true, kind: "castle_wall")) }
        f.addCastle(pieces, level: level)
        return f
    }
    func creature(_ k: String, attack: Int = 10, dmg: Int = 5, shots: Int = 0, move: Int = 10) -> CreatureDef {
        CreatureDef(keyword: k, name: k, plural: k, level: 1, alignment: "might", hitPoints: 20, damageLow: dmg, damageHigh: dmg,
                    attack: attack, defense: 10, move: move, speed: 5, growth: 1, gold: 1, experience: 1, shots: shots, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    /// One attacker at `at` (to act first) against one defender inside the walls.
    func siege(level: Int, _ c: CreatureDef, count: Int, at: (Int, Int), size: Int = 2) -> (Battle, Battle.Unit, Battle.Unit) {
        let a = Battle.Fighter(stats: Combatant(creature: c, count: count), keyword: c.keyword, actor: c.keyword, size: size, move: c.move, shots: c.shots)
        let d = Battle.Fighter(stats: Combatant(creature: creature("guard"), count: 5), keyword: "guard", actor: "guard", size: 2, move: 10, shots: 0)
        let b = Battle(field: field(level: level), attackers: [a], defenders: [d], seed: 7)
        _ = b.takeEvents()
        let u = b.units.first { $0.side == 0 }!, t = b.units.first { $0.side == 1 }!
        t.x = 20; t.y = 70
        u.x = at.0; u.y = at.1
        b.putFirst(u.id)
        return (b, u, t)
    }
    func hits(_ b: Battle) -> [Int] {
        b.takeEvents().compactMap { if case .gateHit(_, let d, _) = $0 { return d }; return nil }
    }

    /// Hit points by castle level (table 0x97ec20) on the gate's 2 x 10 cells.
    func testGateHitPointsByLevel() {
        for (level, hp) in [(1, 50), (2, 100), (3, 150)] {
            let f = field(level: level)
            XCTAssertEqual(f.gateHP, hp)
            XCTAssertEqual(f.gateCells.count, 20)
            XCTAssertFalse(f.isOpen(50 - 1, 50))
        }
    }

    /// A stack away from the gate walks next to it and strikes in the same action (the melee action
    /// on the gate object), as against a creature; the gate does not strike back.
    func testAttackerWalksToTheGateAndStrikes() {
        let (b, u, _) = siege(level: 1, creature("footman"), count: 20, at: (58, 49))
        XCTAssertFalse(b.nextToGate(u))
        XCTAssertFalse(b.gateAttackPositions(u).isEmpty)
        XCTAssertEqual(b.turnsToStrikeGate(u), 1)
        XCTAssertTrue(b.attackGate())
        let e = b.takeEvents()
        guard case .move? = e.first else { return XCTFail("\(e)") }
        XCTAssertEqual(u.x, 50)   // next to the gate's outer side
        XCTAssertEqual(e.compactMap { if case .gateHit(_, let d, _) = $0 { return d }; return nil }, [50])
        XCTAssertFalse(e.contains { if case .melee = $0 { return true }; return false })
        XCTAssertTrue(b.field.gateDestroyed)
    }

    /// The pointer picks where to strike from among the places in reach (0x56f600); a place out of reach is refused.
    func testStrikeFromAChosenPlace() {
        let (b, u, _) = siege(level: 1, creature("footman"), count: 20, at: (58, 49))
        let options = b.gateAttackPositions(u)
        let far = options.max { $0.y < $1.y }!
        XCTAssertTrue(b.attackGate(from: (far.x, far.y)))
        XCTAssertEqual(u.x, far.x); XCTAssertEqual(u.y, far.y)
    }

    /// Out of reach this turn: the stack heads for the gate; next turn it strikes.
    func testOutOfReachWalksTowardsTheGate() {
        let (b, u, _) = siege(level: 1, creature("footman"), count: 20, at: (80, 50))
        XCTAssertTrue(b.gateAttackPositions(u).isEmpty)
        XCTAssertEqual(b.turnsToStrikeGate(u), 3)
        XCTAssertTrue(b.attackGate())
        XCTAssertTrue(hits(b).isEmpty)
        XCTAssertLessThan(u.x, 80)
    }

    /// The damage: the attack / defense ratio against the gate's 1.0 is the attack itself (at most
    /// 20), a blow from outside over the closed gate does 1 / F (F 1.25 for a fort), the gate takes at
    /// most 50 a blow and no more than it has.
    func testGateDamageFormula() {
        // 1 creature, 2 damage, attack 5: 2 x 5 / 1.25 = 8
        let (b, u, _) = siege(level: 1, creature("footman", attack: 5, dmg: 2), count: 1, at: (50, 49))
        XCTAssertTrue(b.nextToGate(u))
        XCTAssertEqual(b.gateDamageRange(u).0, 8)
        XCTAssertTrue(b.attackGate())
        XCTAssertEqual(hits(b), [8])
        XCTAssertEqual(b.field.gateHP, 42)
        // the ratio stops at 20: attack 40 does what attack 20 does; at a castle 1 / 2
        let (b2, u2, _) = siege(level: 3, creature("footman", attack: 40, dmg: 1), count: 1, at: (50, 49))
        XCTAssertEqual(b2.gateDamageRange(u2).0, 10)
        // a big stack: 50 a blow, three blows break a castle's gate
        let (b3, u3, _) = siege(level: 3, creature("footman"), count: 50, at: (50, 49))
        XCTAssertTrue(b3.attackGate())
        XCTAssertEqual(hits(b3), [50])
        XCTAssertEqual(b3.field.gateHP, 100)
        XCTAssertEqual(b3.field.gateState, "light_damage")
        b3.putFirst(u3.id); XCTAssertTrue(b3.attackGate()); _ = hits(b3)
        XCTAssertEqual(b3.field.gateState, "heavy_damage")
        b3.putFirst(u3.id); XCTAssertTrue(b3.attackGate())
        let last = b3.takeEvents()
        XCTAssertTrue(last.contains { if case .gateHit(_, 50, true) = $0 { return true }; return false })
        XCTAssertTrue(b3.field.gateDestroyed)
        XCTAssertEqual(b3.field.gateState, "destroyed")
    }

    /// Every blow of the attack lands on the gate (0x5f2160): Strikes Twice strikes it twice.
    func testEveryBlowOfTheAttack() {
        let (b, u, _) = siege(level: 3, creature("footman"), count: 50, at: (50, 49))
        u.stats.abilities.insert("strikes_twice")
        XCTAssertTrue(b.attackGate())
        XCTAssertEqual(hits(b), [50, 50])
    }

    /// Shots never aim at the gate (0x627700 builds a ranged action on creatures only): a shooter
    /// strikes it in melee (its melee halved), spending no shot.
    func testShooterStrikesTheGateInMelee() {
        let (b, u, _) = siege(level: 1, creature("bowman", attack: 5, dmg: 2, shots: 12), count: 1, at: (58, 49))
        XCTAssertTrue(b.attackGate())
        XCTAssertEqual(u.x, 50)
        XCTAssertEqual(u.shots, 12)
        XCTAssertEqual(hits(b), [4])   // 2 x (5 / 2) / 1.25
    }

    /// The gate is the town's: the defenders never strike it, and walk through it closed
    /// (0x60cc00 opens it for their path search); the attackers do not.
    func testDefendersPassTheirOwnGate() {
        let (b, u, t) = siege(level: 1, creature("footman"), count: 20, at: (58, 49))
        t.x = 44; t.y = 49
        b.putFirst(t.id)
        XCTAssertFalse(b.mayStrikeGate(t))
        XCTAssertFalse(b.attackGate())
        XCTAssertNotNil(b.reachable(t)[Battle.key(52, 49)], "a defender walks out through its gate")
        b.putFirst(u.id)
        XCTAssertNil(b.reachable(u)[Battle.key(44, 49)], "the attacker cannot")
    }

    /// Broken, the gate lets everyone through; the cells it shares with its posts stay walls.
    func testBrokenGateLetsAttackersIn() {
        let (b, u, _) = siege(level: 1, creature("footman"), count: 20, at: (50, 49))
        XCTAssertTrue(b.attackGate())
        XCTAssertTrue(b.field.gateDestroyed)
        _ = b.takeEvents()
        for y in 47...54 { XCTAssertTrue(b.field.isOpen(48, y)); XCTAssertTrue(b.field.isOpen(49, y)) }
        XCTAssertFalse(b.field.isOpen(48, 46)); XCTAssertFalse(b.field.isOpen(49, 55))
        XCTAssertFalse(b.field.crossesWall((51, 50), (45, 50)))
        XCTAssertNil(b.gateRect)
        XCTAssertFalse(b.mayStrikeGate(u))
        b.putFirst(u.id)
        XCTAssertNotNil(b.reachable(u)[Battle.key(44, 49)], "through the broken gate")
        XCTAssertTrue(b.move(to: 44, 49))
        XCTAssertEqual(u.x, 44)
    }

    /// The computer's attackers break the gate and come in (citadel: across the moat).
    func testComputerAttackerBreaksIn() {
        let (b, u, _) = siege(level: 2, creature("footman"), count: 50, at: (60, 49))
        var guardN = 0
        while !b.field.gateDestroyed, guardN < 20, b.finished == nil {
            if b.current?.side == 0 { b.putFirst(u.id) }
            b.autoAct(); _ = b.takeEvents(); guardN += 1
        }
        XCTAssertTrue(b.field.gateDestroyed)
    }

    /// The real layouts (castle.<alignment>.<level>.h4d) put the gate at (48, 46), 2 x 10.
    func testRealLayoutsPlaceTheGate() throws {
        let data = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data")
        guard let archive = try? H4Archive(url: data.appendingPathComponent("heroes4.h4r")) else { throw XCTSkip("game data not installed") }
        let lower = Dictionary(archive.byName.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func payload(_ n: String) -> Data? { lower[n.lowercased()].flatMap { try? archive.payload($0) } }
        for alignment in ["life", "order", "death", "chaos", "nature", "might"] {
            for (level, name) in ["fort", "citadel", "castle"].enumerated() {
                guard let d = payload("castle.\(alignment).\(name).h4d") else { continue }
                var f = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
                f.addCastle(Battlefield.castlePieces(d) { payload($0) }, level: level + 1)
                let xs = f.gateCells.map { $0 / Battlefield.size }, ys = f.gateCells.map { $0 % Battlefield.size }
                XCTAssertEqual(f.gateCells.count, 20, "\(alignment) \(name)")
                XCTAssertEqual(xs.min(), 48); XCTAssertEqual(ys.min(), 46)
                XCTAssertEqual(f.gateHP, [50, 100, 150][level])
            }
        }
    }
}
