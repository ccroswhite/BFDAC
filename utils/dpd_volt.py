# Round 67: VOLTERRA predistortion. NS feedback subtracts the actual emitted
# level including the R66 quadratic memory kernel (leave-one-out validated:
# HD2 within ~1dB/3deg on all 10 gates):
#   L_k = code_k + err_static(code_k) + sum_ij q_ij (c_{k-i}-32)(c_{k-j}-32)
import numpy as np
import sys
import os
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = int(os.environ.get("M", "16384"))   # R95: 65536 for the 1 kHz long gate
BIN = int(os.environ.get("BIN", "17"))
LT = r"C:\Users\ccros\Documents\LTspice"

LUTF = sys.argv[1] if len(sys.argv) > 1 else "cosim55lut_inl.npy"
OUTF = sys.argv[2] if len(sys.argv) > 2 else "cosim67_code.npy"

ppm = np.load(rf"{LT}\{LUTF}")
K2TRIM = float(os.environ.get("K2TRIM", "1"))   # R116: scale the LUT bow (x^2 term of a deg-4 fit); <1 = less 2nd-order predistortion
if K2TRIM != 1.0:
    _x = np.arange(1, 65) - 32.5
    _a2 = np.polyfit(_x, ppm, 4)[2]
    ppm = ppm - (1.0 - K2TRIM) * _a2 * (_x ** 2 - (_x ** 2).mean())
    print(f"K2TRIM={K2TRIM:g}: LUT bow {_a2:.4f} ppm/cell^2 scaled by {K2TRIM:g}")
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
BIN2 = int(os.environ.get("BIN2", "0"))   # P2: equal two-tone, peak sum = amp
if BIN2:
    u = (0.5 * amp * (np.sin(2 * np.pi * BIN * n / M) + np.sin(2 * np.pi * BIN2 * n / M))
         * LSB).astype(np.int64)
else:
    u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = max(1, int(round((LSB >> 1) * float(os.environ.get("DITH", "1")))))   # R109: TPDF dither half-width, x(LSB/2)
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)
u = u + int(round(float(os.environ.get("DCOFF", "0")) * LSB))              # R109: input DC offset, codes
if os.environ.get("OOB"):                # R110: DC-free breaker 1 - tone of <amp> codes at fs/<div>
    _a, _d = os.environ["OOB"].split(",")
    u = u + (float(_a) * np.sin(2 * np.pi * n / float(_d)) * LSB).astype(np.int64)
if os.environ.get("HPD"):                # R110: DC-free breaker 2 - uniform +/-<amp> code dither, <order>-th difference (zero at DC)
    _a, _k = os.environ["HPD"].split(",")
    _w = rng.uniform(-float(_a), float(_a), M)
    for _ in range(int(_k)):
        _w = np.diff(_w, prepend=0.0)
    u = u + (_w * LSB).astype(np.int64)

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
