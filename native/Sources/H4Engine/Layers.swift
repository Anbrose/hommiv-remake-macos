import Foundation

/// One element of a UI screen: an image placed at a screen rectangle, or a hotspot
/// (a clickable region / text field) with the same rectangle and a mask.
public struct UILayer {
    public let name: String
    public let kind: UInt8          // 0 opaque image, 4 image with alpha, 1 hotspot
    public let x: Int, y: Int, width: Int, height: Int
    public let bitmap: Bitmap       // RGBA (index 0 of the palette transparent)
    public var isImage: Bool { kind != 1 && !isMarker }
    /// Colours in the layer's palette: a 2-colour "image" is a placeholder box that marks a slot
    /// for text or a picture (Victor, creature_icon, ok_button, ...), not something to draw.
    public var paletteSize = 256
    public var isMarker: Bool { kind != 1 && paletteSize <= 3 }
    public init(name: String, kind: UInt8, x: Int, y: Int, width: Int, height: Int, bitmap: Bitmap) {
        self.name = name; self.kind = kind; self.x = x; self.y = y; self.width = width; self.height = height; self.bitmap = bitmap
    }
}

/// A layers.*.h4d screen description (format: tools/h4layers.py): `u16 count` then, per layer,
/// a sprite-style palette, the name, the kind, the rectangle and the sprite image encoding.
public struct LayerFile {
    public let layers: [UILayer]

    public subscript(name: String) -> UILayer? { layers.first { $0.name == name } }

    public init(data d: Data) throws {
        let r = ByteReader(d)
        let count = Int(r.peekU16(at: 0))
        var p = 2
        var out: [UILayer] = []
        while out.count < count, p + 7 < d.count {
            let npal = Int(r.peekU16(at: p)), one = r.peekU16(at: p + 2)
            guard npal >= 1, npal <= 256, one <= 1, r.byte(at: p + 6) == 0 else { throw H4Error.corrupt("layers: no palette at \(p)") }
            // the palette runs up to the name: npal-1 entries normally, 254 when npal is 256
            var nameAt = -1, entries = 0
            for n in [npal - 1, npal - 2] where n >= 0 {
                let t = p + 7 + n * 3
                guard t + 2 <= d.count else { continue }
                let ln = Int(r.peekU16(at: t))
                if ln >= 1, ln <= 64, t + 2 + ln <= d.count, (0..<ln).allSatisfy({ let c = r.byte(at: t + 2 + $0); return c >= 32 && c < 127 }) {
                    nameAt = t; entries = n; break
                }
            }
            guard nameAt >= 0 else { throw H4Error.corrupt("layers: no name after palette at \(p)") }
            var pal = [UInt8](repeating: 0, count: 256 * 3)
            for i in 0..<entries {
                pal[(i + 1) * 3] = r.byte(at: p + 9 + i * 3); pal[(i + 1) * 3 + 1] = r.byte(at: p + 8 + i * 3); pal[(i + 1) * 3 + 2] = r.byte(at: p + 7 + i * 3)
            }
            var rd = ByteReader(d, at: nameAt)
            let name = rd.string16()
            let kind = rd.u8()
            let x0 = Int(rd.u32()), y0 = Int(rd.u32()), x1 = Int(rd.u32()), y1 = Int(rd.u32())
            let w = x1 - x0, h = y1 - y0
            var rows: [(Int, Int, Int)] = []
            var px = 0
            for _ in 0..<h {
                let xa = Int(rd.u16()), xb = Int(rd.u16()), off = Int(rd.u32())
                rows.append((xa, xb, off)); px += max(0, xb - xa)
            }
            let pixStart = rd.pos, alphaStart = pixStart + px
            var bm = Bitmap(width: max(w, 1), height: max(h, 1))
            var k = 0
            for (y, row) in rows.enumerated() {
                let (xa, xb, off) = row
                for i in 0..<max(0, xb - xa) {
                    guard pixStart + off + i < d.count else { break }
                    let idx = Int(r.byte(at: pixStart + off + i))
                    var a: UInt8 = 15
                    if kind == 4, alphaStart + k / 2 < d.count {
                        let ab = r.byte(at: alphaStart + k / 2); a = k % 2 == 0 ? (ab & 0xF) : (ab >> 4)
                    }
                    k += 1
                    let x = xa + i
                    if idx != 0, a != 0, x < w {
                        let o = (y * bm.width + x) * 4
                        bm.pixels[o] = pal[idx * 3]; bm.pixels[o + 1] = pal[idx * 3 + 1]; bm.pixels[o + 2] = pal[idx * 3 + 2]; bm.pixels[o + 3] = a * 17
                    }
                }
            }
            p = alphaStart
            // (the summary nibbles follow only when the header's second word is 1: the nature
            // town's views have layers without them)
            if kind == 4 { p += (px + 1) / 2 + (px > 0 && one == 1 ? ((px + 4 + 63) / 64 + 1) / 2 : 0) }
            var layer = UILayer(name: name, kind: kind, x: x0, y: y0, width: w, height: h, bitmap: bm)
            layer.paletteSize = npal
            out.append(layer)
        }
        layers = out
    }
}
