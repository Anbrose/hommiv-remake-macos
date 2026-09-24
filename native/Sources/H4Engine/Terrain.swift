import Foundation

/// A terrain patch (terrain.*.h4d): 100 diamond tiles of 64x32. Format: tools/h4terrain.py.
/// Each tile is stored as 64 vertical scanlines; `tiles[k]` is a 64x32 RGBA bitmap.
public struct TerrainPatch {
    public let tiles: [Bitmap]

    public init(data d: Data) throws {
        let palOff = d.count - 772
        guard palOff > 0 else { throw H4Error.corrupt("terrain: too small") }
        var pal = [UInt8](repeating: 0, count: 256 * 3)
        let r = ByteReader(d)
        for i in 0..<255 {
            let b = r.byte(at: palOff + 7 + i * 3), g = r.byte(at: palOff + 8 + i * 3), rr = r.byte(at: palOff + 9 + i * 3)
            pal[(i + 1) * 3] = rr; pal[(i + 1) * 3 + 1] = g; pal[(i + 1) * 3 + 2] = b
        }
        var pos = 0
        var out: [Bitmap] = []
        while pos < palOff {
            let n = Int(r.peekU32(at: pos))
            let rle = pos + 4
            var offs = [Int](repeating: 0, count: 65)
            for i in 0..<64 { offs[i] = Int(r.peekU32(at: rle + n + i * 4)) }
            offs[64] = n
            var bm = Bitmap(width: 64, height: 32)
            for x in 0..<64 {
                var i = offs[x]
                let end = offs[x + 1]
                var col: [UInt8] = []
                while i < end {
                    let skip = Int(r.byte(at: rle + i)); i += 1
                    col.append(contentsOf: repeatElement(0, count: skip))
                    if i < end {
                        let cnt = Int(r.byte(at: rle + i)); i += 1
                        for j in 0..<cnt { col.append(r.byte(at: rle + i + j)) }
                        i += cnt
                    }
                }
                let y0 = (32 - col.count) / 2
                for (j, v) in col.enumerated() where v != 0 {
                    let p = ((y0 + j) * 64 + x) * 4
                    bm.pixels[p] = pal[Int(v) * 3]; bm.pixels[p + 1] = pal[Int(v) * 3 + 1]; bm.pixels[p + 2] = pal[Int(v) * 3 + 2]; bm.pixels[p + 3] = 255
                }
            }
            out.append(bm)
            pos = rle + n + 256
        }
        tiles = out
    }
}

/// transition.Transitions.h4d: named sets of 93 one-bit 64x32 diamond masks. Format: tools/h4render.py.
/// `sets[name][k]` is a 64x32 array of 0/1 bytes (row-major).
public struct TransitionMasks {
    public let sets: [String: [[UInt8]]]

    public init(data d: Data) throws {
        let widths: [Int] = {
            var w: [Int] = []
            for v in stride(from: 1, through: 31, by: 2) { w.append(v); w.append(v) }
            return w + w.reversed()
        }()
        var r = ByteReader(d)
        let nsec = Int(r.u8())
        var sets: [String: [[UInt8]]] = [:]
        for _ in 0..<nsec {
            let name = r.string16()
            let count = Int(r.u32())
            let size = (name.hasPrefix("water_to") || name.hasPrefix("land_to")) ? 549 : 165
            var masks: [[UInt8]] = []
            masks.reserveCapacity(count)
            for i in 0..<count {
                var p = r.pos + i * size + 5
                var m = [UInt8](repeating: 0, count: 64 * 32)
                for (x, w) in widths.enumerated() {
                    let nb = (w + 7) / 8
                    var bits: UInt64 = 0
                    for k in 0..<nb { bits |= UInt64(r.byte(at: p + k)) << (8 * UInt64(k)) }
                    p += nb
                    let y0 = (32 - w) / 2
                    for j in 0..<w where (bits >> UInt64(j)) & 1 == 1 { m[(y0 + j) * 64 + x] = 1 }
                }
                masks.append(m)
            }
            r.pos += count * size
            sets[name] = masks
        }
        self.sets = sets
    }
}
