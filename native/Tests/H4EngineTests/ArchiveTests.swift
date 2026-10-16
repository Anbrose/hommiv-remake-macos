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

final class ArchiveAliasTests: XCTestCase {
    /// An alias names its target in lower case while the entry is stored capitalised
    /// ("animation.spell.heal" -> "animation.spell.bind wound.h4d", entry "Bind Wound").
    func testAliasIsFollowedWithoutRegardToCase() throws {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xff) } }
        func s16(_ s: String) -> [UInt8] { le16(s.utf8.count) + Array(s.utf8) }
        let body: [UInt8] = Array("PAYLOAD".utf8)
        let dataOffset = 8
        let indexOffset = dataOffset + body.count
        var index = le32(2)
        index += le32(dataOffset) + le32(body.count) + le32(body.count) + le32(0) + s16("animation.spell.Bind Wound.h4d") + s16("") + s16("") + le32(1)
        index += le32(0) + le32(0) + le32(0) + le32(0) + s16("animation.spell.heal.h4d") + s16("") + s16("animation.spell.bind wound.h4d") + le32(1)
        let file = Array("H4R".utf8) + [5] + le32(indexOffset) + body + index
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alias-\(UUID().uuidString).h4r")
        try Data(file).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try H4Archive(url: url)
        XCTAssertEqual(String(decoding: try a.payload("animation.spell.heal.h4d"), as: UTF8.self), "PAYLOAD")
        XCTAssertEqual(a.realName("animation.spell.bind wound.h4d"), "animation.spell.Bind Wound.h4d")
    }
}
