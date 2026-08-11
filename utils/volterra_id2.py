# Round 68: DISCIPLINED Volterra-2 ID per the R66/67 post-mortem protocol:
#  (1) records with INDEPENDENT dither seeds (68a/b/c/d: seeds 101-104),
#  (2) fit/validate on IN-BAND complex spectral projections only (bins where
#      signal products dominate; nuisance = statics + FIR + drift removed and
#      features orthogonalized against the same nuisance space),
#  (3) report the kernel's own out-of-band->in-band mixing on the real NS
#      stream (embed gate: must be below target floor),
#  (4) honest validation = predict the HD2 complex bin of a heldout record
#      with an INDEPENDENT seed (68a <-> 68b, same BIN, different noise).
import numpy as np
import os

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
DL = 16
QL = 5
K0 = 64
BMAX = 300                 # fit band: bins 1..300 (375Hz..112.5kHz)

RECS = {"68a": 37, "68b": 37, "68c": 17, "68d": 11}
if os.environ.get("EXTREC") == "1":     # R75: extra in-band records, fresh seeds
    RECS.update({"75a": 5, "75b": 27})
if os.environ.get("V80") == "1":        # R80: frozen v80 plant, 6 fresh records
    RECS = {"80a": 37, "80b": 37, "80c": 17, "80d": 11, "80e": 5, "80f": 27}
if os.environ.get("V86") == "1":        # R86: v80 plant at .temp 45 (Step 6.6)
    RECS = {"86a": 37, "86b": 37, "86c": 17, "86d": 11, "86e": 5, "86f": 27}
pairs = [(i, j) for i in range(QL + 1) for j in range(i, QL + 1)
         if not (i == 0 and j == 0)]
if os.environ.get("CUBIC") == "1":
    CL = 3
    pairs += [(i, j, l) for i in range(CL + 1) for j in range(i, CL + 1)
              for l in range(j, CL + 1) if not (i == j == l == 0)]

def products(cz, rows, terms):
    return np.stack([np.prod([cz[rows - lag] for lag in t], axis=0)
                     for t in terms], axis=1)

def prep(tag):
    BIN = RECS[tag]
    p = np.load(rf"{LT}\cosim{tag}_pavg.npy")[:M]
    c = np.load(rf"{LT}\cosim{tag}_code.npy")[:M].astype(float)
    rows = np.arange(K0, M)
    y = p[rows]
    cz = c - 32.0
    oh = np.zeros((len(rows), 64))
    oh[np.arange(len(rows)), c[rows].astype(int)] = 1.0
    fir = np.stack([cz[rows - j] for j in range(1, DL + 1)], axis=1)
    nn = rows / M
    nu = np.hstack([oh, fir,
                    np.stack([np.ones(len(rows)), nn, nn ** 2, nn ** 3], axis=1)])
    quad = products(cz, rows, pairs)
    # orthogonalize target and features against nuisance space
    Qn, _ = np.linalg.qr(nu)
    y = y - Qn @ (Qn.T @ y)
    quad = quad - Qn @ (Qn.T @ quad)
    # in-band complex projection
    F = np.fft.rfft(np.eye(1) * 0)  # placeholder
    yf = np.fft.rfft(y)
    qf = np.fft.rfft(quad, axis=0)
    bins = np.arange(1, BMAX + 1)
    bins = bins[np.abs(bins - BIN * (M - K0) / M) > 4]   # drop fund mainlobe
    return yf[bins], qf[bins], y, quad, c, rows, BIN

LAM = float(os.environ.get("RIDGE", "0"))

def stackfit(tags, lam=None):
    lam = LAM if lam is None else lam
    ys, Xs = [], []
    for t in tags:
        yf, qf, *_ = prep(t)
        ys += [yf.real, yf.imag]
        Xs += [qf.real, qf.imag]
    y = np.concatenate(ys)
    X = np.vstack(Xs)
    A = X.T @ X + lam * np.eye(X.shape[1])
    Q = np.linalg.solve(A, X.T @ y)
    return Q, y - X @ Q

def hdbin(tag, x, rows, h):
    BIN = RECS[tag]
    ph = 2 * np.pi * BIN * h * rows / M
    return 2 * (x * np.exp(-1j * ph)).mean()

print(f"records: {RECS}; fit band bins 1..{BMAX}; {len(pairs)} kernel terms; "
      f"ridge {LAM:g}")
