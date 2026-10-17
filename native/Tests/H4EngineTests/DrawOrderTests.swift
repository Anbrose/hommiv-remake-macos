import XCTest
@testable import H4Engine

/// Adventure map draw order (re/adventure_draw_order_spec.md): the models' sort data as
/// heroes4.exe reads it, and the order it sorts by.
final class DrawOrderTests: XCTestCase {
    func archive() throws -> H4Archive {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Games/HoMM4/prefix/drive_c/Games/HoMM4/Data/heroes4.h4r")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("game data not installed") }
        return try H4Archive(url: url)
    }

    /// The image class byte (0x44cab0) and the overlay column depth list (0x7cc590).
    func testModelSortData() throws {
        let a = try archive()
        let expected: [(String, underlay: Bool, start: Int, depths: [Int])] = [
            ("adv_object.rocks.Grass.02.h4d", false, -2, [-2, -3, -3, -2]),    // a rock: the front cell per column
            ("adv_object.shrubs.Grass.10.h4d", false, -2, [-2, -1, -1, -2]),   // flat grass: the back cell in the middle
            ("adv_object.flowers.02.h4d", false, -1, [-1, -1]),
            ("adv_object.movement modifiers.Bridge.Bridge 1.h4d", false, -2, [-1, -1, -1, -1]),
            ("adv_object.moss.16.h4d", true, 0, []),                           // underlays have no list
            ("adv_object.shrubs.Snow tufts.27.h4d", true, 0, []),
        ]
        for (name, underlay, start, depths) in expected {
            let s = try Sprite(data: a.payload(name))
            XCTAssertTrue(s.isAdvObject, name)
            XCTAssertEqual(s.underlay, underlay, name)
            XCTAssertEqual(s.columnDepths, depths, name)
            if !depths.isEmpty {
                XCTAssertEqual(s.columnStart, start, name)
                // one entry per 32-pixel column of the pictures' union
                let b = s.imageBounds
                XCTAssertEqual(Int((Double(b.right) / 32).rounded(.up)) - Int((Double(b.left) / 32).rounded(.down)), depths.count, name)
            }
        }
        // clamped at both ends (0x7d01b0)
        let rock = try Sprite(data: a.payload("adv_object.rocks.Grass.02.h4d"))
        XCTAssertEqual(rock.columnDepth(-9), -2)
        XCTAssertEqual(rock.columnDepth(0), -3)
        XCTAssertEqual(rock.columnDepth(9), -2)
        // actor sequences are not adv_object models: they sort as armies
        let seq = try Sprite(data: a.payload("actor_sequence.hero.life_might_male.walk.e.h4d"))
        XCTAssertFalse(seq.isAdvObject)
    }

    /// 0x406f00: key descending, then the object's place in the map, then the piece index.
    func testOrder() {
        // a hero on a 1x1 flower's cell ties with it (both -1 - (x + y)); the later object is in front
        let flower = (key: DrawOrder.key(depth: -1, cellX: 5, cellY: 5), seq: 10, sub: 0)
        let hero = (key: DrawOrder.key(depth: DrawOrder.armyDepth, cellX: 5, cellY: 5), seq: 1 << 25, sub: 1)
        XCTAssertTrue(DrawOrder.before(flower, hero))
        // a 2x2 grass patch's middle columns sort by its back cell: a hero on its front cell is in front
        let grassMiddle = (key: DrawOrder.key(depth: -1, cellX: 4, cellY: 4), seq: 10, sub: 1)
        let heroFront = (key: DrawOrder.key(depth: DrawOrder.armyDepth, cellX: 5, cellY: 5), seq: 1 << 25, sub: 1)
        XCTAssertTrue(DrawOrder.before(grassMiddle, heroFront))
        // a rock's front column at that cell covers a hero standing behind it
        let rockFront = (key: DrawOrder.key(depth: -3, cellX: 4, cellY: 4), seq: 10, sub: 1)
        let heroBehind = (key: DrawOrder.key(depth: DrawOrder.armyDepth, cellX: 4, cellY: 5), seq: 1 << 25, sub: 1)
        XCTAssertTrue(DrawOrder.before(heroBehind, rockFront))
        // within an object: ring, body, flag
        XCTAssertTrue(DrawOrder.before((0, 3, 0), (0, 3, 1)))
    }

    /// t_army_mover 0x545560 / 0x545d90: the army moves onto the next cell at half the step.
    func testWalkingArmySortsByCellAtHalfStep() {
        let h = Hero(actor: "hero.life_might_male", x: 3, y: 3)
        h.path = [(x: 4, y: 3)]
        h.progress = 0.49
        XCTAssertTrue(h.drawCell == (3, 3))
        h.progress = 0.5
        XCTAssertTrue(h.drawCell == (4, 3))
        h.path = []
        XCTAssertTrue(h.drawCell == (3, 3))
    }
}
