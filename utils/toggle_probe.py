# Round 42 forensics: is the post-DPD residual explained by per-period cell
# TOGGLE COUNT (switching-charge error, signal-correlated through DEM)?
# Model: pavg[n] ~ poly3(code) + FIR(code history) + kt*tog[n] + kt1*tog[n-1].
# If kt is significant and the harmonic residual collapses when included,
# the fix is a toggle-count feed-forward term in the NS (deterministic in RTL).
import numpy as np
import sys
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC\utils")

M = 16384
BIN = 17
DISCARD = 512
NTAP = 12
LT = r"C:\Users\ccros\Documents\LTspice"

code = np.load(rf"{LT}\cosim41_code.npy").astype(np.int64)
a = np.load(rf"{LT}\cosim41_pavg.npy")

# regenerate dem_sort selections to get toggle counts
NCELL = 64
A1 = np.zeros(NCELL, dtype=np.int64)
A2 = np.zeros(NCELL, dtype=np.int64)
idx = np.arange(NCELL)
prev = np.zeros(NCELL, dtype=np.uint8)
tog = np.zeros(M)
for i in range(M):
    c = int(code[i])
    order = np.lexsort((idx, 2 * A1 + A2))
    sel = np.zeros(NCELL, dtype=np.uint8)
    sel[order[:c]] = 1
    tog[i] = np.abs(sel.astype(int) - prev.astype(int)).sum()
    prev = sel
    A1 += 64 * sel.astype(np.int64) - c
    A2 += A1

rows = np.arange(max(DISCARD, NTAP), M)
c = code.astype(float)
base = [np.ones(len(rows)), c[rows], c[rows]**2, c[rows]**3]
base += [c[rows - k] for k in range(1, NTAP + 1)]
X0 = np.vstack(base).T
X1 = np.vstack(base + [tog[rows], tog[rows - 1]]).T
y = a[rows]

def resid_harm(X, label):
    coef, *_ = np.linalg.lstsq(X, y, rcond=None)
    r = y - X @ coef
    gain = abs(coef[1])
    ph = 2 * np.pi * BIN * rows / M
    H = []
    for h in range(2, 4):
        q = np.vstack([np.cos(h * ph), np.sin(h * ph), np.ones(len(rows))]).T
        cf, *_ = np.linalg.lstsq(q, r, rcond=None)
        H.append(np.hypot(cf[0], cf[1]) / (gain * 24.99))
    print(f"{label}: resid rms {r.std()*1e6:.1f} uV | "
          f"HD2 {20*np.log10(H[0]):.1f} dBc, HD3 {20*np.log10(H[1]):.1f} dBc")
    return coef

resid_harm(X0, "without toggle terms          ")
cf = resid_harm(X1, "with    toggle terms          ")
print(f"kt = {cf[-2]*1e6:.3f} uV/toggle, kt1 = {cf[-1]*1e6:.3f} uV/toggle "
      f"(gain {cf[1]*1e3:.3f} mV/cell); tog mean {tog.mean():.1f}, "
      f"range {tog.min():.0f}..{tog.max():.0f}")

# nonlinear previous-code terms: transition N_prev -> 0 -> N edge charge
X2 = np.vstack(base + [c[rows-1]**2, c[rows-1]**3,
                       c[rows]*c[rows-1],
                       c[rows]**2*c[rows-1], c[rows]*c[rows-1]**2]).T
resid_harm(X2, "with nonlin prev-code + cross ")
# second-previous too
X3 = np.vstack(base + [c[rows-1]**2, c[rows-1]**3, c[rows]*c[rows-1],
                       c[rows]**2*c[rows-1], c[rows]*c[rows-1]**2,
                       c[rows-2]**2, c[rows]*c[rows-2]]).T
resid_harm(X3, "  + prev2 nonlinear           ")

# bilinear slow-bias terms: EMA of code (Q4 base tau 2.2us ~ 13.5 periods)
# multiplied by current-code sensitivity: bias_state x f(c[n])
from scipy.signal import lfilter
for tau in (4.0, 13.5, 40.0):
    al = 1.0 / tau
    ema = lfilter([al], [1, -(1 - al)], c)
    Xb = np.vstack(base + [c[rows-1]**2, c[rows-1]**3, c[rows]*c[rows-1],
                           ema[rows-1],
                           ema[rows-1] * c[rows],
                           ema[rows-1] * c[rows]**2,
                           ema[rows-1]**2,
                           ema[rows-1]**2 * c[rows]]).T
    resid_harm(Xb, f"  + bilinear EMA tau={tau:5.1f}p   ")
