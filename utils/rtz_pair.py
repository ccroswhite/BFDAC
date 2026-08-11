# Round 63 analysis: E(N_prev, N) from the pair-transition chop.
# e1 = first-period deviation, e2 = second-period deviation (memory depth),
# each vs the settled mean of periods 3..7 of the same dwell (drift-immune).
# Reports matrix structure, null control (diagonal), and saves the matrix.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

LT = r"C:\Users\ccros\Documents\LTspice"
S = 8
seq = np.load(rf"{LT}\cosim63_seq.npy")
NDWELL = len(seq)
M = NDWELL * S

pav_path = rf"{LT}\cosim63_pavg.npy"
if os.path.exists(pav_path):
    p = np.load(pav_path)
else:
    names, data = read_raw(rf"{LT}\bfdac_cosim63.raw")
    t = data[0]
    d = data[names.index("V(diffout)")]
    p = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(pav_path, p)

p = p.reshape(NDWELL, S)
e1 = p[:, 0] - p[:, 3:8].mean(axis=1)
e2 = p[:, 1] - p[:, 3:8].mean(axis=1)

GRID = sorted(set(seq.tolist()))
idx = {c: i for i, c in enumerate(GRID)}
n = len(GRID)
sum1 = np.zeros((n, n)); sum2 = np.zeros((n, n))
sumsq = np.zeros((n, n)); cnt = np.zeros((n, n))
for d in range(1, NDWELL):          # skip first dwell
    a, b = idx[seq[d - 1]], idx[seq[d]]
    sum1[a, b] += e1[d]; sum2[a, b] += e2[d]
    sumsq[a, b] += e1[d] ** 2; cnt[a, b] += 1
E1 = sum1 / np.maximum(cnt, 1)
E2 = sum2 / np.maximum(cnt, 1)
SD = np.sqrt(np.maximum(sumsq / np.maximum(cnt, 1) - E1 ** 2, 0))
SE = SD / np.sqrt(np.maximum(cnt, 1))

np.set_printoptions(precision=1, suppress=True, linewidth=250)
print(f"grid: {GRID}; counts min/median {cnt[cnt>0].min():.0f}/{np.median(cnt[cnt>0]):.0f}")
print("\nE1(a,b) first-period error [uV] (rows=N_prev a, cols=N b):")
print(E1 * 1e6)
print("\nstd-error of E1 [uV]:")
print(SE * 1e6)
print("\nE2(a,b) second-period error [uV]:")
print(E2 * 1e6)
diag = np.array([E1[i, i] for i in range(n)])
print(f"\nnull control diag(E1) [uV]: {np.array2string(diag*1e6)}")
off = E1[cnt > 0]
print(f"E1 scale: max|offdiag| {np.abs(E1 - np.diag(np.diag(E1))).max()*1e6:.1f} uV; "
      f"1 LSB = 31000 uV; span ppm of 1.98V: "
      f"{np.abs(E1 - np.diag(np.diag(E1))).max()/1.98*1e6:.2f} ppm")

# structure fit: E1 ~ k1*dN + k2*|dN| + k3*dN^2 (dN = b - a)
A_, B_ = np.meshgrid(GRID, GRID, indexing="ij")
mask = cnt > 0
dN = (B_ - A_)[mask].astype(float)
y = E1[mask]
w = np.sqrt(cnt[mask])
X = np.vstack([dN, np.abs(dN), dN ** 2]).T
coef, *_ = np.linalg.lstsq(X * w[:, None], y * w, rcond=None)
resid = y - X @ coef
print(f"\nfit E1 = k1*dN + k2*|dN| + k3*dN^2:")
print(f"  k1={coef[0]*1e6:+.2f} k2={coef[1]*1e6:+.2f} k3={coef[2]*1e6:+.3f} uV/unit")
print(f"  rms(E1)={np.sqrt(np.average(y**2, weights=w**2))*1e6:.1f} uV -> "
      f"rms(resid)={np.sqrt(np.average(resid**2, weights=w**2))*1e6:.1f} uV")
np.save(rf"{LT}\cosim63_E1.npy", E1)
np.save(rf"{LT}\cosim63_grid.npy", np.array(GRID))
print("saved cosim63_E1.npy / cosim63_grid.npy")
