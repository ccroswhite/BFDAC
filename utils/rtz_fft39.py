# Round 39: FFT-gate analysis for the REAL Si1555DL_N cascode deck.
# Extractor = LS harmonic fit (Round 37 lesson: coherent-windowed FFT floods
# the harmonic bins with the fundamental skirt; kaiser mainlobe 28 bins >
# 17-bin harmonic spacing). Quadratures h=1..8 + DC + linear/quadratic drift
# on the settled segment of the per-period boxcar-decimated stream.
# Reference = ideal popcount of the SAME vectors (NS/quantization floor).
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
from lp_ls import lowpass

TAG = sys.argv[1] if len(sys.argv) > 1 else "39"
M = int(sys.argv[2]) if len(sys.argv) > 2 else 16384
BIN = int(sys.argv[3]) if len(sys.argv) > 3 else 17
DISCARD = int(sys.argv[4]) if len(sys.argv) > 4 else 512
NH = 8

CODEF = {"39": "cosim37_code.npy", "41": "cosim41_code.npy",
         "42": "cosim42_code.npy", "43": "cosim37_code.npy",
         "45": "cosim45_code.npy",
         }.get(TAG, f"cosim{TAG}_code.npy"
               if os.path.exists(rf"C:\Users\ccros\Documents\LTspice\cosim{TAG}_code.npy")
               else "cosim41_code.npy")
code = np.load(rf"C:\Users\ccros\Documents\LTspice\{CODEF}").astype(float)
names, data = read_raw(rf"C:\Users\ccros\Documents\LTspice\bfdac_cosim{TAG}.raw")
t = data[0]
d = data[names.index("V(diffout)")]
print(f"raw: {len(t)} points, t_end = {t[-1]*1e6:.1f} us")

pav_path = rf"C:\Users\ccros\Documents\LTspice\cosim{TAG}_pavg.npy"
if os.path.exists(pav_path):
    a = np.load(pav_path)
else:
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(pav_path, a)

LP = os.environ.get("LP", "1") == "1"     # R109: anti-leakage lowpass (lp_ls.py)

def ls_harmonics(x, label):
    x = x.astype(float)
    d0, d1 = DISCARD, len(x)
    if LP:
        x, edge = lowpass(x)
        d0, d1 = max(DISCARD, edge), len(x) - edge
    x = x[d0:d1]
    n = np.arange(len(x), dtype=float)
    ph = 2 * np.pi * BIN * (n + d0) / M
    cols = [np.ones_like(n), n / len(n), (n / len(n)) ** 2]
    for h in range(1, NH + 1):
        cols.append(np.cos(h * ph))
        cols.append(np.sin(h * ph))
    A = np.vstack(cols).T
    coef, *_ = np.linalg.lstsq(A, x, rcond=None)
    resid = x - A @ coef
    amps = np.hypot(coef[3::2], coef[4::2])
    fund = amps[0]
    # per-harmonic sensing floor: noise power that leaks into one quadrature pair
    floor = np.sqrt(2) * resid.std() / np.sqrt(len(x) / 2) / fund
    print(f"\n=== {label} ===")
    print(f"fund amp = {fund:.6g}; resid rms = {resid.std():.3g}; "
          f"per-harmonic sensing floor = {20*np.log10(floor):.1f} dBc")
    for h in range(2, NH + 1):
        fh = h * BIN / (M * Ts)
        tag = "in-band" if fh <= 20e3 else "OUT-of-band"
        print(f"  HD{h} ({fh/1e3:7.3f} kHz, {tag:11s}): "
              f"{20*np.log10(amps[h-1]/fund):7.1f} dBc")
    return amps, fund, resid

ls_harmonics(code, "IDEAL popcount (NS+DEM floor)")
gain = np.polyfit(code[DISCARD:], a[DISCARD:], 1)[0]
ls_harmonics(a / gain, f"ANALOG diffout, cosim{TAG} (boxcar decimated)")
