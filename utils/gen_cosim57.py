# Round 57: HD2 DISCRIMINATOR - pwa/pwb RTZ skew. The deck carries a
# deliberate 1ns pwb delay (real-world clock asymmetry). Skew makes the
# plus/minus rail charges settle differently vs code -> even-order (HD2)
# candidate. Variant: skew=0 on the R54 config (stoppers + slow bias).
# Full honest pipeline: "lut" deck then "gate" patcher (after gen_cosim41 57).
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"

def fix(src):
    assert "skew=1n" in src
    return src.replace("skew=1n", "skew=0n")

which = sys.argv[1] if len(sys.argv) > 1 else "lut"
if which == "lut":
    src = fix(open(os.path.join(LT, "bfdac_cosim54lut.cir")).read())
    src = src.replace(src.splitlines()[0],
                      "* BFDAC CO-SIM v57lut - 64-code LUT, stoppers + slow bias + SKEW=0")
    with open(os.path.join(LT, "bfdac_cosim57lut.cir"), "w") as f:
        f.write(src)
    print("bfdac_cosim57lut.cir written")
else:
    p = os.path.join(LT, "bfdac_cosim57.cir")
    src = fix(open(p).read())
    src = src.replace(src.splitlines()[0],
                      "* BFDAC CO-SIM v57 - FFT GATE, stoppers + slow bias + SKEW=0, predistorted")
    with open(p, "w") as f:
        f.write(src)
    print("bfdac_cosim57.cir patched")
