# Round 47: TWO-BACK MEMORY PROBE. In the chopped LUT schedule every code is
# approached from ref-32, yet the 20-28 zone changes +/-25ppm with schedule
# order (Round 44 lut vs lut2 vs s160). So state must survive THROUGH a
# 40-period ref segment. Trial = [X, 32, 25] x SEG=40 each, X cycling over
# {4,12,20,28,36,44,52,60}, 6 reps interleaved. Correlate level(25) with X;
# bias nodes recorded to identify the carrier.
import os

TS = 162.7604e-9
SEG = 40
XS = [4, 12, 20, 28, 36, 44, 52, 60]
NREP = 6
LT = r"C:\Users\ccros\Documents\LTspice"

sched = []
for r in range(NREP):
    for X in XS:
        sched += [X, 32, 25]

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

src = open(os.path.join(LT, "bfdac_cosim44lut.cir")).read().splitlines()
out = []
for ln in src:
    if ln.startswith("* BFDAC CO-SIM"):
        out.append("* BFDAC CO-SIM v47 - 2-BACK MEMORY PROBE [X,32,25], "
                   "slow-bias deck")
    elif ln.startswith("Vnsch nsch 0 PWL"):
        out.append(f"Vnsch nsch 0 PWL({pwl})")
    elif ln.startswith(".tran"):
        out.append(f".tran 2n {tend*1e6:.6f}u 0")
        out.append(".save V(diffout) V(nsch) V(q4_base) V(casb_p) V(casb2_p)"
                   " V(bus_plus) V(bus_minus) V(col_p) V(col_m)"
                   " V(c25_s) V(c25_e) V(c20_s) V(c30_s)")
    elif ln.startswith(".save"):
        pass
    else:
        out.append(ln)
with open(os.path.join(LT, "bfdac_cosim47.cir"), "w") as f:
    f.write("\n".join(out) + "\n")
nper = int(round(tend / TS))
print(f"bfdac_cosim47.cir: {nper} periods, tend {tend*1e6:.1f} us")
