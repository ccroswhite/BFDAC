# Round 35b: asymptote-extraction upgrade of rtz_chop. Each segment's
# per-period averages follow a∞ + b1*r1^k + b2*r2^k (termination RC ~336ns,
# q4_base line ~2.2us). Shared taus grid-fit across all segments (linear LS in
# amplitudes per segment), then chop-correct asymptotes with the ref trace.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim35.raw"
SCHED = [1, 32, 8, 32, 16, 32, 31, 32, 32, 32, 33, 32, 48, 32, 64, 32]
SEG0, SEGP = 24, 10

names, data = read_raw(RAW)
t = data[0]
d = data[names.index("V(diffout)")]
nper = SEG0 + SEGP * len(SCHED)
a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])

def seg_slices():
    yield 32, a[1:SEG0]              # seg0 (skip boundary period 0)
    p0 = SEG0
    for code in SCHED:
        yield code, a[p0 + 1:p0 + SEGP]
        p0 += SEGP

def fit_all(tau1, tau2):
    r1 = np.exp(-Ts / tau1)
    r2 = np.exp(-Ts / tau2)
    sse, asy, unc = 0.0, [], []
    for code, w in seg_slices():
        k = np.arange(len(w), dtype=float)
        M = np.vstack([np.ones_like(k), r1 ** k, r2 ** k]).T
        c, res, *_ = np.linalg.lstsq(M, w, rcond=None)
        pred = M @ c
        sse += ((w - pred) ** 2).sum()
        asy.append((code, c[0]))
        unc.append((w - pred).std())
    return sse, asy, unc

# grid search shared taus
best = None
for tau1 in np.linspace(0.20e-6, 0.55e-6, 15):
    for tau2 in np.linspace(1.0e-6, 4.0e-6, 13):
        sse, asy, unc = fit_all(tau1, tau2)
        if best is None or sse < best[0]:
            best = (sse, tau1, tau2, asy, unc)
sse, tau1, tau2, asy, unc = best
print(f"best taus: {tau1*1e9:.0f} ns / {tau2*1e6:.2f} us; rms fit residual per point = "
      f"{np.sqrt(sse/ (len(asy)*8))*1e6:.2f} uV")

# chop correction on asymptotes
segs = asy
ref_idx = np.array([i for i, (c, v) in enumerate(segs) if c == 32 and i != 9], float)
ref_val = np.array([v for i, (c, v) in enumerate(segs) if c == 32 and i != 9])
ref_mean = ref_val.mean()
print("\nref asymptote drift trace (uV dev): "
      + " ".join(f"{(v-ref_mean)*1e6:+.1f}" for v in ref_val))

out, res_unc = {}, {}
for i, (c, v) in enumerate(segs):
    if c == 32 and i != 9:
        continue
    out[c] = v - (np.interp(i, ref_idx, ref_val) - ref_mean)
    res_unc[c] = unc[i]

codes = [1, 8, 16, 32, 48, 64]
n = np.array(codes, float)
va = np.array([out[c] for c in codes])
A = np.vstack([np.ones_like(n), n]).T
coef, *_ = np.linalg.lstsq(A, va, rcond=None)
resid = va - A @ coef
span = abs(coef[1] * 64)
print(f"\n=== asymptote+chop INL (gain {coef[1]*1e3:.4f} mV/cell) ===")
for c, r in zip(codes, resid):
    print(f"  N={c:<3d} INL = {r/span*1e6:8.2f} ppm ({r*1e6:+8.1f} uV)  fit-unc {res_unc[c]*1e6:.1f} uV")
print(f"max |INL| = {np.max(np.abs(resid))/span*1e6:.2f} ppm")

lsb = coef[1]
print(f"\nDNL(31->32) = {((out[32]-out[31])/lsb-1)*100:.3f} % of LSB; "
      f"(32->33) = {((out[33]-out[32])/lsb-1)*100:.3f} % of LSB")
