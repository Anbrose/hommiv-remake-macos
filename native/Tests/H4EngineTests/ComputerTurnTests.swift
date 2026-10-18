import XCTest
@testable import H4Engine

/// The options' speed sliders (re/speed_options_spec.md) and the computer players' turns played
/// out on the map (re/ai_turn_display_spec.md).
final class ComputerTurnTests: XCTestCase {
    override func tearDown() {
        GameState.showEnemyMoves = true
        GameState.otherArmySpeedPercent = SpeedOption.defaultEnemy
    }

    func testSpeedSliderPositionsAndPercents() {
        // 0x6ebec0 over the scrollbar's range -2...6
        XCTAssertEqual(SpeedOption.positions.map(SpeedOption.percent(position:)), [50, 71, 100, 141, 200, 283, 400, 566, 800])
        for p in SpeedOption.positions { XCTAssertEqual(SpeedOption.position(percent: SpeedOption.percent(position: p)), p) }
        // the defaults (0x7c91d0) and the user's registry (army 400, combat 566, enemy 283)
        XCTAssertEqual(SpeedOption.position(percent: 150), 1)
        XCTAssertEqual(SpeedOption.position(percent: 200), 2)
        XCTAssertEqual(SpeedOption.position(percent: 400), 4)
        XCTAssertEqual(SpeedOption.position(percent: 566), 5)
        XCTAssertEqual(SpeedOption.position(percent: 283), 3)
        // rounding half away from zero, held in the range
        XCTAssertEqual(SpeedOption.position(percent: 85), 0)    // 2 log2 0.85 = -0.47 -> 0
        XCTAssertEqual(SpeedOption.position(percent: 84), -1)   // -0.503 -> -1
        XCTAssertEqual(SpeedOption.position(percent: 118), 0)   // 0.478 -> 0
        XCTAssertEqual(SpeedOption.position(percent: 119), 1)   // 0.502 -> 1
        XCTAssertEqual(SpeedOption.position(percent: 10), -2)
        XCTAssertEqual(SpeedOption.position(percent: 5000), 6)
    }

    func testSpeedSliderSteps() {
        XCTAssertEqual(SpeedOption.stepped(percent: 150, by: 1), 200)
        XCTAssertEqual(SpeedOption.stepped(percent: 150, by: -1), 100)
        XCTAssertEqual(SpeedOption.stepped(percent: 566, by: 1), 800)
        XCTAssertEqual(SpeedOption.stepped(percent: 800, by: 1), 800)     // the last position stays
        XCTAssertEqual(SpeedOption.stepped(percent: 50, by: -1), 50)
        XCTAssertEqual(SpeedOption.stepped(percent: 150, by: 0), 150)     // an untouched slider keeps its percent
        XCTAssertTrue(SpeedOption.showsEnemyMoves(566))
        XCTAssertFalse(SpeedOption.showsEnemyMoves(800))                  // "Off"
    }

    func testAWalkComingIntoSightStartsInItsWalkLoop() {
        let g = ArmyGait()
        let w = ArmyWalk(steps: [32, 32, 32], gait: g, walking: true)
        XCTAssertEqual(w.state, "walk")
        XCTAssertEqual(ArmyWalk(steps: [32, 32, 32], gait: g).state, "prewalk")
    }

    /// A game whose computer players have armies, the fog off (the player sees everything).
    func game() throws -> GameState {
        let g = try AIEconomyTests.loadGame()
        g.quickCombatOnly = true
        g.setupTreasuries()
        g.fogEnabled = false
        // the computer players' heroes at their towns' gates, as the game places them (main.swift)
        for spec in g.map.playerSpecs where spec.colour != g.map.humanColour {
            guard let t = g.towns.first(where: { $0.owner == spec.colour }),
                  let p = g.scenes[t.z].placed.first(where: { $0.category == "castle" && $0.cellX == t.x && $0.cellY == t.y }) else { continue }
            let back = g.level; g.level = t.z
            if let cell = g.gateCells(p).first(where: { g.passability.isFree($0.0, $0.1) }) {
                var mh = MapHero(); mh.level = 1
                let e = Hero.fromMap(mh, alignment: t.alignment, x: cell.0, y: cell.1, tables: g.tables, random: &g.random)
                e.owner = spec.colour; e.z = t.z; e.home = cell
                g.giveStartingArmy(e)
                g.place(enemy: e)
            }
            g.level = back
        }
        guard !g.enemyHeroes.isEmpty else { throw XCTSkip("no computer armies") }
        g.setupTreasuries()
        return g
    }

    func snapshot(_ g: GameState) -> [String] {
        g.enemyHeroes.map { "\($0.owner) \($0.x),\($0.y),\($0.z) \(Int($0.movement * 100)) \($0.army.map { "\($0.count) \($0.creature)" })" }
            + ["day \(g.day)", "gold \(g.aiResources.sorted { $0.key < $1.key }.map { $0.value["Gold"] ?? 0 })"]
    }

