# Round 41 (code-domain leg): LEVEL-AWARE EF3 = exact predistortion for
# static DAC INL. The NS quantizer feedback subtracts the ACTUAL level
# L(code) = code + err(code) (measured LUT, cosim40_inl.npy) instead of the
# ideal code; the loop then shapes the entire static INL out of band.
# Output stream evaluated AT THE ACTUAL LEVELS (what the analog DAC emits).
# Compares: ideal-feedback NS (uncorrected) vs level-aware NS (corrected).
import numpy as np
import sys
import os
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 16384
BIN = int(os.environ.get("BIN", "17"))
NH = 8

if len(sys.argv) < 2:
    sys.exit("usage: dpd_study.py <lut_inl.npy> [out_code.npy] [inv|dB] "
             "(TRAP 6: no default LUT - stale-plant LUTs inject static HD)")
LUTF = sys.argv[1]
ppm = np.load(rf"C:\Users\ccros\Documents\LTspice\{LUTF}")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64          # ppm of span -> LSB units
LUT = np.round(err_lsb * LSB).astype(np.int64)   # FRAC-bit fixed point

def run_ef3(u_seq, dith_seq, lut):
    st = (0, 0, 0, 0, 0, 0)
    out = np.empty(len(u_seq), dtype=np.int64)
    for i in range(len(u_seq)):
        e1, e2, e3, f1, f2, f3 = st
        f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
             + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
        w = int(u_seq[i]) + (32 << FRAC) + f
        d = w + int(dith_seq[i])
        code = d >> FRAC
        code = 0 if code < 0 else (63 if code > 63 else code)
        e = w - (code << FRAC) - int(lut[code])   # feedback vs ACTUAL level
        e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
        st = (e, e1, e2, f, f1, f2)
        out[i] = code
    return out

def ls_harmonics(x, label):
    # SNDR: Kaiser beta=38 + /-12-bin mainlobe exclusion (Round 37 methodology;
    # rect-window readings are seed-bimodal from edge leakage of shaped noise).
    # Harmonics: LS quadrature fit (robust to leakage).
    x = np.asarray(x, float)
    x = x - x.mean()
    n = np.arange(len(x), dtype=float)
    phv = 2 * np.pi * BIN * n / M
    cols = [np.ones_like(n)]
    for h in range(1, NH + 1):
        cols.append(np.cos(h * phv))
        cols.append(np.sin(h * phv))
    A = np.vstack(cols).T
    coef, *_ = np.linalg.lstsq(A, x, rcond=None)
    amps = np.hypot(coef[1::2], coef[2::2])
    fund = amps[0]
    from scipy.signal.windows import kaiser
    K = 12
    w = kaiser(M, 38)
    X = np.abs(np.fft.rfft(x * w)) ** 2
    freqs = np.fft.rfftfreq(M, 162.7604e-9)
    band = (freqs >= 20) & (freqs <= 20e3)
    sig = X[BIN - K:BIN + K + 1].sum()
    mask = band.copy()
    mask[max(BIN - K, 0):BIN + K + 1] = False
    print(f"\n=== {label} ===")
    print(f"in-band SNDR (Kaiser b38, mainlobe excl) = "
          f"{10*np.log10(sig/X[mask].sum()):.1f} dB")
    for h in range(2, 4):
        print(f"  HD{h}: {20*np.log10(amps[h-1]/fund):7.1f} dBc")

rng = np.random.default_rng(int(os.environ.get("DSEED", "5")))
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
if len(sys.argv) > 3:
    if sys.argv[3] == "inv":
        amp = -amp   # inverted-signal discriminator (Round 58)
    else:            # drive level in dB re 28 LSBpk (Round 59 amp sweep)
        amp = 28.0 * 10 ** (float(sys.argv[3]) / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

code_unc = run_ef3(u, dith, np.zeros(64, dtype=np.int64))
code_cor = run_ef3(u, dith, LUT)
actual = err_lsb[:64]  # actual level offsets indexed by code

ls_harmonics(code_unc + actual[code_unc], "UNCORRECTED NS -> actual DAC levels")
ls_harmonics(code_cor + actual[code_cor], "LEVEL-AWARE NS -> actual DAC levels")
ls_harmonics(code_cor.astype(float), "level-aware code stream at IDEAL levels (sanity)")

OUTF = sys.argv[2] if len(sys.argv) > 2 else "cosim41_code.npy"
np.save(rf"C:\Users\ccros\Documents\LTspice\{OUTF}", code_cor)
print(f"\nsaved {OUTF}; corrected code range {code_cor.min()}..{code_cor.max()}")
