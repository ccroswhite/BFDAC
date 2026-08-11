# Diagnose the cosim30 full-array RTZ steady-state: print signal trajectories
# across one period (5Ts..6Ts) at phase-resolution to find where the rails starve.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim30w.raw"
Ts = 162.7604e-9
tc = Ts / 8

names, data = read_raw(RAW)
t = data[0]
sig = {n: data[i] for i, n in enumerate(names)}

def at(name, tt):
    return np.interp(tt, t, sig[name])

cols = ["V(diffout)", "V(sum_p)", "V(sum_m)", "V(out_p)", "V(out_m)",
        "V(bus_plus)", "V(bus_minus)", "V(casb_p)", "V(casb_m)",
        "Ic(Q5p)", "Ic(Q5m)"]
cols = [c for c in cols if c in sig]
print(f"{'t/tc':>6}" + "".join(f"{c.replace('V(','').replace('Ic(','I:').replace(')',''):>11}" for c in cols))
for f in np.arange(0, 8.01, 0.25):
    tt = 5 * Ts + f * tc
    print(f"{f:6.2f}" + "".join(f"{at(c, tt):11.4f}" for c in cols))

# min/max over the period for each signal
print("\nperiod min/max:")
m = (t >= 5 * Ts) & (t <= 6 * Ts)
for c in cols:
    print(f"  {c:<14} min {sig[c][m].min():9.4f}   max {sig[c][m].max():9.4f}")
