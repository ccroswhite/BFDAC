# Round 63: PAIR-TRANSITION CHOP - measure the dynamic per-period error
# E(N_prev, N): deviation of the FIRST period after a code transition from
# the settled level of the destination code. Random walk over a 9-code grid,
# 2048 dwells x 8 periods on the R54-config deck (stoppers + slow bias).
# Diagonal dwells (a==a) are the null control. Drift-immune: error is
# differenced against settled periods within the same dwell.
import numpy as np
import os
import re

LT = r"C:\Users\ccros\Documents\LTspice"
TS = 162.7604e-9
GRID = [6, 14, 22, 28, 32, 36, 42, 50, 58]
NDWELL = 2048
S = 8                       # periods per dwell

rng = np.random.default_rng(63)
seq = [32] + [int(GRID[i]) for i in rng.integers(0, len(GRID), NDWELL - 1)]
np.save(os.path.join(LT, "cosim63_seq.npy"), np.array(seq))

lines = [f"0 {seq[0]}"]
for d in range(1, NDWELL):
    if seq[d] != seq[d - 1]:
        t = d * S * TS
        lines.append(f"{t*1e9:.4f}n {seq[d-1]}")
        lines.append(f"{(t+0.2e-9)*1e9:.4f}n {seq[d]}")
tend = NDWELL * S * TS
lines.append(f"{tend*1e9:.4f}n {seq[-1]}")
with open(os.path.join(LT, "pair63.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")

src = open(os.path.join(LT, "bfdac_cosim54lut.cir")).read().splitlines()
out = []
for ln in src:
    if ln.startswith("Vnsch "):
        out.append('Vnsch nsch 0 PWL file="pair63.txt"')
    elif ln.startswith(".tran"):
        out.append(f".tran 2n {tend*1e6:.6f}u 0")
    elif ln.startswith("* BFDAC CO-SIM"):
        out.append("* BFDAC CO-SIM v63 - PAIR-TRANSITION CHOP, R54 config")
    else:
        out.append(ln)
with open(os.path.join(LT, "bfdac_cosim63.cir"), "w") as f:
    f.write("\n".join(out) + "\n")
print(f"cosim63: {NDWELL} dwells x {S} periods, grid {GRID}, "
      f"tend {tend*1e6:.1f}us, bfdac_cosim63.cir + pair63.txt written")
