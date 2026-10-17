# Round 40: evaluate the full 64-code chopped run -> static level LUT.
# Discard-average method (20/40) with drift correction by interpolating the
# interleaved ref-32 segments. Saves L(N) residuals (ppm of span) to
# cosim40_inl.npy for the level-aware NS (Round 41).
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

TAGARG = sys.argv[1] if len(sys.argv) > 1 else "cosim40"
SEG = int(TAGARG.split("_s")[1]) if "_s" in TAGARG else 40
DISC, SEG0 = SEG // 2, SEG
codes = [c for c in range(1, 65) if c != 32]
if TAGARG.startswith(("cosim44lut", "cosim49lut", "cosim50lut", "cosim54lut",
                      "cosim57lut", "cosim61")):
    import random
    import re
    _m = re.search(r"lut(\d*)", TAGARG)
    seed = 43 + (int(_m.group(1)) if _m and _m.group(1) else 1)   # lut 44, lut2 45, lut3 46 ... (reorder_lut.py)
    random.Random(seed).shuffle(codes)
    # must match gen_cosim40.py shuf / shuf2
sched = []
for c in codes:
    sched += [c, 32]

RTAG = sys.argv[1] if len(sys.argv) > 1 else "cosim40"
raw = rf"C:\Users\ccros\Documents\LTspice\bfdac_{RTAG}.raw"
names, data = read_raw(raw)
t = data[0]
d = data[names.index("V(diffout)")]
nper = SEG0 + SEG * len(sched)
a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])

# segment means (position index i: 0 = SEG0 ref, then schedule entries)
segs = [(32, a[SEG0 - DISC//2:SEG0].mean(), a[SEG0 - DISC//2:SEG0].std())]
p0 = SEG0
for c in sched:
    w = a[p0 + DISC:p0 + SEG]
    segs.append((c, w.mean(), w.std()))
    p0 += SEG

ref_idx = np.array([i for i, (c, v, s) in enumerate(segs) if c == 32], float)
ref_val = np.array([v for i, (c, v, s) in enumerate(segs) if c == 32])
ref_mean = ref_val.mean()
out, sds = {32: ref_mean}, {32: ref_val.std()}
for i, (c, v, s) in enumerate(segs):
    if c == 32:
        continue
    out[c] = v - (np.interp(i, ref_idx, ref_val) - ref_mean)
    sds[c] = s

n = np.arange(1, 65, dtype=float)
va = np.array([out[c] for c in range(1, 65)])
A = np.vstack([np.ones_like(n), n]).T
coef, *_ = np.linalg.lstsq(A, va, rcond=None)
resid = va - A @ coef
span = coef[1] * 64          # SIGNED: gain is negative (diffout falls with N);
ppm = resid / span * 1e6     # ppm must be in code-domain units for the LUT
floor = np.mean([sds[c] for c in range(1, 65)]) / span * 1e6
print(f"gain {coef[1]*1e3:+.4f} mV/cell; max|INL| = {np.max(np.abs(ppm)):.2f} ppm "
      f"(floor ~{floor:.1f} ppm); refdrift_pp = {(ref_val.max()-ref_val.min())*1e6:.1f} uV")
for r in range(0, 64, 8):
    print("  " + "  ".join(f"{ppm[k]:8.2f}" for k in range(r, r + 8)))
np.save(rf"C:\Users\ccros\Documents\LTspice\{RTAG}_inl.npy", ppm)
print(f"saved {RTAG}_inl.npy (ppm-of-span residual per code 1..64)")
