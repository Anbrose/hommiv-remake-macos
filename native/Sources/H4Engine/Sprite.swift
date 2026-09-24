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
    public let speed: Int   // the record's speed field (frame duration, in 1/60 s as far as we know)
}

/// A decoded sprite .h4d (actor_sequence / adv_object / combat_object / animation). Format: tools/h4sprite.py.
public struct Sprite {
    public let images: [SpriteImage]
    public let origin: (x: Int32, y: Int32)   // from the trailer, if present
    /// Footprint in map cells (adv_object headers: u16 w, u16 h at offset 5); (1, 1) when unknown.
    public let footprint: (w: Int, h: Int)
    /// Cells of the footprint the object occupies (first of the bit masks after the
    /// footprint size, bit i = cell (i % w, i / w) relative to the anchor); empty when unknown.
    public let blocked: [(x: Int, y: Int)]
    /// Cells a hero may step onto to use the object (second mask; set for pickups such as
    /// resource piles and chests, empty for trees, mines and towns).
    public let visitable: [(x: Int, y: Int)]
    public var frames: [SpriteImage] { images.filter { !$0.name.hasPrefix("shadow") && $0.name != "base_frame" } }
    /// Unfinished assets in the game data are a 613x513 "DELETE ME NOW!!!" box (some artifacts,
    /// exhausted mines, stagecoaches, ...); nothing that size is a real adventure object.
    public var isPlaceholder: Bool { images.first.map { $0.bitmap.width == 613 && $0.bitmap.height == 513 } ?? false }
    public var baseFrame: SpriteImage? { images.first { $0.name == "base_frame" } }
    public func shadow(for frame: SpriteImage) -> SpriteImage? {
        guard let n = Sprite.frameNumbers(frame.name).first else { return nil }
        return images.first { $0.name.hasPrefix("shadow") && Sprite.frameNumbers($0.name).contains(n) }
    }

    /// "frame 001 002 003" -> [1, 2, 3]: one image can stand in for a run of frame numbers.
    static func frameNumbers(_ name: String) -> [Int] {
        name.split(separator: " ").dropFirst().compactMap { Int($0) }
    }

    /// The animation as one entry per frame number: (image, shadow). Empty for static sprites.
    public var timeline: [(frame: SpriteImage, shadow: SpriteImage?)] {
        var byNumber: [Int: SpriteImage] = [:]
        var shadows: [Int: SpriteImage] = [:]
        for img in images {
            for n in Sprite.frameNumbers(img.name) {
                if img.name.hasPrefix("shadow") { shadows[n] = img } else { byNumber[n] = img }
            }
        }
        guard byNumber.count > 1, let last = byNumber.keys.max() else { return [] }
        var out: [(SpriteImage, SpriteImage?)] = []
        var current: SpriteImage? = nil
        for n in 1...last {
            if let f = byNumber[n] { current = f }
            guard let f = current else { continue }
            out.append((f, shadows[n]))
        }
        return out
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
            // the byte after the name is the image kind: 4 = full image, 1 = delta frame over base_frame
            // (sparse rows), 0 = empty (zero box, no rows); the layout is the same for all of them
            guard ln >= 1, ln <= 512, q + 2 + ln < d.count, [0, 1, 4].contains(r.byte(at: q + 2 + ln)) else { return false }
            for i in 0..<ln { let c = r.byte(at: q + 2 + i); if c < 32 || c >= 127 { return false } }
            return true
        }
        guard let start = (0..<min(d.count, 4096)).first(where: paletteOK) else { throw H4Error.corrupt("sprite: no image records") }
        var rd = ByteReader(d, at: start)
        var list: [SpriteImage] = []
        var fp = (w: 1, h: 1)
        var occupied: [(x: Int, y: Int)] = [], visit: [(x: Int, y: Int)] = []
        if start >= 9, r.byte(at: 0) == 6 {
            let w = Int(r.peekU16(at: 5)), h = Int(r.peekU16(at: 7))
            if w >= 1, w <= 16, h >= 1, h <= 16 {
                fp = (w, h)
                let nb = (w * h + 7) / 8
                if 9 + 2 * nb <= start {
                    // bit i is cell (i % w, i / w): the windmill's two cells run down-right from
                    // its anchor, a right-facing town's gate cells sit on its lower-right wall
                    for i in 0..<(w * h) {
                        if (r.byte(at: 9 + i / 8) >> UInt8(i % 8)) & 1 == 1 { occupied.append((i % w, i / w)) }
                        if (r.byte(at: 9 + nb + i / 8) >> UInt8(i % 8)) & 1 == 1 { visit.append((i % w, i / w)) }
                    }
                }
            }
        }
        while paletteOK(rd.pos) {
            let npal = Int(rd.u16()); _ = rd.u16(); let speed = Int(rd.u16()); _ = rd.u8()
            var pal = [UInt8](repeating: 0, count: 256 * 3)
            for i in 1..<npal {   // stored BGR, index 0 transparent
                let b = rd.u8(), g = rd.u8(), rr = rd.u8()
                pal[i * 3] = rr; pal[i * 3 + 1] = g; pal[i * 3 + 2] = b
            }
            let name = rd.string16()
            let kind = rd.u8()   // 4 = full image with 4-bit alpha, 1 = delta frame (indices only), 0 = empty
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
            let hasAlpha = kind == 4
            rd.pos = hasAlpha ? alphaStart + (px + 1) / 2 + (px > 0 ? ((px + 4 + 63) / 64 + 1) / 2 : 0) : alphaStart
            var bm = Bitmap(width: max(w, 1), height: max(h, 1))
            var k = 0
            for (y, row) in rows.enumerated() {
                let (x0, x1, off) = row
                for i in 0..<(x1 - x0) {
                    let idx = Int(r.byte(at: pixStart + off + i))
                    var a: UInt8 = 15
                    if hasAlpha {
                        let ab = r.byte(at: alphaStart + k / 2)
                        a = (k % 2 == 0) ? (ab & 0xF) : (ab >> 4)
                    }
                    k += 1
                    if idx != 0 && a != 0 {
                        let p = (y * bm.width + x0 + i) * 4
                        bm.pixels[p] = pal[idx * 3]; bm.pixels[p + 1] = pal[idx * 3 + 1]; bm.pixels[p + 2] = pal[idx * 3 + 2]
                        bm.pixels[p + 3] = a * 17
                    }
                }
            }
            list.append(SpriteImage(name: name, box: (L, T, R, B), bitmap: bm, speed: speed))
        }
        var ox: Int32 = 0, oy: Int32 = 0
        if rd.remaining >= 8 { ox = rd.i32(); oy = rd.i32() }
        images = list
        origin = (ox, oy)
        footprint = fp
        blocked = occupied
        visitable = visit
    }
}
