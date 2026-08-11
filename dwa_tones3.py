# Round 30 leg 4b final: UNCONSTRAINED sort-based vector mismatch shaper.
# Only possible under RTZ (toggles are free): each sample, select the c cells
# with the lowest shaping metric acc1 + g2*acc2. This is the textbook-optimal
# vector shaper that NRZ glitch physics forbade. Tone + shaping check.
import numpy as np

NCELL = 64
FS = 6.144e6
TS = 1.0 / FS
NFFT = 2 ** 18
BIN = 43
RNG = np.random.default_rng(7)
W = 1.0 + 2.2e-3 * RNG.standard_normal(NCELL)

F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)
n = np.arange(NFFT)

def modulate(u):
    code = np.empty(NFFT, int)
    i1 = i2 = vc = 0.0
    for i in range(NFFT):
        i1 += (u[i] - 32.0) - vc
        i2 += i1 - vc
        vc = min(max(round(i2), -32), 32)
        code[i] = int(vc) + 32
    return code

def run_sort(code, g2=0.5, dith=0.0):
    """each sample: pick c cells with the smallest acc1+g2*acc2 (+ optional
    tiny random dither on the metric to break ties/limit cycles)."""
    rng = np.random.default_rng(3)
    acc1 = np.zeros(NCELL)
    acc2 = np.zeros(NCELL)
    y = np.empty(NFFT)
    for i in range(NFFT):
        c = code[i]
        m = acc1 + g2 * acc2
        if dith > 0:
            m = m + dith * rng.standard_normal(NCELL)
        sel = np.argpartition(m, c - 1)[:c] if c > 0 else np.empty(0, int)
        onv = np.zeros(NCELL)
        onv[sel] = 1.0
        y[i] = W[sel].sum() if c > 0 else 0.0
        acc1 += onv - c / NCELL
        acc2 += acc1
    return y

def metrics(code, y):
    e = y - code
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    sig_fs = (32.0 * NFFT / 2) ** 2
    return 10 * np.log10(E[mask].sum() / sig_fs), 10 * np.log10(E[mask].max() / sig_fs)

print(f"{'stimulus':<30}{'sort g2=.5 ib/pk':>20}{'sort g2=0 ib/pk':>20}")
for label, amp, dc in [
    ("-1 dBFS sine", 10 ** (-1 / 20), 32.0),
    ("-20 dBFS sine", 10 ** (-20 / 20), 32.0),
    ("-60 dBFS sine", 10 ** (-60 / 20), 32.0),
    ("-60 dBFS + 0.5-level DC", 10 ** (-60 / 20), 32.5),
    ("-80 dBFS sine", 10 ** (-80 / 20), 32.0),
    ("silence + 0.25-level DC", 0.0, 32.25),
]:
    u = dc + 32.0 * amp * np.sin(2 * np.pi * BIN * n / NFFT)
    code = modulate(u)
    ib1, pk1 = metrics(code, run_sort(code, g2=0.5))
    ib2, pk2 = metrics(code, run_sort(code, g2=0.0))
    print(f"{label:<30}{ib1:10.1f}/{pk1:8.1f}{ib2:10.1f}/{pk2:8.1f}")
