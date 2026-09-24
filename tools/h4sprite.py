#!/usr/bin/env python3
"""Decode Heroes of Might and Magic IV sprite .h4d files to PNG.

    h4sprite.py "actor_sequence.Gold Golem.combat.walk.sw.h4d" out/

Works for actor_sequence (creature and hero animations), animation (spell
effects, flags), adv_object (adventure map objects) and combat_object
(battlefield obstacles): they all carry the same image records, only the
header and trailer differ. Writes one RGBA PNG per image, a strip.png with
shadows composited under their frames, and meta.json with each image's
bounding box (actor_sequence boxes are on the 800x600 combat canvas) plus the
undecoded header and trailer bytes.

Image records (little-endian), worked out from the GOG build:

    palette u16 npal  u16 1  u16 speed  u8 0   (npal-1) x BGR   -- index 0 is transparent
    image   u16 len + name ("frame 001", "shadow 001", ...)
            u8 flag (4)   u32 left, top, right, bottom
            (bottom-top) rows of: u16 x0, u16 x1, u32 offset   -- the opaque span of the row
            pixels     one palette index per span pixel, rows concatenated
            alpha      one nibble per span pixel, low nibble first, 0..15
            summary    ceil((pixels+4)/64) nibbles (0 if no pixels), a coarse
                       per-64-pixel alpha the game uses to skip blocks; ignored here

Records repeat while the next bytes form a valid palette header.

    actor_sequence  header u16 2, u16 kind (2; 3 = mounted/ranged, +6 bytes), u16 count
                    trailer i32 ox, i32 oy (origin, usually -361,-347),
                            u16 n, n x (u16 len + name, u16 type)  -- e.g. owning combat_actor
    animation       header u16 10;  trailer u16 2, u16 x, u16 n, n x u32 frame order, ...
    combat_object   header 25 bytes incl. the object's name;  trailer i32 ox, i32 oy
    adv_object      header with category strings ("decorative", "rock", ...);
                    trailer i32 ox, i32 oy, 8 more bytes
"""
import json
import os
import struct
import sys
import zlib


def palette_ok(b, pos):
    if pos + 7 > len(b):
        return False
    npal, one = struct.unpack_from('<HH', b, pos)
    q = pos + 7 + (npal - 1) * 3
    if not (1 <= npal <= 256 and one == 1 and b[pos + 6] == 0) or q + 7 > len(b):
        return False
    ln = struct.unpack_from('<H', b, q)[0]
    name = b[q + 2:q + 2 + ln]
    return 1 <= ln <= 512 and len(name) == ln and all(32 <= c < 127 for c in name) and b[q + 2 + ln:q + 3 + ln] == b'\x04'


def parse(b):
    start = next((p for p in range(min(len(b), 4096)) if palette_ok(b, p)), None)
    if start is None:
        raise ValueError("no image records found")
    pos = start
    images = []
    while palette_ok(b, pos):
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
    return dict(images=images, header=b[:start], trailer=b[pos:])


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
    base = next((i for i in images if i['name'] == 'base_frame'), None)
    frames = [i for i in images if not i['name'].startswith('shadow') and i is not base]
    shadows = {i['name'].split()[-1]: i for i in images if i['name'].startswith('shadow')}
    cw, ch = R - L, B - T
    canvas = [bytearray(cw * len(frames) * 4) for _ in range(ch)]
    for n, fr in enumerate(frames):
        for img in (shadows.get(fr['name'].split()[-1]), base, fr):
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
    meta = dict(header=seq['header'].hex(' '), trailer=seq['trailer'].hex(' '), images=[])
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
