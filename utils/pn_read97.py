# P3 readout: sidebands at fund +/- fm of the DIFFERENTIAL record
# pavg(97) - pavg(93) (same stream/plant; deterministic content cancels).
# Compares against the time-warp and charge-modulation predictions.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

LT = r"C:\Users\ccros\Documents\LTspice"
M, DISCARD, BIN, FM_BIN = 16384, 512, 37, 3
A, TW = 50e-12, 6 * Ts / 8

def pavg(tag):
    p = rf"{LT}\cosim{tag}_pavg.npy"
    if os.path.exists(p):
        return np.load(p)[:M]
    names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
    t, d = data[0], data[names.index("V(diffout)")]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(p, a)
    return a

ref, jit = pavg("93"), pavg("97")
code = np.load(rf"{LT}\cosim93_code.npy").astype(float)[:M]
gain = np.polyfit(code[DISCARD:], ref[DISCARD:], 1)[0]
e = (jit - ref)[DISCARD:] / gain
n = np.arange(len(e), dtype=float) + DISCARD
cols = [np.ones_like(n), n / M]
bins = [BIN - FM_BIN, BIN + FM_BIN, BIN, FM_BIN, 2 * BIN - FM_BIN, 2 * BIN + FM_BIN]
for b in bins:
    ph = 2 * np.pi * b * n / M
    cols += [np.cos(ph), np.sin(ph)]
coef, *_ = np.linalg.lstsq(np.vstack(cols).T, e, rcond=None)
resid = e - np.vstack(cols).T @ coef
amps = np.hypot(coef[2::2], coef[3::2])
fund = 28.0 * 10 ** (-1 / 20)
fsig = BIN / (M * Ts)
floor = np.sqrt(2) * resid.std() / np.sqrt(len(e) / 2) / fund
print(f"differential resid rms {resid.std():.3g} code units; per-bin sensing floor {20*np.log10(floor):.1f} dBc")
print(f"prediction per sideband: time-warp {20*np.log10(2*np.pi*fsig*A/2):.1f} dBc, "
      f"charge-modulation {20*np.log10(A/TW/2):.1f} dBc")
for b, a in zip(bins, amps):
    print(f"  bin {b:4d} ({b/(M*Ts)/1e3:7.3f} kHz): {20*np.log10(a/fund):7.1f} dBc")
