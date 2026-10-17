# Round 101 (2026-09-21): apply the RATIFIED P5 plant to ANY v80 + passive deck
# (LUT chop, ID record, FFT gate) so the R86/R92 recal protocol can be re-run on
# the plant the hardware will have. Rulings (progress.md N7, gate 100):
#   1. summing node V_VG = 4.0 V (3 V puts M6 in triode: mid_p 2.86 V, Vds 0.14 V)
#   2. R_f 270 || C_f (450 kHz), behavioral OPA1612-class amp + ideal buffer
#      (TRAP 10: TI macro-models collapse the timestep on RTZ edges)
#   3. R_off from +15F, sized for the midcode DC (68 / 80 mA p/m, dem_sort plant)
#   4. padding mirror = Si1555 MOSFET (gate 0.6 V -> ~50 mA through 286R from -15),
#      bottom-cascode gate stopper Rg5 100 -> 10R
# The 28R proxy loads are removed; C_col 12 nF stays.  diffout is re-derived as
# (out_m - out_p)*28/Rf so it FALLS with code exactly like the 28R proxy did
# (rtz_inl_full sign, rtz_fft39 domain and dpd_volt GAIN_V = -0.031 unchanged).
#   python patch_p5.py <src_tag> <dst_tag>
# Copies cosim<src>_code.npy -> cosim<dst>_code.npy when present.
# Env: VVG (4.0) VRAIL (15) RF (270) RG5 (10) VPADG (0.6) PADMOS (1)
#      CCOL (12n) summing-node C (R104: 47n)
#      MIDCODE (32) mean code the R_off pair is sized for; 32.5 nulls the DC of
#        the R110 idle-pattern breaker (DCOFF 0.5) at the summing nodes
#      IVMODE tia (default) | rload (R105 alternative architecture: passive
#        R_load RLOAD (100) from +VRAIL to col, C_col as RTZ filter, RC
#        pre-filter RVF/CVF (100/10n) into a behavioral difference amp of
#        gain GV (2.7) built from the same OPA1612-class block - the amp
#        never sees the RTZ ripple). R1V (2000) keeps col loading < 5 %;
#        200R loaded col by ~8 mA DC and skewed p/m gain. Noise of this
#        variant NOT verified (2k/5.4k resistors alone ~2.3 nV/rtHz in the 28R
#        domain = over budget - a winning 105 needs a low-noise realization).
import os
import re
import shutil
import sys
import numpy as np

LT = r"C:\Users\ccros\Documents\LTspice"
VVG = float(os.environ.get("VVG", 4.0))
VRAIL = float(os.environ.get("VRAIL", 15.0))
RF = float(os.environ.get("RF", 270.0))
RG5 = float(os.environ.get("RG5", 10.0))
VPADG = float(os.environ.get("VPADG", 0.6))
PADMOS = int(os.environ.get("PADMOS", 1))
CCOL = os.environ.get("CCOL", "12n")
IVMODE = os.environ.get("IVMODE", "tia")
RLOAD = float(os.environ.get("RLOAD", 100.0))
RVF, CVF = os.environ.get("RVF", "100"), os.environ.get("CVF", "10n")
GV = float(os.environ.get("GV", 2.7))
R1V = float(os.environ.get("R1V", 2000.0))
CF = 1 / (2 * np.pi * RF * 450e3)
MIDCODE = float(os.environ.get("MIDCODE", 32))
# midcode DC per side (gen_cosim99 bookkeeping): 50 mA pad + k*0.5625 mA (p),
# 50 + 48 - k*0.5625 (m); unselected cells steer into bus_minus
I_DC = {"p": 50e-3 + MIDCODE * 0.5625e-3, "m": 50e-3 + 48e-3 - MIDCODE * 0.5625e-3}
I_RF = VVG / RF                      # out DC = 0 V
ROFF = {s: (VRAIL - VVG) / (i + I_RF) for s, i in I_DC.items()}


def sub1(src, pat, rep, n_expect=1):
    out, n = re.subn(pat, rep, src, flags=re.M)
    assert n == n_expect, (pat, n)
    return out


def iv(side):
    return f"""* ----- P5 I/V, {side} rail: behavioral OPA1612-class + ideal buffer -----
R_off_{side}  v_roff  col_{side}  {ROFF[side]:.1f}
G_a_{side}  0  int_{side}  VALUE={{ilim*tanh((V(v_vg)-V(col_{side}))*gmv/ilim)}}
R_a_{side}  int_{side}  0  {{r1}}
C_a_{side}  int_{side}  0  {{c1}}
E_b_{side}  out_{side}  0  int_{side}  0  1
R_f_{side}  out_{side}  col_{side}  {RF:g}
C_f_{side}  out_{side}  col_{side}  {CF:.4g}
R_ld_{side} out_{side} 0 300
"""


AMP = (".param gbw=40Meg slw=27Meg aol=1e6 c1=100p\n"
       ".param gmv={2*pi*gbw*c1} ilim={slw*c1} r1={aol/gmv}\n")


