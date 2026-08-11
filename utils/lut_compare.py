# Round 41 diagnostics: LUT reproducibility. Evaluates the REVERSED-order
# chopped run (cosim40r) with the same estimator and compares against the
# forward-order LUT (cosim40_inl.npy). If the two disagree beyond the noise
# floor, the "static" LUT has history-dependence (dynamic residue) and caps
# what any static predistortion can achieve.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

SEG, DISC, SEG0 = 40, 20, 40
codes = [c for c in range(1, 65) if c != 32][::-1]
sched = []
for c in codes:
    sched += [c, 32]

names, data = read_raw(r"C:\Users\ccros\Documents\LTspice\bfdac_cosim40r.raw")
t = data[0]
d = data[names.index("V(diffout)")]
nper = SEG0 + SEG * len(sched)
a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])

segs = [(32, a[SEG0 - DISC//2:SEG0].mean())]
p0 = SEG0
for c in sched:
    segs.append((c, a[p0 + DISC:p0 + SEG].mean()))
    p0 += SEG
ref_idx = np.array([i for i, (c, v) in enumerate(segs) if c == 32], float)
ref_val = np.array([v for i, (c, v) in enumerate(segs) if c == 32])
out = {32: ref_val.mean()}
for i, (c, v) in enumerate(segs):
    if c != 32:
        out[c] = v - (np.interp(i, ref_idx, ref_val) - ref_val.mean())

n = np.arange(1, 65, dtype=float)
va = np.array([out[c] for c in range(1, 65)])
A = np.vstack([np.ones_like(n), n]).T
coef, *_ = np.linalg.lstsq(A, va, rcond=None)
ppm_r = (va - A @ coef) / (coef[1] * 64) * 1e6
ppm_f = np.load(r"C:\Users\ccros\Documents\LTspice\cosim40_inl.npy")
diff = ppm_r - ppm_f
print(f"forward  max|INL| = {np.max(np.abs(ppm_f)):.1f} ppm")
print(f"reversed max|INL| = {np.max(np.abs(ppm_r)):.1f} ppm")
print(f"DIFF: rms = {diff.std():.2f} ppm, max|diff| = {np.max(np.abs(diff)):.2f} ppm "
      f"(at N={np.argmax(np.abs(diff))+1})")
for r in range(0, 64, 8):
    print("  " + "  ".join(f"{diff[k]:8.2f}" for k in range(r, r + 8)))
np.save(r"C:\Users\ccros\Documents\LTspice\cosim40r_inl.npy", ppm_r)
