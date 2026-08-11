# Round 66: Volterra-2 system ID of the dynamic residual, fitted jointly on
# existing R54-config gate records (known code streams, rich excitation:
# 4 frequencies x amplitude x inversion x selection scheme). Model:
#   pavg[k] = per-dataset (const + drift n,n^2 + gain*c_k)
#           + shared one-hot(c_k) static INL
#           + shared FIR c_{k-1..k-DL} (LTI tail)
#           + shared quadratic kernel Q_ij * (c_{k-i}-32)(c_{k-j}-32), lags<=QL
# Validation: leave-one-gate-out - predict held-out gate's HD2/HD3 complex
# amplitude from the quadratic kernel alone; compare to measured.
import numpy as np
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
DL = 16            # linear FIR depth
QL = 5             # quadratic memory depth (lags 0..QL)
DISCARD = 64

# tag -> BIN (all R54-config 16k gates, honest static-LUT streams)
GATES = {"55": 17, "58": 17, "59": 17, "60": 37,
         "62b5": 5, "62b11": 11, "65": 37,
         "64": 37, "65b": 37, "65c": 37}

quad_pairs = [(i, j) for i in range(QL + 1) for j in range(i, QL + 1)
              if not (i == 0 and j == 0)]      # (0,0) absorbed by one-hot

def build(tag):
    p = np.load(rf"{LT}\cosim{tag}_pavg.npy")[:M]
    c = np.load(rf"{LT}\cosim{tag}_code.npy")[:M].astype(float)
    k0 = max(DL, QL) + DISCARD
    rows = np.arange(k0, M)
    y = p[rows]
    cz = c - 32.0
    oh = np.zeros((len(rows), 64))
    oh[np.arange(len(rows)), c[rows].astype(int)] = 1.0
    fir = np.stack([c[rows - j] for j in range(1, DL + 1)], axis=1)
    quad = np.stack([cz[rows - i] * cz[rows - j] for i, j in quad_pairs], axis=1)
    nn = rows / M
    local = np.stack([np.ones(len(rows)), nn, nn ** 2, c[rows]], axis=1)
    return y, oh, fir - 32.0, quad, local, c, rows

def hd_complex(x, rows, BIN, h):
    ph = 2 * np.pi * BIN * h * rows / M
    return 2 * (x * np.exp(-1j * ph)).mean()

def fit(tags):
    blocks = []
    ys = []
    nloc = 4
    for d, tag in enumerate(tags):
        y, oh, fir, quad, local, _, _ = build(tag)
        nr = len(y)
        loc = np.zeros((nr, nloc * len(tags)))
        loc[:, d * nloc:(d + 1) * nloc] = local
        blocks.append(np.hstack([loc, oh, fir, quad]))
        ys.append(y)
    X = np.vstack(blocks)
    y = np.concatenate(ys)
    coef, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ coef
    nq = len(quad_pairs)
    return coef, coef[-nq:], resid.std()

print(f"model: FIR depth {DL}, quad lags 0..{QL} ({len(quad_pairs)} kernel terms)")
tags = list(GATES)
coef, Q, rstd = fit(tags)
print(f"joint fit on {len(tags)} gates: resid rms {rstd*1e6:.1f} uV")
print("quad kernel [uV/unit^2]:")
for (i, j), q in zip(quad_pairs, Q):
    if abs(q) * 1e6 > 0.005:
        print(f"  Q({i},{j}) = {q*1e6:+8.4f}")

print("\nleave-one-out validation (quad-kernel HD prediction vs measured):")
print(f"{'gate':>6} {'h':>2} {'pred dBc':>9} {'meas dBc':>9} {'phase err':>9}")
for hold in tags:
    rest = [t for t in tags if t != hold]
    _, Qh, _ = fit(rest)
    y, oh, fir, quad, local, c, rows = build(hold)
    BIN = GATES[hold]
    # measured residual: remove local + statics + FIR fitted on the held-out
    # gate itself WITHOUT quad terms, then compare harmonics to quad prediction
    Xh = np.hstack([local, oh, fir])
    ch, *_ = np.linalg.lstsq(Xh, y, rcond=None)
    meas = y - Xh @ ch
    pred = quad @ Qh
    pred = pred - Xh @ np.linalg.lstsq(Xh, pred, rcond=None)[0]  # same projection
    fund = abs(hd_complex(y - y.mean(), rows, BIN, 1))
    for h in (2, 3):
        mh = hd_complex(meas, rows, BIN, h)
        ph_ = hd_complex(pred, rows, BIN, h)
        dphi = np.angle(mh / ph_, deg=True) if abs(ph_) > 0 else float("nan")
        print(f"{hold:>6} {h:>2} {20*np.log10(abs(ph_)/fund):9.1f} "
              f"{20*np.log10(abs(mh)/fund):9.1f} {dphi:8.1f}d")
np.save(rf"{LT}\cosim66_Q.npy", Q)
np.save(rf"{LT}\cosim66_pairs.npy", np.array(quad_pairs))
print("saved cosim66_Q.npy / cosim66_pairs.npy (joint-fit kernel)")
