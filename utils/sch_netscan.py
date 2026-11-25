"""Schematic network-overlap scan: union-find on wires+labels per sheet.

Flags (a) merged nets: one wire union carrying >=2 different labels
(KiCad would silently name it after one -> two rails shorted), and
(b) floating labels not touching any wire.  Buses are not handled
(the design has none).  Usage: python utils/sch_netscan.py

KiCad connectivity semantics (verified 2026-11-24 against kicad-cli
netlist export): wire<->wire joins happen ONLY at shared endpoints
(or junction dots at interior crossings); a wire ENDPOINT resting on
another wire's interior does NOT connect, but a LABEL anchored on a
wire's interior DOES bind that wire to the label's net - a stray label
one grid row off is the classic silent merge (ap.kicad_sch
USB_MUX_SEL/XMOS_USB_DP).  Always confirm suspects against
hw/kicad/bfdac_analog.xml - the kicad-cli netlist is ground truth.
"""
import glob, collections, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def tokenize(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in ' \t\n\r':
            i += 1
        elif c in '()':
            out.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while j < n and s[j] != '"':
                if s[j] == chr(92):
                    buf.append(s[j + 1])
                    j += 2
                else:
                    buf.append(s[j])
                    j += 1
            out.append('".' + ''.join(buf))
            i = j + 1
        else:
            j = i
            while j < n and s[j] not in ' \t\n\r()"':
                j += 1
            out.append(s[i:j])
            i = j
    return out


def parse(toks, i=0):
    node = []
    while i < len(toks):
        t = toks[i]
        if t == '(':
            sub, i = parse(toks, i + 1)
            node.append(sub)
        elif t == ')':
            return node, i + 1
        else:
            node.append(t)
            i += 1
    return node, i


def walk(n):
    yield n
    for e in n:
        if isinstance(e, list):
            yield from walk(e)


TOL = 0.001


def on_seg(p, a, b):
    ax, ay = a
    bx, by = b
    px, py = p
    dx, dy = bx - ax, by - ay
    if abs(dx) < TOL and abs(dy) < TOL:
        return False
    if abs(dx) >= abs(dy):
        if abs(dy) > TOL or abs(py - ay) > TOL:
            return False
        lo, hi = sorted([ax, bx])
        return lo - TOL <= px <= hi + TOL
    if abs(dx) > TOL or abs(px - ax) > TOL:
        return False
    lo, hi = sorted([ay, by])
    return lo - TOL <= py <= hi + TOL


def interior(p, a, b):
    ax, ay = a
    bx, by = b
    return (on_seg(p, a, b)
            and abs(p[0] - ax) + abs(p[1] - ay) > TOL * 2
            and abs(p[0] - bx) + abs(p[1] - by) > TOL * 2)


def main():
    merged, floating, stats = [], [], {}
    for f in sorted(glob.glob(os.path.join(ROOT, 'hw', 'kicad', '*.kicad_sch'))):
        toks = tokenize(open(f, encoding='utf-8').read())
        root, _ = parse(toks)
        segs, labels, juncs = [], [], []
        for e in walk(root):
            if not e:
                continue
            if e[0] == 'wire':
                pts = [x for x in e if isinstance(x, list) and x and x[0] == 'pts']
                if pts:
                    xy = [(float(x[1]), float(x[2])) for x in pts[0][1:]
                          if isinstance(x, list) and x and x[0] == 'xy']
                    for a, b in zip(xy, xy[1:]):
                        segs.append((a, b))
            elif e[0] in ('label', 'global_label', 'hierarchical_label'):
                at = [x for x in e if isinstance(x, list) and x and x[0] == 'at']
                nm = e[1] if len(e) > 1 and isinstance(e[1], str) else '?'
                labels.append((nm[2:] if nm.startswith('".') else nm,
                               (float(at[0][1]), float(at[0][2])) if at else None,
                               e[0]))
            elif e[0] == 'junction':
                at = [x for x in e if isinstance(x, list) and x and x[0] == 'at']
                if at:
                    juncs.append((float(at[0][1]), float(at[0][2])))
        parent = list(range(len(segs)))

        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        def union(a, b):
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[ra] = rb

        ep = collections.defaultdict(list)
        for i, (a, b) in enumerate(segs):
            ep[(round(a[0], 2), round(a[1], 2))].append(i)
            ep[(round(b[0], 2), round(b[1], 2))].append(i)
        for l in ep.values():
            for x in range(len(l)):
                for y in range(x + 1, len(l)):
                    union(l[x], l[y])
        # junction dots at interior points connect every segment they sit on
        for jx, jy in juncs:
            hits = [i for i, (a, b) in enumerate(segs) if on_seg((jx, jy), a, b)]
            for x in hits:
                union(hits[0], x)

        lbl = collections.defaultdict(set)
        for nm, p, kind in labels:
            if p is None:
                continue
            hits = {find(i) for i, (a, b) in enumerate(segs) if on_seg(p, a, b)}
            if not hits:
                floating.append((os.path.basename(f), kind, nm, p))
            for h in hits:
                lbl[h].add(nm)
        for h, names in lbl.items():
            if len(names) > 1:
                merged.append((os.path.basename(f), sorted(names)))
        stats[os.path.basename(f)] = (len(segs), len(labels))

    print(f'{"sheet":30s} segs  labels')
    for k, (s, l) in stats.items():
        print(f'{k:30s} {s:5d} {l:6d}')
    print()
    print('MERGED (>=2 labels on one wire union):', len(merged))
    for m in merged[:40]:
        print('  ', m)
    print()
    print('FLOATING labels (not on any wire):', len(floating))
    for x in floating[:60]:
        print('  ', x)


if __name__ == '__main__':
    main()
