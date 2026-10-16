import XCTest
@testable import H4Engine

/// The adventure route planner against heroes4.exe (re/adventure_pathing_spec.md). The heap is
/// checked against the exe's own push_heap / pop_heap (0x501540 / 0x501580) run in unicorn;
/// the routes against a literal model of 0x4ff180 built on that heap (scratchpad refplan.py):
/// the whole planner reads too much game state to run in the emulator.
final class PathingTests: XCTestCase {
    /// A push / pop sequence recorded from the exe's heap code (pushes are costs, -1 a pop;
    /// entries numbered in push order): the order the entries come out, ties included.
    func testHeapMatchesTheExe() {
        let ops = [200, 100, 200, 150, -1, 150, 100, 200, -1, -1, 300, 200, 150, 300, -1, 100, 600, 600, -1, 150, 600, 200, -1, 200,
                   300, 200, -1, 600, -1, -1, -1, 100, 400, -1, 200, 200, 300, -1, -1, 600, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
                   -1, -1, -1, -1]
        let exe = [2, 6, 4, 5, 12, 10, 15, 3, 20, 9, 22, 18, 24, 25, 1, 17, 7, 26, 11, 8, 19, 23, 21, 16, 27, 13, 14]
        var h = RouteHeap(), id = 0, out: [Int] = []
        for op in ops {
            if op < 0 { out.append(Int(h.pop().cell)) } else { id += 1; h.push(Int32(op), id) }
        }
        XCTAssertEqual(out, exe)
    }

    func grid(_ n: Int = 7, _ terrain: [(Int, Int, UInt8)] = [], roads: [(Int, Int, UInt8)] = []) -> Passability {
        var t = [UInt8?](repeating: 1, count: n * n)
        for (x, y, v) in terrain { t[x * n + y] = v }
        var r = [UInt8](repeating: 0, count: n * n)
        for (x, y, v) in roads { r[x * n + y] = v }
        return Passability(size: n, terrain: t, roads: r)
    }
    func cells(_ p: [(x: Int, y: Int)]?) -> [[Int]] { (p ?? []).map { [$0.x, $0.y] } }
    func cost(_ g: Passability, _ from: (Int, Int), _ p: [(x: Int, y: Int)]?) -> Int {
        var c = 0, x = from.0, y = from.1
        for s in p ?? [] { c += g.stepCost100(from: x, y, to: s.x, s.y); x = s.x; y = s.y }
        return c
    }

    /// Equal-cost routes: the exe's direction order and heap pick this one.
    func testTiesOnOpenGround() {
        let g = grid()
        let a = g.path(from: (1, 1), to: (5, 3))
        XCTAssertEqual(cells(a), [[2, 1], [3, 1], [4, 2], [5, 3]]); XCTAssertEqual(cost(g, (1, 1), a), 500)
        let b = g.path(from: (0, 0), to: (3, 6))
        XCTAssertEqual(cells(b), [[0, 1], [0, 2], [0, 3], [1, 4], [2, 5], [3, 6]]); XCTAssertEqual(cost(g, (0, 0), b), 750)
    }

    /// Terrain costs of table 0x985378 and the diagonal's half again (cost + cost >> 1).
    func testCosts() {
        let g = grid(7, [(1, 0, 3), (2, 0, 2), (3, 0, 5), (4, 0, 6), (5, 0, 18)])
        XCTAssertEqual(g.stepCost100(from: 0, 0, to: 1, 0), 200)   // swamp
        XCTAssertEqual(g.stepCost100(from: 0, 1, to: 1, 0), 300)   // swamp diagonally
        XCTAssertEqual(g.stepCost100(from: 1, 0, to: 2, 0), 125)   // rough
        XCTAssertEqual(g.stepCost100(from: 2, 1, to: 3, 0), 262)   // snow diagonally: 175 + 87
        XCTAssertEqual(g.stepCost100(from: 3, 0, to: 4, 0), 150)   // sand
        XCTAssertEqual(g.stepCost100(from: 4, 0, to: 5, 0), 125)   // the second magic terrain
        let s = grid(7, (2...4).flatMap { x in (0...4).map { (x, $0, UInt8(3)) } })
        let r = s.path(from: (0, 2), to: (6, 2))
        XCTAssertEqual(cells(r), [[1, 2], [2, 2], [3, 2], [4, 2], [5, 2], [6, 2]]); XCTAssertEqual(cost(s, (0, 2), r), 900)
    }

