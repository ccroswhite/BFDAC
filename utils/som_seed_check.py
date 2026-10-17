"""Pad-for-pad check of hw/kicad/som_seed.kicad_pcb (our ADM6 footprint placed per SOM_CONNECTORS) against the Alinx
AXVU13G carrier .brd (KiCad Allegro importer), both expressed relative to the SoM centre.  Run with KiCad's python:
  "C:/Program Files/KiCad/10.0/bin/python.exe" utils/som_seed_check.py <AXVU13G.brd>"""
import sys, os
import pcbnew

here = os.path.dirname(os.path.abspath(__file__))
seed = os.path.join(os.path.dirname(here), "hw", "kicad", "som_seed.kicad_pcb")
ours = pcbnew.LoadBoard(seed)
alx = pcbnew.PCB_IO_MGR.Load(pcbnew.PCB_IO_MGR.ALLEGRO, sys.argv[1])

def conn_pads(board, refs, want=242):
    out = {}
    for f in board.GetFootprints():
        if f.GetReference() in refs and f.Pads().size() == want:
            d = {}
            for pd in f.Pads():
                q = pd.GetPosition()
                key = pd.GetNumber() or ("NPTH@%.3f,%.3f" % (round((q.x - f.GetPosition().x) / 1e6, 3), 0))
                d.setdefault(pd.GetNumber(), []).append((q.x / 1e6, q.y / 1e6))
            out[f.GetReference()] = d
    return out

refs = ["J%d" % i for i in range(1, 9)]
A = conn_pads(alx, refs)
O = conn_pads(ours, refs)
assert len(A) == 8 and len(O) == 8, (len(A), len(O))

def centre(P):
    xs = [p[0] for d in P.values() for k, v in d.items() if k for p in v]
    ys = [p[1] for d in P.values() for k, v in d.items() if k for p in v]
    return sum(xs) / len(xs), sum(ys) / len(ys)

ca, co = centre(A), centre(O)
print("Alinx SoM centre (KiCad coords) (%.4f, %.4f); seed centre (%.4f, %.4f)" % (ca + co))
worst = 0.0
for r in refs:
    for k, va in A[r].items():
        vo = O[r].get(k)
        if vo is None:
            print("  %s pad %r missing in ours" % (r, k)); continue
        ra = sorted((x - ca[0], y - ca[1]) for x, y in va)
        ro = sorted((x - co[0], y - co[1]) for x, y in vo)
        for (ax, ay), (ox, oy) in zip(ra, ro):
            e = max(abs(ax - ox), abs(ay - oy))
            worst = max(worst, e)
            if e > 0.02:
                print("  %s pad %-4r alinx (%.4f, %.4f) ours (%.4f, %.4f) err %.4f" % (r, k, ax, ay, ox, oy, e))
print("pads compared: %d per connector x 8; worst deviation %.4f mm" % (len(A["J1"]), worst))
print("RESULT:", "PASS" if worst <= 0.02 else "FAIL")
