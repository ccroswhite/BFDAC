# Bin-level verification: (f-e) must equal -NTF*e (+t/B, -300 dB). Compare
# PSDs and the residual (f-e)+NTF*e in the bad mode. Whichever diverges holds
# the bug.
import numpy as np
from scipy.signal import lfilter

FRAC = 42
LSB = 1 << FRAC
N = 65536
BIN = 11
FS = 6.144e6

def run_tr(u, d):
    e1 = e2 = e3 = f1 = f2 = f3 = 0
    fe = np.empty(N, dtype=np.float64)
    ee = np.empty(N, dtype=np.float64)
    for i in range(N):
        f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
             + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
        w = int(u[i]) + (32 << FRAC) + f
        code = (w + int(d[i])) >> FRAC
        code = 63 if code > 63 else (0 if code < 0 else code)
        e = w - (code << FRAC)
        fe[i] = (f - e) / LSB
        ee[i] = e / LSB
        e3, e2, e1 = e2, e1, e
        f3, f2, f1 = f2, f1, f
    return fe, ee

n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
R = np.random.default_rng(1)   # BAD seed
d = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
fe, ee = run_tr(u, d)

ntfe = lfilter([1.0, -3.0, 3.0, -1.0], [1.0, -1.5, 0.75, -0.125], ee)
res = fe + ntfe
print(f"residual (f-e)+NTF*e: rms={res.std():.3e} lv max={np.abs(res).max():.3e} lv")

freqs = np.fft.rfftfreq(N, 1 / FS)
sig = (np.abs(np.fft.rfft(u/LSB - (u/LSB).mean())) ** 2)[BIN]
for name, x in (("f-e", fe), ("-NTF*e", -ntfe), ("residual", res)):
    X = np.abs(np.fft.rfft(x - x.mean())) ** 2
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy(); mask[BIN-1:BIN+2] = False
    print(f"{name:>9}: in-band {10*np.log10(X[mask].sum()/sig):.1f} dBc")

# e PSD profile: average dBc/bin in octave bands (is e white in fine structure?)
E = np.abs(np.fft.rfft(ee - ee.mean())) ** 2
for f0, f1 in ((20, 2000), (2000, 10000), (10000, 20000), (20000, 100000), (1e6, 3e6)):
    m = (freqs >= f0) & (freqs <= f1)
    print(f"e PSD {f0/1e3:g}-{f1/1e3:g} kHz: {10*np.log10(E[m].mean()/sig):.1f} dBc/bin")
