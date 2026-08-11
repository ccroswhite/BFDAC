# Round 46: HYSTERESIS PROBE for the N=20-28 zone.
# The fwd/rev LUTs disagree by +/-25ppm only at codes 20-28 (Round 40).
# Probe: alternate approach direction to code 24 - segments of
# (12 -> 24) and (36 -> 24) repeated; measure the settled level at 24 for
# each approach direction and record every bias node so the state carrier
# is identifiable. Uses the Round 44 slow-bias chopped deck as base
# (C_q4 10u), .save on internal nodes.
import os

TS = 162.7604e-9
SEG = 60          # periods per segment (longer: watch settling shape)
NREP = 24         # repetitions of the 4-segment pattern
LT = r"C:\Users\ccros\Documents\LTspice"

# pattern: 12, 24, 36, 24 | repeat -> code-24 segments alternate approach dir
sched = []
for _ in range(NREP):
    sched += [12, 24, 36, 24]

pts = ["0 24"]
val = 24
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
        out.append("* BFDAC CO-SIM v46 - HYSTERESIS PROBE codes 12/24/36/24, "
                   "slow-bias deck, bias nodes recorded")
    elif ln.startswith("Vnsch nsch 0 PWL"):
        out.append(f"Vnsch nsch 0 PWL({pwl})")
    elif ln.startswith(".tran"):
        out.append(f".tran 2n {tend*1e6:.6f}u 0")
        out.append(".save V(diffout) V(nsch) V(q4_base) V(casb_p) V(casb_m)"
                   " V(casb2_p) V(casb2_m) V(bus_plus) V(bus_minus)"
                   " V(col_p) V(col_m) V(c24_s) V(c24_e) V(c12_s) V(c36_s)")
    elif ln.startswith(".save"):
        pass
    else:
        out.append(ln)
with open(os.path.join(LT, "bfdac_cosim46.cir"), "w") as f:
    f.write("\n".join(out) + "\n")
nper = int(round(tend / TS))
print(f"bfdac_cosim46.cir: {nper} periods, tend {tend*1e6:.1f} us")
