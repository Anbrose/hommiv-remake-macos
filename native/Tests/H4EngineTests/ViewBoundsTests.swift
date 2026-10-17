import XCTest
@testable import H4Engine

/// heroes4.exe's adventure scroll limits (0x4f8f40, adventure_view_bounds_spec.md).
final class ViewBoundsTests: XCTestCase {
    /// The 1024x768 map window is 706 x 747; a 76 map is 2432 x 1216 exe map pixels.
    let window = SIMD2<Float>(706, 747)

    func testMarginsBeyondThePlayableRectangle() {
        XCTAssertEqual(MapScene.clampView(SIMD2(-1000, -1000), size: window, mapSize: 76), SIMD2(-50, -305))
        XCTAssertEqual(MapScene.clampView(SIMD2(5000, 5000), size: window, mapSize: 76), SIMD2(2432 + 50 - 706, 1216 + 50 - 747))
        XCTAssertEqual(MapScene.clampView(SIMD2(100, 200), size: window, mapSize: 76), SIMD2(100, 200))
    }

    func testFarLimitWinsWhenTheViewIsLargerThanTheMap() {
        // 16n + 50 - h < -305 for a tiny map: the bottom limit is applied last
        XCTAssertEqual(MapScene.clampView(SIMD2(0, -400), size: SIMD2(2000, 1000), mapSize: 10), SIMD2(370 - 2000, 210 - 1000))
    }
}
