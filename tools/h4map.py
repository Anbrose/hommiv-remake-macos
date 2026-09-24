#!/usr/bin/env python3
"""Decode Heroes of Might and Magic IV maps (.h4c) to JSON plus a minimap PNG.

    h4map.py "maps/Three Queens.h4c" out/three_queens

Writes out/three_queens.json (header, objects with positions, terrain grid)
and out/three_queens.png (one pixel per cell, base terrain colour).

Format, worked out from the GOG build (little-endian; incomplete):

    file      "H4CAMPAIGN"  u32 22  u8 0  then a gzip stream
    header    u16 version (27..29)   [version 28+: u16 x]
              u16 size (76, 152, 228, 304)   u8 levels (1 or 2)   u32 x
              u8 nplayers, nplayers x 5 bytes (byte 0 = colour)
              u16 len + name,  u8 (0..2, difficulty?),  u16 len + description
    objects   in file order, each starting  u16 len + adv_object name, u16 0,
              3 x (u16 id, u16 len + string)  -- type / subtype / terrain, as in the
              adv_object header --  u16 0, i32 x, i32 y, u8 level, then type-specific
              data (4 bytes for decorative objects, a lot more for towns, mines, heroes)
    terrain   after the objects (and, in some maps, player data): one record per
              playable cell, `levels` times.  The playable area is the diamond
              |r-(size-1)/2| + |c-(size-1)/2| <= size/2 inside the size x size grid,
              stored row-major (2964 cells for size 76).
              cell  u8 type  u8 variant  5 bytes  u16 f (8)  u8 n  n x 5 bytes  u8 m  m x 4 bytes
                    type: 0 water 1 grass 2 rough 3 swamp 4 volcanic 5 snow 6 sand 7 dirt
                          8 subterranean 9 water river 10 lava river 11 ice river 12 magic
                          plains 13 field of life 14 enchanted stone 15 cursed ground
                          16 scorched earth 17 magic garden 18 field of glory
                    the 5-byte entries look like terrain-transition overlays
                    (type, variant, ...); the 4-byte ones are still unknown
"""
import gzip
import json
import struct
import sys
import zlib

COLOURS = {0: (40, 80, 200), 1: (60, 160, 60), 2: (140, 120, 90), 3: (80, 110, 60), 4: (160, 60, 30),
           5: (230, 230, 240), 6: (220, 200, 120), 7: (140, 100, 60), 8: (90, 80, 80), 9: (60, 120, 220),
           10: (220, 90, 30), 11: (180, 220, 240), 12: (170, 120, 210), 13: (200, 220, 120),
           14: (120, 160, 170), 15: (120, 40, 90), 16: (70, 50, 40), 17: (120, 200, 90), 18: (200, 160, 220)}


def read_str(d, pos):
    ln = struct.unpack_from('<H', d, pos)[0]
    return d[pos + 2:pos + 2 + ln].decode('latin1'), pos + 2 + ln


def parse_header(d):
    version = struct.unpack_from('<H', d, 0)[0]
    pos = 4 if version >= 28 else 2
    size = struct.unpack_from('<H', d, pos)[0]
    levels = d[pos + 2]
    nplayers = d[pos + 7]
    pos += 8
    players = [d[pos + i * 5] for i in range(nplayers)]
    pos += nplayers * 5
    name, pos = read_str(d, pos)
    difficulty = d[pos]
    desc, pos = read_str(d, pos + 1)
    return dict(version=version, size=size, levels=levels, players=players, name=name,
                difficulty=difficulty, description=desc), pos


def diamond(size):
    mid = (size - 1) / 2
    return [(r, c) for r in range(size) for c in range(size) if abs(r - mid) + abs(c - mid) <= size / 2]


def parse_cells(d, pos, count):
    cells = []
    for _ in range(count):
        t, v = d[pos], d[pos + 1]
        n = d[pos + 9]
        if t > 18 or v > 3 or n > 8:
            return None, pos
        q = pos + 10 + 5 * n
        m = d[q]
        if m > 8:
            return None, pos
        cells.append((t, v))
        pos = q + 1 + 4 * m
    return cells, pos


def find_terrain(d, start, count):
    for pos in range(start, len(d) - 11 * count):
        cells, end = parse_cells(d, pos, count)
        if cells is not None and (end >= len(d) or d[end + 7:end + 9] != b'\x08\x00'):
            return cells, pos, end
    return None, None, None


def parse_objects(d, names, end):
    objs = []
    p = 0
    while p < end - 2:
        ln = struct.unpack_from('<H', d, p)[0]
        if 4 <= ln <= 60 and d[p + 2:p + 2 + ln] in names:
            name = d[p + 2:p + 2 + ln].decode('latin1')
            q = p + 2 + ln + 2
            cats = []
            for _ in range(3):
                cid, sl = struct.unpack_from('<HH', d, q)
                cats.append(d[q + 4:q + 4 + sl].decode('latin1'))
                q += 4 + sl
            x, y = struct.unpack_from('<ii', d, q + 2)
            objs.append(dict(name=name, type=cats[0], subtype=cats[1], terrain=cats[2], x=x, y=y, level=d[q + 10], offset=p))
            p = q + 11
        else:
            p += 1
    return objs


def parse(raw, names):
    if raw[:10] == b'H4CAMPAIGN':
        raw = raw[raw.find(b'\x1f\x8b\x08'):]
    d = gzip.decompress(raw)
    hdr, pos = parse_header(d)
    pts = diamond(hdr['size'])
    per_level = len(pts)
    levels_cells, tpos, end = find_terrain(d, pos, per_level * hdr['levels'])
    if levels_cells is None:
        raise ValueError("terrain grid not found")
    objs = parse_objects(d, names, tpos)
    grids = []
    for lv in range(hdr['levels']):
        g = [[None] * hdr['size'] for _ in range(hdr['size'])]
        for (r, c), (t, v) in zip(pts, levels_cells[lv * per_level:(lv + 1) * per_level]):
            g[r][c] = [t, v]
        grids.append(g)
    return dict(**hdr, objects=objs, terrain=grids)


def write_png(path, grid, scale=4):
    n = len(grid)
    rows = []
    for r in range(n):
        row = bytearray()
        for c in range(n):
            cell = grid[r][c]
            row += bytes(COLOURS.get(cell[0], (255, 0, 255)) if cell else (0, 0, 0)) * scale
        rows += [bytes(row)] * scale

    def chunk(t, body):
        return struct.pack('>I', len(body)) + t + body + struct.pack('>I', zlib.crc32(t + body))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', n * scale, n * scale, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(b''.join(b'\x00' + r for r in rows))) + chunk(b'IEND', b''))


def load_names(archive):
    sys.path.insert(0, __file__.rsplit('/', 1)[0])
    import h4r
    data, entries = h4r.parse(archive)
    return {e['name'][11:-4].encode('latin1') for e in entries if e['name'].startswith('adv_object.')}


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: h4map.py Data/heroes4.h4r map.h4c out/prefix\n" + __doc__)
    names = load_names(sys.argv[1])
    m = parse(open(sys.argv[2], 'rb').read(), names)
    json.dump(m, open(sys.argv[3] + '.json', 'w'), indent=1)
    write_png(sys.argv[3] + '.png', m['terrain'][0])
    print(f"{m['name']!r}: {m['size']}x{m['size']}, {m['levels']} level(s), {len(m['players'])} players, {len(m['objects'])} objects -> {sys.argv[3]}.json/.png")


if __name__ == '__main__':
    main()
