"""Probe an Alinx mechanical DXF: layers, entity counts, extents, text strings, block inserts."""
import sys, collections
import ezdxf

doc = ezdxf.readfile(sys.argv[1])
msp = doc.modelspace()
print("units:", doc.header.get("$INSUNITS"), " layers:", len(doc.layers))
by_layer = collections.Counter()
types = collections.Counter()
xs, ys = [], []
for e in msp:
    by_layer[e.dxf.layer] += 1
    types[e.dxftype()] += 1
    if e.dxftype() == "LINE":
        xs += [e.dxf.start.x, e.dxf.end.x]; ys += [e.dxf.start.y, e.dxf.end.y]
    elif e.dxftype() in ("CIRCLE", "ARC"):
        xs.append(e.dxf.center.x); ys.append(e.dxf.center.y)
print("types:", dict(types))
if xs:
    print("extent x %.3f..%.3f  y %.3f..%.3f" % (min(xs), max(xs), min(ys), max(ys)))
print("layers (entity count):")
for k, v in by_layer.most_common():
    print("  %-40s %d" % (k, v))
print("texts:")
for e in msp.query("TEXT MTEXT"):
    s = e.dxf.text if e.dxftype() == "TEXT" else e.text
    p = e.dxf.insert
    print("  [%s] %-30r at (%.3f, %.3f)" % (e.dxf.layer, s[:30], p.x, p.y))
print("inserts:")
for e in msp.query("INSERT"):
    p = e.dxf.insert
    print("  [%s] %s at (%.3f, %.3f) rot %.1f" % (e.dxf.layer, e.dxf.name, p.x, p.y, e.dxf.rotation))
print("blocks:", [b.name for b in doc.blocks if not b.name.startswith("*")][:40])
