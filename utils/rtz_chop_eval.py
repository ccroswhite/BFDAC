# Reusable chopped-deck evaluator (Round 36+): discard-average method on the
# 40-period schedule. Usage: python rtz_chop_eval.py <raw> [signal ...]
import numpy as np
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

SCHED = [1, 32, 8, 32, 16, 32, 31, 32, 32, 32, 33, 32, 48, 32, 64, 32]
SEG0, SEGP, DISC = 40, 40, 20

def evaluate(t, d, label):
    nper = SEG0 + SEGP * len(SCHED)
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(nper)])
    segs = [(32, a[SEG0 - 10:SEG0].mean(), a[SEG0 - 10:SEG0].std())]
    p0 = SEG0
    for code in SCHED:
        w = a[p0 + DISC:p0 + SEGP]
        segs.append((code, w.mean(), w.std()))
        p0 += SEGP
    ref_idx = np.array([i for i, (c, v, s) in enumerate(segs) if c == 32 and i != 9], float)
    ref_val = np.array([v for i, (c, v, s) in enumerate(segs) if c == 32 and i != 9])
    ref_mean = ref_val.mean()
    out, sds = {}, {}
    for i, (c, v, s) in enumerate(segs):
        if c == 32 and i != 9:
            continue
        out[c] = v - (np.interp(i, ref_idx, ref_val) - ref_mean)
        sds[c] = s
    codes = [1, 8, 16, 32, 48, 64]
    n = np.array(codes, float)
    va = np.array([out[c] for c in codes])
    A = np.vstack([np.ones_like(n), n]).T
    coef, *_ = np.linalg.lstsq(A, va, rcond=None)
    resid = va - A @ coef
    span = abs(coef[1] * 64)
    floor = np.mean([sds[c] for c in codes]) / span * 1e6
    print(f"{label}: gain {coef[1]*1e3:+.4f} mV/cell; max|INL| = "
          f"{np.max(np.abs(resid))/span*1e6:8.2f} ppm (floor ~{floor:.1f} ppm); "
          f"refdrift_pp = {(ref_val.max()-ref_val.min())*1e6:.1f} uV")
    print("   INL(N): " + "  ".join(f"{r/span*1e6:8.2f}" for r in resid))
    lsb = coef[1]
    print(f"   DNL(31->32) = {((out[32]-out[31])/lsb-1)*100:+.4f} % LSB; "
          f"(32->33) = {((out[33]-out[32])/lsb-1)*100:+.4f} % LSB")
    return dict(out=out, resid=resid, span=span, coef=coef)

if __name__ == "__main__":
    raw = sys.argv[1]
    signals = sys.argv[2:] or ["V(diffout)"]
    names, data = read_raw(raw)
    t = data[0]
    for s in signals:
        evaluate(t, data[names.index(s)], f"{os.path.basename(raw)} {s}")
