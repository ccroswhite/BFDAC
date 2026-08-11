# Exact decomposition: (f-e) = -NTF*e + t where t is the dyadic truncation
# chain. Compute t EXACTLY (x8 integer) and FFT it: does t carry the -95 floor?
import numpy as np

FRAC = 42
LSB = 1 << FRAC
N = 65536
BIN = 11
FS = 6.144e6

def run_tr(u, d):
    e1 = e2 = e3 = f1 = f2 = f3 = 0
    t8 = np.empty(N, dtype=np.int64)
    fe = np.empty(N, dtype=np.float64)
    for i in range(N):
        f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
             + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
        t8[i] = 8 * f - (12*e1 - 18*e2 + 7*e3 + 12*f1 - 6*f2 + f3)
        w = int(u[i]) + (32 << FRAC) + f
        code = (w + int(d[i])) >> FRAC
        code = 63 if code > 63 else (0 if code < 0 else code)
        e = w - (code << FRAC)
        fe[i] = (f - e) / LSB
        e3, e2, e1 = e2, e1, e
        f3, f2, f1 = f2, f1, f
    return t8, fe

n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)

freqs = np.fft.rfftfreq(N, 1 / FS)
band = (freqs >= 20) & (freqs <= 20e3)
mask = band.copy(); mask[BIN-1:BIN+2] = False
sig = (np.abs(np.fft.rfft(u/LSB - (u/LSB).mean())) ** 2)[BIN]

for seed, tag in ((1, "BAD"), (3, "GOOD")):
    R = np.random.default_rng(seed)
    d = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
    t8, fe = run_tr(u, d)
    T = np.abs(np.fft.rfft(t8 / 8 / LSB - (t8 / 8 / LSB).mean())) ** 2
    FE = np.abs(np.fft.rfft(fe - fe.mean())) ** 2
    print(f"seed {seed} {tag}: t stats rms={t8.std()/8:.2f} ulp, mean={t8.mean()/8:+.2f} ulp")
    print(f"   in-band: t = {10*np.log10(T[mask].sum()/sig):.1f} dBc | "
          f"(f-e) = {10*np.log10(FE[mask].sum()/sig):.1f} dBc")
    # t spectral character: is t WHITE or does it inherit the IIR pole gain?
    lo = (freqs >= 20) & (freqs <= 2e3)
    hi = (freqs >= 2e3) & (freqs <= 20e3)
    print(f"   t in 20-2k: {10*np.log10(T[lo].sum()/sig):.1f} dBc, "
          f"2k-20k: {10*np.log10(T[hi].sum()/sig):.1f} dBc")
