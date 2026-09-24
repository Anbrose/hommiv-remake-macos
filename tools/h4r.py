#!/usr/bin/env python3
"""Extract Heroes of Might and Magic IV .h4r resource archives.

    h4r.py list    Data/heroes4.h4r [prefix]
    h4r.py extract Data/heroes4.h4r out/ [prefix]

Format (little-endian), worked out from the GOG build:

    header   "H4R" ver(u8)  u32 index_offset
    index    u32 entry_count, then the entries (right after the header in
             heroes4/x2/movies, at the end of the file in storm/text/updates)
    entry    u32 offset  u32 size  u32 size_unpacked  u32 mtime (unix)
             u16 len + name        e.g. "actor_sequence.gold golem.combat.walk.sw.h4d"
             u16 len + dev_path    original artist's path, e.g. "D:\\Heroes 4\\Assets\\layers\\button\\"
             u16 len + alias       non-empty (with offset 0) means this entry is an alias of that name
             u32 type              1 = stored as-is, 3 = gzip
    data     each entry's bytes at its offset; in practice concatenated in index order

Entries are written as out/<category>/<name>, category being the first
dotted component of the name. Aliases are skipped. bitmap_raw entries
(u32 ver, height, width, byte_count + BGR24 pixels) are also written as PNG.
"""
import gzip
import os
import struct
import sys
import zlib


def parse(path):
    data = open(path, 'rb').read()
    if data[:3] != b'H4R':
        sys.exit(f"{path}: not an H4R archive")
    off = struct.unpack_from('<I', data, 4)[0]
    count = struct.unpack_from('<I', data, off)[0]
    off += 4
    entries = []
    for _ in range(count):
        offset, size, size_unpacked, mtime = struct.unpack_from('<IIII', data, off)
        off += 16
        strings = []
        for _ in range(3):
            n = struct.unpack_from('<H', data, off)[0]
            off += 2
            strings.append(data[off:off + n].decode('latin1'))
            off += n
        etype = struct.unpack_from('<I', data, off)[0]
        off += 4
        name, dev_path, alias = strings
        entries.append(dict(name=name, dev_path=dev_path, alias=alias, offset=offset,
                            size=size, size_unpacked=size_unpacked, mtime=mtime, type=etype))
    return data, entries


def payload(data, e):
    blob = data[e['offset']:e['offset'] + e['size']]
    return gzip.decompress(blob) if e['type'] == 3 else blob


def write_png(path, raw):
    _, h, w, n = struct.unpack_from('<IIII', raw, 0)
    px = raw[16:16 + n]
    rows = bytearray()
    for y in range(h):
        row = px[y * w * 3:(y + 1) * w * 3]
        rows += b'\x00' + bytes(c for i in range(0, len(row), 3) for c in (row[i + 2], row[i + 1], row[i]))

    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body))

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(rows))))
        f.write(chunk(b'IEND', b''))


def write_audio(stem, raw):
    # u16 fmt (0 = PCM, 1 = MP3), u8 0, u8 bits, u8 channels, u32 rate,
    # u32 decoded length, u16 1, then (MP3 only) u32 encoded length
    fmt, _, bits, ch, rate, n = struct.unpack_from('<HBBBII', raw, 0)
    if fmt == 1:
        open(stem + '.mp3', 'wb').write(raw[19:])
        return
    pcm = raw[15:15 + n]
    hdr = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ' \
        + struct.pack('<IHHIIHH', 16, 1, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits) \
        + b'data' + struct.pack('<I', len(pcm))
    open(stem + '.wav', 'wb').write(hdr + pcm)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('list', 'extract'):
        sys.exit(__doc__)
    cmd, archive = sys.argv[1], sys.argv[2]
    data, entries = parse(archive)

    if cmd == 'list':
        prefix = sys.argv[3] if len(sys.argv) > 3 else ''
        for e in entries:
            if e['name'].startswith(prefix):
                tag = f"-> {e['alias']}" if e['alias'] else f"{e['size_unpacked']:>10}"
                print(f"{tag}  {e['name']}")
        return

    if len(sys.argv) < 4:
        sys.exit(__doc__)
    out, prefix = sys.argv[3], (sys.argv[4] if len(sys.argv) > 4 else '')
    n = 0
    for e in entries:
        if e['alias'] or not e['name'].startswith(prefix):
            continue
        category = e['name'].split('.', 1)[0]
        d = os.path.join(out, category)
        os.makedirs(d, exist_ok=True)
        raw = payload(data, e)
        dest = os.path.join(d, e['name'])
        open(dest, 'wb').write(raw)
        if category == 'bitmap_raw':
            write_png(dest[:-4] + '.png', raw)
        elif category == 'sound':
            write_audio(dest[:-4], raw)
        n += 1
    print(f"extracted {n} entries to {out}")


if __name__ == '__main__':
    main()
