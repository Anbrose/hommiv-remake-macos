import Foundation

/// A game font (font.*.h4d, format: tools/h4font.py): 8-bit alpha glyphs for codes 32..255.
public final class H4Font {
    public struct Glyph {
        public let width: Int, height: Int, advance: Int
        public let alpha: [UInt8]   // width * height
    }
    public let size: Int
    public let lineHeight: Int
    public let ascent: Int
    public let glyphs: [Glyph]
    public let firstCode = 32

    public init(data d: Data) throws {
        let r = ByteReader(d)
        size = Int(r.byte(at: 3)); lineHeight = Int(r.byte(at: 4)); ascent = Int(r.byte(at: 5))
        var found: [Glyph]? = nil
        for start in 11..<min(400, d.count) where found == nil {
            var q = start
            var list: [Glyph] = []
            while q + 16 <= d.count {
                let w = Int(r.peekU32(at: q)), h = Int(r.peekU32(at: q + 4)), adv = Int(r.peekU32(at: q + 12))
                guard h == size, w <= 64, q + 16 + w * h <= d.count else { break }
                list.append(Glyph(width: w, height: h, advance: adv, alpha: Array(d[(d.startIndex + q + 16)..<(d.startIndex + q + 16 + w * h)])))
                q += 16 + w * h
            }
            if q == d.count, list.count >= 200 { found = list }
        }
        guard let g = found else { throw H4Error.corrupt("font: no glyph chain") }
        glyphs = g
    }

    public func glyph(_ c: Character) -> Glyph {
        let code = Int(c.unicodeScalars.first?.value ?? 32) - firstCode
        return code >= 0 && code < glyphs.count ? glyphs[code] : glyphs[0]
    }

    public func measure(_ text: String) -> Int {
        text.reduce(0) { $0 + max(glyph($1).width, glyph($1).advance) + 1 }
    }

    /// The text as an RGBA bitmap in one colour.
    public func render(_ text: String, colour: (UInt8, UInt8, UInt8) = (0, 0, 0)) -> Bitmap {
        let w = max(measure(text), 1)
        var bm = Bitmap(width: w, height: size)
        var x = 0
        for c in text {
            let g = glyph(c)
            for y in 0..<g.height {
                for i in 0..<g.width where x + i < w {
                    let a = g.alpha[y * g.width + i]
                    if a != 0 {
                        let o = (y * w + x + i) * 4
                        bm.pixels[o] = colour.0; bm.pixels[o + 1] = colour.1; bm.pixels[o + 2] = colour.2; bm.pixels[o + 3] = a
                    }
                }
            }
            x += max(g.width, g.advance) + 1
        }
        return bm
    }
}
