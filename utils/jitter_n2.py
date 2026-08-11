# N2 analysis: DIFFERENTIAL jitter floor. Gates 78a/78b share the exact
# gate-77 stream, plant and integration grid - pavg(78x)-pavg(77) is the pure
# jitter-induced per-period error (deterministic content cancels exactly,
# so the reading is NOT limited by the -81dBc single-gate sensing floor).
# In-band noise of the difference, Kaiser b38, reported re -1dBFS fund and
# in nVrms against the 245 nVrms budget.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
from scipy.signal.windows import kaiser

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
DISCARD = 512
FS = 1 / Ts
VRMS_FUND_M1DB = 0.62

def pavg(tag):
    p = rf"{LT}\cosim{tag}_pavg.npy"
    if os.path.exists(p):
        return np.load(p)[:M]
    names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
    t = data[0]
    d = data[names.index("V(diffout)")]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(p, a)
    return a

ref = pavg("77")
code = np.load(rf"{LT}\cosim77_code.npy").astype(float)[:M]
gain = np.polyfit(code[DISCARD:], ref[DISCARD:], 1)[0]
fund = 28.0 * 10 ** (-1 / 20)

for tag, sig in (("78a", 10e-12), ("78b", 1e-12), ("78c", 0.0)):
    e = (pavg(tag) - ref)[DISCARD:] / gain      # code units
    e = e - e.mean()
    N = len(e)
    nn = np.arange(N) / N
    e_d = e - np.polyval(np.polyfit(nn, e, 3), nn)   # inter-run drift removal
    freqs = np.fft.rfftfreq(N, Ts)
    band = (freqs >= 20) & (freqs <= 20e3)
    w = kaiser(N, 38)
    cg = (w ** 2).sum() / N
    for lbl, x in (("raw ", e), ("-drift", e_d)):
        X = np.abs(np.fft.rfft(x * w)) ** 2 / (N / 2) / N / cg
        pin = X[band].sum()
        snr = 10 * np.log10((fund ** 2 / 2) / pin)
        ptot = (x ** 2).mean()
        wfrac = 10 * np.log10(pin / ptot) + 10 * np.log10(0.5 / Ts / 19980)
        print(f"{tag} sigma_t {sig*1e12:5.1f} ps [{lbl:6s}]: total rms "
              f"{np.sqrt(ptot)/fund*1e6:7.2f} ppm; in-band {snr:6.1f} dB re -1dBFS "
              f"({VRMS_FUND_M1DB*10**(-snr/20)*1e9:8.1f} nVrms; budget 245); "
              f"in-band excess over white {wfrac:+5.1f} dB")
