# Round 64: DYNAMIC predistortion. The EF3 quantizer feedback subtracts the
# ACTUAL emitted level including the measured pair-transition dynamic error:
#   L(prev, code) = code + err_static(code) + E_dyn(prev, code)
# E_dyn measured on a 9x9 grid (R63, cosim63_Enl.npy, volts at diffout),
# bilinearly interpolated to 64x64 and converted to code units via the
# static gain. Loop shapes both static AND dynamic error out of band.
import numpy as np
import sys
import os
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 16384
BIN = int(os.environ.get("BIN", "17"))
LT = r"C:\Users\ccros\Documents\LTspice"

LUTF = sys.argv[1] if len(sys.argv) > 1 else "cosim55lut_inl.npy"
OUTF = sys.argv[2] if len(sys.argv) > 2 else "cosim64_code.npy"

ppm = np.load(rf"{LT}\{LUTF}")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)

GAIN_V = -0.0310            # V/cell (R54 static gain, sign included)
Enl_V = np.load(rf"{LT}\cosim63_Enl.npy")
grid = np.load(rf"{LT}\cosim63_grid.npy").astype(float)
Enl_code = Enl_V / GAIN_V   # code units

from scipy.interpolate import RegularGridInterpolator
itp = RegularGridInterpolator((grid, grid), Enl_code,
                              bounds_error=False, fill_value=None)
aa, bb = np.meshgrid(np.arange(64), np.arange(64), indexing="ij")
ED = itp(np.stack([aa.ravel(), bb.ravel()], axis=1)).reshape(64, 64)
np.fill_diagonal(ED, 0.0)   # null control says no-transition error ~ 0
if os.environ.get("DYNSIGN") == "-1":
    ED = -ED            # R65c sign discriminator
EDFX = np.round(ED * LSB).astype(np.int64)
print(f"ELUT: max|E_dyn| {np.abs(ED).max():.4f} code units "
      f"({np.abs(ED).max()/64*1e6:.0f} ppm of span)")

rng = np.random.default_rng(5)
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

st = (0, 0, 0, 0, 0, 0)
prev = 32
out = np.empty(M, dtype=np.int64)
for i in range(M):
    e1, e2, e3, f1, f2, f3 = st
    f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
         + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
    w = int(u[i]) + (32 << FRAC) + f
    d = w + int(dith[i])
    code = d >> FRAC
    code = 0 if code < 0 else (63 if code > 63 else code)
    e = w - (code << FRAC) - int(LUT[code]) - int(EDFX[prev, code])
    e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
    st = (e, e1, e2, f, f1, f2)
    out[i] = code
    prev = code
np.save(rf"{LT}\{OUTF}", out)
print(f"saved {OUTF}; code range {out.min()}..{out.max()}, BIN={BIN}")
