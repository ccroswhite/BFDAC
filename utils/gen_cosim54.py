# Round 54: GATE-STOPPER fix (53d: 100R in series with M5 AND M6 gates).
# Kills the codes-23-28 self-oscillation completely (probe std <=1.3uV vs
# 38-52uV control) with ZERO signal-path insertion (no drain current through
# the stopper). Slow bias (C_q4 10u) retained. Full honest pipeline:
# LUT deck ("lut") + gate-deck patcher ("gate", run after gen_cosim41.py 54).
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
RG = 100

def fix(lines):
    out = []
    for ln in lines:
        if ln.startswith("M5p"):
            out.append("M5p  mid_p  m5g_p  bus_plus  bus_plus  Si1555DL_N")
            out.append(f"Rg5_p casb_p m5g_p {RG}")
        elif ln.startswith("M5m"):
            out.append("M5m  mid_m  m5g_m  bus_minus bus_minus Si1555DL_N")
            out.append(f"Rg5_m casb_m m5g_m {RG}")
        elif ln.startswith("M6p"):
            out.append("M6p  col_p  m6g_p  mid_p  mid_p  Si1555DL_N")
            out.append(f"Rg6_p casb2_p m6g_p {RG}")
        elif ln.startswith("M6m"):
            out.append("M6m  col_m  m6g_m  mid_m  mid_m  Si1555DL_N")
            out.append(f"Rg6_m casb2_m m6g_m {RG}")
        else:
            out.append(ln.replace("C_q4 q4_base 0 22n", "C_q4 q4_base 0 10u"))
    return out

which = sys.argv[1] if len(sys.argv) > 1 else "lut"
if which in ("lut", "lut2"):
    base = "bfdac_cosim44lut.cir" if which == "lut" else "bfdac_cosim44lut2.cir"
    src = fix(open(os.path.join(LT, base)).read().splitlines())
    src[0] = (f"* BFDAC CO-SIM v54{which[3:]} - 64-code LUT, "
              "slow-bias + 100R gate stoppers M5/M6")
    with open(os.path.join(LT, f"bfdac_cosim54{which}.cir".replace("54lut", "54lut")), "w") as f:
        f.write("\n".join(src) + "\n")
    print(f"bfdac_cosim54{which}.cir written")
else:
    tag = sys.argv[2] if len(sys.argv) > 2 else "54"
    p = os.path.join(LT, f"bfdac_cosim{tag}.cir")
    src = fix(open(p).read().splitlines())
    src[0] = (f"* BFDAC CO-SIM v{tag} - FFT GATE, slow-bias + 100R gate "
              "stoppers, predistorted")
    with open(p, "w") as f:
        f.write("\n".join(src) + "\n")
    print(f"bfdac_cosim{tag}.cir patched")
