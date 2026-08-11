# Round 47 analysis: level(25) vs the 2-back code X, per bias node.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

SEG, DISC = 40, 20
XS = [4, 12, 20, 28, 36, 44, 52, 60]
NREP = 6
sched = []
for r in range(NREP):
    for X in XS:
        sched += [X, 32, 25]

names, data = read_raw(r"C:\Users\ccros\Documents\LTspice\bfdac_cosim47.raw")
t = data[0]
nper = SEG * (1 + len(sched))
span = 30.978e-3 * 64

for nd in ["V(diffout)", "V(q4_base)", "V(casb_p)", "V(casb2_p)",
           "V(bus_plus)", "V(col_p)", "V(c25_s)", "V(c25_e)"]:
    d = data[names.index(nd)]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])
    lv = {X: [] for X in XS}
    p0 = SEG
    for i, c in enumerate(sched):
        if c == 25:
            X = sched[i - 2]
            lv[X].append(a[p0 + DISC:p0 + SEG].mean())
        p0 += SEG
    means = {X: np.mean(v[1:]) for X, v in lv.items()}   # drop first rep
    sds = {X: np.std(v[1:]) / np.sqrt(len(v) - 1) for X, v in lv.items()}
    g = np.mean(list(means.values()))
    dev = {X: means[X] - g for X in XS}
    line = "  ".join(f"{dev[X]*1e6:+7.2f}" for X in XS)
    rng_ppm = (max(means.values()) - min(means.values())) / span * 1e6
    print(f"{nd:12s} dev(uV) vs X={XS}: {line} | range "
          f"{rng_ppm if nd=='V(diffout)' else (max(means.values())-min(means.values()))*1e6:.2f}"
          f"{' ppm-of-span' if nd=='V(diffout)' else ' uV'}"
          f" (sem ~{np.mean(list(sds.values()))*1e6:.2f} uV)")
