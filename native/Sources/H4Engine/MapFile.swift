import Foundation

public struct MapObject {
    public let name: String
    public let type: String
    public let subtype: String
    public let terrain: String
    public let x: Int
    public let y: Int
    public let level: Int
}

public struct Overlay {
    public let type: UInt8, variant: UInt8, mask: Int, order: UInt8
}

/// A road piece on a cell: `kind` 0 is the road body (drawn where the mask is CLEAR), 1..3 a
/// shoulder spilling from a neighbouring road of that type (1 stone, 2 dirt, 3 cobble; drawn
/// where the mask is SET); `order` (10..14) sorts it among the cell's terrain overlays.
public struct Road {
    public let kind: UInt8, mask: Int, order: UInt8
}

public struct Cell {
    public let type: UInt8
    public let variant: UInt8
    public let overlays: [Overlay]
    public let roads: [Road]
}

/// A decoded .h4c scenario. Format: tools/h4map.py.
public struct MapFile {
    public let version: Int
    public let size: Int
    public let levels: Int
    public let players: [UInt8]
    public let name: String
    public let description: String
    public let objects: [MapObject]
    /// cells[level][x * size + y]; nil outside the playable diamond
    public let cells: [[Cell?]]

    public static func diamond(_ size: Int) -> [(Int, Int)] {
        let mid = Double(size - 1) / 2
        var pts: [(Int, Int)] = []
        for r in 0..<size { for c in 0..<size where abs(Double(r) - mid) + abs(Double(c) - mid) <= Double(size) / 2 { pts.append((r, c)) } }
        return pts
    }

    public init(data raw: Data, objectNames: Set<String>) throws {
        var d = raw
        if raw.count > 10, raw.prefix(10) == Data("H4CAMPAIGN".utf8) {
            guard let g = raw.firstRange(of: Data([0x1f, 0x8b, 0x08])) else { throw H4Error.corrupt("map: no gzip") }
            d = try gunzip(raw.subdata(in: g.lowerBound..<raw.count), expected: raw.count * 12)
        }
        var r = ByteReader(d)
        version = Int(r.u16())
        if version >= 28 { _ = r.u16() }
        size = Int(r.u16())
        levels = Int(r.u8())
        _ = r.u32()
        let np = Int(r.u8())
        var pl: [UInt8] = []
        for _ in 0..<np { pl.append(r.u8()); r.pos += 4 }
        players = pl
        name = r.string16()
        _ = r.u8()
        description = r.string16()
        let headerEnd = r.pos

        let pts = MapFile.diamond(size)
        let perLevel = pts.count
        guard let (cellsFlat, terrainPos) = MapFile.findTerrain(d, from: headerEnd, count: perLevel * levels) else {
            throw H4Error.corrupt("map: terrain not found")
        }
        objects = MapFile.parseObjects(d, end: terrainPos, names: objectNames)
        var grids: [[Cell?]] = []
        for lv in 0..<levels {
            var g = [Cell?](repeating: nil, count: size * size)
            for (i, (x, y)) in pts.enumerated() { g[x * size + y] = cellsFlat[lv * perLevel + i] }
            grids.append(g)
        }
        cells = grids
    }

    static func parseCells(_ d: Data, at start: Int, count: Int) -> ([Cell], Int)? {
        let r = ByteReader(d)
        var pos = start
        var out: [Cell] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard pos + 11 <= d.count else { return nil }
            let t = r.byte(at: pos), v = r.byte(at: pos + 1), n = Int(r.byte(at: pos + 9))
            guard t <= 18, v <= 3, n <= 8 else { return nil }
            var ov: [Overlay] = []
            for i in 0..<n {
                let p = pos + 10 + i * 5
                guard p + 5 <= d.count else { return nil }
                ov.append(Overlay(type: r.byte(at: p), variant: r.byte(at: p + 1), mask: Int(r.peekU16(at: p + 2)), order: r.byte(at: p + 4)))
            }
            let q = pos + 10 + 5 * n
            guard q < d.count else { return nil }
            let m = Int(r.byte(at: q))
            guard m <= 8, q + 1 + 4 * m <= d.count else { return nil }
            var rd: [Road] = []
            for i in 0..<m { let p = q + 1 + i * 4; rd.append(Road(kind: r.byte(at: p), mask: Int(r.byte(at: p + 1)), order: r.byte(at: p + 3))) }
            out.append(Cell(type: t, variant: v, overlays: ov, roads: rd))
            pos = q + 1 + 4 * m
        }
        return (out, pos)
    }

    static func findTerrain(_ d: Data, from: Int, count: Int) -> ([Cell], Int)? {
        let r = ByteReader(d)
        var p = from
        while p + 11 * count <= d.count {
            if let (cells, end) = parseCells(d, at: p, count: count) {
                if end >= d.count || r.peekU16(at: end + 7) != 8 { return (cells, p) }
            }
            p += 1
        }
        return nil
    }

    static func parseObjects(_ d: Data, end: Int, names: Set<String>) -> [MapObject] {
        let r = ByteReader(d)
        var starts: [Int] = []
        var p = 0
        while p < end - 2 {
            let ln = Int(r.peekU16(at: p))
            if ln >= 4, ln <= 60, p + 2 + ln <= d.count,
               let s = String(bytes: d[(d.startIndex + p + 2)..<(d.startIndex + p + 2 + ln)], encoding: .isoLatin1), names.contains(s) {
                starts.append(p)
                p += 2 + ln
            } else {
                p += 1
            }
        }
        // Each record is `i32 x, i32 y, u8 level, u32 0` followed by the object's name and body:
        // the position comes BEFORE the name (reading it after the body shifts every object onto
        // the next record's cell -- it looked plausible because the editor saves neighbours together).
        var objs: [MapObject] = []
        for p in starts where p >= 13 {
            var rd = ByteReader(d, at: p)
            let name = rd.string16()
            rd.pos += 2
            var cats: [String] = []
            for _ in 0..<3 { _ = rd.u16(); cats.append(rd.string16()) }
            let x = Int(Int32(bitPattern: r.peekU32(at: p - 13))), y = Int(Int32(bitPattern: r.peekU32(at: p - 9)))
            objs.append(MapObject(name: name, type: cats[0], subtype: cats[1], terrain: cats[2], x: x, y: y, level: Int(r.byte(at: p - 5))))
        }
        return objs
    }
}
