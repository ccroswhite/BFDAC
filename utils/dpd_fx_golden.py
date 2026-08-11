# DPD FIXED-POINT BIT-EXACT GOLDEN MODEL (2026-08-03, user-requested gate
# before ratifying decision (d)). PURE INTEGER controller — every operation is
# what the RTL computes (no floats anywhere in the loop):
#   - history h = code-32 : 6-bit signed int
#   - 2nd/3rd-order products: exact ints (<=16-bit signed; (-32)^3 = -32768)
#   - term = product x 18-bit coef mantissa: 16x18 -> one DSP48E2, 34-bit
#   - accumulate 39 terms + stat + FIR on a common 2^-G code-LSB integer grid
#     (per-array exponent alignment = compile-time shifts), <=48-bit
#   - action rounded to the 2^-F code-LSB grid, injected at FRAC scale
# Plant (scoring) stays exact float. Sweeps dither seeds to resolve the BIN-37
# outlier caveat from dpd_fx_study.py. This file is the Step 4D.5 golden model.
# Usage: python dpd_fx_golden.py [BIN ...]  (default 5 11 17 27 37)
import numpy as np
import sys, os

sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

assert FRAC >= 24, "action grid needs FRAC >= 24"

M = 16384
LT = r"C:\Users\ccros\Documents\LTspice"
LUTF = os.environ.get("LUTF", "cosim55lut_inl.npy")
KF   = os.environ.get("KERNEL", "cosim80c3j")
AMPDB = float(os.environ.get("AMPDB", "-1"))
SEEDS = [int(s) for s in os.environ.get("SEEDS", "1,2,3,4,5,6,7,8").split(",")]
OSR = 154

ppm = np.load(rf"{LT}\{LUTF}")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64

GAIN_V = -0.0310
Q     = np.load(rf"{LT}\{KF}_Q.npy") / GAIN_V
pairs = np.load(rf"{LT}\{KF}_pairs.npy")
STAT  = np.load(rf"{LT}\{KF}_stat.npy") / GAIN_V
FIRW  = np.load(rf"{LT}\{KF}_firw.npy") / GAIN_V
QL, DLW = int(pairs.max()), len(FIRW)
HL = max(QL, DLW) + 1

def mant_exp(a, W):
    """Block fixed-point: W-bit signed mantissas + shared power-of-2 exponent."""
    m = np.abs(a).max()
    ex = int(np.ceil(np.log2(m / (2 ** (W - 1) - 1)))) if m > 0 else 0
    q = np.clip(np.round(a / 2.0 ** ex), -(2 ** (W - 1)), 2 ** (W - 1) - 1)
    return q.astype(int).tolist(), ex

def dyn_exact(hist, code):
    d = -STAT[code]
    for t, qq in zip(pairs, Q):
        prod = 1.0
        for lag in t:
            if lag >= 0:
                prod *= hist[lag]
        d += qq * prod
    for j in range(DLW):
        d -= FIRW[j] * hist[j + 1]
    return d

def ef3_f(st):
    e1, e2, e3, f1, f2, f3 = st
    return ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
            + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))

