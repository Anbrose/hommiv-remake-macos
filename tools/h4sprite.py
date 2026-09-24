#!/usr/bin/env python3
"""Decode Heroes of Might and Magic IV actor_sequence sprites (.h4d) to PNG.

    h4sprite.py "actor_sequence.Gold Golem.combat.walk.sw.h4d" out/

Writes one RGBA PNG per frame and per shadow, a strip.png with the shadows
composited under the frames, and meta.json with each image's bounding box in
the game's 800x600 combat canvas.

Format (little-endian), worked out from the GOG build:

    header    u16 version = 2   u16 kind (2, or 3 = mounted/ranged variant)   u16 count
              kind 3 only: i32 -1, u16 x
    then repeated until an i32 < 0 is found:
      palette u16 npal  u16 1  u16 speed  u8 0   (npal-1) x BGR   -- index 0 is transparent
      image   u16 len + name ("frame 001", "shadow 001", ...)
              u8 flag (4)   u32 left, top, right, bottom
              (bottom-top) rows of: u16 x0, u16 x1, u32 offset   -- the opaque span of the row
              pixels     one palette index per span pixel, rows concatenated
              alpha      one nibble per span pixel, low nibble first, 0..15
              summary    ceil((pixels+4)/64) nibbles (0 if no pixels), a coarse
                         per-64-pixel alpha the game uses to skip blocks; ignored here
    trailer   i32 ox, i32 oy   (origin, almost always -361,-347)
              u16 n, then n x (u16 len + name, u16 type)   -- e.g. the owning combat_actor
"""
import json
import os
import struct
import sys
import zlib


def parse(b):
    ver, kind, count = struct.unpack_from('<3H', b, 0)
    pos = 6 + (6 if kind == 3 else 0)
    images = []
    while struct.unpack_from('<i', b, pos)[0] >= 0:
        npal, _, speed = struct.unpack_from('<HHH', b, pos)
        pos += 7
        pal = [None] + [b[pos + i * 3:pos + i * 3 + 3][::-1] for i in range(npal - 1)]
        pos += (npal - 1) * 3
        ln = struct.unpack_from('<H', b, pos)[0]
        name = b[pos + 2:pos + 2 + ln].decode('latin1')
        pos += 2 + ln
        L, T, R, B = struct.unpack_from('<4I', b, pos + 1)
        pos += 17
        rows = [struct.unpack_from('<HHI', b, pos + i * 8) for i in range(B - T)]
        pos += (B - T) * 8
        px = sum(x1 - x0 for x0, x1, _ in rows)
        pix = b[pos:pos + px]
        pos += px
        alpha = b[pos:pos + (px + 1) // 2]
        pos += (px + 1) // 2
        pos += ((px + 4 + 63) // 64 + 1) // 2 if px else 0
        images.append(dict(name=name, box=(L, T, R, B), rows=rows, pix=pix, alpha=alpha, pal=pal, speed=speed))
    ox, oy, n = struct.unpack_from('<iiH', b, pos)
    pos += 10
    refs = []
    for _ in range(n):
        ln = struct.unpack_from('<H', b, pos)[0]
        refs.append(b[pos + 2:pos + 2 + ln].decode('latin1'))
        pos += 4 + ln
    if pos != len(b):
        raise ValueError(f"parsed {pos} of {len(b)} bytes")
    return dict(kind=kind, images=images, origin=(ox, oy), refs=refs)


def rgba(img):
    L, T, R, B = img['box']
    w = R - L
    pal = img['pal']
    out = []
    k = 0
    for x0, x1, off in img['rows']:
        row = bytearray(w * 4)
        for i in range(x1 - x0):
            idx = img['pix'][off + i]
            a = (img['alpha'][k // 2] >> (4 * (k % 2))) & 0xF
            k += 1
            if idx and a:
                x = (x0 + i) * 4
                row[x:x + 4] = pal[idx] + bytes([a * 17])
        out.append(bytes(row))
    return w, B - T, out


def write_png(path, w, h, rows):
    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))
    raw = b''.join(b'\x00' + r for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def blit(dst, dw, rows, ox, oy):
    for y, row in enumerate(rows):
        d = dst[oy + y]
        for x in range(len(row) // 4):
            a = row[x * 4 + 3]
            if not a:
                continue
            p = (ox + x) * 4
            if d[p + 3] == 0 or a == 255:
                d[p:p + 4] = row[x * 4:x * 4 + 4]
            else:
                for c in range(3):
                    d[p + c] = (row[x * 4 + c] * a + d[p + c] * (255 - a)) // 255
                d[p + 3] = max(a, d[p + 3])


def strip(images, path):
    L = min(i['box'][0] for i in images); T = min(i['box'][1] for i in images)
    R = max(i['box'][2] for i in images); B = max(i['box'][3] for i in images)
    frames = [i for i in images if not i['name'].startswith('shadow')]
    shadows = {i['name'].split()[-1]: i for i in images if i['name'].startswith('shadow')}
    cw, ch = R - L, B - T
    canvas = [bytearray(cw * len(frames) * 4) for _ in range(ch)]
    for n, fr in enumerate(frames):
        for img in (shadows.get(fr['name'].split()[-1]), fr):
            if img:
                w, h, rows = rgba(img)
                blit(canvas, cw, rows, img['box'][0] - L + n * cw, img['box'][1] - T)
    write_png(path, cw * len(frames), ch, [bytes(r) for r in canvas])


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    seq = parse(open(src, 'rb').read())
    os.makedirs(out, exist_ok=True)
    meta = dict(kind=seq['kind'], origin=seq['origin'], refs=seq['refs'], images=[])
    for img in seq['images']:
        w, h, rows = rgba(img)
        fname = img['name'].replace(' ', '_') + '.png'
        write_png(os.path.join(out, fname), w, h, rows)
        meta['images'].append(dict(name=img['name'], file=fname, box=img['box'], speed=img['speed']))
    strip(seq['images'], os.path.join(out, 'strip.png'))
    json.dump(meta, open(os.path.join(out, 'meta.json'), 'w'), indent=1)
    print(f"{len(seq['images'])} images -> {out}")


if __name__ == '__main__':
    main()
