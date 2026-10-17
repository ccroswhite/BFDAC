# Round 31: extract steady-state INL(N) from the cosim31-series raw files.
# The averaging I/V (284kHz pole) makes windowed charge invalid; instead compute
# the per-period average of diffout over the final 2 periods per step (true
# periodic steady state after ~10 tau), fit line vs N, report INL + health.
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw

Ts = 162.7604e-9
N_LIST = [1, 8, 16, 32, 48, 64]
_mono = {}

def split_steps(t):
    """Step boundaries = where time decreases."""
    idx = np.where(np.diff(t) < 0)[0] + 1
    return np.split(np.arange(len(t)), idx)

def period_avg(t, y, t0, t1):
    """Integrate over EXACTLY [t0, t1]: interpolate boundary samples. Nearest-
    sample windows misalign by up to one timestep; on a +-2.6V square that
    fakes mV-level INL (8mV/0.5ns at Ts=163ns)."""
    key = (id(t), len(t))
    if key not in _mono:
        _mono[key] = bool(np.all(np.diff(t) >= 0))
    if _mono[key]:
        m = slice(np.searchsorted(t, t0, "right"), np.searchsorted(t, t1, "left"))
    else:
        m = (t > t0) & (t < t1)
    tt = np.concatenate(([t0], t[m], [t1]))
    yy = np.concatenate(([np.interp(t0, t, y)], y[m], [np.interp(t1, t, y)]))
    return np.trapezoid(yy, tt) / (t1 - t0)

def analyze(path, label):
    names, data = read_raw(path)
    t = data[0]
    sig = {n: data[i] for i, n in enumerate(names)}
    segs = split_steps(t)
    assert len(segs) == len(N_LIST), f"{len(segs)} steps found, expected {len(N_LIST)}"
    print(f"\n=== {label} ===")
    print(f"{'N':>3} {'vavg (V)':>12} {'settle_err':>11} {'q5p_min':>9} {'q5m_min':>9} {'sum_pp':>8}")
    va = []
    for seg, N in zip(segs, N_LIST):
        ts, d = t[seg], sig["V(diffout)"][seg]
        tend = ts[-1]
        a1 = period_avg(ts, d, tend - 2 * Ts, tend - Ts)
        a2 = period_avg(ts, d, tend - Ts, tend)
        sp = sig["V(sum_p)"][seg]
        m = ts >= tend - Ts
        if "Ic(Q5p)" in sig:
            q5p, q5m = sig["Ic(Q5p)"][seg], sig["Ic(Q5m)"][seg]
            q5s = f"{q5p[m].min():9.5f} {q5m[m].min():9.5f}"
        else:
            q5s = f"{'n/a':>9} {'n/a':>9}"
        print(f"{N:>3} {a2:12.6f} {a2 - a1:11.2e} {q5s} "
              f"{sp[m].max() - sp[m].min():8.4f}")
        va.append(a2)
    va = np.array(va, float)
    n = np.array(N_LIST, float)
    # LS line through all points; INL = residual, in ppm of span
    A = np.vstack([np.ones_like(n), n]).T
    coef, *_ = np.linalg.lstsq(A, va, rcond=None)
    resid = va - A @ coef
    span = coef[1] * 64
    print(f"gain: {coef[1]*1e3:.4f} mV/cell, span {span:.3f} V")
    for N, r in zip(N_LIST, resid):
        print(f"  N={N:<3d} INL = {r/abs(span)*1e6:9.2f} ppm ({r*1e6:9.1f} uV)")
    print(f"max |INL| = {np.max(np.abs(resid))/abs(span)*1e6:.2f} ppm of span")
    return n, va

if __name__ == "__main__":
    base = r"C:\Users\ccros\Documents\LTspice"
    for f, lab in (("bfdac_cosim31.raw", "v31 stagger 4x5ns"),
                   ("bfdac_cosim31b.raw", "v31b no stagger"),
                   ("bfdac_cosim31c.raw", "v31c regulated cascode")):
        p = os.path.join(base, f)
        if os.path.exists(p):
            try:
                analyze(p, lab)
            except AssertionError as e:
                print(f"{lab}: {e}")
