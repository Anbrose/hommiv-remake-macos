import Foundation

// The adventure route planner as heroes4.exe has it (re/adventure_pathing_spec.md): the search
// 0x4ff180, its heap (MSVC push_heap / pop_heap over the route records, 0x501540 / 0x501580),
// the neighbours in the exe's direction order (0x497810 with the table of 0x705b80) and the way
// a route enters an object (0x4d7300 over the entry edges the object models carry).

/// The planner's open list: MSVC's push_heap / pop_heap with "a.cost > b.cost" (a min-heap),
/// replayed move for move so that routes of equal cost come out as the exe's do (checked
/// against the exe's own heap code run in an emulator, scratchpad heapemu.py).
struct RouteHeap {
    private(set) var items: [(cost: Int32, cell: Int32)] = []
    var isEmpty: Bool { items.isEmpty }

    mutating func push(_ cost: Int32, _ cell: Int) {
        items.append((cost, Int32(cell)))
        siftUp(from: items.count - 1, top: 0, (cost, Int32(cell)))
    }

    /// _Push_heap: move the hole up while the parent costs strictly more.
    private mutating func siftUp(from start: Int, top: Int, _ v: (cost: Int32, cell: Int32)) {
        var hole = start
        while hole > top {
            let p = (hole - 1) / 2
            guard items[p].cost > v.cost else { break }
            items[hole] = items[p]; hole = p
        }
        items[hole] = v
    }

    /// _Pop_heap: the last entry fills the hole _Adjust_heap walks down (taking the left child
    /// unless the right one costs less... strictly: the right child unless it costs more).
    mutating func pop() -> (cost: Int32, cell: Int32) {
        let top = items[0]
        let n = items.count - 1
        let v = items[n]
        items[n] = items[0]
        var hole = 0, child = 2
        while child < n {
            if items[child].cost > items[child - 1].cost { child -= 1 }
            items[hole] = items[child]; hole = child; child = 2 * child + 2
        }
        if child == n { items[hole] = items[n - 1]; hole = n - 1 }
        if n > 0 { siftUp(from: hole, top: 0, v) }
        items.removeLast()
        return top
    }
}

extension Sprite {
    /// The edges of an object model a hero may step across into it (model +0x38 / +0x64, read
    /// by 0x44ca30 when the u16 at offset 3 is set): `top` has (h + 1) x w bits, bit y * w + x the
    /// edge on the -y side of cell (x, y) (y = h: the edge below the last row); `left` has
    /// (w + 1) x h bits, bit x * h + y the edge on the -x side of cell (x, y). A town's are the
    /// two edges of its gate, a pile's all four of its cell.
    public struct EntryEdges {
        public let w: Int, h: Int
        public let top: [Bool], left: [Bool]
        public func top(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y <= h && top[y * w + x] }
        public func left(_ x: Int, _ y: Int) -> Bool { x >= 0 && x <= w && y >= 0 && y < h && left[x * h + y] }
        /// A trigger cell (0x44cdd0): one of its four edges is an entry.
        public func isTrigger(_ x: Int, _ y: Int) -> Bool { top(x, y) || top(x, y + 1) || left(x, y) || left(x + 1, y) }
    }

    /// Header: u16 version, u8, u16 k (v >= 3), u16 w, u16 h, the footprint mask (w x h bits),
    /// then when k >= 1 the two entry masks (each mask ceil(bits / 8) bytes, low bit first).
    static func advObjectEntryEdges(_ r: ByteReader, end: Int) -> EntryEdges? {
        guard end >= 9, r.byte(at: 0) >= 3, r.byte(at: 1) == 0, r.peekU16(at: 3) >= 1 else { return nil }
        let w = Int(r.peekU16(at: 5)), h = Int(r.peekU16(at: 7))
        guard w >= 1, w <= 16, h >= 1, h <= 16 else { return nil }
        let nA = (w * h + 7) / 8, nT = ((h + 1) * w + 7) / 8, nL = ((w + 1) * h + 7) / 8
        guard 9 + nA + nT + nL <= end else { return nil }
        func bits(_ at: Int, _ n: Int) -> [Bool] { (0..<n).map { (r.byte(at: at + $0 / 8) >> UInt8($0 % 8)) & 1 == 1 } }
        return EntryEdges(w: w, h: h, top: bits(9 + nA, (h + 1) * w), left: bits(9 + nA + nT, (w + 1) * h))
    }
}

extension Passability {
    /// The exe's eight directions in its order (0x705b80): screen NE, E, SE, S, SW, W, NW, N;
    /// odd ones are the grid's diagonals.
    public static let directions: [(dx: Int, dy: Int)] = [(-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1)]

    /// A step from (x0, y0) onto (x1, y1) enters the object standing there (0x4d7300): the cell
    /// is one of its trigger cells and the step crosses an entry edge -- for a diagonal step
    /// either of the target cell's two edges facing the walker will do.
    public func enters(from x0: Int, _ y0: Int, to x1: Int, _ y1: Int) -> Bool {
        guard x1 >= 0, y1 >= 0, x1 < size, y1 < size, trigger[x1 * size + y1] >= 0 else { return false }
        let dx = x1 - x0, dy = y1 - y0
        func e(_ x: Int, _ y: Int, _ bit: UInt8) -> Bool { x >= 0 && y >= 0 && x < size && y < size && entry[x * size + y] & bit != 0 }
        if dy > 0, e(x1, y1, 1) { return true }
        if dx > 0, e(x1, y1, 2) { return true }
        if dy < 0, e(x1, y1 + 1, 1) { return true }
        if dx < 0, e(x1 + 1, y1, 2) { return true }
        return false
    }

