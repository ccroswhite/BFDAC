# Identity probe: for EF3, exactly y*LSB = u + 32*LSB + f - e whenever the
# output doesn't clip and e-clamp doesn't fire. The extra -95 dBc floor in the
# bad mode must live in the residual (clip/clamp injections) or the identity
# holds and the floor rides on f-e (truncation). Count events, FFT residual.
import numpy as np

FRAC = 42
LSB = 1 << FRAC
CLAMP = 63 * LSB
N = 65536
BIN = 11
FS = 6.144e6

def run_full(u, d):
    e1 = e2 = e3 = f1 = f2 = f3 = 0
    y = np.empty(N, dtype=np.int64)
    ftr = np.empty(N, dtype=np.int64)
    etr = np.empty(N, dtype=np.int64)
    clips = clamps = 0
    for i in range(N):
        f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
             + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
        w = int(u[i]) + (32 << FRAC) + f
        code = (w + int(d[i])) >> FRAC
        if code > 63:
            code = 63; clips += 1
        elif code < 0:
            code = 0; clips += 1
        e = w - (code << FRAC)
        if e > CLAMP:
            e = CLAMP; clamps += 1
        elif e < -CLAMP:
            e = -CLAMP; clamps += 1
        y[i] = code; ftr[i] = f; etr[i] = e
        e3, e2, e1 = e2, e1, e
        f3, f2, f1 = f2, f1, f
    return y, ftr, etr, clips, clamps

n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)

def spec_stats(x, label):
    X = np.abs(np.fft.rfft(x - x.mean())) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy(); mask[BIN-1:BIN+2] = False
    sig = (np.abs(np.fft.rfft(u/LSB - (u/LSB).mean())) ** 2)[BIN]
    print(f"  {label}: in-band power vs fundamental = "
          f"{10*np.log10(X[mask].sum()/sig):.1f} dBc")

for seed, tag in ((1, "BAD"), (3, "GOOD")):
    R = np.random.default_rng(seed)
    d = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
    y, ftr, etr, clips, clamps = run_full(u, d)
    ident = y.astype(object) * LSB - (u.astype(object) + (32 << FRAC) + ftr.astype(object) - etr.astype(object))
    ident = np.array([int(v) for v in ident], dtype=np.int64)
    print(f"seed {seed} ({tag}): clips={clips} clamps={clamps} "
          f"max|ident|={np.abs(ident).max()} code {y.min()}..{y.max()}")
    # noise component riding on (f - e): the shaped part is -NTF*e; isolate the
    # truncation by comparing f to the exact rational filter applied in floats
    spec_stats((ftr - etr) / LSB, f"(f-e)/LSB   {tag}")
    spec_stats(ftr / LSB, f"f/LSB       {tag}")
    spec_stats(etr / LSB, f"e/LSB       {tag}")
