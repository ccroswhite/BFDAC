# Round 32 leg 2: bus-cap sweep on the passive-termination deck (mode=1).
# 24 steps = cbus(2.2n,10n,47n,100n) x N(6). INL per cbus.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import split_steps, period_avg, Ts, N_LIST

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim32b.raw"
CBUS = ["2.2n", "10n", "47n", "100n"]
names, data = read_raw(RAW)
t = data[0]
sig = {n: data[i] for i, n in enumerate(names)}
segs = split_steps(t)
assert len(segs) == len(CBUS) * len(N_LIST), f"{len(segs)} steps"
n = np.array(N_LIST, float)
A = np.vstack([np.ones_like(n), n]).T

for ci, cb in enumerate(CBUS):
    va, buspp, serr = [], [], []
    for si in range(len(N_LIST)):
        seg = segs[ci * len(N_LIST) + si]
        ts, d = t[seg], sig["V(diffout)"][seg]
        tend = ts[-1]
        a1 = period_avg(ts, d, tend - 2 * Ts, tend - Ts)
        a2 = period_avg(ts, d, tend - Ts, tend)
        bp = sig["V(bus_plus)"][seg]
        m = ts >= tend - Ts
        va.append(a2)
        buspp.append((bp[m].max() - bp[m].min()) * 1e3)
        serr.append(a2 - a1)
    va = np.array(va)
    coef, *_ = np.linalg.lstsq(A, va, rcond=None)
    resid = va - A @ coef
    span = abs(coef[1] * 64)
    print(f"cbus={cb:>5}: max|INL| = {np.max(np.abs(resid))/span*1e6:9.2f} ppm; "
          f"bus_pp@N64 = {buspp[-1]:7.1f} mV; max|settle_err| = {np.max(np.abs(serr)):.2e}")
    print("        INL(N): " + "  ".join(f"{r/span*1e6:9.1f}" for r in resid))
