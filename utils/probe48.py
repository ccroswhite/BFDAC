# Round 48 analysis: segment std + settled level per code, per variant.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

SEG = 160
sched = [24, 32, 27, 32, 28, 32, 40, 32]

for var in sys.argv[1:] or ("a", "b", "c"):
    tag = var if len(var) > 1 else f"48{var}"
    raw = rf"C:\Users\ccros\Documents\LTspice\bfdac_cosim{tag}.raw"
    names, data = read_raw(raw)
    t = data[0]
    d = data[names.index("V(diffout)")]
    nper = SEG * (1 + len(sched))
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])
    msg = []
    p0 = SEG
    for c in sched:
        seg = a[p0 + 30:p0 + SEG]
        if c != 32:
            msg.append(f"c{c}: std {seg.std()*1e6:6.1f} uV, "
                       f"mean {seg.mean()*1e3:+.4f} mV")
        p0 += SEG
    print(f"{tag}: " + " | ".join(msg))
