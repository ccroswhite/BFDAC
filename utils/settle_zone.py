# Round 47b: settling-shape autopsy from the SEG=160 chopped run.
# For zone codes (23,24,25,27,28) and controls (8,40,55): per-period level
# across the 160-period segment, drift-corrected by neighbor refs. If the
# zone has a slow tail or bistability it shows directly.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
import random

SEG, SEG0 = 160, 160
codes = [c for c in range(1, 65) if c != 32]
random.Random(44).shuffle(codes)
sched = []
for c in codes:
    sched += [c, 32]

names, data = read_raw(r"C:\Users\ccros\Documents\LTspice\bfdac_cosim44lut_s160.raw")
t = data[0]
d = data[names.index("V(diffout)")]
nper = SEG0 + SEG * len(sched)
pav = r"C:\Users\ccros\Documents\LTspice\cosim44lut_s160_pavg.npy"
if os.path.exists(pav):
    a = np.load(pav)
else:
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])
    np.save(pav, a)

span = 30.978e-3 * 64
for target in (23, 24, 25, 27, 28, 8, 40, 55):
    pos = sched.index(target)
    p0 = SEG0 + pos * SEG
    seg = a[p0:p0 + SEG]
    ref_after = a[p0 + SEG + SEG//2:p0 + 2*SEG].mean()
    # quarter-means through the segment, relative to final quarter (ppm)
    q = [seg[k*40+10:(k+1)*40].mean() for k in range(4)]
    rel = [(x - q[3]) / span * 1e6 for x in q]
    tail = (seg[40:100].mean() - seg[100:160].mean()) / span * 1e6
    print(f"code {target:2d}: quarters rel final = "
          f"{rel[0]:+7.2f} {rel[1]:+7.2f} {rel[2]:+7.2f} ppm | "
          f"mid-vs-late tail {tail:+6.2f} ppm | seg std {seg[20:].std()*1e6:6.1f} uV")
