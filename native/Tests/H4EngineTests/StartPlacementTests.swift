import XCTest
@testable import H4Engine

/// Preplaced armies' records (re/start_placement_spec.md): position read verbatim, v7+ ship byte.
final class StartPlacementTests: XCTestCase {
    static let root = URL(fileURLWithPath: NSHomeDirectory() + "/Games/HoMM4/prefix/drive_c/Games/HoMM4")

    func archive() throws -> (H4Archive, Set<String>) {
        let data = StartPlacementTests.root.appendingPathComponent("Data")
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent("storm.h4r").path) else { throw XCTSkip("no game files") }
        let a = try H4Archive(url: data.appendingPathComponent("heroes4.h4r"))
        for f in ["x2.h4r", "storm.h4r", "updates.h4r"] { if let s = try? H4Archive(url: data.appendingPathComponent(f)) { a.supplement(with: s) } }
        return (a, Set(a.names(prefix: "adv_object.").map { String($0.dropFirst("adv_object.".count).dropLast(4)) }))
    }

    /// Isle of the Dawn (Bard campaign, scenario 1): Agraynel's army record says (33,106) on the
    /// surface with no ship (byte -1); the cell is deep water.
    func testIsleOfTheDawnStartingArmyRecord() throws {
        let (a, names) = try archive()
        let m = try MapFile(data: CampaignFile.load(11, from: a).scenario(0), objectNames: names)
        let o = try XCTUnwrap(m.objects.first { $0.heroes.contains { $0.name == "Agraynel" } })
        XCTAssertEqual([o.x, o.y, o.level], [33, 106, 0])
        XCTAssertNil(o.boat)
        XCTAssertEqual(m.cells[0][33 * m.size + 106]?.type, 0)
    }

    /// A player's army that starts aboard a ship (v7+ byte 0x523e55 = the ship's alignment).
    func testShipByteOfAPlayersArmy() throws {
        let (_, names) = try archive()
        let url = StartPlacementTests.root.appendingPathComponent("maps/Search for the Old Heroes 2.h4c")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("no map") }
        let m = try MapFile(data: Data(contentsOf: url), objectNames: names)
        let o = try XCTUnwrap(m.objects.first { $0.heroes.contains { $0.name == "Timin" } })
        XCTAssertEqual([o.x, o.y], [76, 5])
        XCTAssertEqual(o.boat, 5)
    }
}
