# Quick-look for the Round 91 passive replica-ff legs (8 us sanity runs):
# replica current law, bus pinning vs the gate-88 reference, rail powers.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw

LT = r"C:\Users\ccros\Documents\LTspice"
RAILV = {"I(V_p15r)": 15.0, "I(V_n15r)": -15.0, "I(V_p8)": 9.0, "I(V_fr)": 1.75,
         "I(V_fr2)": 3.0, "I(Ve1)": 7.2, "I(Vb1)": 5.94, "I(Vb2)": 9.54,
         "I(Vcb2p)": 4.37, "I(Vcb2m)": 4.37}

def load(tag):
    names, data = read_raw(os.path.join(LT, f"bfdac_{tag}.raw"))
    t = data[0]
    return names, data, t

def stat(names, data, t, sig, t0=2e-6):
    m = t >= t0
    x = data[names.index(sig)][m]
    return x.min(), x.max(), x.mean(), np.trapezoid(x, t[m]) / (t[m][-1] - t[m][0])

for tag in sys.argv[1:] or ["q88", "q91a", "q91b"]:
    names, data, t = load(tag)
    print(f"=== {tag}: {len(t)} pts, {t[-1]*1e6:.1f} us ===")
    for sig in ["V(bus_plus)", "V(bus_minus)", "V(mid_p)", "V(casb_p)", "I(Re1p)", "I(Re1m)", "V(ns1p)"]:
        if sig in names:
            mn, mx, _, av = stat(names, data, t, sig)
            print(f"  {sig:14s} min {mn:9.4f}  max {mx:9.4f}  avg {av:9.4f}  p-p {mx-mn:8.4f}")
    ptot = 0.0
    for sig, v in RAILV.items():
        if sig in names:
            _, _, _, iav = stat(names, data, t, sig)
            # LTspice: I(Vsrc) positive = current INTO the + terminal (source sinking)
            p = -v * iav
            ptot += p
            print(f"  {sig:10s} {v:6.2f} V  I_avg {iav*1e3:9.2f} mA  P {p:8.3f} W")
    print(f"  total (analog decks rails)            P {ptot:8.3f} W  per channel-pair-of-rails")
