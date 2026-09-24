import Foundation

/// An RGBA8 bitmap (row-major, premultiplied = false).
public struct Bitmap {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]   // width * height * 4

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: max(width * height * 4, 4))
    }
}

/// One image of a sprite file: a name, its bounding box on the sprite's canvas, and the decoded bitmap.
public struct SpriteImage {
    public let name: String
    public let box: (left: Int, top: Int, right: Int, bottom: Int)
    public let bitmap: Bitmap
}

/// A decoded sprite .h4d (actor_sequence / adv_object / combat_object / animation). Format: tools/h4sprite.py.
public struct Sprite {
    public let images: [SpriteImage]
    public let origin: (x: Int32, y: Int32)   // from the trailer, if present
    public var frames: [SpriteImage] { images.filter { !$0.name.hasPrefix("shadow") && $0.name != "base_frame" } }
    public var baseFrame: SpriteImage? { images.first { $0.name == "base_frame" } }
    public func shadow(for frame: SpriteImage) -> SpriteImage? {
        let suffix = frame.name.split(separator: " ").last.map(String.init) ?? ""
        return images.first { $0.name.hasPrefix("shadow") && $0.name.hasSuffix(" " + suffix) }
    }

    public init(data d: Data) throws {
        let r = ByteReader(d)
        func paletteOK(_ p: Int) -> Bool {
            guard p + 7 <= d.count else { return false }
            let npal = Int(r.peekU16(at: p)), one = r.peekU16(at: p + 2)
            guard npal >= 1, npal <= 256, one == 1, r.byte(at: p + 6) == 0 else { return false }
            let q = p + 7 + (npal - 1) * 3
            guard q + 7 <= d.count else { return false }
            let ln = Int(r.peekU16(at: q))
            guard ln >= 1, ln <= 512, q + 2 + ln < d.count, r.byte(at: q + 2 + ln) == 4 else { return false }
            for i in 0..<ln { let c = r.byte(at: q + 2 + i); if c < 32 || c >= 127 { return false } }
            return true
        }
        guard let start = (0..<min(d.count, 4096)).first(where: paletteOK) else { throw H4Error.corrupt("sprite: no image records") }
        var rd = ByteReader(d, at: start)
        var list: [SpriteImage] = []
        while paletteOK(rd.pos) {
            let npal = Int(rd.u16()); _ = rd.u16(); _ = rd.u16(); _ = rd.u8()
            var pal = [UInt8](repeating: 0, count: 256 * 3)
            for i in 1..<npal {   // stored BGR, index 0 transparent
                let b = rd.u8(), g = rd.u8(), rr = rd.u8()
                pal[i * 3] = rr; pal[i * 3 + 1] = g; pal[i * 3 + 2] = b
            }
            let name = rd.string16()
            _ = rd.u8()
            let L = Int(rd.u32()), T = Int(rd.u32()), R = Int(rd.u32()), B = Int(rd.u32())
            let w = R - L, h = B - T
            var rows: [(Int, Int, Int)] = []
            rows.reserveCapacity(h)
            var px = 0
            for _ in 0..<h {
                let x0 = Int(rd.u16()), x1 = Int(rd.u16()), off = Int(rd.u32())
                rows.append((x0, x1, off))
                px += x1 - x0
            }
            let pixStart = rd.pos
            let alphaStart = pixStart + px
            rd.pos = alphaStart + (px + 1) / 2 + (px > 0 ? ((px + 4 + 63) / 64 + 1) / 2 : 0)
            var bm = Bitmap(width: max(w, 1), height: max(h, 1))
            var k = 0
            for (y, row) in rows.enumerated() {
                let (x0, x1, off) = row
                for i in 0..<(x1 - x0) {
                    let idx = Int(r.byte(at: pixStart + off + i))
                    let ab = r.byte(at: alphaStart + k / 2)
                    let a = (k % 2 == 0) ? (ab & 0xF) : (ab >> 4)
                    k += 1
                    if idx != 0 && a != 0 {
                        let p = (y * bm.width + x0 + i) * 4
                        bm.pixels[p] = pal[idx * 3]; bm.pixels[p + 1] = pal[idx * 3 + 1]; bm.pixels[p + 2] = pal[idx * 3 + 2]
                        bm.pixels[p + 3] = a * 17
                    }
                }
            }
            list.append(SpriteImage(name: name, box: (L, T, R, B), bitmap: bm))
        }
        var ox: Int32 = 0, oy: Int32 = 0
        if rd.remaining >= 8 { ox = rd.i32(); oy = rd.i32() }
        images = list
        origin = (ox, oy)
    }
}
