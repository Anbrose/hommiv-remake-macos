#!/usr/bin/env python3
"""Decode a Heroes of Might and Magic IV rule table (table.*.h4d from text.h4r) to TSV.

    h4table.py "table.creatures.h4d" > creatures.tsv

Every cell is a string:

    u32 rows
    either u32 columns, then (columns - 1) group labels ("Dmg", "Skill", "Cost", ...)
    or     nothing (the heroes table)
    rows of: u16 n, n x (u16 len + text)      -- the first row usually names the columns

The tables: creatures (name, level, alignment, hit points, damage, attack,
defense, move, speed, shots, spell points, growth, cost, experience),
heroes (keyword, name, sex, class, biography), Artifacts, Spells, skills,
buildings, creature_banks, Adventure Object, random_names, Interface.
"""
import struct
import sys


def read_str(b, p):
    n = struct.unpack_from('<H', b, p)[0]
    return b[p + 2:p + 2 + n].decode('latin1'), p + 2 + n


def parse(b):
    nrows = struct.unpack_from('<I', b, 0)[0]
    p = 4
    groups = []
    a, c = struct.unpack_from('<HH', b, 4)
    if c == 0 and a < 256:        # u32 column count + group labels
        ncols = a
        p = 8
        for _ in range(max(0, ncols - 1)):
            s, p = read_str(b, p)
            groups.append(s)
    rows = []
    while p + 2 <= len(b):
        n = struct.unpack_from('<H', b, p)[0]
        p += 2
        row = []
        for _ in range(n):
            s, p = read_str(b, p)
            row.append(s)
        rows.append(row)
    header = None
    if rows and any(x in rows[0] for x in ('Keyword', 'Name', 'Teleporter_Entrance')) and 'Keyword' in rows[0]:
        header = rows.pop(0)
    return dict(nrows=nrows, groups=groups, header=header, rows=rows)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    t = parse(open(sys.argv[1], 'rb').read())
    if t['header']:
        print('\t'.join(t['header']))
    for r in t['rows']:
        print('\t'.join(x.replace('\t', ' ').replace('\n', ' ') for x in r))


if __name__ == '__main__':
    main()
