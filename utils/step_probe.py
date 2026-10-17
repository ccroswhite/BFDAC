"""Probe an Allegro STEP export: product names (component footprints) and vertical cylinders (holes / standoffs) with
their global position and radius.  Plain text parse of ISO-10303-21, no CAD kernel needed."""
import sys, re, collections

txt = open(sys.argv[1], encoding="latin-1").read()
ents = {}
for m in re.finditer(r"#(\d+)=([A-Z0-9_]+)\((.*?)\);\n", txt, re.S):
    ents[int(m.group(1))] = (m.group(2), m.group(3))
print("entities:", len(ents))

prods = collections.Counter()
for k, (t, a) in ents.items():
    if t == "PRODUCT":
        prods[a.split(",")[0].strip("'")] += 1
print("products:", sorted(prods))

def refs(a):
    return [int(x) for x in re.findall(r"#(\d+)", a)]

def point(i):
    t, a = ents[i]
    assert t == "CARTESIAN_POINT", t
    return tuple(float(v) for v in re.search(r"\(([^()]*)\)\s*$", a).group(1).split(","))

def direction(i):
    t, a = ents[i]
    return tuple(float(v) for v in re.search(r"\(([^()]*)\)\s*$", a).group(1).split(","))

cyl = []
for k, (t, a) in ents.items():
    if t == "CYLINDRICAL_SURFACE":
        r = refs(a)
        radius = float(a.rsplit(",", 1)[1])
        pt, (ta, aa) = None, ents[r[0]]
        rr = refs(aa)
        pt = point(rr[0])
        ax = direction(rr[1]) if len(rr) > 1 else (0, 0, 1)
        cyl.append((pt, ax, radius))
print("cylinders:", len(cyl))
vert = [(p, r) for p, ax, r in cyl if abs(abs(ax[2]) - 1) < 1e-6]
print("vertical:", len(vert))
hist = collections.Counter(round(r, 3) for _, r in vert)
print("radius histogram (vertical):", sorted(hist.items(), key=lambda kv: -kv[1])[:20])
xs = [p[0] for p, _ in vert]; ys = [p[1] for p, _ in vert]; zs = [p[2] for p, _ in vert]
print("extent x %.2f..%.2f y %.2f..%.2f z %.2f..%.2f" % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
rmin = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
big = sorted({(round(p[0], 3), round(p[1], 3), round(r, 3)) for p, r in vert if r >= rmin})
print("distinct vertical cylinders with r >= %.2f:" % rmin)
for x, y, r in big[:80]:
    print("  (%.3f, %.3f) r %.3f" % (x, y, r))
