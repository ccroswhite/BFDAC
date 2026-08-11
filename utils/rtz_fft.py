# Round 37: FFT-gate analysis. Per-period boxcar decimation of diffout
# (exact-boundary integration) -> Kaiser(beta=38) FFT. Reference = ideal
# popcount stream of the SAME vectors (separates NS/quantization floor from
# analog-induced error). Reports SNDR, harmonic table, in-band noise.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
from scipy.signal.windows import kaiser

M = 16384
BIN = 17
FS = 1 / Ts
DISCARD = 512          # settle: q4_base tau 2.2us ~ 14 periods; 512 >> that
BETA = 38
K = 12                 # Kaiser beta=38 mainlobe half-width (bins at full M)

code = np.load(r"C:\Users\ccros\Documents\LTspice\cosim37_code.npy").astype(float)
names, data = read_raw(r"C:\Users\ccros\Documents\LTspice\bfdac_cosim37.raw")
t = data[0]
d = data[names.index("V(diffout)")]
print(f"raw: {len(t)} points, t_end = {t[-1]*1e6:.1f} us")

a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
np.save(r"C:\Users\ccros\Documents\LTspice\cosim37_pavg.npy", a)

def spectrum(x, label):
    x = x[DISCARD:]
    x = x - x.mean()
    w = kaiser(len(x), BETA)
    cg = w.sum() / len(w)
    X = np.abs(np.fft.rfft(x * w)) ** 2
    freqs = np.fft.rfftfreq(len(x), Ts)
    df = freqs[1]
    band = (freqs >= 20) & (freqs <= 20e3)
    # signal power: mainlobe around the tone
    f0 = BIN * FS / M
    b0 = int(round(f0 / df))
    kk = K + 2
    sig = X[b0 - kk:b0 + kk + 1].sum()
    mask = band.copy()
    mask[b0 - kk:b0 + kk + 1] = False
    # harmonics
    print(f"\n=== {label} ===")
    print(f"tone {f0/1e3:.3f} kHz; SNDR(in-band, fund excl) = "
          f"{10*np.log10(sig / X[mask].sum()):.1f} dB")
    for h in range(2, 8):
        fh = h * f0
        if fh > 20e3:
            break
        bh = int(round(fh / df))
        ph = X[bh - kk:bh + kk + 1].sum()
        print(f"  HD{h} ({fh/1e3:6.3f} kHz): {10*np.log10(ph/sig):7.1f} dBc")
    hmask = mask.copy()
    for h in range(2, 8):
        bh = int(round(h * f0 / df))
        if h * f0 <= 20e3 + 2e3:
            hmask[max(bh - kk, 0):bh + kk + 1] = False
    print(f"  in-band noise (fund+harm excl): "
          f"{10*np.log10(X[hmask].sum()/sig):7.1f} dBc")
    return sig, X, freqs

s_ref, X_ref, fr = spectrum(code, "IDEAL popcount (NS+DEM floor)")
gain = np.polyfit(code[DISCARD:], a[DISCARD:], 1)[0]
s_dac, X_dac, _ = spectrum(a / gain, "ANALOG diffout (boxcar decimated, gain-normalized)")

# analog-only error stream: decimated analog minus ideal (gain-fit removed)
e = a / gain - code
e = e - e.mean()
w = kaiser(len(e[DISCARD:]), BETA)
E = np.abs(np.fft.rfft(e[DISCARD:] * w)) ** 2
freqs = np.fft.rfftfreq(len(e[DISCARD:]), Ts)
df = freqs[1]
band = (freqs >= 20) & (freqs <= 20e3)
b0 = int(round(BIN * FS / M / df))
mask = band.copy()
mask[b0 - K - 2:b0 + K + 3] = False
print(f"\nANALOG-ONLY error (analog - ideal): in-band power = "
      f"{10*np.log10(E[mask].sum()/s_ref):.1f} dBc "
      f"(this is the pure DAC-analog contribution)")
