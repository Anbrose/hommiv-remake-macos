import Foundation

public struct MapObject {
    public let name: String
    public let type: String
    public let subtype: String
    public let terrain: String
    public let x: Int
    public let y: Int
    public let level: Int
    /// Owning player (0 = the first player) for towns; nil when unowned or not ownable.
    public var owner: Int? = nil
    /// A town's name set in the editor ("none" = pick a random one).
    public var customName: String? = nil
    /// A town's editor settings (garrison, built and allowed buildings).
    public var town: TownSettings? = nil
    /// A placed army's stacks (creature id, count; 0 = random), for type "army".
    public var army: [(creature: Int, count: Int)?]? = nil
    /// A random monster's size range in peasants (min, max), when the editor set one.
    public var monsterRange: (min: Int, max: Int)? = nil

    /// The town part of a town record as heroes4.exe reads it (0x417990, versions 6...8):
    /// u16 version, u8 owner (6 = none), string16 name, u8 custom garrison + creature array,
    /// u8 custom buildings + 6 bytes built + 6 bytes allowed (43-bit sets, 0x417c10) or u8 fort.
    /// Four event lists follow. A placed town (0x89a710) puts u16 version and, from version
    /// 4, two versioned 188-bit spell sets in front; a random town a u32 and a string16.
    static func parseTownBody(_ rd: inout ByteReader, random: Bool) -> TownSettings? {
        if random {
            guard rd.remaining >= 6 else { return nil }
            _ = rd.u32(); _ = rd.string16()
        } else {
            guard rd.remaining >= 2 else { return nil }
            let v = rd.u16()
            if v >= 4 {
                for _ in 0..<2 {
                    guard rd.remaining >= 25 else { return nil }
                    let bv = rd.u8(); rd.pos += bv == 0 ? 23 : 24
                }
            }
        }
        guard rd.remaining >= 4 else { return nil }
        let ver = Int(rd.u16())
        guard (6...8).contains(ver) else { return nil }
        var t = TownSettings()
        let o = Int(rd.u8())
        t.owner = o < 6 ? o : nil
        let n = rd.string16()
        if !n.isEmpty, n.lowercased() != "none" { t.name = n }
        guard rd.remaining >= 1 else { return t }
        if rd.u8() != 0 {
            guard let g = MapFile.parseCreatureArray(&rd) else { return t }
            t.garrison = g
        }
        guard rd.remaining >= 1 else { return t }
        if rd.u8() != 0 {
            guard rd.remaining >= 12 else { return t }
            func bits(_ d: Data) -> UInt64 { d.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
            t.built = bits(rd.bytes(6)); t.allowed = bits(rd.bytes(6))
        } else if rd.remaining >= 1 {
            t.hasFort = rd.u8() != 0
        }
        return t
    }
}

/// A player slot of the map: its colour, whether a human may take it, and the alignments
/// (bit 0 life, 1 order, 2 death, 3 chaos, 4 nature, 5 might) its random heroes and towns may have.
public struct PlayerSpec { public let colour: Int, canBeHuman: Bool, alignments: UInt8 }

/// Editor settings of a town.
public struct TownSettings {
    public var owner: Int? = nil
    public var name: String? = nil
    /// (creature id in heroes4.exe's order, count; 0 = a random count) per slot, nil when empty.
    public var garrison: [(creature: Int, count: Int)?]? = nil
    /// Building ids (0...42, per town type: see RuleTables.buildingIds) as bit sets.
    public var built: UInt64? = nil, allowed: UInt64? = nil
    public var hasFort = false
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
    public let playerSpecs: [PlayerSpec]
    public let name: String
    public let description: String
    /// Map difficulty (0 easy ... 4 impossible), the byte after the name.
    public let difficulty: Int
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
        // players (heroes4.exe 0x77a5f6): u8 colour, u8 can be human, u8 (unknown), then a
        // versioned bit set of the alignments its random heroes and towns may take
        let np = Int(r.u8())
        var pl: [UInt8] = [], specs: [PlayerSpec] = []
        for _ in 0..<np {
            let colour = r.u8(), human = r.u8() != 0
            _ = r.u8(); _ = r.u8()
            let mask = r.u8()
            pl.append(colour); specs.append(PlayerSpec(colour: Int(colour), canBeHuman: human, alignments: mask))
        }
        players = pl
        playerSpecs = specs
        name = r.string16()
        difficulty = Int(r.u8())
        description = r.string16()
        let headerEnd = r.pos

