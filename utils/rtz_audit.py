# Round 31: current audit - which per-period average current is nonlinear in N?
# For each saved current/voltage, compute exact-period steady-state average per
# step, fit vs N, print residual from the line (uA / uV) - the nonlinear ampere.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import split_steps, period_avg, Ts, N_LIST

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim31f.raw"
names, data = read_raw(RAW)
t = data[0]
segs = split_steps(t)
n = np.array(N_LIST, float)
A = np.vstack([np.ones_like(n), n]).T

print(f"{'signal':<18}" + "".join(f"{N:>11}" for N in N_LIST) + "   (residual from LS line)")
for i, name in enumerate(names):
    if name == "time":
        continue
    va = []
    for seg in segs:
        ts, y = t[seg], data[i][seg]
        va.append(period_avg(ts, y, ts[-1] - Ts, ts[-1]))
    va = np.array(va)
    coef, *_ = np.linalg.lstsq(A, va, rcond=None)
    resid = (va - A @ coef) * 1e6
    unit = "uV" if name.startswith("V(") else "uA"
    print(f"{name:<18}" + "".join(f"{r:11.1f}" for r in resid) + f"  {unit}"
          + f"   slope={coef[1]*1e6:.1f} {unit}/cell")
