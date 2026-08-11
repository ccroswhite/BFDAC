# Round 42: EXTENDED predistortion = static LUT + bilinear bias-memory terms.
# Forensics (toggle_probe.py) showed the post-static-DPD residual is explained
# by ema_tau(code) x poly(code) products (bias nodes with ~4/13.5/40-period
# taus modulated by code-dependent bus current, multiplying cell charge).
# Fit the model on the cosim41 run, then embed it in the level-aware EF3
# feedback (all causal/deterministic - RTL-implementable) -> cosim42 vectors.
import numpy as np
import sys
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP
from scipy.signal import lfilter

M = 16384
BIN = 17
DISCARD = 512
NTAP = 12
TAUS = (4.0, 13.5, 40.0)
LT = r"C:\Users\ccros\Documents\LTspice"

code = np.load(rf"{LT}\cosim41_code.npy").astype(np.int64)
a = np.load(rf"{LT}\cosim41_pavg.npy")
ppm_avg = np.load(rf"{LT}\cosim40avg_inl.npy")

c = code.astype(float)
cell_gain = np.polyfit(c[DISCARD:], a[DISCARD:], 1)[0]   # V per cell (signed)

rows = np.arange(max(DISCARD, NTAP), M)
cc = c - 32.0                          # centered code
# LINEAR block (absorbed, NOT applied in corrector): DC, FIR of code history
lin = [np.ones(len(rows))] + [c[rows - k] for k in range(0, NTAP + 1)]
# NONLINEAR block (centered; this is what the corrector applies):
nl = [cc[rows]**2, cc[rows]**3,
      cc[rows-1]**2, cc[rows-1]**3, cc[rows]*cc[rows-1]]
emas = []
for tau in TAUS:
    al = 1.0 / tau
    ema = lfilter([al], [1, -(1 - al)], cc)
    emas.append(al)
    nl += [ema[rows-1]*cc[rows], ema[rows-1]*cc[rows]**2,
           ema[rows-1]**2, ema[rows-1]**2*cc[rows]]
NLIN = len(lin)
X = np.vstack(lin + nl).T
coef, *_ = np.linalg.lstsq(X, a[rows], rcond=None)
r = a[rows] - X @ coef
ph = 2 * np.pi * BIN * rows / M
for h in (2, 3):
    q = np.vstack([np.cos(h*ph), np.sin(h*ph), np.ones(len(rows))]).T
    cf, *_ = np.linalg.lstsq(q, r, rcond=None)
    print(f"full-model in-sample HD{h}: "
          f"{20*np.log10(np.hypot(cf[0],cf[1])/abs(cell_gain)/24.99):.1f} dBc")
g = coef[NLIN:] / cell_gain           # nonlinear coeffs, cells units
print("nonlinear coeffs (cells):", np.round(g, 8))

# ---- extended level-aware EF3 ----
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm_avg * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)

rng = np.random.default_rng(5)
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

st = (0, 0, 0, 0, 0, 0)
ema_st = [0.0] * len(TAUS)
prev_cc = 0.0
out = np.empty(M, dtype=np.int64)
for i in range(M):
    e1, e2, e3, f1, f2, f3 = st
    f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
         + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
    w = int(u[i]) + (32 << FRAC) + f
    cq = (w + int(dith[i])) >> FRAC
    cq = 0 if cq < 0 else (63 if cq > 63 else cq)
    x = cq - 32.0
    corr = (g[0]*x*x + g[1]*x**3
            + g[2]*prev_cc**2 + g[3]*prev_cc**3 + g[4]*x*prev_cc)
    for j in range(len(TAUS)):
        E = ema_st[j]
        gj = g[5 + 4*j:5 + 4*j + 4]
        corr += gj[0]*E*x + gj[1]*E*x*x + gj[2]*E*E + gj[3]*E*E*x
    e = w - (cq << FRAC) - int(LUT[cq]) - int(round(corr * LSB))
    e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
    st = (e, e1, e2, f, f1, f2)
    out[i] = cq
    for j, al in enumerate(emas):
        ema_st[j] = (1 - al) * ema_st[j] + al * x
    prev_cc = x

np.save(rf"{LT}\cosim42_code.npy", out)
print(f"saved cosim42_code.npy; range {out.min()}..{out.max()}")