        let pts = MapFile.diamond(size)
        let perLevel = pts.count
        guard let (cellsFlat, terrainPos) = MapFile.findTerrain(d, from: headerEnd, count: perLevel * levels) else {
            throw H4Error.corrupt("map: terrain not found")
        }
        objects = MapFile.parseObjects(d, end: terrainPos, names: objectNames) + MapFile.parseArmies(d, end: terrainPos, size: size)
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

    /// A creature array (0x640d00): u16 version 0, 7 slots of u8 kind (0xff empty, 0 creature:
    /// u16 version, i16 id, i16 count, version 1: u16 extra count). Heroes and extras are not read.
    static func parseCreatureArray(_ rd: inout ByteReader) -> [(creature: Int, count: Int)?]? {
        guard rd.remaining >= 2, rd.u16() == 0 else { return nil }
        var out: [(creature: Int, count: Int)?] = []
        for _ in 0..<7 {
            guard rd.remaining >= 1 else { return nil }
            let kind = rd.u8()
            if kind == 0xff { out.append(nil); continue }
            guard kind == 0, rd.remaining >= 6 else { return nil }
            let v = rd.u16(), id = Int(Int16(bitPattern: rd.u16())), n = Int(Int16(bitPattern: rd.u16()))
            if v >= 1 { guard rd.remaining >= 2, rd.u16() == 0 else { return nil } }
            out.append(id >= 0 ? (id, n) : nil)
        }
        return out
    }

    /// Armies placed in the editor (the object loop 0x4ced20 with flag 1: t_army, no model
    /// name): i32 x, i32 y, i32 level, u8 1, then t_army's record (0x523a30): u16 version,
    /// u8 owner (6 = neutral), the creature array. Found by that shape; neutral ones only.
    static func parseArmies(_ d: Data, end: Int, size: Int) -> [MapObject] {
        let r = ByteReader(d)
        var out: [MapObject] = []
        var p = 0
        while p + 30 < end {
            defer { p += 1 }
            guard r.byte(at: p + 12) == 1 else { continue }
            let x = Int(Int32(bitPattern: r.peekU32(at: p))), y = Int(Int32(bitPattern: r.peekU32(at: p + 4))), lv = Int(Int32(bitPattern: r.peekU32(at: p + 8)))
            guard (0..<size).contains(x), (0..<size).contains(y), lv == 0 || lv == 1 else { continue }
            let v = Int(r.peekU16(at: p + 13))
            guard (3...9).contains(v), r.byte(at: p + 15) == 6 else { continue }
            var rd = ByteReader(d, at: p + 16)
            guard let stacks = MapFile.parseCreatureArray(&rd), stacks.contains(where: { $0 != nil }) else { continue }
            var o = MapObject(name: "army", type: "army", subtype: "", terrain: "", x: x, y: y, level: lv)
            o.army = stacks
            out.append(o)
        }
        return out
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
            var o = MapObject(name: name, type: cats[0], subtype: cats[1], terrain: cats[2], x: x, y: y, level: Int(r.byte(at: p - 5)))
            if cats[0] == "town" || cats[0] == "random_town" {
                let t = MapObject.parseTownBody(&rd, random: cats[0] == "random_town")
                o.town = t; o.owner = t?.owner; o.customName = t?.name
            }
            if cats[0] == "random_monster", let next = starts.first(where: { $0 > p }) {
                // version 4 records end with i32 min, i32 max (0x7f3710), just before the next
                // record's 13-byte header; 0, 0 = the level's default size
                let end = next - 13
                if end - 8 > rd.pos {
                    let lo = Int(Int32(bitPattern: r.peekU32(at: end - 8))), hi = Int(Int32(bitPattern: r.peekU32(at: end - 4)))
                    if lo > 0, hi >= lo, hi < 1_000_000 { o.monsterRange = (lo, hi) }
                }
            }
            objs.append(o)
        }
        return objs
    }
}
