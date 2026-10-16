import XCTest
@testable import H4Engine

/// Owner flags (re/adventure_flags_spec.md): the models' flag points as heroes4.exe reads them.
final class FlagTests: XCTestCase {
    func archive() throws -> H4Archive {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Games/HoMM4/prefix/drive_c/Games/HoMM4/Data/heroes4.h4r")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("game data not installed") }
        return try H4Archive(url: url)
    }

    /// adv_object models (0x44ca30): the has-flag byte and point after the type triple.
    func testAdvObjectFlagPoints() throws {
        let a = try archive()
        let expected: [(String, (Int, Int)?)] = [
            ("adv_object.mine.Sawmill.h4d", (28, -3)),
            ("adv_object.mine.Gold.h4d", (16, -76)),
            ("adv_object.castle.Necropolis.Castle.h4d", (1, -23)),
            ("adv_object.castle.Academy.Castle R.h4d", (0, 19)),
            ("adv_object.miscellaneous.Garrison.h4d", (2, -35)),
            ("adv_object.creature generators.Altar of Light.h4d", (-1, -176)),
            ("adv_object.Borderguard-Bordergate.b Guard Blue Water R.h4d", nil),   // 9 x 9: no flag
        ]
        for (name, point) in expected {
            let s = try Sprite(data: a.payload(name))
            XCTAssertEqual(s.flagPoint?.x, point?.0, name)
            XCTAssertEqual(s.flagPoint?.y, point?.1, name)
        }
    }

    /// adv_actor models (0x42cfc0): the model offset, then the flag point.
    func testActorFlagPoints() throws {
        let a = try archive()
        let hero = try AdvActor(data: a.payload("adv_actor.hero.life_might_male.h4d"))
        XCTAssertEqual(hero.offset.x, -5); XCTAssertEqual(hero.offset.y, -24)
        XCTAssertEqual(hero.flagPoint?.x, -14); XCTAssertEqual(hero.flagPoint?.y, -38)
        let ship = try AdvActor(data: a.payload("adv_actor.ships.order.h4d"))
        XCTAssertEqual(ship.flagPoint?.x, -3); XCTAssertEqual(ship.flagPoint?.y, -35)
    }

    /// 0x44b1c0: ((ms + phase) / frame time) % frames, the phase below frames x frame time.
    func testFlagFrameAdvancesEveryFrameTime() {
        let f0 = GameState.flagFrame(ms: 0, frameTime: 125, frames: 10, cellX: 3, cellY: 4)
        XCTAssertTrue((0..<10).contains(f0))
        for k in 1...30 {
            XCTAssertEqual(GameState.flagFrame(ms: 125 * k, frameTime: 125, frames: 10, cellX: 3, cellY: 4), (f0 + k) % 10)
        }
    }
}
