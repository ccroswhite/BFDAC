# R109: offline INJECTION scan - what the predistorted code stream itself
# carries at the harmonics / IMD products. The plant reproduces stream content
# within ~1 dB where it has no distortion of its own (gate 111: stream HD4/6/8
# -114 -> analog -113), so injected content must sit well below the D1/D3
# limits. Runs dpd_volt for each kernel at 1 kHz -1 dBFS (M 65536, BIN 11) and
# 19+20 kHz -3 dBFS (M 16384, bins 51/53), projects on the exact bins.
#   python inject_scan.py <lut> <kernel> [<kernel> ...]     env STATFIT=<deg>
# STATFIT=<deg>: also build <kernel>w<deg> with the stat table replaced by a
# sine-visit-weighted polynomial of that degree (kills one-hot roughness).
import numpy as np
import os
import shutil
import subprocess
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
UT = os.path.dirname(os.path.abspath(__file__))
LUT = sys.argv[1]
kernels = sys.argv[2:]
deg = os.environ.get("STATFIT")

def smooth(k, deg):
    s = np.load(rf"{LT}\{k}_stat.npy")
    c = np.arange(64) - 32.0
    n = np.arange(65536)
    code = np.clip(np.round(32 + 24.955 * np.sin(2 * np.pi * 11 * n / 65536)), 0, 63).astype(int)
    w = np.bincount(code, minlength=64).astype(float)
    m = w > 0
    p = np.polyfit(c[m], s[m], deg, w=np.sqrt(w[m]))
    nk = f"{k}w{deg}"
    for f in ("Q", "pairs", "firw"):
        shutil.copy(rf"{LT}\{k}_{f}.npy", rf"{LT}\{nk}_{f}.npy")
    np.save(rf"{LT}\{nk}_stat.npy", np.polyval(p, c))
    r = s - np.polyval(p, c)
    print(f"  {nk}: stat -> weighted deg-{deg} polynomial, dropped roughness "
          f"{np.sqrt(np.average(r[m]**2, weights=w[m]))*1e6:.1f} uV rms")
    return nk

if deg:
    kernels = kernels + [smooth(k, int(deg)) for k in kernels]

def stream(kernel, M, bin_, ampdb, bin2=0, seed=193, extra=None):
    env = dict(os.environ, M=str(M), BIN=str(bin_), AMPDB=str(ampdb), DSEED=str(seed), KERNEL=kernel)
    if bin2:
        env["BIN2"] = str(bin2)
    if extra:
        env.update(extra)
    subprocess.run([sys.executable, os.path.join(UT, "dpd_volt.py"), LUT, "tmp_inj.npy"],
                   env=env, capture_output=True, check=True)
    x = np.load(rf"{LT}\tmp_inj.npy").astype(float)
    return x - x.mean()

def proj(x, b):
    n = np.arange(len(x))
    return abs(2 * (x * np.exp(-2j * np.pi * b * n / len(x))).mean())

print(f"LUT {LUT}")
print(f"{'kernel':16s} 1 kHz -1 dBFS HD2..HD8 [dBc]                       | 19+20k -3 dBFS: f2-f1  2f1-f2  2f2-f1 [dB re peak]")
for k in kernels:
    x = stream(k, 65536, 11, -1)
    fund = proj(x, 11)
    hd = [20 * np.log10(proj(x, 11 * h) / fund) for h in range(2, 9)]
    y = stream(f"{k}", 16384, 51, -3, bin2=53, seed=190)
    pk = proj(y, 51) + proj(y, 53)
    imd = [20 * np.log10(proj(y, b) / pk) for b in (2, 49, 55)]
    print(f"{k:16s} " + " ".join(f"{v:7.1f}" for v in hd) + "   | " + " ".join(f"{v:7.1f}" for v in imd))
os.remove(rf"{LT}\tmp_inj.npy")
