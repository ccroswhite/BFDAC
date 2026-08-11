# Round 49: MID-NODE FIX (10R + 1n on the cascode mid node, Round 48j winner)
# + slow bias (C_q4 10u), full honest pipeline. The 48j fix kills the zone
# oscillation (38-56uV -> <4uV) which capped LUT reproducibility at +/-25ppm.
# Emits bfdac_cosim49lut.cir (chopped, seed-44 shuffle) and patches the gate
# deck bfdac_cosim49.cir produced by gen_cosim41.py 49 (pwl49).
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"

def midfix(lines):
    out = []
    for ln in lines:
        if ln.startswith("M6p"):
            out.append("M6p col_p casb2_p mid6_p mid6_p Si1555DL_N")
            out.append("Rmid_p mid6_p mid_p 10")
            out.append("Cmid_p mid_p 0 1n")
        elif ln.startswith("M6m"):
            out.append("M6m col_m casb2_m mid6_m mid6_m Si1555DL_N")
            out.append("Rmid_m mid6_m mid_m 10")
            out.append("Cmid_m mid_m 0 1n")
        else:
            out.append(ln.replace("C_q4 q4_base 0 22n", "C_q4 q4_base 0 10u"))
    return out

which = sys.argv[1] if len(sys.argv) > 1 else "lut"
if which == "lut":
    # base: cosim44lut.cir already has slow bias + seed-44 shuffled schedule
    src = open(os.path.join(LT, "bfdac_cosim44lut.cir")).read().splitlines()
    src = midfix(src)
    src[0] = "* BFDAC CO-SIM v49lut - 64-code LUT, slow-bias + mid-node fix"
    with open(os.path.join(LT, "bfdac_cosim49lut.cir"), "w") as f:
        f.write("\n".join(src) + "\n")
    print("bfdac_cosim49lut.cir written")
else:
    # gate deck: gen_cosim41.py 49 wrote bfdac_cosim49.cir from the v39 base
    # (pwl49 vectors, no circuit mods) - apply slow bias + mid fix in place
    p = os.path.join(LT, "bfdac_cosim49.cir")
    src = midfix(open(p).read().splitlines())
    src[0] = "* BFDAC CO-SIM v49 - FFT GATE, slow-bias + mid-node fix, predistorted"
    with open(p, "w") as f:
        f.write("\n".join(src) + "\n")
    print("bfdac_cosim49.cir patched (slow bias + mid fix)")
