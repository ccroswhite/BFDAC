# Round 30 leg 4b addendum: tone check of the greedy 2nd-order vector shaper
# WITHOUT const-k padding (K=2 minimum; RTZ makes transition count benign, so
# padding is no longer needed). Candidate to replace DWA if tones are cleaner.
import numpy as np

src = open("dem_study.py").read()
prefix = src[: src.index("schemes = [")]
g = {}
exec(compile(prefix, "dem_study.py", "exec"), g)
NCELL = g["NCELL"]
NFFT = g["NFFT"]
BAND = g["BAND"]
BIN = g["BIN"]
RNG = np.random.default_rng(7)
g["w"] = 1.0 + 2.2e-3 * RNG.standard_normal(NCELL)   # 0.1% element + 0.2% duty spread
run_constk = g["run_constk"]

def modulate(u):
    code = np.empty(NFFT, int)
    i1 = i2 = vc = 0.0
    for i in range(NFFT):
        i1 += (u[i] - 32.0) - vc
        i2 += i1 - vc
        vc = min(max(round(i2), -32), 32)
        code[i] = int(vc) + 32
    return code

def metrics(code, y):
    e = y - code
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    sig_fs = (32.0 * NFFT / 2) ** 2
    return 10 * np.log10(E[mask].sum() / sig_fs), 10 * np.log10(E[mask].max() / sig_fs)

n = np.arange(NFFT)
print(f"{'stimulus':<30}{'greedy-2nd ib/pk dBFS':>22}   k_mean")
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
    name, y, k, carr = run_constk(2, carr=code, shape_par=True, greedy=True, g2=0.5, name="g2")
    ib, pk = metrics(code, y)
    print(f"{label:<30}{ib:11.1f}/{pk:9.1f}   {k.mean():.1f}")
