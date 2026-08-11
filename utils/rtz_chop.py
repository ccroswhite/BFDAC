# Round 35: drift-chopped INL/DNL analysis of the continuous-transient deck.
# - per-period exact averages a(k) for all 184 periods
# - segment map: seg0 = 24 periods @ref(32), then 16 x 10 periods,
#   codes [1,32,8,32,16,32,31,32,32,32,33,32,48,32,64,32]
# - per segment: discard first 5 periods (termination tau 336ns ~ 2 periods),
#   value = mean of last 5; within-segment drift check = (last period - period 6)
# - chop correction: each measurement segment gets the mean of its two
#   neighboring ref segments subtracted (relative to global ref mean)
# - outputs: ref drift trace (what chopping removed), corrected INL fit,
#   DNL at 31->32->33, error bars from within-segment scatter
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim35.raw"
SCHED = [1, 32, 8, 32, 16, 32, 31, 32, 32, 32, 33, 32, 48, 32, 64, 32]
SEG0, SEGP, DISC = 24, 10, 5

names, data = read_raw(RAW)
t = data[0]
d = data[names.index("V(diffout)")]

nper = SEG0 + SEGP * len(SCHED)
a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])

# segment values
segs = []  # (code, value, sd, drift)
p0 = SEG0
# seg0 ref tail as the first ref point
segs.append((32, a[SEG0 - 5:SEG0].mean(), a[SEG0 - 5:SEG0].std(), a[SEG0 - 1] - a[SEG0 - 6]))
for code in SCHED:
    w = a[p0 + DISC:p0 + SEGP]
    segs.append((code, w.mean(), w.std(), a[p0 + SEGP - 1] - a[p0 + DISC]))
    p0 += SEGP

refs = [(i, v) for i, (c, v, s, dr) in enumerate(segs) if c == 32]
meas = [(i, c, v, s, dr) for i, (c, v, s, dr) in enumerate(segs) if c != 32 or i in (0,)]
ref_idx = np.array([i for i, v in refs], float)
ref_val = np.array([v for i, v in refs])
ref_mean = ref_val.mean()

print("=== ref (N=32) drift trace: what chopping removes ===")
print("  seg idx: " + "  ".join(f"{int(i):3d}" for i in ref_idx))
print("  dev(uV): " + "  ".join(f"{(v-ref_mean)*1e6:+7.1f}" for v in ref_val))
print(f"  ref pk-pk drift = {(ref_val.max()-ref_val.min())*1e6:.1f} uV; per-seg sd = "
      + " ".join(f"{s*1e6:.1f}" for _, c, s in [(0, 0, x[2]) for x in segs if x[0] == 32]) + " uV")

# corrected code values (interpolate ref to each segment index)
out = {}
sds = {}
for i, (c, v, s, dr) in enumerate(segs):
    if c == 32 and i != 9:   # segment index 9 is the deliberate N=32 measurement slot
        continue
    ref_here = np.interp(i, ref_idx, ref_val)
    out[c] = v - (ref_here - ref_mean)
    sds[c] = s
print("\n=== corrected code values ===")
print(f"{'N':>3} {'vavg (V)':>12} {'seg sd (uV)':>12} {'within-seg drift (uV)':>22}")
for i, (c, v, s, dr) in enumerate(segs):
    if c == 32 and i != 9:
        continue
    print(f"{c:>3} {out[c]:12.7f} {s*1e6:12.2f} {dr*1e6:22.2f}")

# INL over the 6 comparable codes
codes = [1, 8, 16, 32, 48, 64]
n = np.array(codes, float)
va = np.array([out[c] for c in codes])
A = np.vstack([np.ones_like(n), n]).T
coef, *_ = np.linalg.lstsq(A, va, rcond=None)
resid = va - A @ coef
span = abs(coef[1] * 64)
print(f"\n=== chopped INL (gain {coef[1]*1e3:.4f} mV/cell) ===")
for c, r in zip(codes, resid):
    print(f"  N={c:<3d} INL = {r/span*1e6:8.2f} ppm ({r*1e6:+8.1f} uV)")
print(f"max |INL| = {np.max(np.abs(resid))/span*1e6:.2f} ppm; "
      f"floor est (seg sd) ~ {np.mean([sds[c] for c in codes])/abs(span)*1e6:.2f} ppm")

# DNL cross-check at midscale
lsb = coef[1]
d1 = (out[32] - out[31]) / lsb - 1
d2 = (out[33] - out[32]) / lsb - 1
print(f"\nDNL(31->32) = {d1*1e6:8.1f} ppm of LSB relative; (32->33) = {d2*1e6:8.1f} ppm")
print(f"(in ppm of SPAN: {d1/64*1e6:.3f} / {d2/64*1e6:.3f})")
