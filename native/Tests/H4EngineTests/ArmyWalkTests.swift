import XCTest
@testable import H4Engine

/// The walk's animation as heroes4.exe's t_army_mover fits it (re/adventure_walk_spec.md §3-4):
/// a prewalk, walk loops stretched over the route, a postwalk; a diagonal step 48 against 32.
final class ArmyWalkTests: XCTestCase {
    let hero = ArmyGait()   // 8 / 32 / 8, frames 2 / 6 / 2, speed 10: 66 ms a frame at 150 %

    /// Frames until the walk is done, and the states seen in order.
    func run(_ steps: [Int]) -> (frames: Int, states: [String], stepFrames: [Int]) {
        var w = ArmyWalk(steps: steps, gait: hero)
        var frames = 0, states: [String] = [w.state], stepFrames: [Int] = [], since = 0
        while !w.done, frames < 1000 {
            let n = w.advance(Float(hero.frameMs("walk", percent: 150) / 1000) + 0.0001, gait: hero, percent: 150)
            frames += 1; since += 1
            if n > 0 { stepFrames.append(since); since = 0 }
            if states.last != w.state, !w.done { states.append(w.state) }
        }
        return (frames, states, stepFrames)
    }

    func testFrameTimeIsTheExesFormula() {
        XCTAssertEqual(hero.frameMs("walk", percent: 150), 10000.0 / 150, accuracy: 0.001)   // 100 x (1000 / 10) / 150
        XCTAssertEqual(hero.frameMs("walk", percent: 200), 50, accuracy: 0.001)
    }

    func testEveryWalkStartsWithThePrewalkAndEndsWithThePostwalk() {
        XCTAssertEqual(run([32]).states, ["prewalk", "postwalk"])           // too short for a walk loop
        XCTAssertEqual(run([32, 32, 32]).states, ["prewalk", "walk", "postwalk"])
    }

    /// One straight cell: prewalk 2 frames + postwalk 2; four straight cells: 2 + 3 loops of 6 + 2.
    func testLoopsAreFittedToTheRoute() {
        XCTAssertEqual(run([32]).frames, 4)
        XCTAssertEqual(run([32, 32, 32, 32]).frames, 22)
    }

    /// A diagonal step is 48: it takes longer than a straight one (the remake used to give every
    /// step the same time, so a step across the screen looked like a jump).
    func testADiagonalStepTakesLongerThanAStraightOne() {
        let r = run([32, 32, 48, 32, 32])
        XCTAssertEqual(r.stepFrames.count, 5)
        XCTAssertGreaterThan(r.stepFrames[2], r.stepFrames[1])
        XCTAssertGreaterThan(run([48, 48, 48, 48]).frames, run([32, 32, 32, 32]).frames)
    }

    /// Stopped by a click: the walk ends with the current step, the postwalk fitted into it.
    func testStopEndsWithTheCurrentStep() {
        var w = ArmyWalk(steps: [32, 32, 32, 32, 32], gait: hero)
        var finished = 0
        while finished == 0 { finished += w.advance(0.07, gait: hero, percent: 150) }
        w.stopAfterCurrentStep(hero)
        var more = 0
        while !w.done { more += w.advance(0.07, gait: hero, percent: 150) }
        XCTAssertEqual(more, 1)
        XCTAssertEqual(w.state, "postwalk")
    }

    /// 0x51ee70 / 0x51edd0: the army reached turns toward the one that came.
    func testFacingTowardAnArmy() {
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (4, 5)), "ne")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (6, 5)), "sw")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (5, 6)), "se")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (6, 6)), "s")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (4, 6)), "e")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (6, 4)), "w")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (4, 4)), "n")
        XCTAssertEqual(GameState.facing(from: (5, 5), toward: (5, 4)), "nw")
    }
}
