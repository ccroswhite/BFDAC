# Round 42: IN-SITU calibration iteration (bench-realistic). The step-response
# LUT leaves a +-25ppm history-dependent zone (N=20-28). Under dynamic (music/
# tone) operation the effective level of each code is the average over real
# transition histories -> extract it FROM the operational run itself:
# group per-period residuals of cosim41 by code, correct the LUT, regenerate.
import numpy as np
import sys
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC\utils")
from ns_ef3_gen import LSB
from dpd_study import run_ef3   # level-aware EF3 (imports run its own study)

M = 16384
DISCARD = 512
LT = r"C:\Users\ccros\Documents\LTspice"

code41 = np.load(rf"{LT}\cosim41_code.npy")
a = np.load(rf"{LT}\cosim41_pavg.npy")
ppm = np.load(rf"{LT}\cosim40_inl.npy")

# JOINT deconvolution: y[n] = sum_k h_k c[n-k] + err(c[n]) + const.
# The output pole (12n*28R tau=336ns > Ts) smears code history into each
# period; the FIR kernel absorbs all LTI dynamics, the one-hot terms give
# the true effective static level error per code under dynamic operation.
NTAP = 12
c = code41.astype(float)
y = a.astype(float)
n0 = max(DISCARD, NTAP)
rows = np.arange(n0, M)
# NOTE: no constant column and no tap-0 column - the one-hot block spans both
# (would be rank-deficient); one-hot coefficients ARE the per-code levels.
cols = [c[rows - k] for k in range(1, NTAP + 1)]
oneh = np.zeros((len(rows), 64))
oneh[np.arange(len(rows)), code41[rows]] = 1.0
X = np.hstack([np.vstack(cols).T, oneh[:, 1:64]])   # code 0 unused
coef, *_ = np.linalg.lstsq(X, y[rows], rcond=None)
lev = coef[NTAP:]                                    # volts, codes 1..63
used = np.arange(1, 64, dtype=float)
pl = np.polyfit(used, lev, 1)
gain = pl[0]                                         # V/cell (signed)
delta_ppm = np.zeros(64)
delta_ppm[1:64] = (lev - np.polyval(pl, used)) / (gain * 64) * 1e6
print(f"gain {gain*1e3:+.4f} mV/cell; kernel h/h0: "
      f"{np.round(coef[:NTAP]/gain, 4)}")
print(f"delta rms = {delta_ppm[1:].std():.2f} ppm; "
      f"max|delta| = {np.max(np.abs(delta_ppm)):.2f} ppm at N={np.argmax(np.abs(delta_ppm))}")
for r in range(16, 32, 8):
    print("  N%2d-%2d:" % (r, r+7), "  ".join(f"{delta_ppm[k]:7.2f}" for k in range(r, r+8)))

# updated LUT (index by code 0..63; ppm array is codes 1..64 -> shift)
ppm2 = ppm.copy()
ppm2[:63] = ppm[:63] + delta_ppm[1:64]   # ppm[k-1] is code k
np.save(rf"{LT}\cosim42_inl.npy", ppm2)

err_lsb = np.zeros(65)
err_lsb[1:65] = ppm2 * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)
rng = np.random.default_rng(5)
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * 17 * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)
code42 = run_ef3(u, dith, LUT)
np.save(rf"{LT}\cosim42_code.npy", code42)
print(f"saved cosim42_code.npy; range {code42.min()}..{code42.max()}")
