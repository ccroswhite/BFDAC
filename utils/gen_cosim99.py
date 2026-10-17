# P5 gate 99 (2026-09-19): gate-93 plant with the 28R proxy loads replaced by
# the P5 transimpedance stage (iv_n5.py values). Same stimulus/PWL/code as
# gate 93 -> direct A/B on HD2..HD8 with the 92c3j kernel.
# Amp = BEHAVIORAL (cosim24 recipe: slew-limited gm into R||C integrator,
# GBW 40 MHz, 27 V/us, Aol 1e6, ideal unity buffer) - TRAP 10: the TI
# macro-models collapse the timestep on RTZ edges (3-day run); they are used
# for .noise only (gen_iv5.py).  Summing node held at 7.0 V = the col-node DC
# of the passive plant, C_col 12 nF kept.  diffout = (out_p - out_m)*28/Rf so
# rtz_fft39.py and the kernel domain (0.031 V/code) are unchanged.
# Usage: python gen_cosim99.py [TAG] [NPERIODS]   (NPERIODS -> short timing probe)
import numpy as np
import os
import re
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
TAG = sys.argv[1] if len(sys.argv) > 1 else "99"
NPER = int(sys.argv[2]) if len(sys.argv) > 2 else 0
TS = 162.7604e-9
RF, VVG = 270.0, 7.0
CF = 1 / (2 * np.pi * RF * 450e3)
VRAIL = float(os.environ.get("VRAIL", 24.0))     # R_off feed rail (iv_n5.py sweep)
VOUTDC = float(os.environ.get("VOUTDC", 0.0))
I_DC = {"p": 50e-3 + 32 * 0.5625e-3, "m": 50e-3 + 48e-3 - 32 * 0.5625e-3}   # 68 / 80 mA midcode
I_RF = (VVG - VOUTDC) / RF
ROFF = {s: (VRAIL - VVG) / (i + I_RF) for s, i in I_DC.items()}

src = open(os.path.join(LT, "bfdac_cosim93.cir")).read().replace("v93", f"v{TAG}")
# remove the proxy loads (C_col stays), keep diffout name/domain
src, n1 = re.subn(r"^R_load_p vp8 col_p \{rload\}\n", "", src, flags=re.M)
src, n2 = re.subn(r"^R_load_m vp8 col_m \{rload\}\n", "", src, flags=re.M)
assert n1 == n2 == 1, (n1, n2)
src, n3 = re.subn(r"^B_diff  diffout  0  V=\{V\(col_p\)-V\(col_m\)\}\n",
                  f"B_diff  diffout  0  V={{(V(out_p)-V(out_m))*28/{RF}}}\n", src, flags=re.M)
assert n3 == 1

def iv(side):
    return f"""* ----- P5 I/V, {side} rail: behavioral OPA1612-class + ideal buffer -----
R_off_{side}  v_roff  col_{side}  {ROFF[side]:.1f}
G_a_{side}  0  int_{side}  VALUE={{ilim*tanh((V(v_vg)-V(col_{side}))*gmv/ilim)}}
R_a_{side}  int_{side}  0  {{r1}}
C_a_{side}  int_{side}  0  {{c1}}
E_b_{side}  out_{side}  0  int_{side}  0  1
R_f_{side}  out_{side}  col_{side}  {RF}
C_f_{side}  out_{side}  col_{side}  {CF:.4g}
R_ld_{side} out_{side} 0 300
"""

block = f"""* ===== P5 I/V stage (iv_n5.py): Rf {RF:.0f} || Cf, R_off p/m {ROFF['p']:.0f}/{ROFF['m']:.0f} from +{VRAIL:.0f} V, sum at {VVG} V, out DC {VOUTDC} V =====
.param gbw=40Meg slw=27Meg aol=1e6 c1=100p
.param gmv={{2*pi*gbw*c1}} ilim={{slw*c1}} r1={{aol/gmv}}
V_vg  v_vg  0  DC {VVG}
V_roff  v_roff  0  DC {VRAIL}
{iv('p')}{iv('m')}"""
src = src.replace("V_fr  vfr  0  DC 1.75\n", block + "V_fr  vfr  0  DC 1.75\n")
src = src.replace(".save V(diffout) V(nsch)", ".save V(diffout) V(nsch) V(col_p) V(out_p)")
if NPER:
    src, n4 = re.subn(r"^\.tran 2n \S+ 0", f".tran 2n {NPER*TS*1e6:.6f}u 0", src, flags=re.M)
    assert n4 == 1
open(os.path.join(LT, f"bfdac_cosim{TAG}.cir"), "w").write(src)
np.save(os.path.join(LT, f"cosim{TAG}_code.npy"), np.load(os.path.join(LT, "cosim93_code.npy")))
print(f"{TAG}: gate-93 plant + P5 I/V (Rf {RF:.0f}, Cf {CF*1e12:.0f} pF, R_off p/m {ROFF['p']:.0f}/{ROFF['m']:.0f} "
      f"from +{VRAIL:.0f} V, sum {VVG} V, out DC {VOUTDC} V)"
      + (f"; SHORT probe {NPER} periods" if NPER else "; full 16384-period gate"))