    /// Road to road: 75, a dirt road 100, whatever the ground.
    func testRoads() {
        let stone = grid(7, (0..<7).map { ($0, 1, 3) }, roads: (0..<7).map { ($0, 1, 1) })
        let a = stone.path(from: (0, 1), to: (6, 1))
        XCTAssertEqual(cells(a), (1...6).map { [$0, 1] }); XCTAssertEqual(cost(stone, (0, 1), a), 450)
        let dirt = grid(7, roads: (0..<7).map { ($0, 1, 2) })
        XCTAssertEqual(cost(dirt, (0, 1), dirt.path(from: (0, 1), to: (6, 1))), 600)
    }

    /// A 1 x 2 mine open on its +x side at its first cell: the route goes round and ends on the
    /// mine through that edge (here diagonally, which an open edge allows, 0x4d7300).
    func testObjectEntry() {
        var g = grid()
        g.place(at: 3, 2, blocked: [(0, 0), (0, 1)], entries: Sprite.EntryEdges(w: 1, h: 2, top: [false, false, false], left: [false, false, true, false]))
        let r = g.path(from: (0, 2), to: (3, 2))
        XCTAssertEqual(cells(r), [[1, 2], [2, 1], [3, 1], [4, 1], [3, 2]]); XCTAssertEqual(cost(g, (0, 2), r), 600)
        XCTAssertTrue(g.enters(from: 4, 2, to: 3, 2)); XCTAssertTrue(g.enters(from: 4, 3, to: 3, 2))
        XCTAssertFalse(g.enters(from: 2, 2, to: 3, 2)); XCTAssertFalse(g.enters(from: 4, 3, to: 3, 3))
        XCTAssertNil(g.path(from: (0, 2), to: (3, 3)))   // its other cell is no way in
    }

    /// No diagonal past a corner of an object's cell (its edges are blocked, 0x4d79d0).
    func testNoCornerCutting() {
        var g = grid()
        g.place(at: 3, 3, blocked: [(0, 0)], entries: nil)
        let r = g.path(from: (2, 2), to: (4, 4))
        XCTAssertEqual(cells(r), [[3, 2], [4, 2], [4, 3], [4, 4]]); XCTAssertEqual(cost(g, (2, 2), r), 400)
    }

    /// Guard-zone cells are entered but not left (0x4cbc10): the route goes round them.
    func testGuardZoneIsTerminal() {
        var g = grid()
        g.zones = [3 * 7 + 2, 3 * 7 + 3, 3 * 7 + 4]
        let r = g.path(from: (0, 3), to: (6, 3))
        XCTAssertEqual(cells(r), [[1, 3], [2, 4], [3, 5], [4, 5], [5, 4], [6, 3]]); XCTAssertEqual(cost(g, (0, 3), r), 800)
        XCTAssertEqual(cells(g.path(from: (0, 3), to: (3, 3))), [[1, 3], [2, 3], [3, 3]])
    }

    /// Onto a bridge's deck 75 (0x4ffa44).
    func testBridgeDeck() {
        var g = grid()
        g.makeBridge(3, 2, axis: 1)
        XCTAssertEqual(g.stepCost100(from: 2, 2, to: 3, 2), 75)
        XCTAssertEqual(g.stepCost100(from: 3, 2, to: 4, 2), 100)
    }

    /// The real entry masks of a few models (0x44ca30 layout).
    func testModelEntryEdges() throws {
        let path = NSString(string: "~/Games/HoMM4/prefix/drive_c/Games/HoMM4/Data/heroes4.h4r").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("game data not installed") }
        let a = try H4Archive(url: URL(fileURLWithPath: path))
        let town = try Sprite(data: a.payload("adv_object.castle.Academy.Castle.h4d")).entryEdges
        XCTAssertEqual(town.map { e in (0..<6).filter { e.left(6, $0) } }, [2, 3])   // the gate, on the +x side
        XCTAssertEqual(town.map { e in (0..<6).flatMap { x in (0...6).filter { e.top(x, $0) } }.count }, 0)
        let pile = try Sprite(data: a.payload("adv_object.Resources.Gold.h4d")).entryEdges
        XCTAssertEqual(pile.map { [$0.top(0, 0), $0.top(0, 1), $0.left(0, 0), $0.left(1, 0)] }, [true, true, true, true])
        let mine = try Sprite(data: a.payload("adv_object.mine.Gold.h4d")).entryEdges
        XCTAssertEqual(mine.map { [$0.left(1, 0), $0.left(1, 1), $0.left(0, 0)] }, [true, false, false])
    }
}
