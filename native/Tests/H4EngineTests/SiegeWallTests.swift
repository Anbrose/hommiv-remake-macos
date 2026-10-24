import XCTest
@testable import H4Engine

/// Walls, gate and arrow towers in the siege path map (heroes4.exe 0x60cc00 / 0x60e4a0 / 0x60d610,
/// re/siege_walls_spec.md).
final class SiegeWallTests: XCTestCase {
    /// The gate's 2 x 10 at (48, 46) with its posts, the wall along x = 48...49, and (`towers`) a
    /// castle's arrow tower at (32, 34), 7 x 7.
    func field(level: Int, towers: Bool = false) -> Battlefield {
        var f = Battlefield(terrain: 1, variant: 0, kinds: [], frequency: [:], adjacency: [:], seed: 1)
        var pieces = [Battlefield.CastlePiece(name: "gate", x: 48, y: 46, w: 2, h: 10, blocks: true, kind: "castle_gate"),
                      Battlefield.CastlePiece(name: "post_L", x: 48, y: 45, w: 2, h: 2, blocks: true, kind: "castle_wall"),
                      Battlefield.CastlePiece(name: "post_R", x: 48, y: 55, w: 2, h: 2, blocks: true, kind: "castle_wall")]
        for y in stride(from: 10, to: 45, by: 9) { pieces.append(Battlefield.CastlePiece(name: "wall", x: 48, y: y, w: 2, h: 9, blocks: true, kind: "castle_wall")) }
        for y in stride(from: 57, to: 95, by: 9) { pieces.append(Battlefield.CastlePiece(name: "wall", x: 48, y: y, w: 2, h: 9, blocks: true, kind: "castle_wall")) }
        if towers { pieces.append(Battlefield.CastlePiece(name: "tower_archer", x: 32, y: 34, w: 7, h: 7, blocks: false, kind: "castle_tower")) }
        f.addCastle(pieces, level: level)
        return f
    }
    func creature(_ k: String, move: Int = 20, shots: Int = 0) -> CreatureDef {
        CreatureDef(keyword: k, name: k, plural: k, level: 1, alignment: "might", hitPoints: 20, damageLow: 5, damageHigh: 5,
                    attack: 10, defense: 10, move: move, speed: 5, growth: 1, gold: 1, experience: 1, shots: shots, spellPoints: 0,
                    shortHelp: "", longHelp: "")
    }
    func fighter(_ c: CreatureDef, abilities: [String] = []) -> Battle.Fighter {
        var s = Combatant(creature: c, count: 10)
        s.abilities = Set(abilities)
        return Battle.Fighter(stats: s, keyword: c.keyword, actor: c.keyword, size: 2, move: c.move, shots: c.shots)
    }
    func siege(_ a: Battle.Fighter, _ d: Battle.Fighter, level: Int = 1, towers: Bool = false) -> (Battle, Battle.Unit, Battle.Unit) {
        let b = Battle(field: field(level: level, towers: towers), attackers: [a], defenders: [d], seed: 7)
        _ = b.takeEvents()
        return (b, b.units.first { $0.side == 0 }!, b.units.first { $0.side == 1 }!)
    }
    func inside(_ b: Battle, _ u: Battle.Unit) -> [Int] {
        b.reachable(u).keys.filter { $0 / Battlefield.size < 48 }
    }

    /// A flyer outside cannot cross the standing walls or the closed gate unless it starts at the wall:
    /// each placement over them costs (Move - 2) / (size + 1) when flying inwards (0x60dc69).
    func testFlyerCannotFlyInFromAfar() {
        let (b, u, t) = siege(fighter(creature("griffin"), abilities: ["flying"]), fighter(creature("guard")))
        t.x = 20; t.y = 70
        u.x = 60; u.y = 49; b.version += 1
        XCTAssertTrue(inside(b, u).isEmpty, "20 cells of flight from 10 cells out never get over the wall")
        XCTAssertNotNil(b.reachable(u)[Battle.key(52, 40)], "along the outside it flies freely")
        // right at the gate: 3 placements x 6 cells + 1 = 19 of its 20 cells
        u.x = 50; u.y = 49; b.version += 1
        let cost = b.reachable(u)
        XCTAssertEqual(cost[Battle.key(46, 49)] ?? -1, 19, accuracy: 0.01)
        XCTAssertNotNil(cost[Battle.key(45, 49)])
        XCTAssertNil(cost[Battle.key(44, 49)])
    }

    /// Flying outwards over the wall costs nothing extra (only directions 7, 0, 1 pay).
    func testFlyerFliesOutFreely() {
        let (b, _, t) = siege(fighter(creature("guard")), fighter(creature("griffin"), abilities: ["flying"]))
        t.x = 44; t.y = 49; b.version += 1
        XCTAssertEqual(b.reachable(t)[Battle.key(56, 49)] ?? -1, 12, accuracy: 0.01)
    }

    /// The broken gate is open for everyone, flyers included (0x5c0970).
    func testBrokenGateOpensTheWayForFlyers() {
        let (b, u, t) = siege(fighter(creature("griffin"), abilities: ["flying"]), fighter(creature("guard")))
        t.x = 20; t.y = 70
        u.x = 60; u.y = 49
        b.setGate(hp: 0); b.version += 1
        XCTAssertEqual(b.reachable(u)[Battle.key(46, 49)] ?? -1, 14, accuracy: 0.01)
    }