def run_golden(u, dith, W, F):
    """Pure-integer C1 controller; emitted scored under the exact plant."""
    Qm, exQ = mant_exp(Q, W)
    Sm, exS = mant_exp(STAT, W)
    Fm, exF = mant_exp(FIRW, W)
    G = max(-exQ, -exS, -exF) + 1          # common integer grid 2^-G code-LSB
    shQ, shS, shF = G + exQ, G + exS, G + exF
    assert min(shQ, shS, shF) >= 0
    lut24 = [int(round(v * 2 ** 24)) for v in err_lsb]   # LUT on 2^-24 grid
    plist = [[lag for lag in t if lag >= 0] for t in pairs]

    st = (0, 0, 0, 0, 0, 0)
    hist = [0] * HL
    emitted = np.empty(M)
    clamps = 0
    for k in range(M):
        e1, e2, e3, f1, f2, f3 = st
        f = ef3_f(st)
        w = int(u[k]) + (32 << FRAC) + f
        code = (w + int(dith[k])) >> FRAC
        code = 0 if code < 0 else (63 if code > 63 else code)
        h = [code - 32] + hist[:HL - 1]
        acc = -(Sm[code] << shS)                    # 2^-G grid
        for lags, m in zip(plist, Qm):
            prod = 1
            for lag in lags:
                prod *= h[lag]                      # <=16-bit signed exact
            acc += (m * prod) << shQ                # 16x18 DSP op + shift
        for j in range(DLW):
            acc -= (Fm[j] * h[j + 1]) << shF
        # round 2^-G -> 2^-F grid (round-half-away like python round on .5? RTL
        # uses round-half-up via +half then arithmetic shift — do exactly that)
        half = 1 << (G - F - 1)
        act = (acc + half) >> (G - F)               # 2^-F code-LSB units
        e = (w - (code << FRAC)
             - (lut24[code] << (FRAC - 24))
             - (act << (FRAC - F)))
        clamps += abs(e) > CLAMP
        e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
        st = (e, e1, e2, f, f1, f2)
        hist = h
        emitted[k] = code + err_lsb[code] + dyn_exact([float(x) for x in h], code)
    return emitted, clamps

def run_exact(u, dith):
    """Reference: exact-model controller (dpd_volt semantics)."""
    st = (0, 0, 0, 0, 0, 0)
    hist = [0.0] * HL
    emitted = np.empty(M)
    lut_int = np.round(err_lsb * LSB).astype(np.int64)
    for k in range(M):
        e1, e2, e3, f1, f2, f3 = st
        f = ef3_f(st)
        w = int(u[k]) + (32 << FRAC) + f
        code = (w + int(dith[k])) >> FRAC
        code = 0 if code < 0 else (63 if code > 63 else code)
        h = [float(code - 32)] + hist[:HL - 1]
        dyn = dyn_exact(h, code)
        e = w - (code << FRAC) - int(lut_int[code]) - int(round(dyn * LSB))
        e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
        st = (e, e1, e2, f, f1, f2)
        hist = h
        emitted[k] = code + err_lsb[code] + dyn
    return emitted

def score(emitted, BIN):
    x = emitted - emitted.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    fund = X[BIN]
    hds = [10 * np.log10(X[BIN * h] / fund) if BIN * h < len(X) else float("-inf")
           for h in range(2, 6)]
    nb = M // (2 * OSR)
    mask = np.ones(len(X), bool)
    mask[0] = False
    for h in range(1, 6):
        if BIN * h < len(X):
            mask[BIN * h] = False
    inband = X[1:nb][mask[1:nb]].sum()
    sndr = 10 * np.log10(fund / (inband + sum(X[BIN * h] for h in range(2, 6) if BIN * h < nb)))
    return sndr, max(hds)

def main():
    bins = [int(b) for b in sys.argv[1:]] or [5, 11, 17, 27, 37]
    amp = 28.0 * 10 ** (AMPDB / 20)
    HD = LSB >> 1
    for BIN in bins:
        n = np.arange(M)
        u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
        print(f"--- BIN {BIN} (worst HD = max of HD2..HD5) ---")
        for name, runner in [("exact      ", lambda uu, dd: (run_exact(uu, dd), 0)),
                             ("int W18 F24", lambda uu, dd: run_golden(uu, dd, 18, 24)),
                             ("int W14 F20", lambda uu, dd: run_golden(uu, dd, 14, 20))]:
            res = []
            for s in SEEDS:
                rng = np.random.default_rng(s)
                dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)
                emit, cl = runner(u, dith)
                res.append(score(emit, BIN) + (cl,))
            sndrs = [r[0] for r in res]
            whds = [r[1] for r in res]
            cls = sum(r[2] for r in res)
            wi = int(np.argmax(whds))
            print(f"{name}: SNDR min {min(sndrs):6.1f} / med {np.median(sndrs):6.1f}  "
                  f"worstHD best {min(whds):7.1f} / WORST {max(whds):7.1f} (seed {SEEDS[wi]})  "
                  f"clamps {cls}")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
