import XCTest
@testable import H4Engine

/// The cell record's rock bytes (heroes4.exe reader 0x413b30): +3 rock type, +4 the rim flag.
final class RockCellTests: XCTestCase {
    func testRockBytes() throws {
        // type, variant, road, rock, rim, fog dword 0x00080000, no overlays, no roads
        let rec: [UInt8] = [1, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0,
                            8, 1, 0, 2, 1, 0, 0, 8, 0, 0, 0,
                            1, 1, 0, 0, 0, 0, 0, 8, 0, 0, 0]
        let (cells, end) = try XCTUnwrap(MapFile.parseCells(Data(rec), at: 0, count: 3))
        XCTAssertEqual(end, rec.count)
        XCTAssertEqual(cells.map(\.rock), [1, 2, 0])
        XCTAssertEqual(cells.map(\.rockEdge), [false, true, false])
        // solid rock is filled black; a rim keeps its terrain
        XCTAssertEqual(cells.map(\.isSolidRock), [true, false, false])
    }
}
