#!/usr/bin/env python3
"""Render a Heroes of Might and Magic IV map to a PNG from the extracted assets.

    h4render.py Data/heroes4.h4r out/ "maps/Three Queens.h4c" three_queens.png [level]

`out/` is the folder h4r.py extracted heroes4.h4r into (terrain/ and adv_object/).

Projection: a cell (x, y) of the map is drawn as a 64x32 diamond centred at
screen (x + y) * 32, (x - y) * 16 (plus an offset), which is the orientation
in which the scenario "Black Jack" spells its name the right way round.
Terrain uses the interior tiles of the type's first patch, chosen by cell
position so the texture continues across cells. Objects are drawn back to
front at their anchor cell, offset by the origin stored in their sprite file.

Not drawn yet: the per-cell terrain transitions and roads/rivers that the map
stores as overlay lists, animated frames, the underground level's darkness.
"""
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h4map
import h4sprite
import h4terrain

TERRAIN_FILE = {0: 'water.1.1', 1: 'grass.1.1', 2: 'rough.1.1', 3: 'swamp.1.1', 4: 'lava.1.1', 5: 'snow.1.1',
                6: 'sand.1.1', 7: 'dirt.1.1', 8: 'subterranean.1.1', 9: 'river.water.1', 10: 'river.lava.1',
                11: 'river.ice.1', 12: 'magic.all', 13: 'magic.life', 14: 'magic.order', 15: 'magic.death.1',
                16: 'magic.chaos.1', 17: 'magic.nature.1', 18: 'magic.all'}


def load_tiles(assets, t):
    tiles, pal = h4terrain.parse(open(f'{assets}/terrain/terrain.{TERRAIN_FILE[t]}.h4d', 'rb').read())
    out = []
    for rows in tiles:
        buf = [bytearray(64 * 4) for _ in range(32)]
        for x, col in enumerate(rows):
            y0 = (32 - len(col)) // 2
            for i, v in enumerate(col):
                if v:
                    buf[y0 + i][x * 4:x * 4 + 4] = pal[v] + b'\xff'
        out.append(buf)
    return out


def load_sprite(assets, name):
    path = f'{assets}/adv_object/adv_object.{name}.h4d'
    if not os.path.exists(path):
        return None
    seq = h4sprite.parse(open(path, 'rb').read())
    imgs = seq['images']
    img = next((i for i in imgs if i['name'] == 'base_frame'), None) \
        or next((i for i in imgs if not i['name'].startswith('shadow')), None)
    if img is None:
        return None
    w, h, rows = h4sprite.rgba(img)
    tr = seq['trailer']
    ox, oy = struct.unpack_from('<ii', tr, 0) if len(tr) >= 8 else (-(w // 2), -h)
    return w, h, rows, img['box'], ox, oy


def blit(canvas, W, H, rows, w, h, left, top):
    for y in range(h):
        yy = top + y
        if not 0 <= yy < H:
            continue
        dst = canvas[yy]
        src = rows[y]
        for x in range(w):
            a = src[x * 4 + 3]
            if not a:
                continue
            xx = left + x
            if not 0 <= xx < W:
                continue
            p = xx * 4
            if a == 255:
                dst[p:p + 4] = src[x * 4:x * 4 + 4]
            else:
                for k in range(3):
                    dst[p + k] = (src[x * 4 + k] * a + dst[p + k] * (255 - a)) // 255
                dst[p + 3] = 255


def render(archive, assets, mapfile, level=0):
    t0 = time.time()
    m = h4map.parse(open(mapfile, 'rb').read(), h4map.load_names(archive))
    N = m['size']
    grid = m['terrain'][level]
    W, H = 2 * N * 32 + 64, N * 32 + 96

    def screen(x, y):
        return (x + y) * 32 + 32, (x - y) * 16 + N * 16 + 32

    canvas = [bytearray(W * 4) for _ in range(H)]
    tilesets = {}
    for x in range(N):
        for y in range(N):
            cell = grid[x][y]
            if not cell:
                continue
            t = cell[0]
            if t not in tilesets:
                tilesets[t] = load_tiles(assets, t)
            sx, sy = screen(x, y)
            j = (x - y) % 6 + 2
            i = ((x + y - j % 2) // 2) % 6 + 2
            blit(canvas, W, H, tilesets[t][j * 10 + i], 64, 32, sx - 32, sy - 16)
    objs = [o for o in m['objects'] if o['x'] is not None and o['level'] == level
            and -2 <= o['x'] < N + 2 and -2 <= o['y'] < N + 2]
    objs.sort(key=lambda o: (o['x'] + o['y'], o['x'] - o['y']))
    cache = {}
    for o in objs:
        if o['name'] not in cache:
            cache[o['name']] = load_sprite(assets, o['name'])
        sp = cache[o['name']]
        if sp is None:
            continue
        w, h, rows, box, ox, oy = sp
        sx, sy = screen(o['x'], o['y'])
        blit(canvas, W, H, rows, w, h, sx + ox + box[0], sy + oy + box[1])
    print(f"{m['name']!r}: {N}x{N} level {level}, {len(objs)} objects, {time.time() - t0:.0f}s")
    return W, H, [bytes(r) for r in canvas]


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    level = int(sys.argv[5]) if len(sys.argv) == 6 else 0
    W, H, rows = render(sys.argv[1], sys.argv[2], sys.argv[3], level)
    h4sprite.write_png(sys.argv[4], W, H, rows)
    print("wrote", sys.argv[4], W, H)


if __name__ == '__main__':
    main()
