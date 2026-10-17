# P3 / N2b (2026-09-12): CLOSE-IN PHASE-NOISE VALIDATION GATE.
# Gate-93 deck (passive replica plant, BIN=37 = 13.875 kHz, 92lut+92c3j) with
# the shared RTZ window sources pwa/pwb replaced by PWL trains whose edges are
# ALL displaced by one common slow phase modulation tau(t) = A*sin(2*pi*fm*t)
# (= carrier phase noise at offset fm after the reclock flops). Both edges of
# every pulse move together, so the pulse WIDTH is untouched and only its
# POSITION moves. Two competing predictions for the fund+/-fm sidebands:
#   time-warp   : each sideband = 2*pi*f_sig*A/2  -> -113.2 dBc (A=50ps, 13.875k)
#   charge-modul: each sideband = (A/T_w)/2       ->  -73.7 dBc
# Differential readout pavg(97)-pavg(93) (jitter_n2 style, deterministic
# content cancels). fm = bin 3 = 1125 Hz (coherent).
import numpy as np
import os

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
TS = 162.7604e-9
TC = TS / 8
T0 = TC
TEDGE = 3e-9
TWID = 6 * TC
SKEW = 1e-9
A = 50e-12
FM_BIN = 3
FM = FM_BIN / (M * TS)

def tau(t):
    return A * np.sin(2 * np.pi * FM * t)

def pwl_train(skew):
    lines = ["0 0"]
    for k in range(M):
        tr = k * TS + T0 + skew
        tf = k * TS + T0 + TEDGE + TWID + skew
        tr += tau(tr)
        tf += tau(tf)
        lines.append(f"{tr*1e9:.6f}n 0")
        lines.append(f"{(tr+TEDGE)*1e9:.6f}n 1")
        lines.append(f"{tf*1e9:.6f}n 1")
        lines.append(f"{(tf+TEDGE)*1e9:.6f}n 0")
    lines.append(f"{(M*TS)*1e9:.6f}n 0")
    return "\n".join(lines) + "\n"

tag = "97"
src = open(os.path.join(LT, "bfdac_cosim93.cir")).read()
pd = os.path.join(LT, f"pwl{tag}")
os.makedirs(pd, exist_ok=True)
open(os.path.join(pd, "pwa.txt"), "w").write(pwl_train(0.0))
open(os.path.join(pd, "pwb.txt"), "w").write(pwl_train(SKEW))
src = src.replace("v93", f"v{tag}").replace("pwl93", "pwl93")   # sel vectors shared
src = src.replace(
    "Vpwa pwa 0 PULSE(0 1 {t0} {tedge} {tedge} {twid} {Ts})",
    f'Vpwa pwa 0 PWL file="{pd}\\pwa.txt"')
src = src.replace(
    "Vpwb pwb 0 PULSE(0 1 {t0+skew} {tedge} {tedge} {twid} {Ts})",
    f'Vpwb pwb 0 PWL file="{pd}\\pwb.txt"')
assert "PULSE(0 1 {t0" not in src
open(os.path.join(LT, f"bfdac_cosim{tag}.cir"), "w").write(src)
np.save(os.path.join(LT, f"cosim{tag}_code.npy"),
        np.load(os.path.join(LT, "cosim93_code.npy")))
fsig = 37 / (M * TS)
print(f"{tag}: A={A*1e12:.0f} ps, fm={FM:.1f} Hz (bin {FM_BIN}); predictions per sideband: "
      f"time-warp {20*np.log10(2*np.pi*fsig*A/2):.1f} dBc, "
      f"charge-modulation {20*np.log10(A/TWID/2):.1f} dBc")
