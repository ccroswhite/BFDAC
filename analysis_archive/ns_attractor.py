# Round 30 resume: isolate the state-dependent EF3 noise regime in pure python.
# EXP1: ideal sine, zero state vs state harvested from the real (captured) run.
# EXP2: dither amplitude / pole variants if EXP1 reproduces the bad mode.
import numpy as np
from ns_ef3_gen import step, run, FRAC, LSB, N, BIN, FS

def read_hex(path, bits):
    out = []
    with open(path) as f:
        for line in f:
            v = int(line.strip(), 16)
            if v >= 1 << (bits - 1):
                v -= 1 << bits
            out.append(v)
    return np.array(out, dtype=np.int64)

def sndr(y):
    x = y - y.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy()
    mask[BIN-1:BIN+2] = False
    return 10 * np.log10(X[BIN] / X[mask].sum())

def run_from(u_seq, d_seq, st):
    y = np.empty(len(u_seq), dtype=np.int64)
    for i in range(len(u_seq)):
        y[i], st = step(int(u_seq[i]), int(d_seq[i]), st)
    return y, st

# captured (from-reset) streams: harvest the mid-run state
u_cap = read_hex("sim_run/e2e_paced_l.txt", 48)
d_cap = read_hex("sim_run/e2e_dither_l.txt", 42)
_, st_real = run_from(u_cap[:8192], d_cap[:8192], (0,) * 6)
print("harvested state (levels):", [f"{s/LSB:+.3f}" for s in st_real])

# ideal coherent sine + fresh white dither
RNG = np.random.default_rng(7)
HD = LSB >> 1
n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
d = (RNG.integers(0, HD, N) + RNG.integers(0, HD, N) - HD).astype(np.int64)

y0, _ = run_from(u, d, (0,) * 6)
y1, _ = run_from(u, d, st_real)
print(f"EXP1 ideal sine: zero-state SNDR={sndr(y0):.1f} dB | real-state SNDR={sndr(y1):.1f} dB")

# EXP2: full +-1 LSB TPDF, sweep states and seeds — must be uniformly clean
print("EXP2 (+-1 LSB TPDF):")
for seed in (1, 2, 3):
    R = np.random.default_rng(seed)
    d1 = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
    ya, _ = run_from(u, d1, (0,) * 6)
    yb, _ = run_from(u, d1, st_real)
    print(f"  seed {seed}: zero-state {sndr(ya):.1f} dB | real-state {sndr(yb):.1f} dB")

# control: +-0.5 LSB across seeds (how fragile is it?)
print("EXP2b (+-0.5 LSB control):")
for seed in (1, 2, 3):
    R = np.random.default_rng(seed)
    dh = (R.integers(0, HD, N) + R.integers(0, HD, N) - HD).astype(np.int64)
    ya, _ = run_from(u, dh, (0,) * 6)
    print(f"  seed {seed}: zero-state {sndr(ya):.1f} dB")

# EXP3: anatomy of a 95.0 dB failure
R = np.random.default_rng(2)
dh = (R.integers(0, HD, N) + R.integers(0, HD, N) - HD).astype(np.int64)
y, _ = run_from(u, dh, (0,) * 6)
x = y - y.mean()
X = np.abs(np.fft.rfft(x)) ** 2
freqs = np.fft.rfftfreq(N, 1 / FS)
band = (freqs >= 20) & (freqs <= 20e3)
mask = band.copy(); mask[BIN-1:BIN+2] = False
worst = np.argsort(np.where(mask, X, 0))[::-1][:8]
print("EXP3 worst in-band bins (seed 2 failure):")
for b in worst:
    h = b / BIN
    print(f"  bin {b} ({freqs[b]:.0f} Hz, {h:.2f}x fund): {10*np.log10(X[b]/X[BIN]):.1f} dBc")
inband_floor = X[mask].sum() - X[worst].sum()
print(f"  residual floor (ex-top8): {10*np.log10(inband_floor/X[BIN]):.1f} dBc total")
