# Round 32 leg 1: INL of the passive-termination RTZ path.
# 12 steps = mode(0,1) x N(1,8,16,32,48,64). Exact-period averages, INL per mode.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import split_steps, period_avg, Ts, N_LIST

RAW = r"C:\Users\ccros\Documents\LTspice\bfdac_cosim32.raw"
names, data = read_raw(RAW)
t = data[0]
sig = {n: data[i] for i, n in enumerate(names)}
segs = split_steps(t)
assert len(segs) == 12, f"{len(segs)} steps"
n = np.array(N_LIST, float)
A = np.vstack([np.ones_like(n), n]).T

# LTspice step order: inner .step (N) varies fastest
for mi, mode in enumerate(("mode=0 fixed casb", "mode=1 replica-ff casb")):
    print(f"\n=== v32 passive termination, {mode} ===")
    print(f"{'N':>3} {'vavg (V)':>12} {'settle_err':>11} {'bus_pp (mV)':>12}")
    va = []
    for si, N in enumerate(N_LIST):
        seg = segs[mi * len(N_LIST) + si]
        ts, d = t[seg], sig["V(diffout)"][seg]
        tend = ts[-1]
        a1 = period_avg(ts, d, tend - 2 * Ts, tend - Ts)
        a2 = period_avg(ts, d, tend - Ts, tend)
        bp = sig["V(bus_plus)"][seg]
        m = ts >= tend - Ts
        print(f"{N:>3} {a2:12.6f} {a2 - a1:11.2e} {(bp[m].max()-bp[m].min())*1e3:12.2f}")
        va.append(a2)
    va = np.array(va)
    coef, *_ = np.linalg.lstsq(A, va, rcond=None)
    resid = va - A @ coef
    span = abs(coef[1] * 64)
    for N, r in zip(N_LIST, resid):
        print(f"  N={N:<3d} INL = {r/span*1e6:9.2f} ppm")
    print(f"gain {coef[1]*1e3:.4f} mV/cell; max |INL| = {np.max(np.abs(resid))/span*1e6:.2f} ppm")
