# Round 30: replay captured paced_l WITH the captured in-system dither.
# Isolates whether the RTL dither generator explains the 84 dB in-system
# floor (replay w/ ideal dither gave 135.9 dB).
import numpy as np
from ns_ef3_gen import run, LSB, N, BIN, FS

def read_hex(path, bits):
    vals = []
    with open(path) as f:
        for line in f:
            v = int(line.strip(), 16)
            if v >= 1 << (bits - 1):
                v -= 1 << bits
            vals.append(v)
    return np.array(vals, dtype=np.int64)

u = read_hex("sim_run/e2e_paced_l.txt", 48)
d = read_hex("sim_run/e2e_dither_l.txt", 42)   # 42-bit signed (44-bit field, top pad)
print(f"dither stats: mean={d.mean()/LSB:+.4f} lv  rms={d.std()/LSB:.4f} lv  "
      f"min={d.min()/LSB:.3f} max={d.max()/LSB:.3f}")
# dither spectrum: white?
D = np.abs(np.fft.rfft(d - d.mean()))**2
freqs = np.fft.rfftfreq(N, 1/FS)
band = (freqs >= 20) & (freqs <= 20e3)
print(f"dither in-band power fraction: {D[band].sum()/D[1:].sum():.4f} "
      f"(white would be {band.sum()/ (len(freqs)-1):.4f})")

y = run(u, d)
x = y - y.mean()
X = np.abs(np.fft.rfft(x)) ** 2
mask = band.copy()
mask[BIN-1:BIN+2] = False
print(f"replay w/ captured dither: SNDR={10*np.log10(X[BIN]/X[mask].sum()):.1f} dB, "
      f"code range {y.min()}..{y.max()}")
