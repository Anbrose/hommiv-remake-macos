import XCTest
@testable import H4Engine

final class CombatActorTests: XCTestCase {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    func le32(_ v: Int) -> [UInt8] { let u = UInt32(bitPattern: Int32(v)); return (0..<4).map { UInt8((u >> (8 * $0)) & 0xff) } }
    func str16(_ s: String) -> [UInt8] { le16(s.utf8.count) + Array(s.utf8) }
    func actorFile(version v: Int, size: Int, height: Int, launch: [(Int, Int, Int)]?, trailer: (Int, Int)?) -> Data {
        var b = le16(v) + [UInt8(size), UInt8(height)] + le16(16) + le16(64) + le16(16)
        if let l = launch { for (x, y, z) in l { b += le32(x) + le32(y) + le32(z) } }
        b += le16(2)
        for (name, fps, hit) in [("ranged", 9, 4), ("walk", 10, 0)] {
            b += str16(name) + [UInt8(fps)]
            if v >= 5 { b += [UInt8(hit)] }
            for k in 0..<8 { b += str16("seq.\(name).\(k)") }
        }
        if let t = trailer { b += le32(t.0) + le32(t.1) }
        return Data(b)
    }

    func testVersion6LaunchBlockAndTrailer() throws {
        let launch = (0..<8).map { ($0, 10 + $0, 74) }
        let a = try CombatActor(data: actorFile(version: 6, size: 4, height: 96, launch: launch, trailer: (-1, 2)))
        XCTAssertEqual(a.size, 4)
        XCTAssertEqual(a.height, 96)
        XCTAssertEqual(a.launchOffset("se").x, 2)
        XCTAssertEqual(a.launchOffset("se").y, 12)
        XCTAssertEqual(a.launchOffset("n").z, 74)
        XCTAssertEqual(a.state("ranged")?.hitFrame, 4)
        XCTAssertEqual(a.state("walk")?.sequences[1], "seq.walk.1")
        XCTAssertEqual(a.drawOffset.x, -1)
        XCTAssertEqual(a.drawOffset.y, 2)
    }

    /// Version-5 files (missile.magic_arrow, .lightning, .pebble ...) have no launch block: the
    /// state count is at offset 10, and every facing launches from (size*8, size*8, height/2).
    func testVersion5HasNoLaunchBlock() throws {
        let a = try CombatActor(data: actorFile(version: 5, size: 2, height: 10, launch: nil, trailer: (76, 89)))
        XCTAssertEqual(a.states.count, 2)
        XCTAssertEqual(a.state("ranged")?.hitFrame, 4)
        XCTAssertEqual(a.launchOffset("e").x, 16)
        XCTAssertEqual(a.launchOffset("e").z, 5)
        XCTAssertEqual(a.drawOffset.x, 76)
        XCTAssertEqual(a.footprint, 2)
    }

    /// Below version 5 there is no hit-frame byte, below 4 no trailer.
    func testVersion3HasNoHitFrameOrTrailer() throws {
        let a = try CombatActor(data: actorFile(version: 3, size: 2, height: 10, launch: nil, trailer: nil))
        XCTAssertEqual(a.state("ranged")?.hitFrame, 0)
        XCTAssertEqual(a.state("ranged")?.speed, 9)
        XCTAssertEqual(a.drawOffset.x, 0)
    }

    /// 0x51ee00: world angle atan2(dy, -dx) in 45-degree world sectors.
    func testFacingUsesWorldAngle() {
        XCTAssertEqual(Battle.facing(dx: -1, dy: 0), "ne")
        XCTAssertEqual(Battle.facing(dx: 0, dy: 1), "se")
        XCTAssertEqual(Battle.facing(dx: 1, dy: 0), "sw")
        XCTAssertEqual(Battle.facing(dx: 0, dy: -1), "nw")
        XCTAssertEqual(Battle.facing(dx: -1, dy: 1), "e")
        XCTAssertEqual(Battle.facing(dx: 1, dy: 1), "s")
        XCTAssertEqual(Battle.facing(dx: 1, dy: -1), "w")
        XCTAssertEqual(Battle.facing(dx: -1, dy: -1), "n")
        // the spec's example: world (-1, 0.3) is ne (17 degrees), where a screen-angle bucket gives e
        XCTAssertEqual(Battle.facing(dx: -1, dy: 0.3), "ne")
        XCTAssertEqual(Battle.facing(dx: -1, dy: 0.42), "ne")   // 22 degrees
        XCTAssertEqual(Battle.facing(dx: -1, dy: 0.45), "e")    // 24 degrees
    }
}
