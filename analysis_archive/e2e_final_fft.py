# Round 30 final e2e measurement with a deep-sidelobe Kaiser window (beta=38,
# sidelobes < -280 dB) — rectangular/Hann windows leak the out-of-band shaped
# noise into the audio band (the earlier "84 dB / bimodal 95 dB" scare was
# entirely this artifact; Hann floors at ~116 dB).
import numpy as np
from scipy.signal.windows import kaiser

N = 65536
BIN = 11
FS = 6.144e6
BETA = 38

def sndr_kaiser(y, label):
    x = np.asarray(y, dtype=np.float64)
    x = x - x.mean()
    w = kaiser(len(x), BETA)
    X = np.abs(np.fft.rfft(x * w)) ** 2
    freqs = np.fft.rfftfreq(len(x), 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    k = 12                       # Kaiser beta=38 main lobe half-width ~12 bins
    mask = band.copy()
    mask[max(BIN - k, 0):BIN + k + 1] = False
    sig = X[max(BIN - k, 0):BIN + k + 1].sum()
    print(f"{label:>28}: SNDR = {10*np.log10(sig / X[mask].sum()):6.1f} dB")

# 1. python EF3 reference across seeds (should now be unimodal)
from ns_window_check import run_y, u   # reuses model + stimulus (runs its prints)

# 2. captured RTL streams (no-skip capture from yesterday)
words = [int(l.strip(), 16) for l in open("sim_run/e2e_dem_l.txt")]
code = np.array([bin(w).count("1") for w in words], dtype=np.float64)
sndr_kaiser(code, "RTL DEM popcount (in-system)")

def read_hex(path, bits):
    out = []
    for line in open(path):
        v = int(line.strip(), 16)
        if v >= 1 << (bits - 1):
            v -= 1 << bits
        out.append(v)
    return np.array(out, dtype=np.float64)

paced = read_hex("sim_run/e2e_paced_l.txt", 48) / (1 << 42)
sndr_kaiser(paced, "RTL NS input (paced_l)")

R = np.random.default_rng(1)
LSB = 1 << 42
d = (R.integers(0, LSB, N) + R.integers(0, LSB, N) - LSB).astype(np.int64)
sndr_kaiser(run_y(u, d), "python EF3 (seed 1)")
