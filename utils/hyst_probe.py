# Round 46 analysis: settled level at code 24 vs approach direction
# (from 12 vs from 36), plus per-segment settled values of every bias node.
# The node whose direction-split mirrors diffout's split carries the state.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

SEG, DISC = 60, 30
NREP = 24
sched = []
for _ in range(NREP):
    sched += [12, 24, 36, 24]

names, data = read_raw(r"C:\Users\ccros\Documents\LTspice\bfdac_cosim46.raw")
t = data[0]
nodes = [n for n in names if n.startswith("V(") and n != "V(nsch)"]

nper = SEG * (1 + len(sched))
res = {}
for nd in nodes:
    d = data[names.index(nd)]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])
    segs = []
    p0 = SEG
    for c in sched:
        segs.append((c, a[p0 + DISC:p0 + SEG].mean()))
        p0 += SEG
    # code-24 segments: even pattern index 1 (from 12), index 3 (from 36)
    from12 = np.array([v for i, (c, v) in enumerate(segs) if c == 24 and i % 4 == 1])
    from36 = np.array([v for i, (c, v) in enumerate(segs) if c == 24 and i % 4 == 3])
    # discard first rep (global settling), report split
    d12, d36 = from12[1:], from36[1:]
    split = d12.mean() - d36.mean()
    sem = np.sqrt(d12.std()**2/len(d12) + d36.std()**2/len(d36))
    res[nd] = (split, sem, d12.mean())
    print(f"{nd:14s}: from12-from36 = {split*1e6:+9.2f} uV "
          f"(sem {sem*1e6:6.2f}) | level {d12.mean():+.5f} V")

gain = 30.978e-3 * 64  # V span
s, _, _ = res["V(diffout)"]
print(f"\ndiffout split = {s/gain*1e6:+.1f} ppm of span "
      f"(Round 40 fwd/rev zone showed +/-25ppm)")
