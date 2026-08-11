# DPD FIXED-POINT FORMAT STUDY (2026-08-03, decision (d) support).
# C1 controller (EF3-embedded DPD, ratified 2026-08-03) with QUANTIZED
# coefficients/action vs the FULL-PRECISION plant:
#   - kernel Q/STAT/FIRW: block fixed-point, W-bit signed mantissa with one
#     shared power-of-2 exponent per array (what DSP48-based RTL stores);
#   - static LUT: quantized to 2^-F code-LSB;
#   - accumulated dyn action: quantized to 2^-F code-LSB before feedback
#     (models the RTL accumulator output truncation).
# Plant (scoring) stays exact. The knee of SNDR/HD vs W and F specifies the
# RTL word widths. Usage: python dpd_fx_study.py [BIN ...] (default 11 17 37)
import numpy as np
import sys, os

sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 16384
LT = r"C:\Users\ccros\Documents\LTspice"
LUTF = os.environ.get("LUTF", "cosim55lut_inl.npy")
KF   = os.environ.get("KERNEL", "cosim80c3j")
AMPDB = float(os.environ.get("AMPDB", "-1"))
DSEED = int(os.environ.get("DSEED", "5"))
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

def blockfx(a, W):
    """Block fixed-point: W-bit signed mantissa, shared power-of-2 exponent."""
    m = np.abs(a).max()
    if m == 0:
        return a.copy(), 0
    ex = int(np.ceil(np.log2(m / (2 ** (W - 1) - 1))))
    q = np.round(a / 2.0 ** ex).astype(np.int64)
    q = np.clip(q, -(2 ** (W - 1)), 2 ** (W - 1) - 1)
    return q * 2.0 ** ex, ex

def dyn_action(hist, code, q, stat, firw):
    d = -stat[code]
    for t, qq in zip(pairs, q):
        prod = 1.0
        for lag in t:
            if lag >= 0:
                prod *= hist[lag]
        d += qq * prod
    for j in range(DLW):
        d -= firw[j] * hist[j + 1]
    return d

def ef3_f(st):
    e1, e2, e3, f1, f2, f3 = st
    return ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
            + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))

def run_c1(u, dith, qc, statc, firwc, lut_int, F):
    """C1 loop; controller uses quantized model, returns emitted under exact plant."""
    st = (0, 0, 0, 0, 0, 0)
    hist = [0.0] * HL
    emitted = np.empty(M)
    clamps = 0
    scale = 2.0 ** F
    for k in range(M):
        e1, e2, e3, f1, f2, f3 = st
        f = ef3_f(st)
        w = int(u[k]) + (32 << FRAC) + f
        code = (w + int(dith[k])) >> FRAC
        code = 0 if code < 0 else (63 if code > 63 else code)
        h2 = [float(code - 32)] + hist[:HL - 1]
        dyn_c = dyn_action(h2, code, qc, statc, firwc)
        dyn_q = round(dyn_c * scale) / scale            # 2^-F code-LSB action grid
        e = w - (code << FRAC) - int(lut_int[code]) - int(round(dyn_q * LSB))
        clamps += abs(e) > CLAMP
        e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
        st = (e, e1, e2, f, f1, f2)
        hist = h2
        emitted[k] = code + err_lsb[code] + dyn_action(h2, code, Q, STAT, FIRW)
    return emitted, clamps

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
    return sndr, hds

def main():
    bins = [int(b) for b in sys.argv[1:]] or [11, 17, 37]
    amp = 28.0 * 10 ** (AMPDB / 20)
    rng = np.random.default_rng(DSEED)
    HD = LSB >> 1
    dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

    print(f"coef ranges: |Q|max {np.abs(Q).max():.3e}  |STAT|max {np.abs(STAT).max():.3e}  "
          f"|FIRW|max {np.abs(FIRW).max():.3e}  |LUT err|max {np.abs(err_lsb).max():.3e} code-LSB")

    configs = [("exact     ", None, None)] + \
              [(f"W={w:2d} F={f:2d}", w, f) for w in (18, 14, 12, 10, 8) for f in (24, 20, 16)]

    for BIN in bins:
        n = np.arange(M)
        u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
        print(f"--- BIN {BIN} ---")
        for name, w, f in configs:
            if w is None:
                qc, statc, firwc = Q, STAT, FIRW
                lut_int = np.round(err_lsb * LSB).astype(np.int64)
                f = 99
            else:
                qc, _ = blockfx(Q, w)
                statc, _ = blockfx(STAT, w)
                firwc, _ = blockfx(FIRW, w)
                lut_int = (np.round(err_lsb * 2.0 ** f) / 2.0 ** f * LSB).round().astype(np.int64)
            emit, cl = run_c1(u, dith, qc, statc, firwc, lut_int, f)
            sndr, hds = score(emit, BIN)
            print(f"{name}: SNDR {sndr:6.1f}  HD2 {hds[0]:7.1f}  HD3 {hds[1]:7.1f}  "
                  f"HD4 {hds[2]:7.1f}  HD5 {hds[3]:7.1f}  clamps {cl}")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
