# Round 30 #29: bisect the e2e distortion — FFT of the NS INPUT (paced_l,
# 48-bit signed hex) vs the DEM popcount output at the same 6.144 MHz grid.
import numpy as np

FS = 6.144e6
N = 65536
BIN = 11

def spectrum(x, label):
    x = x - x.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    sig = X[BIN]
    mask = band.copy()
    mask[BIN-1:BIN+2] = False
    sndr = 10 * np.log10(sig / X[mask].sum())
    print(f"{label}:")
    for h in range(2, 6):
        print(f"  H{h}: {10*np.log10(X[BIN*h]/sig):8.1f} dBc")
    pk = np.argmax(np.where(mask, X, 0))
    print(f"  worst spur: bin {pk} ({freqs[pk]:.0f} Hz) {10*np.log10(X[pk]/sig):.1f} dBc")
    print(f"  in-band SNDR: {sndr:.1f} dB\n")

# NS input: 48-bit signed hex
vals = []
with open("sim_run/e2e_paced_l.txt") as f:
    for line in f:
        v = int(line.strip(), 16)
        if v >= 1 << 47:
            v -= 1 << 48
        vals.append(v)
paced = np.array(vals, dtype=float)
print(f"paced stats: mean={paced.mean():.3e} min={paced.min():.3e} max={paced.max():.3e} (FS=2^47)")
spectrum(paced, "NS INPUT (paced_l — FIR+HB+volume+pacer)")

words = []
with open("sim_run/e2e_dem_l.txt") as f:
    for line in f:
        words.append(int(line.strip(), 16))
code = np.array([bin(w).count("1") for w in words], dtype=float)
spectrum(code, "DEM OUTPUT (popcount)")
