# Round 53: GATE-STOPPER probe. Kill the codes-23-28 marginal oscillation
# with a series R at the cascode MOSFET GATE (no signal current flows there,
# unlike the mid-series R of R49/50 which cost 10dB). Loop = M5 gm against
# 47n bus caps; Rg*Cgs adds damping inside the loop without series loss.
# Variants: a=22R M5, b=100R M5, c=470R M5, d=100R M5+M6.
# Same schedule as Round 48 probes: [24,32,27,32,28,32,40,32] x SEG=160.
import os

TS = 162.7604e-9
SEG = 160
LT = r"C:\Users\ccros\Documents\LTspice"
sched = [24, 32, 27, 32, 28, 32, 40, 32]

pts = ["0 32"]
val = 32
t = SEG * TS
for v in sched:
    pts.append(f"{t*1e9:.4f}n {val}")
    pts.append(f"{(t+0.2e-9)*1e9:.4f}n {v}")
    val = v
    t += SEG * TS
tend = t
pwl = " ".join(pts)

base = open(os.path.join(LT, "bfdac_cosim44lut.cir")).read().splitlines()
for var, rg5, rg6 in (("a", 22, None), ("b", 100, None),
                      ("c", 470, None), ("d", 100, 100),
                      ("e", 1000, None), ("f", 2200, None),
                      ("g", 470, 470)):
    out = []
    for ln in base:
        if ln.startswith("* BFDAC CO-SIM"):
            out.append(f"* BFDAC CO-SIM v53{var} - gate stopper probe, "
                       f"Rg5={rg5} Rg6={rg6}")
        elif ln.startswith("Vnsch nsch 0 PWL"):
            out.append(f"Vnsch nsch 0 PWL({pwl})")
        elif ln.startswith(".tran"):
            out.append(f".tran 2n {tend*1e6:.6f}u 0")
        elif ln.startswith("M5p"):
            out.append("M5p  mid_p  m5g_p  bus_plus  bus_plus  Si1555DL_N")
            out.append(f"Rg5_p casb_p m5g_p {rg5}")
        elif ln.startswith("M5m"):
            out.append("M5m  mid_m  m5g_m  bus_minus bus_minus Si1555DL_N")
            out.append(f"Rg5_m casb_m m5g_m {rg5}")
        elif rg6 is not None and ln.startswith("M6p"):
            out.append("M6p  col_p  m6g_p  mid_p  mid_p  Si1555DL_N")
            out.append(f"Rg6_p casb2_p m6g_p {rg6}")
        elif rg6 is not None and ln.startswith("M6m"):
            out.append("M6m  col_m  m6g_m  mid_m  mid_m  Si1555DL_N")
            out.append(f"Rg6_m casb2_m m6g_m {rg6}")
        else:
            out.append(ln)
    with open(os.path.join(LT, f"bfdac_cosim53{var}.cir"), "w") as f:
        f.write("\n".join(out) + "\n")
print(f"decks 53a-d written, {int(round(tend/TS))} periods each")
