import XCTest
@testable import H4Engine

final class ArchiveTests: XCTestCase {
    func testGunzipRoundTrip() throws {
        // gzip of "hello hello hello" produced by Python's gzip module
        let gz: [UInt8] = [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 203, 72, 205, 201, 201, 87, 200, 64, 144, 0, 128, 136, 249, 229, 17, 0, 0, 0]
        let out = try gunzip(Data(gz), expected: 17)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello hello hello")
    }
}