    /// Is the cell an object's trigger cell (one a route may end on)?
    public func isTrigger(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < size && y < size && trigger[x * size + y] >= 0 }

    /// An object model's entry edges and trigger cells laid on the level (0x4d6150).
    public mutating func addEntries(_ e: Sprite.EntryEdges, at x0: Int, _ y0: Int, object k: Int) {
        func inside(_ x: Int, _ y: Int) -> Int? { x >= 0 && y >= 0 && x < size && y < size ? x * size + y : nil }
        for x in 0..<e.w { for y in 0...e.h where e.top(x, y) { if let i = inside(x0 + x, y0 + y) { entry[i] |= 1 } } }
        for x in 0...e.w { for y in 0..<e.h where e.left(x, y) { if let i = inside(x0 + x, y0 + y) { entry[i] |= 2 } } }
        for x in 0..<e.w { for y in 0..<e.h where e.isTrigger(x, y) {
            if let i = inside(x0 + x, y0 + y), trigger[i] < 0 { trigger[i] = Int32(clamping: k) }
        } }
    }

    /// Mark a cell as a trigger open on all four sides (a wandering stack, an army).
    public mutating func openTrigger(_ x: Int, _ y: Int, object: Int) {
        guard x >= 0, y >= 0, x < size, y < size else { return }
        revision &+= 1
        trigger[x * size + y] = Int32(clamping: object)
        entry[x * size + y] |= 3
        if x + 1 < size { entry[(x + 1) * size + y] |= 2 }
        if y + 1 < size { entry[x * size + y + 1] |= 1 }
    }

    /// The search of 0x4ff180 from one cell over the whole level (or until every goal is
    /// settled): Dijkstra on integer costs, the exe's direction order and heap, a cell's record
    /// replaced only by a strictly cheaper one. A step the plain rules refuse may still enter an
    /// object through its entry edges (0x4fe990); object cells are reached but never left
    /// (0x4cbc10); a cell with a forced exit (the zone of a stack the player sees, 0x4ff856) is
    /// left only in that direction. Returns the cost and predecessor of every cell.
    public func search(from start: (Int, Int), goals: Set<Int> = []) -> (cost: [Int32], prev: [Int32]) {
        let n = size * size
        var g = [Int32](repeating: .max, count: n)
        var prev = [Int32](repeating: -1, count: n)
        var heap = RouteHeap()
        var pending = goals
        let s = start.0 * size + start.1
        guard start.0 >= 0, start.1 >= 0, start.0 < size, start.1 < size else { return (g, prev) }
        g[s] = 0; heap.push(0, s)
        while !heap.isEmpty {
            let (c, ii) = heap.pop(); let i = Int(ii)
            if c > g[i] { continue }   // a stale record
            if !goals.isEmpty { pending.remove(i); if pending.isEmpty { break } }
            if i != s, blocked[i] { continue }   // entered, not left
            let x = i / size, y = i % size
            let forced = forcedExit[i]
            for (k, d) in Passability.directions.enumerated() {
                if let f = forced, f != k { continue }
                let nx = x + d.dx, ny = y + d.dy
                guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                guard canStep(from: x, y, to: nx, ny) || enters(from: x, y, to: nx, ny) else { continue }
                let j = nx * size + ny
                let ng = c + Int32(stepCost100(from: x, y, to: nx, ny))
                if ng < g[j] { g[j] = ng; prev[j] = Int32(i); heap.push(ng, j) }
            }
            for j in forced == nil ? jumps[i] ?? [] : [] where !blocked[j] {
                let ng = c + 100
                if ng < g[j] { g[j] = ng; prev[j] = Int32(i); heap.push(ng, j) }
            }
        }
        return (g, prev)
    }

    /// The route from a search to a cell: the cells after the start up to and including it.
    public func route(to t: Int, in r: (cost: [Int32], prev: [Int32]), from start: (Int, Int)) -> [(x: Int, y: Int)]? {
        guard t >= 0, t < r.cost.count, r.cost[t] < .max else { return nil }
        let s = start.0 * size + start.1
        var out: [(x: Int, y: Int)] = []
        var i = t
        while i != s { out.append((i / size, i % size)); i = Int(r.prev[i]); if i < 0 { return nil } }
        return out.reversed()
    }

    /// The cheapest route into one of an object's trigger cells (it ends on the object's cell;
    /// the walker stops on the cell before it), with its cost; on equal costs the cell listed first.
    public func routeInto(_ cells: [(Int, Int)], from start: (Int, Int)) -> (route: [(x: Int, y: Int)], cost: Int)? {
        let keys = cells.filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 < size && $0.1 < size }.map { $0.0 * size + $0.1 }
        guard !keys.isEmpty else { return nil }
        let r = search(from: start, goals: Set(keys))
        var best: (route: [(x: Int, y: Int)], cost: Int)? = nil
        for k in keys where r.cost[k] < .max && (best == nil || Int(r.cost[k]) < best!.cost) {
            if let p = route(to: k, in: r, from: start), !p.isEmpty { best = (p, Int(r.cost[k])) }
        }
        return best
    }
}
