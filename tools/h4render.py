#!/usr/bin/env python3
"""Render a Heroes of Might and Magic IV map to a PNG from the extracted assets.

    h4render.py Data/heroes4.h4r out/ "maps/Three Queens.h4c" three_queens.png [level]

`out/` is the folder h4r.py extracted heroes4.h4r into (terrain/ and adv_object/).

Projection: a cell (x, y) of the map is drawn as a 64x32 diamond centred at
screen (y - x) * 32, (x + y) * 16 (plus an offset): x runs down-left, y runs
down-right. That orientation was derived from the transition masks -- the
side of a mask that is filled always faces the neighbouring cell of the
overlay's terrain type.

Each cell is painted in layers, all using the interior tiles of the terrain
patch chosen by screen position so the texture continues across cells:
  1. the cell's own terrain (type, variant)
  2. its overlays, in `order`: another terrain's texture clipped by mask number
     `mask` of the "land 1" set in transition.Transitions.h4d (93 masks of
     64x32 1-bit diamonds; the header code is four base-4 digits, the extent of
     the shape at the E, S, W and N corners)
  3. its roads, clipped the same way with the "road 1" masks
Objects are then drawn back to front at their anchor cell, offset by the origin
stored in their sprite file.

Not drawn yet: the soft 3-bit alpha of the water_to_land masks, the choice
between the 1/2/3 mask variants, animation frames, the underground darkness.
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


ROAD_FILE = {0: 'road.dirt.1', 1: 'road.gravel.1', 2: 'road.cobblestone.1'}
MASK_WIDTHS = [w for w in range(1, 32, 2) for _ in (0, 1)]
MASK_WIDTHS += MASK_WIDTHS[::-1]


def load_masks(assets):
    b = open(f'{assets}/transition/transition.Transitions.h4d', 'rb').read()
    sets = {}
    pos = 1
    for _ in range(b[0]):
        ln = struct.unpack_from('<H', b, pos)[0]
        name = b[pos + 2:pos + 2 + ln].decode('latin1')
        count = struct.unpack_from('<I', b, pos + 2 + ln)[0]
        pos += 6 + ln
        size = 549 if name.startswith(('water_to', 'land_to')) else 165
        masks = []
        for i in range(count):
            m = b[pos + i * size + 5:pos + i * size + 165]
            cols = []
            p = 0
            for w in MASK_WIDTHS:
                nb = (w + 7) // 8
                bits = int.from_bytes(m[p:p + nb], 'little')
                p += nb
                cols.append([(bits >> k) & 1 for k in range(w)])
            masks.append(cols)
        pos += count * size
        sets[name] = masks
    return sets


def load_tiles(assets, t, road=False):
    name = ROAD_FILE[t] if road else TERRAIN_FILE[t]
    tiles, pal = h4terrain.parse(open(f'{assets}/terrain/terrain.{name}.h4d', 'rb').read())
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


def masked_blit(canvas, W, H, tile, cols, left, top):
    for x, col in enumerate(cols):
        xx = left + x
        if not 0 <= xx < W:
            continue
        y0 = (32 - len(col)) // 2
        for i, on in enumerate(col):
            yy = top + y0 + i
            if on and 0 <= yy < H and tile[y0 + i][x * 4 + 3]:
                canvas[yy][xx * 4:xx * 4 + 4] = tile[y0 + i][x * 4:x * 4 + 4]


def render(archive, assets, mapfile, level=0):
    t0 = time.time()
    m = h4map.parse(open(mapfile, 'rb').read(), h4map.load_names(archive))
    N = m['size']
    grid = m['terrain'][level]
    W, H = 2 * N * 32 + 64, N * 32 + 96
    masks = load_masks(assets)

    def screen(x, y):
        return (y - x) * 32 + N * 32 + 32, (x + y) * 16 + 32

    def tile_index(x, y):
        row, col = x + y, (y - x - (x + y) % 2) // 2
        return (row % 6 + 2) * 10 + (col % 6 + 2)

    canvas = [bytearray(W * 4) for _ in range(H)]
    tilesets = {}
    roadsets = {}
    for x in range(N):
        for y in range(N):
            cell = grid[x][y]
            if not cell:
                continue
            t, v, overlays, roads = cell
            ti = tile_index(x, y)
            sx, sy = screen(x, y)
            left, top = sx - 32, sy - 16
            if t not in tilesets:
                tilesets[t] = load_tiles(assets, t)
            blit(canvas, W, H, tilesets[t][ti], 64, 32, left, top)
            for k, f, mask, order in sorted(overlays, key=lambda o: o[3]):
                if k in TERRAIN_FILE and mask < 93:
                    if k not in tilesets:
                        tilesets[k] = load_tiles(assets, k)
                    masked_blit(canvas, W, H, tilesets[k][ti], masks['land 1'][mask], left, top)
            for kind, mask, _ in roads:
                if kind in ROAD_FILE and mask < 93:
                    if kind not in roadsets:
                        roadsets[kind] = load_tiles(assets, kind, road=True)
                    masked_blit(canvas, W, H, roadsets[kind][ti], masks['road 1'][mask], left, top)
    objs = [o for o in m['objects'] if o['x'] is not None and o['level'] == level
            and -2 <= o['x'] < N + 2 and -2 <= o['y'] < N + 2]
    objs.sort(key=lambda o: (o['x'] + o['y'], o['y'] - o['x']))
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
