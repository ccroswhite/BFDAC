# R109: offline idle-pattern scan. Generates silence code streams with dpd_volt
# under different dither / DC-offset / kernel settings and reports the 12.01 kHz
# (fs/511.5) line in the stream's ACTIVITY proxies - the plant turns any
# periodic modulation of the code statistics into a tone (gate 110: -131 dB0).
#   python idle_scan.py            (M 65536, seed 192, LUT cosim107lut_inl.npy)
import numpy as np
import os
import subprocess
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
UT = os.path.dirname(os.path.abspath(__file__))
TS = 162.7604e-9
M, N = 65536, 65024
w = np.kaiser(N, 38)
f = np.fft.rfftfreq(N, TS)
ib = (f > 2.5e3) & (f < 20e3)
k12 = int(round(12011.8 * N * TS))

KERNEL = os.environ.get("KERNEL", "cosim109c3jw3")
breakers = [
    ("none",                 {}),
    ("DCOFF 0.5",            {"DCOFF": "0.5"}),
    ("OOB 0.5 @ fs/2",       {"OOB": "0.5,2"}),
    ("OOB 0.25 @ fs/2",      {"OOB": "0.25,2"}),
    ("OOB 0.5 @ fs/4",       {"OOB": "0.5,4"}),
    ("OOB 0.5 @ fs/3",       {"OOB": "0.5,3"}),
    ("HPD 0.25 ord2",        {"HPD": "0.25,2"}),
    ("HPD 0.25 ord3",        {"HPD": "0.25,3"}),
    ("HPD 0.5 ord3",         {"HPD": "0.5,3"}),
]
cases = [(f"{lv:>4s} dBFS | {nm}", dict(ev, AMPDB=lv)) for lv in ("-200", "-90", "-60") for nm, ev in breakers]

def line(x):
    x = x[512:] - x[512:].mean()
    P = 2 * np.abs(np.fft.rfft(x * w) / w.sum()) ** 2 / (28 ** 2 / 2)
    k = np.argmax(P * ib)
    return 10 * np.log10(P[k12 - 1:k12 + 2].max()), 10 * np.log10(np.median(P[ib])), f[k], 10 * np.log10(P[k])

print(f"kernel {KERNEL}; proxies: code (popcount), |dcode| (switching), code^2 (activity); "
      f"'worst' = max in-band bin minus median of that proxy (dB); code med = in-band popcount median dB0 (noise cost)")
print(f"{'case':30s} {'code med':>9s} {'code worst':>11s} {'|dcode| worst':>14s} {'code^2 worst':>13s} {'@ kHz':>7s} {'code rms':>9s}")
for name, ev in cases:
    env = dict(os.environ, M=str(M), BIN="11", DSEED="192", KERNEL=KERNEL)
    env.update(ev)
    subprocess.run([sys.executable, os.path.join(UT, "dpd_volt.py"), "cosim109lut_inl.npy", "tmp_idle.npy"],
                   env=env, capture_output=True, check=True)
    c = np.load(os.path.join(LT, "tmp_idle.npy")).astype(float)
    r1 = line(c)
    r2 = line(np.abs(np.diff(c, prepend=c[0])) * 0.01)
    r3 = line((c - 32) ** 2 * 1e-3)
    print(f"{name:30s} {r1[1]:9.1f} {r1[3]-r1[1]:11.1f} {r2[3]-r2[1]:14.1f} {r3[3]-r3[1]:13.1f} {r3[2]/1e3:7.2f} {c.std():9.2f}")
os.remove(os.path.join(LT, "tmp_idle.npy"))
