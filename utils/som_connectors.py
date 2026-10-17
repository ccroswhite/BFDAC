"""Extract the ACVU13 SoM board-to-board connector positions from Alinx's ACVU13_BOT.dxf (Allegro DXF export of the
module bottom, board coordinates as seen from the top).  Clusters the PIN_BOTTOM pads into the eight ADF6-60 connectors,
reports centre / orientation / pin-row geometry per connector, and the mounting holes."""
import sys, collections, math
import ezdxf

path = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\ccros\Downloads\ACVU13_BOT.dxf"
doc = ezdxf.readfile(path)
msp = doc.modelspace()

circ = [(e.dxf.center.x, e.dxf.center.y, e.dxf.radius) for e in msp.query("CIRCLE") if e.dxf.layer == "PIN_BOTTOM"]
print("PIN_BOTTOM circles:", len(circ))
rad = collections.Counter(round(r, 3) for _, _, r in circ)
print("radius histogram:", sorted(rad.items(), key=lambda kv: -kv[1])[:12])

# refdes texts on the bottom
ref = {}
for e in msp.query("TEXT"):
    if e.dxf.layer == "RD_SILKSCREEN_BOTTOM":
        ref[e.dxf.text] = (e.dxf.insert.x, e.dxf.insert.y, e.dxf.rotation, getattr(e.dxf, "text_generation_flag", 0))
for j in sorted(k for k in ref if k.startswith("J")):
    print("  %s text at (%.3f, %.3f) rot %.0f flags %s" % ((j,) + ref[j]))

# connector pads: the most common radius, in a 4-row x 60 pattern; cluster by proximity
if len(sys.argv) > 2:
    target = float(sys.argv[2])
else:
    target = sorted(rad.items(), key=lambda kv: -kv[1])[0][0]
pads = [(x, y) for x, y, r in circ if abs(r - target) < 0.01]
print("pads with r=%.3f: %d" % (target, len(pads)))

# simple single-linkage clustering with 1.0 mm threshold (pitch 0.635, row gap <= 1.58)
pads.sort()
clusters = []
for p in pads:
    for c in clusters:
        if any(abs(p[0] - q[0]) < 1.7 and abs(p[1] - q[1]) < 1.7 for q in c[-300:]):
            c.append(p)
            break
    else:
        clusters.append([p])
# merge clusters that touch
merged = True
while merged:
    merged = False
    for i in range(len(clusters)):
        for j in range(i + 1, len(clusters)):
            ci, cj = clusters[i], clusters[j]
            if any(abs(a[0] - b[0]) < 1.7 and abs(a[1] - b[1]) < 1.7 for a in ci[::7] for b in cj[::7]):
                clusters[i] = ci + cj
                del clusters[j]
                merged = True
                break
        if merged:
            break
clusters = [c for c in clusters if len(c) >= 200]
print("connector-sized clusters:", [len(c) for c in clusters])
for c in sorted(clusters, key=lambda c: (round(sum(p[1] for p in c) / len(c)), sum(p[0] for p in c) / len(c))):
    xs = [p[0] for p in c]; ys = [p[1] for p in c]
    cx, cy = sum(xs) / len(c), sum(ys) / len(c)
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    horiz = w > h
    rows = collections.Counter(round(p[1] if horiz else p[0], 2) for p in c)
    near = min(ref.items(), key=lambda kv: (kv[0][0] != "J", math.hypot(kv[1][0] - cx, kv[1][1] - cy)))
    print("  %s? n=%d centre (%.4f, %.4f) span %.3f x %.3f %s rows@%s" % (near[0], len(c), cx, cy, w, h, "horizontal" if horiz else "vertical",
                                                                           sorted(rows)))
    # pin span along the row direction and the corner pads (for A1 identification)
    along = xs if horiz else ys
    print("     row length %.3f (60 x 0.635 = %.3f), first/last along %.4f / %.4f" % (max(along) - min(along), 59 * 0.635, min(along), max(along)))

# mounting / alignment holes: larger circles
big = sorted(((x, y, r) for x, y, r in circ if r > 0.4), key=lambda t: (-t[2], t[0], t[1]))
print("larger circles (holes?):")
for x, y, r in big[:40]:
    print("  (%.4f, %.4f) r %.3f" % (x, y, r))