    /// Walkers: the walls hold everyone, the closed gate only the attackers.
    func testWalkersAndTheGate() {
        let (b, u, t) = siege(fighter(creature("footman")), fighter(creature("guard")))
        u.x = 51; u.y = 49; t.x = 44; t.y = 49; b.version += 1
        XCTAssertTrue(inside(b, u).isEmpty)
        XCTAssertNotNil(b.reachable(t)[Battle.key(51, 60)])
        t.x = 44; t.y = 30; b.version += 1
        XCTAssertNil(b.reachable(t)[Battle.key(51, 30)], "the wall holds the defenders too (the gate is the way out)")
    }

    /// An empty arrow tower: a walker pays 4 cells to climb it and moves on it for nothing (0x60d1f5, 0x60dc22).
    func testClimbingATower() {
        let (b, _, t) = siege(fighter(creature("footman")), fighter(creature("guard")), level: 3, towers: true)
        t.x = 41; t.y = 37; b.version += 1   // the tower covers x 32...38
        let c = b.reachable(t)
        XCTAssertEqual(c[Battle.key(39, 37)] ?? -1, 2, accuracy: 0.01)   // footprint 39...40: still off it
        XCTAssertEqual(c[Battle.key(38, 37)] ?? -1, 6, accuracy: 0.01)   // 2 + 4 onto it
        XCTAssertEqual(c[Battle.key(33, 37)] ?? -1, 6, accuracy: 0.01)   // and across it for free
    }

    /// A shooter on a tower shoots out over the wall with no range or obstacle penalty and double attack.
    func testTowerShooterShoots() {
        let (b, u, t) = siege(fighter(creature("footman")), fighter(creature("archer", shots: 12)), level: 3, towers: true)
        t.x = 34; t.y = 36; u.x = 80; u.y = 40; b.version += 1
        XCTAssertTrue(b.onTower(t))
        XCTAssertTrue(b.shotOverWallOK(t, u))
        XCTAssertEqual(b.rangeDivisor(t, u), 1)
        b.putFirst(t.id)
        XCTAssertTrue(b.shoot(u.id))
        XCTAssertTrue(b.takeEvents().contains { if case .shoot = $0 { return true }; return false })
    }

    // MARK: teleport and Bind Flyer

    /// A teleporter searches as a flyer but pays nothing for the wall (0x60d79d) and goes as far as
    /// its Move: from 10 cells out it lands inside for 14 of its 20 cells; from 30 out it cannot.
    func testTeleporterCrossesTheWallWithinItsMove() {
        let (b, u, t) = siege(fighter(creature("archdevil"), abilities: ["teleport"]), fighter(creature("guard")))
        t.x = 20; t.y = 70
        u.x = 60; u.y = 49; b.version += 1
        XCTAssertEqual(b.reachable(u)[Battle.key(46, 49)] ?? -1, 14, accuracy: 0.01)
        XCTAssertEqual(b.path(u, to: 46, 49)?.count, 1, "it goes straight there")
        u.x = 80; b.version += 1
        XCTAssertTrue(inside(b, u).isEmpty, "the inside lies beyond its Move")
        XCTAssertNil(b.reachable(u)[Battle.key(55, 49)], "no 'any free place': 25 cells is past a Move of 20")
        XCTAssertNotNil(b.reachable(u)[Battle.key(60, 49)])
    }

    /// Zones of control never hold a teleporter (0x60d87d skips 0x572370).
    func testTeleporterIgnoresZonesOfControl() {
        let (b, u, t) = siege(fighter(creature("archdevil"), abilities: ["teleport"]), fighter(creature("guard")))
        u.x = 60; u.y = 49; t.x = 62; t.y = 49; b.version += 1
        XCTAssertEqual(b.reachable(u)[Battle.key(60, 59)] ?? -1, 10, accuracy: 0.01)
    }

    /// The Teleport spell runs the same search over the whole field (0x87eef0): any free placement,
    /// inside the walls too; never onto the wall or a stack.
    func testTeleportSpellLandsInsideTheWalls() {
        let (b, u, t) = siege(fighter(creature("footman")), fighter(creature("guard")))
        u.x = 80; u.y = 49; t.x = 20; t.y = 70; b.version += 1
        XCTAssertTrue(b.teleportOK(u, to: (30, 49)))
        XCTAssertFalse(b.teleportOK(u, to: (48, 30)), "on the wall")
        XCTAssertFalse(b.teleportOK(u, to: (20, 70)), "on the defender")
    }

    /// Bind Flyer (effect 7) makes a flyer a walker (0x60d67e, 0x60d053): the walls and closed gate hold
    /// it, every enemy's zone of control holds it, and it walks (0x56bdbf), at half its Move.
    func testBoundFlyerWalks() {
        let (b, u, t) = siege(fighter(creature("griffin"), abilities: ["flying"]), fighter(creature("guard")))
        t.x = 20; t.y = 70
        u.x = 50; u.y = 49; u.stats.effects.insert(7); b.version += 1
        XCTAssertFalse(u.stats.has("flying"))
        XCTAssertTrue(inside(b, u).isEmpty, "the wall holds it like a walker")
        XCTAssertEqual(b.reachable(u)[Battle.key(55, 49)] ?? -1, 5, accuracy: 0.01)
        XCTAssertNil(b.reachable(u)[Battle.key(61, 49)], "a Move of 20 halved")
        t.x = 50; t.y = 51; b.version += 1   // a walking guard next to it now holds it
        XCTAssertEqual(b.reachable(u)[Battle.key(50, 48)] ?? -1, 1, accuracy: 0.01, "away from the guard: free")
        XCTAssertEqual(b.reachable(u)[Battle.key(51, 49)] ?? -1, 2.5, accuracy: 0.01, "across costs 1 + 2.5: cheaper to step away, then diagonally")
    }
}
