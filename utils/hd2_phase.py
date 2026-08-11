# Round 58: complex HD2/HD3 comparison between gates (e.g. normal 55 vs
# inverted 58). Same LS fit as rtz_fft39 but reports complex harmonic
# coefficients (magnitude dBc + phase deg, absolute time reference - both
# runs share the same period grid, so phases are directly comparable).
# Signal-driven even-order: HD2 identical in both. Fundamental-tracking
# artifact: HD2 flips 180deg with the inverted fundamental.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

M = 16384
BIN = int(os.environ.get("BIN", "17"))
DISCARD = 512
NH = 8
LT = r"C:\Users\ccros\Documents\LTspice"

def fit(x):
    x = x[DISCARD:].astype(float)
    n = np.arange(len(x), dtype=float)
    ph = 2 * np.pi * BIN * (n + DISCARD) / M
    cols = [np.ones_like(n), n / len(n), (n / len(n)) ** 2]
    for h in range(1, NH + 1):
        cols.append(np.cos(h * ph))
        cols.append(np.sin(h * ph))
    A = np.vstack(cols).T
    coef, *_ = np.linalg.lstsq(A, x, rcond=None)
    return coef[3::2] - 1j * coef[4::2]   # complex amp per harmonic (h=1..NH)

for tag in sys.argv[1:] or ("55", "58"):
    pav_path = rf"{LT}\cosim{tag}_pavg.npy"
    if os.path.exists(pav_path):
        a = np.load(pav_path)
    else:
        names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
        t = data[0]
        d = data[names.index("V(diffout)")]
        a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
        np.save(pav_path, a)
    code = np.load(rf"{LT}\cosim{tag}_code.npy").astype(float)
    gain = np.polyfit(code[DISCARD:], a[DISCARD:], 1)[0]
    h = fit(a / gain)
    print(f"cosim{tag}: fund {abs(h[0]):.4f} @ {np.angle(h[0], deg=True):+7.2f} deg")
    for k in (2, 3):
        print(f"  HD{k}: {20*np.log10(abs(h[k-1])/abs(h[0])):7.1f} dBc "
              f"@ {np.angle(h[k-1], deg=True):+7.2f} deg")
