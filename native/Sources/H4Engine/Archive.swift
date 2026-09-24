import Foundation
import Compression

/// A Heroes IV .h4r resource archive. Format: see tools/h4r.py.
public final class H4Archive {
    public struct Entry {
        public let name: String
        public let offset: Int
        public let size: Int
        public let unpackedSize: Int
        public let type: UInt32
        public let alias: String
    }

    public let entries: [Entry]
    public let byName: [String: Entry]
    private let data: Data

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 12, data[0] == 0x48, data[1] == 0x34, data[2] == 0x52 else {
            throw H4Error.badMagic(url.lastPathComponent)
        }
        var r = ByteReader(data)
        r.pos = 4
        let indexOffset = Int(r.u32())
        r.pos = indexOffset
        let count = Int(r.u32())
        var list: [Entry] = []
        list.reserveCapacity(count)
        for _ in 0..<count {
            let offset = Int(r.u32()), size = Int(r.u32()), unpacked = Int(r.u32())
            _ = r.u32()  // mtime
            let name = r.string16()
            _ = r.string16()  // developer path
            let alias = r.string16()
            let type = r.u32()
            list.append(Entry(name: name, offset: offset, size: size, unpackedSize: unpacked, type: type, alias: alias))
        }
        entries = list
        var map: [String: Entry] = [:]
        for e in list { map[e.name] = e }
        byName = map
    }

    public func names(prefix: String) -> [String] {
        entries.filter { $0.name.hasPrefix(prefix) && $0.alias.isEmpty }.map { $0.name }
    }

    /// Unpacked bytes of an entry (aliases are followed).
    public func payload(_ name: String) throws -> Data {
        guard var e = byName[name] else { throw H4Error.missing(name) }
        var hops = 0
        while !e.alias.isEmpty, hops < 8 {
            guard let t = byName[e.alias] else { throw H4Error.missing(e.alias) }
            e = t
            hops += 1
        }
        let raw = data.subdata(in: e.offset..<(e.offset + e.size))
        if e.type == 3 { return try gunzip(raw, expected: e.unpackedSize) }
        return raw
    }
}

public enum H4Error: Error {
    case badMagic(String)
    case missing(String)
    case corrupt(String)
}

/// Inflate a gzip stream (RFC 1952 header + raw deflate body).
public func gunzip(_ gz: Data, expected: Int) throws -> Data {
    guard gz.count > 18, gz[0] == 0x1f, gz[1] == 0x8b, gz[2] == 8 else { throw H4Error.corrupt("gzip header") }
    let flags = gz[3]
    var p = 10
    if flags & 4 != 0 { p += 2 + Int(gz[p]) | Int(gz[p + 1]) << 8 }
    if flags & 8 != 0 { while gz[p] != 0 { p += 1 }; p += 1 }
    if flags & 16 != 0 { while gz[p] != 0 { p += 1 }; p += 1 }
    if flags & 2 != 0 { p += 2 }
    let body = gz.subdata(in: p..<(gz.count - 8))
    var out = Data(count: max(expected, 1))
    let n = out.withUnsafeMutableBytes { dst -> Int in
        body.withUnsafeBytes { src -> Int in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                      nil, COMPRESSION_ZLIB)
        }
    }
    if n == 0 { throw H4Error.corrupt("deflate") }
    out.count = n
    return out
}

/// Little-endian cursor over a Data.
public struct ByteReader {
    public let data: Data
    public var pos: Int
    private let base: Int

    public init(_ d: Data, at: Int = 0) {
        data = d
        base = d.startIndex
        pos = at
    }

    public var remaining: Int { data.count - pos }
    public mutating func u8() -> UInt8 { let v = data[base + pos]; pos += 1; return v }
    public mutating func u16() -> UInt16 { let v = UInt16(data[base + pos]) | UInt16(data[base + pos + 1]) << 8; pos += 2; return v }
    public mutating func u32() -> UInt32 {
        let v = UInt32(data[base + pos]) | UInt32(data[base + pos + 1]) << 8 | UInt32(data[base + pos + 2]) << 16 | UInt32(data[base + pos + 3]) << 24
        pos += 4
        return v
    }
    public mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
    public mutating func bytes(_ n: Int) -> Data { let v = data.subdata(in: (base + pos)..<(base + pos + n)); pos += n; return v }
    public mutating func string16() -> String {
        let n = Int(u16())
        let s = String(bytes: data[(base + pos)..<(base + pos + n)], encoding: .isoLatin1) ?? ""
        pos += n
        return s
    }
    public func peekU32(at p: Int) -> UInt32 {
        UInt32(data[base + p]) | UInt32(data[base + p + 1]) << 8 | UInt32(data[base + p + 2]) << 16 | UInt32(data[base + p + 3]) << 24
    }
    public func peekU16(at p: Int) -> UInt16 { UInt16(data[base + p]) | UInt16(data[base + p + 1]) << 8 }
    public func byte(at p: Int) -> UInt8 { data[base + p] }
}
