# Round 30: SNDR/tone check of the INTEGER-EXACT sort shaper (lexsort
# tie-break, the exact RTL algorithm) vs the float version from dwa_tones3.
import numpy as np
from dem_sort_gen import modulate, run_int_sort, NCELL, NFFT, BIN

FS = 6.144e6
TS = 1.0 / FS
RNG = np.random.default_rng(7)
W = 1.0 + 2.2e-3 * RNG.standard_normal(NCELL)
F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)

def metrics(code, y):
    e = y - code
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    sig_fs = (32.0 * NFFT / 2) ** 2
    return 10 * np.log10(E[mask].sum() / sig_fs), 10 * np.log10(E[mask].max() / sig_fs)

n = np.arange(NFFT)
print(f"{'stimulus':<28}{'int-sort ib/pk dBFS':>22}")
for label, amp, dc in [
    ("-1 dBFS sine", 10 ** (-1 / 20), 32.0),
    ("-60 dBFS sine", 10 ** (-60 / 20), 32.0),
    ("-60 dBFS + 0.5-level DC", 10 ** (-60 / 20), 32.5),
    ("silence + 0.25-level DC", 0.0, 32.25),
]:
    u = dc + 32.0 * amp * np.sin(2 * np.pi * BIN * n / NFFT)
    code = modulate(u)
    sels, _, _, _ = run_int_sort(code)
    y = sels @ W
    ib, pk = metrics(code, y)
    print(f"{label:<28}{ib:11.1f}/{pk:9.1f}")
