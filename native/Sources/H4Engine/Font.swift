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

    /// The pen moves on by the glyph's width plus its extra spacing (the record's fourth word: 0 for
    /// most letters, 4 for the space).
    func step(_ g: Glyph) -> Int { g.width + g.advance }
    public func measure(_ text: String) -> Int {
        text.reduce(0) { $0 + step(glyph($1)) }
    }

    /// The text as an RGBA bitmap. Each glyph byte holds two 4-bit coverages: the letter in the
    /// high nibble, its halo in the low one (0x71b820); the halo is drawn under the letter in
    /// `halo`'s colour when one is given (the army screen's texts use (200,200,200)).
    public func render(_ text: String, colour: (UInt8, UInt8, UInt8) = (0, 0, 0), halo: (UInt8, UInt8, UInt8)? = nil) -> Bitmap {
        let w = max(measure(text), 1)
        var bm = Bitmap(width: w, height: size)
        var x = 0
        for c in text {
            let g = glyph(c)
            for y in 0..<g.height {
                for i in 0..<g.width where x + i < w {
                    let v = g.alpha[y * g.width + i]
                    let a1 = Float(v >> 4) / 15, a2 = halo != nil ? Float(v & 15) / 15 : 0
                    guard a1 > 0 || a2 > 0 else { continue }
                    let h = halo ?? colour
                    let a = a1 + a2 * (1 - a1)
                    func mix(_ c1: UInt8, _ c2: UInt8) -> UInt8 { UInt8(min(255, (Float(c1) * a1 + Float(c2) * a2 * (1 - a1)) / a + 0.5)) }
                    let o = (y * w + x + i) * 4
                    bm.pixels[o] = mix(colour.0, h.0); bm.pixels[o + 1] = mix(colour.1, h.1); bm.pixels[o + 2] = mix(colour.2, h.2)
                    bm.pixels[o + 3] = UInt8(min(255, a * 255 + 0.5))
                }
            }
            x += step(g)
        }
        return bm
    }
}
