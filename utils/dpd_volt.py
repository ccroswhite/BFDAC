# Round 67: VOLTERRA predistortion. NS feedback subtracts the actual emitted
# level including the R66 quadratic memory kernel (leave-one-out validated:
# HD2 within ~1dB/3deg on all 10 gates):
#   L_k = code_k + err_static(code_k) + sum_ij q_ij (c_{k-i}-32)(c_{k-j}-32)
import numpy as np
import sys
import os
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 16384
BIN = int(os.environ.get("BIN", "17"))
LT = r"C:\Users\ccros\Documents\LTspice"

LUTF = sys.argv[1] if len(sys.argv) > 1 else "cosim55lut_inl.npy"
OUTF = sys.argv[2] if len(sys.argv) > 2 else "cosim67_code.npy"

ppm = np.load(rf"{LT}\{LUTF}")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)

GAIN_V = -0.0310                     # V per code unit at diffout
KF = os.environ.get("KERNEL", "cosim66")
Q = np.load(rf"{LT}\{KF}_Q.npy") / GAIN_V     # code units
pairs = np.load(rf"{LT}\{KF}_pairs.npy")
QL = int(pairs.max())
# R70: subtract the kernel's static+LTI+const content (R69 post-mortem) so
# only the true dynamic action enters the feedback
STAT = np.load(rf"{LT}\{KF}_stat.npy") / GAIN_V
FIRW = np.load(rf"{LT}\{KF}_firw.npy") / GAIN_V
DLW = len(FIRW)
KSCALE = float(os.environ.get("KSCALE", "1"))   # Step 6.5: kernel mis-scale
Q, STAT, FIRW = Q * KSCALE, STAT * KSCALE, FIRW * KSCALE
print(f"kernel: {len(Q)} terms, max lag {QL}, max|q| {np.abs(Q).max()*1e6:.2f} ucode/unit^2, "
      f"stat/fir decomposition loaded, KSCALE={KSCALE:g}")

rng = np.random.default_rng(int(os.environ.get("DSEED", "5")))
n = np.arange(M)
amp = 28.0 * 10 ** (float(os.environ.get("AMPDB", "-1")) / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

st = (0, 0, 0, 0, 0, 0)
hist = [0.0] * (max(QL, DLW) + 1)    # c-32 history, hist[0] = current
out = np.empty(M, dtype=np.int64)
for k in range(M):
    e1, e2, e3, f1, f2, f3 = st
    f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
         + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
    w = int(u[k]) + (32 << FRAC) + f
    d = w + int(dith[k])
    code = d >> FRAC
    code = 0 if code < 0 else (63 if code > 63 else code)
    hist = [float(code - 32)] + hist[:max(QL, DLW)]
    dyn = -STAT[code]
    for t, q in zip(pairs, Q):
        prod = 1.0
        for lag in t:
            if lag >= 0:
                prod *= hist[lag]
        dyn += q * prod
    for j in range(DLW):
        dyn -= FIRW[j] * hist[j + 1]
    e = w - (code << FRAC) - int(LUT[code]) - int(round(dyn * LSB))
    e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
    st = (e, e1, e2, f, f1, f2)
    out[k] = code
np.save(rf"{LT}\{OUTF}", out)
print(f"saved {OUTF}; code range {out.min()}..{out.max()}, BIN={BIN}")
