# Round 30: noise_shaper_7th_order coefficient fix verification.
# The shipped "placeholder" {7,6,5,4,3,2,1} has NTF(1) = -3 (NO DC zero):
# in-band quantization noise is amplified, not shaped -> the 21 dB e2e SNDR.
# Candidate replacements: binomial (1-z^-1)^L EF FIR H = 1-NTF, evaluated
# with the EXACT integer loop semantics of the RTL (incl. e_z1 clamp and
# 64-level output clamp), TPDF dither, -1 dBFS sine on the +-28-level scale.
import numpy as np

FS = 6.144e6
N = 65536
BIN = 11
FRAC = 42
LSB = 1 << FRAC
CLAMP = 63 * LSB
RNG = np.random.default_rng(5)

def run_ns(coefs, amp_levels=28.0 * 10 ** (-1 / 20)):
    n = np.arange(N)
    u = (amp_levels * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
    e = np.zeros(len(coefs), dtype=np.int64)
    y = np.empty(N, dtype=np.int64)
    dith = (RNG.integers(0, LSB, N) + RNG.integers(0, LSB, N) - LSB).astype(np.int64)
    clamp_hits = 0
    for i in range(N):
        ns = u[i] + (32 << FRAC) + int(np.dot(coefs, e))
        d = ns + dith[i]
        code = d >> FRAC
        if code > 63:
            code = 63
        elif code < 0:
            code = 0
        y[i] = code
        e1 = ns - (code << FRAC)
        if e1 > CLAMP:
            e1 = CLAMP; clamp_hits += 1
        elif e1 < -CLAMP:
            e1 = -CLAMP; clamp_hits += 1
        e[1:] = e[:-1]
        e[0] = e1
    return y, clamp_hits

def sndr(y):
    x = y - y.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy()
    mask[BIN-1:BIN+2] = False
    return 10 * np.log10(X[BIN] / X[mask].sum())

def run_cifb(order, amp_levels=28.0 * 10 ** (-1 / 20)):
    """CIFB with unity a/c coefficients (dem_study style, extended order):
    i1 += u-v ; i2 += i1-v ; ... ; v = Q(i_last + dither). Integer at FRAC scale."""
    n = np.arange(N)
    u = (amp_levels * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
    s = np.zeros(order, dtype=np.int64)
    y = np.empty(N, dtype=np.int64)
    dith = (RNG.integers(0, LSB, N) + RNG.integers(0, LSB, N) - LSB).astype(np.int64)
    pk = np.zeros(order, dtype=np.int64)
    for i in range(N):
        v_scaled = 0  # previous v in levels, applied below
        # v from LAST sample: use y[i-1]-32
        vprev = (int(y[i - 1]) - 32) << FRAC if i > 0 else 0
        s[0] += u[i] - vprev
        for k in range(1, order):
            s[k] += s[k - 1] - vprev
        code = ((s[order - 1] + dith[i]) >> FRAC) + 32
        if code > 63:
            code = 63
        elif code < 0:
            code = 0
        y[i] = code
        pk = np.maximum(pk, np.abs(s))
    return y, pk

cands = {
    "shipped {7,6,5,4,3,2,1} (BROKEN)": [7, -6, 5, -4, 3, -2, 1],
    "binomial L=2 {2,-1}":              [2, -1],
    "binomial L=3 {3,-3,1}":            [3, -3, 1],
    "binomial L=4 {4,-6,4,-1}":         [4, -6, 4, -1],
    "binomial L=5 {5,-10,10,-5,1}":     [5, -10, 10, -5, 1],
}
for name, c in cands.items():
    ntf_dc = 1 - sum(c)
    y, hits = run_ns(np.array(c, dtype=np.int64))
    print(f"{name:<36} NTF(DC)={ntf_dc:+d}  SNDR={sndr(y):7.1f} dB  clamp_hits={hits}  "
          f"code range {y.min()}..{y.max()}")

print()
for order in (2, 3, 4):
    y, pk = run_cifb(order)
    print(f"CIFB order {order} (unity coefs)           SNDR={sndr(y):7.1f} dB  "
          f"code range {y.min()}..{y.max()}  state peaks (levels): "
          + ", ".join(f"{p/LSB:.1f}" for p in pk))

# ---------------------------------------------------------------------------
# EF with IIR NTF: NTF = (1-z^-1)^L / (1-p z^-1)^L, dyadic p (shift-add RTL).
# w = u + f;  y = Q(w);  e = w - y_scaled;
# f[n] = sum(be_k e[n-k]) + sum(bf_k f[n-k])   (be = B-A taps, bf = -(B-1))
# ---------------------------------------------------------------------------
def poly_pow(p, L):
    """coefficients of (1 - p z^-1)^L"""
    c = np.array([1.0])
    for _ in range(L):
        c = np.convolve(c, [1.0, -p])
    return c

def run_ef_iir(L, p, amp_levels=28.0 * 10 ** (-1 / 20)):
    A = poly_pow(1.0, L)
    B = poly_pow(p, L)
    be = (B - A)[1:]          # taps on e[n-1..n-L]
    bf = -B[1:]               # taps on f[n-1..n-L]
    n = np.arange(N)
    u = amp_levels * np.sin(2 * np.pi * BIN * n / N)
    eh = np.zeros(L)
    fh = np.zeros(L)
    y = np.empty(N)
    dith = (RNG.random(N) + RNG.random(N) - 1.0)
    fpk = 0.0
    for i in range(N):
        f = float(np.dot(be, eh) + np.dot(bf, fh))
        fpk = max(fpk, abs(f))
        w = u[i] + 32.0 + f
        code = int(np.floor(w + dith[i]))
        if code > 63:
            code = 63
        elif code < 0:
            code = 0
        e = w - code
        eh[1:] = eh[:-1]; eh[0] = e
        fh[1:] = fh[:-1]; fh[0] = f
        y[i] = code
    return y, fpk

print()
for L, p in ((3, 0.25), (3, 0.5), (4, 0.5), (5, 0.5)):
    y, fpk = run_ef_iir(L, p)
    print(f"EF-IIR L={L} p={p:<5} NTFinf={2**L/((1+p)**L):4.2f}   SNDR={sndr(y):7.1f} dB  "
          f"code range {y.min():.0f}..{y.max():.0f}  |f|pk={fpk:.2f} levels")
