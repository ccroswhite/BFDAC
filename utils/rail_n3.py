# N3 analysis: rail/reference tone-injection sensitivity, differential
# pavg(79x)-pavg(77). LS quadrature fit at the two injected tones (997/9973Hz)
# plus intermod sidebands around the 13.875k fund (fund +/- tone). Sensitivity
# in V/V (diffout per rail volt) -> budget line vs regulator noise density.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
DISCARD = 512
BIN = 37
F1, F2 = 997.0, 9973.0
FFUND = BIN / (M * Ts)

def pavg(tag):
    p = rf"{LT}\cosim{tag}_pavg.npy"
    if os.path.exists(p):
        return np.load(p)[:M]
    names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
    t = data[0]
    d = data[names.index("V(diffout)")]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(p, a)
    return a

ref = pavg("77")
fund_v = 28.0 * 10 ** (-1 / 20) * 0.0310   # V at diffout

for tag, amp_inj, rail in (("79a", 1e-3, "V_ref"), ("79b", 10e-3, "vcc15")):
    e = (pavg(tag) - ref)[DISCARD:]
    e = e - e.mean()
    N = len(e)
    tt = (np.arange(N) + DISCARD) * Ts
    comps = {"tone1": F1, "tone2": F2,
             "f-t1": FFUND - F1, "f+t1": FFUND + F1,
             "f-t2": FFUND - F2, "f+t2": FFUND + F2}
    nn = np.arange(N) / N
    cols = [np.ones(N), nn, nn ** 2]
    keys = list(comps)
    for k in keys:
        cols += [np.cos(2 * np.pi * comps[k] * tt), np.sin(2 * np.pi * comps[k] * tt)]
    A = np.vstack(cols).T
    c, *_ = np.linalg.lstsq(A, e, rcond=None)
    amps = np.hypot(c[3::2], c[4::2])
    resid = e - A @ c
    floor = np.sqrt(2) * resid.std() / np.sqrt(N / 2)
    print(f"\n=== {tag}: {amp_inj*1e3:.0f}mV tones on {rail} ===")
    print(f"  resid rms {resid.std()*1e6:.2f} uV; per-tone floor {floor*1e9:.1f} nV")
    for k, a in zip(keys, amps):
        sens = a / amp_inj
        print(f"  {k:5s} ({comps[k]/1e3:7.3f} kHz): {a*1e9:9.1f} nV at diffout "
              f"-> sens {20*np.log10(max(sens,1e-12)):6.1f} dB (V/V), "
              f"{20*np.log10(max(a,1e-15)/fund_v):7.1f} dBc")
