# Round 63b: dynamic-nonlinearity extraction with the LTI tail properly
# removed. Fit pavg[k] = onehot(c_k) levels + FIR(c_{k-1..k-D}) + drift,
# then bin the residual by (c_{k-1}, c_k). The FIR absorbs the output-filter
# transient (tau ~ 8 periods leaked into the R63 dwell analysis); the one-hot
# absorbs static INL. What remains binned by pair = pure dynamic nonlinearity.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

LT = r"C:\Users\ccros\Documents\LTspice"
D = int(os.environ.get("FIRD", "16"))   # FIR depth (periods)
seq = np.load(rf"{LT}\cosim63_seq.npy")
S = 8
c = np.repeat(seq, S).astype(float)         # per-period code
p = np.load(rf"{LT}\cosim63_pavg.npy")
M = len(p)
assert len(c) == M

GRID = sorted(set(seq.tolist()))
n = len(GRID)
idx = {g: i for i, g in enumerate(GRID)}

k0 = D
rows = np.arange(k0, M)
cols = []
oh = np.zeros((len(rows), n))
for j, k in enumerate(rows):
    oh[j, idx[c[k]]] = 1.0
cols.append(oh)
fir = np.stack([c[rows - j] for j in range(1, D + 1)], axis=1)
cols.append(fir - fir.mean(axis=0))
nn = (rows - k0) / (M - k0)
cols.append(np.stack([nn, nn ** 2, nn ** 3], axis=1))
X = np.hstack(cols)
y = p[rows]
coef, *_ = np.linalg.lstsq(X, y, rcond=None)
r = y - X @ coef
print(f"fit: {X.shape[1]} params on {len(rows)} periods; "
      f"resid rms {r.std()*1e6:.1f} uV (per-period noise floor)")
print("FIR kernel [uV/unit]:",
      np.array2string(coef[n:n+D]*1e6, precision=1, suppress_small=True))

# bin residual by transition pair (c_{k-1} -> c_k)
E = np.zeros((n, n)); C = np.zeros((n, n)); SS = np.zeros((n, n))
for j, k in enumerate(rows):
    a, b = idx[c[k - 1]], idx[c[k]]
    E[a, b] += r[j]; SS[a, b] += r[j] ** 2; C[a, b] += 1
E /= np.maximum(C, 1)
SE = np.sqrt(np.maximum(SS / np.maximum(C, 1) - E ** 2, 0) / np.maximum(C, 1))
np.set_printoptions(precision=1, suppress=True, linewidth=250)
print(f"\nE_nl(a,b) dynamic nonlinearity [uV] (rows a=prev, cols b=curr), "
      f"counts min {C[C>0].min():.0f}:")
print(E * 1e6)
print("\nstd-error [uV]:")
print(SE * 1e6)
print(f"\ndiag (null) max|.| {np.abs(np.diag(E)).max()*1e6:.1f} uV; "
      f"offdiag max|.| {np.abs(E - np.diag(np.diag(E))).max()*1e6:.1f} uV; "
      f"1 ppm span = 2.0 uV")

# depth-2 check: bin by (c_{k-2}, c_k)
E2 = np.zeros((n, n)); C2 = np.zeros((n, n))
for j, k in enumerate(rows):
    a, b = idx[c[k - 2]], idx[c[k]]
    E2[a, b] += r[j]; C2[a, b] += 1
E2 /= np.maximum(C2, 1)
print(f"depth-2 binning offdiag max|.| {np.abs(E2 - np.diag(np.diag(E2))).max()*1e6:.1f} uV")
np.save(rf"{LT}\cosim63_Enl.npy", E)
print("saved cosim63_Enl.npy")
