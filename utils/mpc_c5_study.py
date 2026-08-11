# C5 STUDY (2026-08-01, user-commissioned): model-predictive (lookahead) code
# selection vs the certified C1 EF3-embedded DPD, on the SAME plant model.
#
# C1 = dpd_volt.py exactly: nearest-code quantizer, error fed back against the
#      predicted emitted level (code + static LUT + Volterra kernel action).
# C5 = same loop, but the code choice branches over nearest+/-B candidates for
#      the first L moves (tail = nearest policy), minimizing sum of squared
#      fed-back errors over the horizon. L=0,B>0 is the greedy special case
#      ("pick the code minimizing |e|, not the nearest code"). C1 is the
#      B=0 special case.
#
# Legs per BIN:
#   matched   : controller model == plant (both cosim80c3j)
#   mismatch  : plant kernel scaled KSCALE_TRUE (1.1), controller nominal
# Scoring: FFT of the modeled emitted stream L_k = code + err_static(code)
#   + dyn_true(hist); HD2..HD5 (dBc), in-band SNDR (OSR 154), e-clamp count,
#   hysteresis-zone (code 20..28) occupancy and entry count.
#
# Usage: python mpc_c5_study.py [BIN ...]   (default: 5 11 17 27 37)
import numpy as np
import sys, os, time

sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 16384
LT = r"C:\Users\ccros\Documents\LTspice"
LUTF = os.environ.get("LUTF", "cosim55lut_inl.npy")
KF   = os.environ.get("KERNEL", "cosim80c3j")
AMPDB = float(os.environ.get("AMPDB", "-1"))
DSEED = int(os.environ.get("DSEED", "5"))
KSCALE_TRUE = float(os.environ.get("KSCALE_TRUE", "1.1"))
OSR = 154

ppm = np.load(rf"{LT}\{LUTF}")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)

GAIN_V = -0.0310
Q     = np.load(rf"{LT}\{KF}_Q.npy") / GAIN_V
pairs = np.load(rf"{LT}\{KF}_pairs.npy")
STAT  = np.load(rf"{LT}\{KF}_stat.npy") / GAIN_V
FIRW  = np.load(rf"{LT}\{KF}_firw.npy") / GAIN_V
QL, DLW = int(pairs.max()), len(FIRW)
HL = max(QL, DLW) + 1

ZONE = (20, 28)   # hysteresis zone (cell count N = code)

def dyn_action(hist, code, q, stat, firw):
    """Kernel dynamic action for hist[0]=code-32 already prepended."""
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

def step_err(w, code, hist, q, stat, firw):
    """Fed-back error for choosing `code` at input w with history hist (no code yet)."""
    h2 = [float(code - 32)] + hist[:HL - 1]
    dyn = dyn_action(h2, code, q, stat, firw)
    e = w - (code << FRAC) - int(LUT[code]) - int(round(dyn * LSB))
    clamped = abs(e) > CLAMP
    e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
    return e, h2, clamped