def vstage():
    r2 = GV * R1V
    return f"""* ===== R105 ALTERNATIVE: passive load + filtered difference V-stage =====
* R_load {RLOAD:g} from +{VRAIL:g} (col DC ~{VRAIL - 0.074*RLOAD:.1f} V), C_col RTZ filter, RC {RVF}/{CVF} pre-filter,
* OPA1612-class difference amp R1 {R1V:g} / R2 {r2:g} (gain {GV:g}); diffout = -out*28/(R_load*G) (falls with code)
{AMP}V_roff  v_roff  0  DC {VRAIL:g}
R_load_p v_roff col_p {RLOAD:g}
R_load_m v_roff col_m {RLOAD:g}
R_vf_p col_p vf_p {RVF}
C_vf_p vf_p 0 {CVF}
R_vf_m col_m vf_m {RVF}
C_vf_m vf_m 0 {CVF}
R1_p vf_p inv_d {R1V:g}
R2_p inv_d out_d {r2:g}
R1_m vf_m ninv_d {R1V:g}
R2_m ninv_d 0 {r2:g}
G_a_d  0  int_d  VALUE={{ilim*tanh((V(ninv_d)-V(inv_d))*gmv/ilim)}}
R_a_d  int_d  0  {{r1}}
C_a_d  int_d  0  {{c1}}
E_b_d  out_d  0  int_d  0  1
R_ld_d out_d 0 600
"""


def patch(src):
    # proxy loads out, diffout re-derived in the same (falling-with-code) domain
    src = sub1(src, r"^R_load_[pm] vp8 col_[pm] \{rload\}\n", "", 2)
    src = sub1(src, r"^C_col_([pm]) col_[pm] 0 12n$", rf"C_col_\1 col_\1 0 {CCOL}", 2)
    if IVMODE == "rload":
        src = sub1(src, r"^B_diff  diffout  0  V=\{V\(col_p\)-V\(col_m\)\}$",
                   f"B_diff  diffout  0  V={{-V(out_d)*28/{RLOAD*GV:g}}}")
        block = vstage()
    else:
        src = sub1(src, r"^B_diff  diffout  0  V=\{V\(col_p\)-V\(col_m\)\}$",
                   f"B_diff  diffout  0  V={{(V(out_m)-V(out_p))*28/{RF:g}}}")
        block = (f"* ===== P5 I/V stage (ratified 2026-09-21): Rf {RF:g} || Cf {CF*1e12:.0f} pF, "
                 f"R_off p/m {ROFF['p']:.0f}/{ROFF['m']:.0f} from +{VRAIL:g} V, sum at {VVG:g} V, C_col {CCOL} =====\n"
                 + AMP +
                 f"V_vg  v_vg  0  DC {VVG:g}\n"
                 f"V_roff  v_roff  0  DC {VRAIL:g}\n" + iv("p") + iv("m"))
    anchor = "V_fr  vfr  0  DC 1.75\n"
    assert anchor in src
    src = src.replace(anchor, block + anchor)
    # plant items from gate 100
    src = sub1(src, r"^(Rg5_[pm] casb_[pm] m5g_[pm]) 100$", rf"\1 {RG5:g}", 2)
    if PADMOS:
        src = sub1(src, r"^Qpad_(p|m) bus_(plus|minus) padb_base padb_e(p|m) QNPN_THAT_NS$",
                   lambda m: f"Mpad_{m.group(1)} bus_{m.group(2)} padb_base padb_e{m.group(3)} padb_e{m.group(3)} Si1555DL_N", 2)
        src = sub1(src, r"^Vpadb padb_base 0 DC 0$", f"Vpadb padb_base 0 DC {VPADG:g}")
    return src


if __name__ == "__main__":
    s, d = sys.argv[1], sys.argv[2]
    src = open(os.path.join(LT, f"bfdac_cosim{s}.cir")).read()
    out = patch(src)
    first = out.split("\n", 1)
    out = first[0].rstrip() + f" + P5 I/V plant [{IVMODE}, C_col {CCOL}] (patched from {s})\n" + first[1]
    open(os.path.join(LT, f"bfdac_cosim{d}.cir"), "w").write(out)
    p = os.path.join(LT, f"cosim{s}_code.npy")
    if s != d and os.path.exists(p):
        shutil.copyfile(p, os.path.join(LT, f"cosim{d}_code.npy"))
    desc = (f"R_load {RLOAD:g} + V-stage G {GV:g} (RC {RVF}/{CVF})" if IVMODE == "rload" else
            f"V_VG {VVG:g}, R_off p/m {ROFF['p']:.0f}/{ROFF['m']:.0f} from +{VRAIL:g}, Rf {RF:g}")
    print(f"wrote bfdac_cosim{d}.cir from {s}: {desc}, C_col {CCOL}, Rg5 {RG5:g}, pad {'MOSFET' if PADMOS else 'BJT'}")