for hold in RECS:
    rest = [t for t in RECS if t != hold]
    Qh, _ = stackfit(rest)
    yf, qf, y, quad, c, rows, BIN = prep(hold)
    pred = quad @ Qh
    fund = 28.0 * 10 ** (-1 / 20) * 0.0310
    for h in (2, 3):
        mh = hdbin(hold, y, rows, h)
        ph_ = hdbin(hold, pred, rows, h)
        dphi = np.angle(mh / ph_, deg=True) if abs(ph_) > 0 else float("nan")
        print(f"hold {hold} HD{h}: pred {20*np.log10(abs(ph_)/fund):7.1f} "
              f"meas {20*np.log10(abs(mh)/fund):7.1f} dBc  dphi {dphi:7.1f}d")

Q, fresid = stackfit(list(RECS))
print(f"\njoint fit: freq-domain resid rms {fresid.std()*1e6:.2f} uV/bin")
print("kernel [uV/unit^n]:")
for t, q in zip(pairs, Q):
    print(f"  Q{t} = {q*1e6:+8.4f}")

# decompose the RAW kernel action on the nuisance basis so the embed can
# subtract its static + LTI + drift content (R69 post-mortem: fitting on
# orthogonalized features but applying raw injects the nulled directions).
# R74 (generalization fix A): the decomposition is STREAM-DEPENDENT - doing it
# on 68a (BIN=37) alone leaves residual static content on other-BIN streams.
# NUALL=1 stacks ALL records so the stat/firw split is BIN-independent.
dtags = list(RECS) if os.environ.get("NUALL") == "1" else [list(RECS)[0]]
nus, acts = [], []
for tag in dtags:
    c = np.load(rf"{LT}\cosim{tag}_code.npy")[:M].astype(float)
    rows = np.arange(K0, M)
    cz = c - 32.0
    quad_raw = products(cz, rows, pairs)
    acts.append(quad_raw @ Q)
    oh = np.zeros((len(rows), 64))
    oh[np.arange(len(rows)), c[rows].astype(int)] = 1.0
    fir = np.stack([cz[rows - j] for j in range(1, DL + 1)], axis=1)
    nus.append(np.hstack([oh, fir, np.ones((len(rows), 1))]))
act_raw = np.concatenate(acts)
nu = np.vstack(nus)
nc, *_ = np.linalg.lstsq(nu, act_raw, rcond=None)
tag = dtags[0]
act_raw = acts[0]
nu = nus[0]
act_dyn = act_raw - nu @ nc
stat = np.zeros(64)
stat[:] = nc[:64]
firw = nc[64:64 + DL]
const = nc[-1]

# requirement (3), done RIGHT: spurious floor of the RAW-minus-nuisance action
sp = np.abs(np.fft.rfft(act_dyn * np.hanning(len(act_dyn)))) / (len(act_dyn) / 4)
fund_v = 28.0 * 10 ** (-1 / 20) * 0.0310
BINa = RECS[tag]
msk = np.ones(len(sp), bool); msk[0] = False
msk[max(BINa - 4, 0):BINa + 5] = False
inb = sp[:60][msk[:60]]
print(f"\nRAW-action decomposition: |static| max {np.abs(stat - stat.mean()).max()*1e6:.1f} uV, "
      f"|fir| max {np.abs(firw).max()*1e6:.2f} uV/unit, dyn rms {act_dyn.std()*1e6:.1f} uV")
print(f"kernel dyn-action on {tag}: max in-band non-fund bin "
      f"{20*np.log10(inb.max()/fund_v):.1f} dBc (target < -110)")
KF = "cosim68c3" if os.environ.get("CUBIC") == "1" else "cosim68"
if os.environ.get("V80") == "1":
    KF = "cosim80c3" if os.environ.get("CUBIC") == "1" else "cosim80"
if os.environ.get("V86") == "1":
    KF = "cosim86c3" if os.environ.get("CUBIC") == "1" else "cosim86"
if os.environ.get("NUALL") == "1":
    KF += "j"
if os.environ.get("EXTREC") == "1":
    KF += "e"
pad = np.full((len(pairs), 3), -1, dtype=np.int64)
for r, t in enumerate(pairs):
    pad[r, :len(t)] = t
np.save(rf"{LT}\{KF}_Q.npy", Q)
np.save(rf"{LT}\{KF}_pairs.npy", pad)
np.save(rf"{LT}\{KF}_stat.npy", stat)
np.save(rf"{LT}\{KF}_firw.npy", firw)
print(f"saved {KF}_Q/pairs/stat/firw")
