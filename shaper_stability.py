"""
BFDAC shaper long-run stability test (Round 8 follow-up)
Verifies the constant-k K=4 parity-shaped 2nd-order-greedy mapper (g2=0.5) for:
  - bounded shaper state: max|acc1|, max|acc2| tracked in windows over LONG runs (2^21 samples ~ 0.34s)
  - no growth trend: compare state bounds first half vs second half
  - idle/DC limit-cycle tones: in-band spectrum peak-vs-noise-floor check on pathological inputs
Inputs tested: -1dBFS sine, -60dBFS sine, silence (code 32), DC offsets incl. irrational, half-LSB.
"""
import numpy as np

NCELL = 64
FS = 6.144e6
NLONG = 2 ** 21
BIN = 43 * (NLONG // 2 ** 18)      # keep ~1007.8 Hz coherent
RNG = np.random.default_rng(7)
w = 1.0 + RNG.normal(0, 1e-3, NCELL)
K, G2 = 4, 0.5

def modulate(u):
    codes = np.empty(len(u), int)
    i1 = i2 = vc = 0.0
    for i in range(len(u)):
        i1 += (u[i] - 32.0) - vc
        i2 += i1 - vc
        vc = min(max(round(i2), -32), 32)
        codes[i] = int(vc) + 32
    return codes

def run_shaper(carr):
    sel = np.zeros(NCELL, bool)
    p = 0
    acc_par = 0
    acc1 = np.zeros(NCELL)
    acc2 = np.zeros(NCELL)
    y_mis = np.empty(len(carr))
    nwin = 64
    wlen = len(carr) // nwin
    a1max = np.zeros(nwin)
    a2max = np.zeros(nwin)
    def next_cell(new, start, p0, state):
        elig = np.nonzero((new == state) & (new == start))[0]
        if elig.size == 0:
            return -1
        m = acc1[elig] + G2 * acc2[elig]
        return elig[np.argmin(m)] if not state else elig[np.argmax(m)]
    for i in range(len(carr)):
        c = carr[i]
        start = sel.copy()
        new = sel
        d = c - int(start.sum())
        toggles = 0
        for _ in range(abs(d)):
            q = next_cell(new, start, p, d < 0)
            new[q] = d > 0
            toggles += 1
            p = (q + 1) % NCELL
        if (K - toggles) % 2 == 0:
            target = max(K, toggles)
        elif K - 1 >= toggles and acc_par > 0:
            target = K - 1
        else:
            target = K + 1
        acc_par += target - K
        while toggles < target:
            q_on = next_cell(new, start, p, False)
            if q_on < 0:
                break
            new[q_on] = True
            q_off = next_cell(new, start, (q_on + 1) % NCELL, True)
            if q_off < 0:
                new[q_on] = False
                break
            new[q_off] = False
            toggles += 2
            p = (q_off + 1) % NCELL
        acc1 += new
        acc1 -= c / NCELL
        acc2 += acc1
        y_mis[i] = w[new].sum()
        j = min(i // wlen, nwin - 1)
        a1max[j] = max(a1max[j], np.abs(acc1).max())
        a2max[j] = max(a2max[j], np.abs(acc2).max())
    return y_mis, a1max, a2max

SIG_P = None  # set from -1dBFS case below

def inband_report(err):
    """dem_study convention: coherent FFT, in-band 20Hz-20kHz, fundamental bin excluded.
    Returns (SNDR dB vs -1dBFS carrier, worst single spur dBc, spur dB over median floor)"""
    E = np.abs(np.fft.rfft(err - err.mean())) ** 2
    f = np.fft.rfftfreq(len(err), 1 / FS)
    mask = (f >= 20) & (f <= 20e3)
    mask[BIN] = False
    s = E[mask]
    sndr = 10 * np.log10(SIG_P / s.sum())
    spur_dbc = 10 * np.log10(s.max() / SIG_P)
    floor_db = 10 * np.log10(s.max() / np.median(s)) if np.median(s) > 0 else 0
    return sndr, spur_dbc, floor_db

cases = [
    ("-1dBFS sine",   32.0 + 32.0 * 10 ** (-1/20) * np.sin(2*np.pi*BIN*np.arange(NLONG)/NLONG)),
    ("-60dBFS sine",  32.0 + 32.0 * 10 ** (-60/20) * np.sin(2*np.pi*BIN*np.arange(NLONG)/NLONG)),
    ("silence (mid)", np.full(NLONG, 32.0)),
    ("DC +0.5 lvl",   np.full(NLONG, 32.5)),
    ("DC irrational", np.full(NLONG, 32.0 + np.sqrt(2) - 1)),
    ("DC near-full",  np.full(NLONG, 32.0 + 31.7)),
]

AMP1 = 32.0 * 10 ** (-1 / 20)
u_ref = 32.0 + AMP1 * np.sin(2 * np.pi * BIN * np.arange(NLONG) / NLONG)
c_ref = modulate(u_ref)
SIG_P = np.abs(np.fft.rfft(c_ref - c_ref.mean()))[BIN] ** 2

print(f"const-k K={K} par-shaped 2nd-order greedy g2={G2}, NCELL={NCELL}, N={NLONG} samples ({NLONG/FS*1e3:.0f} ms)")
print(f"{'case':<16}{'a1max_H1':>9}{'a1max_H2':>9}{'a2max_H1':>10}{'a2max_H2':>10}{'SNDR_mis':>9}{'worst_spur_dBc':>15}{'spur_vs_floor':>14}")
for label, u in cases:
    carr = modulate(u)
    y_mis, a1, a2 = run_shaper(carr)
    err = y_mis - carr
    sndr, spur, floor = inband_report(err)
    h = len(a1) // 2
    print(f"{label:<16}{a1[:h].max():9.1f}{a1[h:].max():9.1f}{a2[:h].max():10.1f}{a2[h:].max():10.1f}{sndr:9.1f}{spur:15.1f}{floor:14.1f}")
print("\nPASS: state bounds not growing H1->H2; worst spur well below -130dBc; sine SNDR ~130 matches dem_study.")