def run(u, dith, B, L, q_true, stat_true, firw_true):
    """B=0 -> C1 (nearest code, certified). B>0: branch nearest+/-B at the
    current move (and, for L>1, at subsequent moves), roll out L tail steps
    with the nearest policy; cost = sum of squared fed-back errors."""
    st = (0, 0, 0, 0, 0, 0)
    hist = [0.0] * HL
    out = np.empty(M, dtype=np.int64)
    emitted = np.empty(M)
    clamps = 0
    zone_occ = 0
    zone_ent = 0
    prev_in_zone = False

    def nearest(w, d):
        c = (w + d) >> FRAC
        return 0 if c < 0 else (63 if c > 63 else c)

    def cand_list(w, d):
        n = nearest(w, d)
        return sorted(set(max(0, min(63, n + dd)) for dd in range(-B, B + 1)))

    def horizon_cost(k, st_k, hist_k, depth):
        """Best achievable sum e^2 for moves k..k+depth (branching), tail nearest."""
        e1, e2, e3, f1, f2, f3 = st_k
        f = ef3_f(st_k)
        w = int(u[k]) + (32 << FRAC) + f
        d = int(dith[k])
        if depth == 0 or k == M - 1:
            c = nearest(w, d)
            e, _, _ = step_err(w, c, hist_k, Q, STAT, FIRW)
            return float(e) ** 2
        best = None
        for c in cand_list(w, d):
            e, h2, _ = step_err(w, c, hist_k, Q, STAT, FIRW)
            st2 = (e, e1, e2, f, f1, f2)
            cost = float(e) ** 2 + horizon_cost(k + 1, st2, h2, depth - 1)
            if best is None or cost < best:
                best = cost
        return best

    for k in range(M):
        e1, e2, e3, f1, f2, f3 = st
        f = ef3_f(st)
        w = int(u[k]) + (32 << FRAC) + f
        d = int(dith[k])
        wq = w  # controller quantizes w; dither enters the code decision
        if B == 0:
            code = nearest(w, d)
        else:
            best, code = None, nearest(w, d)
            for c in cand_list(w, d):
                e, h2, _ = step_err(w, c, hist, Q, STAT, FIRW)
                st2 = (e, e1, e2, f, f1, f2)
                cost = float(e) ** 2
                if L > 0 and k < M - 1:
                    cost += horizon_cost(k + 1, st2, h2, L - 1 if L > 1 else 0)
                if best is None or cost < best:
                    best, code = cost, c
        # commit with the CONTROLLER model (nominal)
        e, hist, cl = step_err(w, code, hist, Q, STAT, FIRW)
        clamps += cl
        st = (e, e1, e2, f, f1, f2)
        out[k] = code
        # emitted level under the TRUE plant
        emitted[k] = code + err_lsb[code] + dyn_action(hist, code, q_true, stat_true, firw_true)
        in_zone = ZONE[0] <= code <= ZONE[1]
        zone_occ += in_zone
        if in_zone and not prev_in_zone:
            zone_ent += 1
        prev_in_zone = in_zone
    return out, emitted, clamps, zone_occ, zone_ent

def score(emitted, BIN):
    x = emitted - emitted.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    fund = X[BIN]
    res = {}
    for h in range(2, 6):
        res[f"HD{h}"] = 10 * np.log10(X[BIN * h] / fund) if BIN * h < len(X) else float("-inf")
    nb = M // (2 * OSR)             # in-band bin count
    mask = np.ones(len(X), bool)
    mask[0] = False
    for h in range(1, 6):
        if BIN * h < len(X):
            mask[BIN * h] = False
    inband = X[1:nb][mask[1:nb]].sum()
    res["SNDR"] = 10 * np.log10(fund / (inband + sum(X[BIN * h] for h in range(2, 6) if BIN * h < nb)))
    return res

def main():
    bins = [int(b) for b in sys.argv[1:]] or [5, 11, 17, 27, 37]
    amp = 28.0 * 10 ** (AMPDB / 20)
    rng = np.random.default_rng(DSEED)
    HD = LSB >> 1
    dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

    variants = [
        ("C1        (B=0)      ", 0, 0),
        ("C5 greedy (B=2,L=0)  ", 2, 0),
        ("C5 look1  (B=2,L=1)  ", 2, 1),
        ("C5 look2  (B=2,L=2)  ", 2, 2),
    ]
    for BIN in bins:
        n = np.arange(M)
        u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
        for legname, ks in [("matched", 1.0), ("mismatch x%.2f" % KSCALE_TRUE, KSCALE_TRUE)]:
            qt, stt, fwt = Q * ks, STAT * ks, FIRW * ks
            print(f"--- BIN {BIN}  [{legname}] ---")
            for name, B, L in variants:
                t0 = time.time()
                out, emit, cl, zo, ze = run(u, dith, B, L, qt, stt, fwt)
                s = score(emit, BIN)
                print(f"{name}: SNDR {s['SNDR']:6.1f}  "
                      f"HD2 {s['HD2']:7.1f}  HD3 {s['HD3']:7.1f}  HD4 {s['HD4']:7.1f}  HD5 {s['HD5']:7.1f}  "
                      f"clamps {cl:4d}  zone occ {zo:5d} ent {ze:4d}  ({time.time()-t0:.0f}s)")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
