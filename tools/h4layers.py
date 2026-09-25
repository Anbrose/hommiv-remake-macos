#!/usr/bin/env python3
"""Decode a Heroes of Might and Magic IV UI layer file (layers.*.h4d) to PNGs.

    h4layers.py layers.adventure.1024.h4d out/          one PNG per image layer + composite.png

A layer file is a screen (or dialog) description: `u16 count`, then `count`
layers, each carrying its own palette in the sprite format:

    palette   u16 npal, u16 1, u16 flags, u8 0, then BGR entries up to the name
              (npal-1 entries for small palettes, 254 for npal = 256); index 0
              is transparent
    u16 len + name  ("Right", "Top_Border", "Gold_Number", ...)
    u8 kind         0 = opaque image, 4 = image with 4-bit alpha, 1 = hotspot/region
    u32 x0, y0, x1, y1   screen rectangle
    image     the sprite image encoding (see h4sprite.py) without its header:
              (y1-y0) rows of u16 x0, u16 x1, u32 offset; one palette index per
              span pixel; kind 4 adds the alpha nibbles and the summary nibbles

Hotspot layers (kind 1, a 2-4 colour palette) mark clickable regions and text
fields; their pixel data is a mask.  The adventure screen (adventure.0800 /
1024 / 1280) has the frame borders, the right panel, the resource icons and
the hotspots for buttons, minimap, hero/town lists and resource numbers.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h4sprite


def parse(b):
    count = struct.unpack_from('<H', b, 0)[0]
    p = 2
    layers = []
    while len(layers) < count and p + 7 < len(b):
        npal, one, flags = struct.unpack_from('<HHH', b, p)
        if not (1 <= npal <= 256 and one in (0, 1) and b[p + 6] == 0):
            raise ValueError(f"layer {len(layers)}: no palette at {p}")
        # the palette runs up to the name: npal-1 entries normally, 254 when npal is 256
        q = None
        for n in (npal - 1, npal - 2):
            t = p + 7 + n * 3
            ln = struct.unpack_from('<H', b, t)[0] if t + 2 <= len(b) else 0
            if 1 <= ln <= 64 and all(32 <= c < 127 for c in b[t + 2:t + 2 + ln]):
                q, nent = t, n
                break
        if q is None:
            raise ValueError(f"layer {len(layers)}: no name after the palette at {p}")
        pal = [None] + [b[p + 7 + i * 3:p + 10 + i * 3][::-1] for i in range(nent)]
        ln = struct.unpack_from('<H', b, q)[0]
        name = b[q + 2:q + 2 + ln].decode('latin1')
        q += 2 + ln
        kind = b[q]
        x0, y0, x1, y1 = struct.unpack_from('<4I', b, q + 1)
        q += 17
        h = y1 - y0
        rows = [struct.unpack_from('<HHI', b, q + k * 8) for k in range(h)]
        q += h * 8
        npx = sum(xb - xa for xa, xb, _ in rows)
        pix = b[q:q + npx]
        q += npx
        alpha = None
        if kind == 4:
            alpha = b[q:q + (npx + 1) // 2]
            q += (npx + 1) // 2
            q += ((npx + 4 + 63) // 64 + 1) // 2 if npx else 0   # summary nibbles, as in sprites
        layers.append(dict(name=name, kind=kind, box=(x0, y0, x1, y1), pal=pal, rows=rows, pix=pix, alpha=alpha))
        p = q
    return layers


def rgba(layer):
    x0, y0, x1, y1 = layer['box']
    w, h = x1 - x0, y1 - y0
    out = []
    k = 0
    for xs, xe, off in layer['rows']:
        row = bytearray(w * 4)
        for i in range(xe - xs):
            v = layer['pix'][off + i] if off + i < len(layer['pix']) else 0
            a = 255
            if layer['alpha'] is not None and k // 2 < len(layer['alpha']):
                a = ((layer['alpha'][k // 2] >> (4 * (k % 2))) & 0xF) * 17
            k += 1
            x = xs + i
            if v and a and x < w and v < len(layer['pal']) and layer['pal'][v] is not None:
                row[x * 4:x * 4 + 4] = layer['pal'][v] + bytes([a])
        out.append(bytes(row))
    return w, h, out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    b = open(sys.argv[1], 'rb').read()
    layers = parse(b)
    os.makedirs(sys.argv[2], exist_ok=True)
    W = max(l['box'][2] for l in layers)
    H = max(l['box'][3] for l in layers)
    canvas = [bytearray(W * 4) for _ in range(H)]
    for l in layers:
        w, h, rows = rgba(l)
        tag = {0: 'image', 4: 'image+alpha', 1: 'hotspot'}.get(l['kind'], str(l['kind']))
        print(f"{l['name']:24s} {tag:12s} at {l['box'][:2]} {w}x{h} palette {len(l['pal'])}")
        h4sprite.write_png(os.path.join(sys.argv[2], f"{l['name']}.png"), w, h, rows)
        if l['kind'] != 1:
            h4sprite.blit(canvas, W, rows, l['box'][0], l['box'][1])
    h4sprite.write_png(os.path.join(sys.argv[2], 'composite.png'), W, H, [bytes(r) for r in canvas])
    print("wrote", os.path.join(sys.argv[2], 'composite.png'), W, H)


if __name__ == '__main__':
    main()
