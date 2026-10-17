# N2c readout: independent per-cell FF jitter (gate 98, sigma 10 ps) vs the
# common-jitter N2 slope. Differential pavg(98)-pavg(93); in-band 20 Hz-20 kHz
# Kaiser b38, re -1 dBFS fund 0.62 Vrms; floor-corrected with the N2 sigma=0
# control (0.90 uV PWL-grid floor). Reports the independence ratio
# (in-band uV per ps, independent) / (1.1 uV per ps, common).
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts
from scipy.signal.windows import kaiser

LT = r"C:\Users\ccros\Documents\LTspice"
M, DISCARD = 16384, 512
FS = 1 / Ts
VRMS_FUND_M1DB = 0.62
SIG_PS = 10.0
COMMON_UV_PER_PS = 1.1
CONTROL_UV = 0.90

def pavg(tag):
    p = rf"{LT}\cosim{tag}_pavg.npy"
    if os.path.exists(p):
        return np.load(p)[:M]
    names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
    t, d = data[0], data[names.index("V(diffout)")]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(p, a)
    return a

ref = pavg("93")
code = np.load(rf"{LT}\cosim93_code.npy").astype(float)[:M]
gain = np.polyfit(code[DISCARD:], ref[DISCARD:], 1)[0]
fund = 28.0 * 10 ** (-1 / 20)
e = (pavg("98") - ref)[DISCARD:] / gain
e = e - e.mean()
N = len(e)
w = kaiser(N, 38)
cg = w.mean()
X = np.fft.rfft(e * w) / (N * cg)
f = np.fft.rfftfreq(N, 1 / FS)
enbw = (w ** 2).mean() / cg ** 2
psd = 2 * np.abs(X) ** 2 / (enbw * FS / N)          # code^2/Hz
ib = (f >= 20) & (f <= 20e3)
v_ib = np.sqrt(np.trapezoid(psd[ib], f[ib])) / (fund / np.sqrt(2)) * VRMS_FUND_M1DB
tot = np.sqrt(np.trapezoid(psd[1:], f[1:])) / (fund / np.sqrt(2)) * VRMS_FUND_M1DB
corr = np.sqrt(max(v_ib ** 2 - (CONTROL_UV * 1e-6) ** 2, 0))
ratio = corr * 1e6 / SIG_PS / COMMON_UV_PER_PS
print(f"gate 98 (independent per-cell sigma {SIG_PS:.0f} ps) differential vs 93:")
print(f"  in-band 20Hz-20kHz: {v_ib*1e6:.2f} uVrms  ({20*np.log10(VRMS_FUND_M1DB/v_ib):.1f} dB re fund)"
      f" | full-band {tot*1e6:.1f} uVrms")
print(f"  floor-corrected (control {CONTROL_UV} uV): {corr*1e6:.2f} uV -> "
      f"{corr*1e6/SIG_PS:.3f} uV/ps independent vs {COMMON_UV_PER_PS} uV/ps common")
print(f"  INDEPENDENCE RATIO = {ratio:.3f}  (pn_n2b.py assumed sqrt(64)/40 = 0.200)")
for ff in (200, 400, 600, 1000):
    print(f"    per-FF {ff:5d} fs -> FF line {ff*1e-3*COMMON_UV_PER_PS*ratio*1e3:6.1f} nV")