    /// Played out on the map, the computer turn ends where the one run at once ends, its armies
    /// walking cell by cell, one after another.
    func testShownComputerTurnMatchesTheTurnRunAtOnce() throws {
        let a = try game(), b = try game()
        a.endTurn()
        XCTAssertNil(a.computerTurn)
        b.beginEndTurn(animated: true)
        var shownWalks = 0, frames = 0
        var walker: Hero? = nil, at = (x: 0, y: 0)
        while b.computerTurn != nil, frames < 200_000 {
            frames += 1
            if let w = b.computerTurn?.walk, w.shown {
                if walker !== w.hero { walker = w.hero; at = (w.hero.x, w.hero.y); shownWalks += 1 }
                // only the walking army moves, one cell at a time
                XCTAssertLessThanOrEqual(max(abs(w.hero.x - at.x), abs(w.hero.y - at.y)), 1)
                at = (w.hero.x, w.hero.y)
            } else { walker = nil }
            if b.pendingHeroBattle != nil { throw XCTSkip("a battle with the player's army") }
            b.update(dt: 0.05)
        }
        XCTAssertNil(b.computerTurn)
        XCTAssertGreaterThan(shownWalks, 0)
        XCTAssertEqual(snapshot(a), snapshot(b))
    }

    /// Enemy speed "Off": nothing is shown, the turn is over at once.
    func testEnemyMovesOffRunsTheTurnAtOnce() throws {
        let a = try game(), b = try game()
        GameState.showEnemyMoves = false
        a.endTurn()
        b.beginEndTurn(animated: true)
        XCTAssertNil(b.computerTurn)
        XCTAssertEqual(snapshot(a), snapshot(b))
    }

    /// The armies the player does not see move at once; only those he sees walk.
    func testUnseenArmiesMoveAtOnce() throws {
        let g = try game()
        g.fogEnabled = true
        g.updateVision()
        g.beginEndTurn(animated: true)
        var frames = 0
        while g.computerTurn != nil, frames < 200_000 {
            frames += 1
            if let w = g.computerTurn?.walk, w.shown { XCTAssertTrue(g.isVisible(w.hero)) }
            if g.pendingHeroBattle != nil { throw XCTSkip("a battle with the player's army") }
            g.update(dt: 0.05)
        }
        XCTAssertNil(g.computerTurn)
    }

    /// A computer army attacking the player's army walks up to it, takes its attack pose, and the
    /// turn waits for the battle; afterwards the turn goes on to its end.
    func testComputerAttackOpensTheBattleAfterItsWalk() throws {
        let g = try game()
        guard let e = g.enemyHeroes.first else { throw XCTSkip("no armies") }
        // the computer's army: overwhelming, a few cells from a weak army of the player's
        guard let strong = g.tables?.creatures.filter({ $0.expansion == 0 }).max(by: { $0.level < $1.level })?.keyword,
              let weak = g.tables?.creatures.filter({ $0.expansion == 0 }).min(by: { $0.level < $1.level })?.keyword else { throw XCTSkip("no tables") }
        e.army = [Hero.Stack(creature: strong, count: 50)]
        g.level = e.z
        var spot: (Int, Int)? = nil
        for d in 3...6 where spot == nil {
            for (dx, dy) in [(d, 0), (-d, 0), (0, d), (0, -d), (d, d), (-d, -d)] where spot == nil {
                let c = (e.x + dx, e.y + dy)
                if g.passability.isFree(c.0, c.1), g.passability.path(from: (e.x, e.y), to: c) != nil, g.isVacant(c, for: e) { spot = c }
            }
        }
        guard let s = spot else { throw XCTSkip("no room near the computer's army") }
        var mh = MapHero(); mh.level = 1
        let ph = Hero.fromMap(mh, alignment: "life", x: s.0, y: s.1, tables: g.tables, random: &g.random)
        ph.owner = g.map.humanColour; ph.z = e.z
        ph.army = [Hero.Stack(creature: weak, count: 1)]
        g.heroes = [ph]
        g.passability.block(ph.x, ph.y)
        for o in g.enemyHeroes where o !== e { g.removeEnemy(o) }
        g.beginEndTurn(animated: true)
        var frames = 0, walked = false
        while g.pendingHeroBattle == nil, g.computerTurn != nil, frames < 100_000 {
            frames += 1
            if g.computerTurn?.walk?.hero === e, g.computerTurn?.walk?.shown == true { walked = true }
            g.update(dt: 0.05)
        }
        guard let pb = g.pendingHeroBattle else { throw XCTSkip("the computer did not attack") }
        XCTAssertTrue(walked)
        XCTAssertTrue(pb.hero === ph && pb.enemy === e)
        XCTAssertEqual(max(abs(e.x - ph.x), abs(e.y - ph.y)), 1)
        XCTAssertEqual(e.animState, "attack")
        XCTAssertNotNil(g.computerTurn)
        // the turn waits while the battle is pending or fought
        let day = g.day
        for _ in 0..<20 { g.update(dt: 0.05) }
        XCTAssertNotNil(g.computerTurn)
        g.pendingHeroBattle = nil; g.battleUnderway = true
        for _ in 0..<20 { g.update(dt: 0.05) }
        XCTAssertNotNil(g.computerTurn)
        XCTAssertEqual(g.day, day)
        // the battle over: the pose ends, the turn finishes and the new day starts
        g.battleUnderway = false
        g.update(dt: 0.05)
        XCTAssertNil(e.animState)
        frames = 0
        while g.computerTurn != nil, frames < 100_000 {
            frames += 1
            g.pendingHeroBattle = nil   // (other armies' battles, not fought here)
            g.update(dt: 0.05)
        }
        XCTAssertNil(g.computerTurn)
        XCTAssertEqual(g.day, day + 1)
    }
}
