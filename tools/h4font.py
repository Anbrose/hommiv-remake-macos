#!/usr/bin/env python3
"""Decode a Heroes of Might and Magic IV font (font.*.h4d) and render text.

    h4font.py "font.Prose_Antique.16.h4d" "Day 1 of Week 1" out.png

Format:
    header   u16 1, u8 ?, u8 size, u8 line height, u8 ascent(?), u16 ?, 3 x u8 0
    extra    a few dozen bytes (an extra glyph record; not needed)
    glyphs   224 records for character codes 32..255 (223 in the Small Fonts):
             u32 width, u32 height (= size), u32 ?, u32 advance-or-0,
             width x height bytes of 8-bit alpha, row-major
The glyph records start wherever a chain of such records runs exactly to the
end of the file, so `parse` finds the start by trying each offset.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h4sprite


def parse(b):
    size = b[3]
    for start in range(11, 400):
        q = start
        glyphs = []
        while q + 16 <= len(b):
            w, h, c, d = struct.unpack_from('<4I', b, q)
            if h != size or w > 64:
                break
            glyphs.append(dict(w=w, h=h, c=c, d=d, data=b[q + 16:q + 16 + w * h]))
            q += 16 + w * h
        if q == len(b) and len(glyphs) >= 200:
            return dict(size=size, line=b[4], ascent=b[5], glyphs=glyphs, first=32)
    raise ValueError("no glyph chain found")


def glyph(font, ch):
    i = ord(ch) - font['first']
    return font['glyphs'][i] if 0 <= i < len(font['glyphs']) else font['glyphs'][0]


def measure(font, text):
    return sum(max(glyph(font, c)['w'], glyph(font, c)['d']) + 1 for c in text)


def render(font, text, colour=(0, 0, 0)):
    w, h = measure(font, text), font['size']
    rows = [bytearray(w * 4) for _ in range(h)]
    x = 0
    for c in text:
        g = glyph(font, c)
        for y in range(g['h']):
            for i in range(g['w']):
                a = g['data'][y * g['w'] + i]
                if a:
                    rows[y][(x + i) * 4:(x + i) * 4 + 4] = bytes(colour) + bytes([a])
        x += max(g['w'], g['d']) + 1
    return w, h, [bytes(r) for r in rows]


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    font = parse(open(sys.argv[1], 'rb').read())
    w, h, rows = render(font, sys.argv[2])
    h4sprite.write_png(sys.argv[3], w, h, rows)
    print(f"size {font['size']} line {font['line']} ascent {font['ascent']} glyphs {len(font['glyphs'])} -> {sys.argv[3]} {w}x{h}")


if __name__ == '__main__':
    main()
