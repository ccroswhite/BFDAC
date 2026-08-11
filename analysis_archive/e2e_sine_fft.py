# Round 30 #29: FFT analysis of the RTL e2e sine capture (tb_e2e_sine.sv).
# Reads sim_run/e2e_dem_l.txt (65536 DEM selection words at the 6.144 MHz
# update rate), forms the unit-weight cell sum (popcount = code), and
# measures in-band signal/SNDR. Signal: 1031.25 Hz coherent (bin 11 x 512/…
# = bin 11*…): N=65536 at 6.144 MHz -> bin spacing 93.75 Hz, signal bin 11.
import numpy as np

FS = 6.144e6
N = 65536
BIN = 11

words = []
with open("sim_run/e2e_dem_l.txt") as f:
    for line in f:
        words.append(int(line.strip(), 16))
assert len(words) == N, f"expected {N} lines, got {len(words)}"

code = np.array([bin(w).count("1") for w in words], dtype=float)
print(f"code stats: mean={code.mean():.2f} min={code.min():.0f} max={code.max():.0f}")

x = code - code.mean()
X = np.abs(np.fft.rfft(x)) ** 2
freqs = np.fft.rfftfreq(N, 1 / FS)

band = (freqs >= 20) & (freqs <= 20e3)
sig_p = X[BIN]
mask = band.copy()
mask[BIN] = False
# exclude +-1 bins around the carrier (tiny residual settling leakage)
mask[BIN - 1] = False
mask[BIN + 1] = False
noise_p = X[mask].sum()

# harmonics check
print(f"signal bin {BIN} ({freqs[BIN]:.2f} Hz): {10*np.log10(sig_p):.1f} dB (arb)")
for h in range(2, 6):
    hb = BIN * h
    print(f"  H{h} (bin {hb}, {freqs[hb]:.1f} Hz): {10*np.log10(X[hb]/sig_p):.1f} dBc")
pk = np.argmax(np.where(mask, X, 0))
print(f"  worst in-band spur: bin {pk} ({freqs[pk]:.1f} Hz) {10*np.log10(X[pk]/sig_p):.1f} dBc")
sndr = 10 * np.log10(sig_p / noise_p)
print(f"\nin-band (20 Hz - 20 kHz) SNDR vs carrier: {sndr:.1f} dB")
print("(carrier is -7 dBFS after the boxcar-FIR gain 0.5; add ~7 dB for dBFS-referred)")
