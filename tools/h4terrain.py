#!/usr/bin/env python3
"""Decode Heroes of Might and Magic IV terrain tile sets (terrain.*.h4d) to PNG.

    h4terrain.py terrain.dirt.1.1.h4d dirt.png

Each file holds 100 diamond tiles (64x32) that together form one big patch
of terrain with a ragged outline: 10 staggered rows of 10, each row 16 pixels
below the previous one and odd rows shifted right by 32. The PNG is that
reassembled patch. (A tile is stored as 64 scanlines of up to 31 pixels, i.e.
the diamond on its side; the output transposes it.)

Format (little-endian), worked out from the GOG build:

    tile      u32 len   len bytes of RLE   64 x u32 offset of each scanline in the RLE
              scanline: runs of  u8 skip (transparent pixels), u8 n, n palette indices;
                        a trailing skip may be the whole remainder
    ... 100 tiles, then
    palette   u16 256  u16 0  u16 0  u8 0   255 x BGR   (index 0 is transparent)
"""
import struct
import sys
import zlib


def parse(b):
    pal_off = len(b) - 772
    pal = [None] + [b[pal_off + 7 + i * 3:pal_off + 10 + i * 3][::-1] for i in range(255)]
    pos = 0
    tiles = []
    while pos < pal_off:
        n = struct.unpack_from('<I', b, pos)[0]
        rle = b[pos + 4:pos + 4 + n]
        offs = struct.unpack_from('<64I', b, pos + 4 + n) + (n,)
        pos += 4 + n + 256
        rows = []
        for r in range(64):
            seg = rle[offs[r]:offs[r + 1]]
            row = bytearray()
            i = 0
            while i < len(seg):
                row += b'\x00' * seg[i]
                i += 1
                if i < len(seg):
                    cnt = seg[i]
                    row += seg[i + 1:i + 1 + cnt]
                    i += 1 + cnt
            rows.append(bytes(row))
        tiles.append(rows)
    if pos != pal_off:
        raise ValueError(f"parsed {pos} of {pal_off} bytes")
    return tiles, pal


def write_png(path, w, h, rows):
    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))
    raw = b''.join(b'\x00' + r for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tiles, pal = parse(open(sys.argv[1], 'rb').read())
    cols = 10
    nrows = (len(tiles) + cols - 1) // cols
    w, h = cols * 64 + 32, nrows * 16 + 16
    sheet = [bytearray(w * 4) for _ in range(h)]
    for k, rows in enumerate(tiles):
        ox, oy = (k % cols) * 64 + (k // cols % 2) * 32, (k // cols) * 16
        for x, col in enumerate(rows):
            y0 = (32 - len(col)) // 2
            for i, v in enumerate(col):
                if v:
                    p = (ox + x) * 4
                    sheet[oy + y0 + i][p:p + 4] = pal[v] + b'\xff'
    write_png(sys.argv[2], w, h, [bytes(r) for r in sheet])
    print(f"{len(tiles)} tiles -> {sys.argv[2]}")


if __name__ == '__main__':
    main()
