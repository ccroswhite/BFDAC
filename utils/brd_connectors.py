"""Read the Alinx AXVU13G carrier .brd (Allegro) through KiCad's Allegro importer and dump the ADM6 connector
placements + per-pin coordinates (pin A1 etc.) and the mounting holes.  Run with KiCad's python:
  "C:/Program Files/KiCad/10.0/bin/python.exe" utils/brd_connectors.py <file.brd> [out.kicad_pcb]"""
import sys
import pcbnew

src = sys.argv[1]
board = pcbnew.PCB_IO_MGR.Load(pcbnew.PCB_IO_MGR.ALLEGRO, src)
if board is None:
    sys.exit("import failed")
if len(sys.argv) > 2:
    pcbnew.SaveBoard(sys.argv[2], board)
    print("saved", sys.argv[2])
fps = list(board.GetFootprints())
print("footprints:", len(fps), " tracks:", len(board.GetTracks()), " layers:", board.GetCopperLayerCount())
bb = board.GetBoardEdgesBoundingBox()
print("edge bbox: (%.3f, %.3f) - (%.3f, %.3f)" % (bb.GetLeft() / 1e6, bb.GetTop() / 1e6, bb.GetRight() / 1e6, bb.GetBottom() / 1e6))
conns = [f for f in fps if f.GetReference() in ("J%d" % i for i in range(1, 9)) and f.Pads().size() == 242]
print("connector footprints:", [f.GetReference() for f in conns])
centres = {}
for f in sorted(conns, key=lambda f: f.GetReference()):
    pads = {}
    for pd in f.Pads():
        q = pd.GetPosition()
        pads[pd.GetNumber()] = (q.x / 1e6, -q.y / 1e6, pd.GetNetname(), pd.GetAttribute())
    sig = [v for k, v in pads.items() if k and k[0] in "ABCD"]
    cx = sum(v[0] for v in sig) / len(sig); cy = sum(v[1] for v in sig) / len(sig)
    centres[f.GetReference()] = (cx, cy)
    p = f.GetPosition()
    print("%s origin (%.4f, %.4f) pad-centroid (%.4f, %.4f) rot %.1f %s" % (f.GetReference(), p.x / 1e6, -p.y / 1e6, cx, cy,
                                                                          f.GetOrientationDegrees(), "BACK" if f.IsFlipped() else "front"))
    for n in ("A1", "A60", "D1", "D60", "B1", "C1"):
        if n in pads:
            print("    pin %-3s (%.4f, %.4f)  net %s" % (n, pads[n][0], pads[n][1], pads[n][2]))
    npth = [v for k, v in pads.items() if k not in sig and (not k or k[0] not in "ABCD")]
    print("    alignment/NPTH pads:", [("%.4f, %.4f" % (v[0], v[1])) for v in npth])
print("mechanical: footprints with <= 2 pads and no net (holes):")
for f in fps:
    if f.Pads().size() <= 2 and all(not pd.GetNetname() for pd in f.Pads()) and f.GetReference():
        p = f.GetPosition()
        print("  %s (%.4f, %.4f) pads %d" % (f.GetReference(), p.x / 1e6, -p.y / 1e6, f.Pads().size()))
