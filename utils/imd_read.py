# P2 (2026-09-12): two-tone IMD readout for a cosim gate. Same LS estimator as
# rtz_fft39.ls_harmonics but the basis is all |i*f1 + j*f2| products up to
# order NORD (2nd: f2-f1, f1+f2, 2f1, 2f2; 3rd: 2f1-f2, 2f2-f1, ...), plus the
# ideal-popcount reference. dCS benchmark: 19+20 kHz at -3 dBFS peak, 1 kHz
# difference product -130 dB.
#   python imd_read.py <tag> <M> <BIN1> <BIN2> [DISCARD=512]
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
from lp_ls import lowpass

TAG = sys.argv[1]
M = int(sys.argv[2])
B1, B2 = int(sys.argv[3]), int(sys.argv[4])
DISCARD = int(sys.argv[5]) if len(sys.argv) > 5 else 512
NORD = 3
LT = r"C:\Users\ccros\Documents\LTspice"
LP = os.environ.get("LP", "1") == "1"     # R109: anti-leakage lowpass (lp_ls.py)

code = np.load(rf"{LT}\cosim{TAG}_code.npy").astype(float)[:M]
pav_path = rf"{LT}\cosim{TAG}_pavg.npy"
if os.path.exists(pav_path):
    a = np.load(pav_path)
else:
    names, data = read_raw(rf"{LT}\bfdac_cosim{TAG}.raw")
    t, d = data[0], data[names.index("V(diffout)")]
    print(f"raw: {len(t)} points, t_end = {t[-1]*1e6:.1f} us")
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(pav_path, a)

# product table: (i, j) -> bin |i*B1 + j*B2|, order |i|+|j| <= NORD, bin > 0
prods = {}
for i in range(-NORD, NORD + 1):
    for j in range(-NORD, NORD + 1):
        o = abs(i) + abs(j)
        if o == 0 or o > NORD:
            continue
        b = i * B1 + j * B2
        if b <= 0 or b >= M // 2:
            continue
        prods.setdefault(b, (o, i, j))
bins = sorted(prods)

def ls(x, label):
    x = x.astype(float)
    d0, d1 = DISCARD, len(x)
    if LP:
        x, edge = lowpass(x)
        d0, d1 = max(DISCARD, edge), len(x) - edge
    x = x[d0:d1]
    n = np.arange(len(x), dtype=float)
    cols = [np.ones_like(n), n / len(n), (n / len(n)) ** 2]
    for b in bins:
        ph = 2 * np.pi * b * (n + d0) / M
        cols += [np.cos(ph), np.sin(ph)]
    A = np.vstack(cols).T
    coef, *_ = np.linalg.lstsq(A, x, rcond=None)
    resid = x - A @ coef
    cplx = dict(zip(bins, coef[3::2] - 1j * coef[4::2]))
    amps = {b: abs(v) for b, v in cplx.items()}
    ref = amps[B1] + amps[B2]                    # peak of the two-tone envelope
    floor = np.sqrt(2) * resid.std() / np.sqrt(len(x) / 2) / ref
    print(f"\n=== {label} ===")
    print(f"tones {amps[B1]:.5g} / {amps[B2]:.5g} (re peak sum); resid rms {resid.std():.3g}; "
          f"sensing floor {20*np.log10(floor):.1f} dB")
    for b in bins:
        o, i, j = prods[b]
        if b in (B1, B2):
            continue
        f = b / (M * Ts)
        inb = "in-band" if f <= 20e3 else "OUT-of-band"
        print(f"  {i:+d}f1{j:+d}f2  ord{o}  ({f/1e3:7.3f} kHz, {inb:11s}): "
              f"{20*np.log10(amps[b]/ref):7.1f} dB")
    return cplx, ref

cs, rs = ls(code, "IDEAL popcount (NS+DEM floor)")
gain = np.polyfit(code[DISCARD:], a[DISCARD:], 1)[0]
ca, ra = ls(a / gain, f"ANALOG diffout, cosim{TAG}")

# R109: stream vs analog per product. dphase ~0 and equal magnitude = the plant
# merely reproduced injected predistortion; plant-own = analog - stream is what
# the plant itself adds (what a correct kernel would have to cancel).
print(f"\n=== stream -> analog, cosim{TAG} (analog scaled to stream tones) ===")
sc = ra / rs
for b in bins:
    o, i, j = prods[b]
    if b in (B1, B2) or b / (M * Ts) > 20e3:
        continue
    s, y = cs[b] * sc, ca[b]
    print(f"  {i:+d}f1{j:+d}f2  ord{o}: stream {20*np.log10(abs(s)/ra):7.1f}  analog {20*np.log10(abs(y)/ra):7.1f} dB  "
          f"dphase {np.angle(y/s, deg=True):7.1f} deg  | plant-own {20*np.log10(abs(y-s)/ra):7.1f} dB")
