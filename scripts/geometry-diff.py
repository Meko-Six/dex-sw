"""Compare two element-geometry dumps from scripts/pixel-diff.mjs.

    python3 scripts/geometry-diff.py out/home

Elements are paired by their path (tag and sorted classes down from the
stage) and order; prints every box or text that differs by more than
0.01 px, and the elements only one side has.
"""
import json
import sys
from collections import defaultdict

d = sys.argv[1]
a = json.load(open(f'{d}/a.json'))
b = json.load(open(f'{d}/b.json'))


def index(rows):
    seen = defaultdict(int)
    out = {}
    for path, *box in rows:
        seen[path] += 1
        out[(path, seen[path])] = box
    return out


ia, ib = index(a), index(b)
shown = 0
for key in list(ia) + [k for k in ib if k not in ia]:
    if key not in ia or key not in ib:
        print(('only mockup ' if key in ia else 'only app    ') + key[0][-110:], (ia.get(key) or ib.get(key)))
        shown += 1
        continue
    ra, rb = ia[key], ib[key]
    # display: contents and hidden elements have no box; where one says it is is meaningless.
    if ra[2] == ra[3] == rb[2] == rb[3] == 0 and ra[4] == rb[4]:
        continue
    if any(abs(x - y) > 0.01 for x, y in zip(ra[:4], rb[:4])) or ra[4] != rb[4]:
        print(key[0][-90:], 'mockup', ra, 'app', rb)
        shown += 1
print(f'{shown} differences, {len(a)} vs {len(b)} elements')
