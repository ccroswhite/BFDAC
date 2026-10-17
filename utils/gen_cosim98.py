# P3 / N2c (2026-09-13): INDEPENDENT PER-CELL reclock-FF jitter gate.
# Gate-93 deck; every cell i gets its own RTZ window pair pwa_i / pwb_i whose
# per-period edges carry white gaussian jitter INDEPENDENT per cell and per
# clock edge (Q and Qb of one FF share the same clock edge -> same jitter,
# pwb keeps the 1 ns trace skew). Differential vs gate 93 (PULSE windows;
# 0.9 uV PWL-grid floor from N2 applies). Purpose: pin the independent-vs-
# common sensitivity ratio assumed sqrt(64)/40 = 0.2 in pn_n2b.py.
# sigma = 10 ps -> predicted in-band 0.2 * 10 * 1.1 uV = 2.2 uV (vs N2 common
# 10 ps = 9.1 uV).
import numpy as np
import os
import re

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
TS = 162.7604e-9
TC = TS / 8
T0 = TC
TEDGE = 3e-9
TWID = 6 * TC
SKEW = 1e-9
SIG = 10e-12
NCELL = 64
TAG = "98"
rng = np.random.default_rng(980)

def pwl_train(skew, dr, df):
    lines = ["0 0"]
    for k in range(M):
        tr = k * TS + T0 + skew + dr[k]
        tf = k * TS + T0 + TEDGE + TWID + skew + df[k]
        lines.append(f"{tr*1e9:.6f}n 0")
        lines.append(f"{(tr+TEDGE)*1e9:.6f}n 1")
        lines.append(f"{tf*1e9:.6f}n 1")
        lines.append(f"{(tf+TEDGE)*1e9:.6f}n 0")
    lines.append(f"{(M*TS)*1e9:.6f}n 0")
    return "\n".join(lines) + "\n"

pd = os.path.join(LT, f"pwl{TAG}")
os.makedirs(pd, exist_ok=True)
src = open(os.path.join(LT, "bfdac_cosim93.cir")).read().replace("v93", f"v{TAG}")
extra = []
for i in range(1, NCELL + 1):
    dr, df = rng.normal(0, SIG, M), rng.normal(0, SIG, M)   # one FF: Q and Qb share edges
    open(os.path.join(pd, f"pwa{i:02d}.txt"), "w").write(pwl_train(0.0, dr, df))
    open(os.path.join(pd, f"pwb{i:02d}.txt"), "w").write(pwl_train(SKEW, dr, df))
    # every source whose expression contains V(sel{i}) uses that cell's FF edges
    src, n = re.subn(rf"(V\(sel{i}\)\*V\(pw)([ab])\)", rf"\g<1>\g<2>{i})", src)
    assert n == 4, (i, n)
    extra.append(f'Vpwa{i} pwa{i} 0 PWL file="{pd}\\pwa{i:02d}.txt"')
    extra.append(f'Vpwb{i} pwb{i} 0 PWL file="{pd}\\pwb{i:02d}.txt"')
src = src.replace(".end\n", "\n".join(extra) + "\n.end\n")
assert "V(pwa)" not in src and "V(pwb)" not in src
open(os.path.join(LT, f"bfdac_cosim{TAG}.cir"), "w").write(src)
np.save(os.path.join(LT, f"cosim{TAG}_code.npy"), np.load(os.path.join(LT, "cosim93_code.npy")))
print(f"{TAG}: {NCELL} cells x (pwa,pwb) PWL, sigma {SIG*1e12:.0f} ps independent per cell/edge; "
      f"predicted in-band ~{0.2*SIG*1e12*1.1:.1f} uV (common would be {SIG*1e12*0.91:.1f} uV)")
