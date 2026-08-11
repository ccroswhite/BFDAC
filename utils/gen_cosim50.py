# Round 50: series 10R at mid (48h - no Cmid: the 1n in 48j injected
# first-difference charge errors, poisoning the Round 49 gate at -88dBc).
# Slow bias retained. Full honest pipeline: LUT deck + gate-deck patcher.
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"

def fix(lines):
    out = []
    for ln in lines:
        if ln.startswith("M6p"):
            out.append("M6p col_p casb2_p mid6_p mid6_p Si1555DL_N")
            out.append("Rmid_p mid6_p mid_p 10")
        elif ln.startswith("M6m"):
            out.append("M6m col_m casb2_m mid6_m mid6_m Si1555DL_N")
            out.append("Rmid_m mid6_m mid_m 10")
        else:
            out.append(ln.replace("C_q4 q4_base 0 22n", "C_q4 q4_base 0 10u"))
    return out

which = sys.argv[1] if len(sys.argv) > 1 else "lut"
if which == "lut":
    src = fix(open(os.path.join(LT, "bfdac_cosim44lut.cir")).read().splitlines())
    src[0] = "* BFDAC CO-SIM v50lut - 64-code LUT, slow-bias + mid series 10R"
    with open(os.path.join(LT, "bfdac_cosim50lut.cir"), "w") as f:
        f.write("\n".join(src) + "\n")
    print("bfdac_cosim50lut.cir written")
else:
    p = os.path.join(LT, "bfdac_cosim50.cir")
    src = fix(open(p).read().splitlines())
    src[0] = "* BFDAC CO-SIM v50 - FFT GATE, slow-bias + mid series 10R, predistorted"
    with open(p, "w") as f:
        f.write("\n".join(src) + "\n")
    print("bfdac_cosim50.cir patched")
