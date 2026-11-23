# Discriminator: is the -95 dB "bad mode" a RECTANGULAR-WINDOW EDGE ARTIFACT?
# The noise state is not periodic across the window even when the sine is
# coherent; the FFT edge term can swamp a triple-DC-zero-shaped floor.
# Hann-windowed measurement of the SAME sequences: artifact vanishes if so.
import numpy as np

FRAC = 42
LSB = 1 << FRAC
N = 65536
BIN = 11
FS = 6.144e6

def run_y(u, d):
    e1 = e2 = e3 = f1 = f2 = f3 = 0
    y = np.empty(N, dtype=np.float64)
    for i in range(N):
        f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
             + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
        w = int(u[i]) + (32 << FRAC) + f
        code = (w + int(d[i])) >> FRAC
        code = 63 if code > 63 else (0 if code < 0 else code)
        e = w - (code << FRAC)
        y[i] = code
        e3, e2, e1 = e2, e1, e
        f3, f2, f1 = f2, f1, f
    return y

def sndr_win(y, window):
    x = y - y.mean()
    if window:
        wn = np.hanning(len(x))
        x = x * wn
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(len(y), 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy()
    k = 3 if window else 1          # wider exclusion for Hann main lobe
    mask[BIN - k:BIN + k + 1] = False
    sig = X[BIN - k:BIN + k + 1].sum()
    return 10 * np.log10(sig / X[mask].sum())

n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)

for seed, tag in ((1, "BAD?"), (2, "BAD?"), (3, "GOOD")):
    R = np.random.default_rng(seed)
    d = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
    y = run_y(u, d)
    print(f"seed {seed} ({tag}): rect={sndr_win(y, False):7.1f} dB   "
          f"hann={sndr_win(y, True):7.1f} dB")
