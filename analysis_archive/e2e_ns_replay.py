# Round 30: replay the CAPTURED in-system NS input (paced_l) through the
# integer-exact EF3 reference. If the replay is clean (~136 dB) the RTL NS
# integration differs from the model; if dirty, the input itself is the issue.
import numpy as np
from ns_ef3_gen import run, FRAC, LSB, N, BIN, FS

vals = []
with open("sim_run/e2e_paced_l.txt") as f:
    for line in f:
        v = int(line.strip(), 16)
        if v >= 1 << 47:
            v -= 1 << 48
        vals.append(v)
u = np.array(vals, dtype=np.int64)
print(f"input peak = {np.abs(u).max()/LSB:.2f} levels")

RNG = np.random.default_rng(5)
HD = LSB >> 1
dith = (RNG.integers(0, HD, N) + RNG.integers(0, HD, N) - HD).astype(np.int64)
y = run(u, dith)

x = y - y.mean()
X = np.abs(np.fft.rfft(x)) ** 2
freqs = np.fft.rfftfreq(N, 1 / FS)
band = (freqs >= 20) & (freqs <= 20e3)
mask = band.copy()
mask[BIN-1:BIN+2] = False
print(f"replay: SNDR={10*np.log10(X[BIN]/X[mask].sum()):.1f} dB, code range {y.min()}..{y.max()}")
