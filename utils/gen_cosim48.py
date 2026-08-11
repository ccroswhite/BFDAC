# Round 48: OSCILLATION KILL TEST. Zone codes 23-28 self-oscillate (~18-period
# quasi-cycle, +/-50-100uV) while others are dead flat -> marginal stability:
# 47n bus cap against the inductive-looking source impedance of the M5
# cascode in a specific current window. Textbook fix = series damping R in
# the bus caps. Variants: a=no snub (control), b=3R3, c=10R.
# Schedule: [24,32,27,32,28,32,40,32] x SEG=160 -> compare seg std.
import os
import sys

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
for var, rs in (("a", None), ("b", 3.3), ("c", 10.0)):
    out = []
    for ln in base:
        if ln.startswith("* BFDAC CO-SIM"):
            out.append(f"* BFDAC CO-SIM v48{var} - oscillation kill test, "
                       f"snub={rs}")
        elif ln.startswith("Vnsch nsch 0 PWL"):
            out.append(f"Vnsch nsch 0 PWL({pwl})")
        elif ln.startswith(".tran"):
            out.append(f".tran 2n {tend*1e6:.6f}u 0")
        elif rs is not None and ln.startswith("C_bus_p"):
            out.append("C_bus_p bus_plus busp_s {cbus}")
            out.append(f"Rsnub_p busp_s 0 {rs}")
        elif rs is not None and ln.startswith("C_bus_m"):
            out.append("C_bus_m bus_minus busm_s {cbus}")
            out.append(f"Rsnub_m busm_s 0 {rs}")
        else:
            out.append(ln)
    with open(os.path.join(LT, f"bfdac_cosim48{var}.cir"), "w") as f:
        f.write("\n".join(out) + "\n")
print(f"decks a/b/c written, {int(round(tend/TS))} periods each")
