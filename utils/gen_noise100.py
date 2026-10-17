# N7 / gate 100 (2026-09-21): FULL-PLANT static .noise of the ratified gate-93
# deck with the P5 I/V (TI OPA1612 + BUF634A macro-models) - the SPICE check of
# the analytic stack (thermal_n4 core, flicker_n6 P6 lines, iv_n5 I/V, N3 V_ref).
# static midcode: cells 1..32 selected, RTZ window held ON (pwa=pwb=1); .noise
# is a small-signal analysis so no timestep problem (TRAP 10 does not apply).
# I/V amp = BEHAVIORAL (the TI macro-models fail the 64-cell DC op point) with
# OPA1612 e_n / i_n injected by copier sources (gen_iv5.py verified the
# analytic amp lines against the macro-models to 4%).  Buffer ideal (its
# noise is loop-suppressed when Cf hangs on its output - iv5 finding).
# Reference/rail noise is injected with resistor-noise copiers:
#   Rn nX 0 R  (4kTR = e_n^2)  +  E  node  node_ideal  nX 0 1
# so ideal V sources carry a spec'd white e_n (1/f not modelled -> P6 stays
# analytic for the MOSFET 1/f; the .noise gives thermal + shot + the wC_bus
# conversion of every rail that reaches casb).  Jitter (P3) and quantization
# (N1) are time-domain lines and are added analytically in the report.
# MIS: fractional p/m mismatch applied to R_off, C_bus, R_f and Rg5 on the MINUS
# side so the common-mode rail copiers (vfr, casb2, 5.94, 7.2, FF, V_ref, V_VG)
# leak differentially instead of cancelling in the symmetric deck (P6 leak line).
# DUTY: the static deck holds the RTZ window ON; the cell groups (Rt, tail Q,
# steering QS) reach the differential output only for DUTY of the period, so
# their power is scaled by DUTY in the report (rails/I-V/pad are continuous).
# EROFF: white e_n (V/rtHz) put on the R_off feed rail (default 0 = ideal, as in gate 100); item 17
#   shallow-rail gate: VRAIL 8 -> R_off ~45R, rail-noise gain into the summing node x2.8.
# VPADRAIL: padding-mirror return rail (default -15); Rpad rescaled from 286R so the pad current stays
#   ~47.5 mA (MOSFET source ~-1.4 V). Item 13 shallow-rail gate.
# Usage: python gen_noise100.py [run]   env: VVG VRAIL VOUTDC NPAR RF PADMOS RG5 MIS DUTY EROFF VPADRAIL
import os
import re
import sys
import subprocess
import numpy as np

LT = r"C:\Users\ccros\Documents\LTspice"
LTEXE = r"C:\Program Files\ADI\LTspice\LTspice.exe"
VVG = float(os.environ.get("VVG", 4.0))
VRAIL = float(os.environ.get("VRAIL", 15.0))
VOUTDC = float(os.environ.get("VOUTDC", 0.0))
NPAR = int(os.environ.get("NPAR", 1))
RF = float(os.environ.get("RF", 270.0))
CF = 1 / (2 * np.pi * RF * 450e3)
PADMOS = int(os.environ.get("PADMOS", 0))      # 1: padding mirror = Si1555 MOSFET (no base shot noise)
RG5 = float(os.environ.get("RG5", 100.0))       # bottom-cascode gate stopper (100R in v93)
MIS = float(os.environ.get("MIS", 0.0))         # p/m mismatch fraction (R_off, C_bus, R_f, Rg5 on the m side)
DUTY = float(os.environ.get("DUTY", 1.0))       # RTZ duty applied to the cell groups in the report (6/8 in the plant)
EROFF = float(os.environ.get("EROFF", 0.0))     # R_off feed-rail e_n, V/rtHz (0 = ideal rail)
VPADRAIL = float(os.environ.get("VPADRAIL", -15.0))   # padding mirror return rail
RPAD = 286.0 * (abs(VPADRAIL) - 1.4) / 13.6
TAG = os.environ.get("TAG", f"100_v{VVG:g}_r{VRAIL:g}" + (f"_p{NPAR}" if NPAR > 1 else "")
                     + ("_padmos" if PADMOS else "") + (f"_rg{RG5:g}" if RG5 != 100 else "")
                     + (f"_mis{MIS*100:g}" if MIS else "") + (f"_eroff{EROFF*1e9:g}" if EROFF else "")
                     + (f"_pad{VPADRAIL:g}" if VPADRAIL != -15 else ""))
kT4 = 4 * 1.380649e-23 * 318.15          # .temp 45
# spec'd white noise densities (V/rtHz) -> copier resistors
EN = {"ref": 55e-9, "vfr": 20e-9, "cb2": 20e-9, "vb1": 20e-9, "ve1": 20e-9, "ff": 15e-9, "vg": 10e-9, "padb": 20e-9,
      "en_p": 1.1e-9 / np.sqrt(NPAR), "en_m": 1.1e-9 / np.sqrt(NPAR)}
if EROFF:
    EN["roff"] = EROFF
RN = {k: v ** 2 / kT4 for k, v in EN.items()}
IN_AMP = 1.7e-12 * np.sqrt(NPAR)        # A/rtHz, injected via G from a 1k copier resistor
R_IN = 1e3
G_IN = IN_AMP / np.sqrt(kT4 * R_IN)
I_DC = {"p": 50e-3 + 32 * 0.75e-3, "m": 50e-3 + 32 * 0.75e-3}   # static window ON: 74/74 mA
I_RF = (VVG - VOUTDC) / RF
ROFF = {s: (VRAIL - VVG) / (i + I_RF) for s, i in I_DC.items()}

src = open(os.path.join(LT, "bfdac_cosim93.cir")).read()
# --- static stimulus ---
src = re.sub(r"^Vsel(\d+) sel\1 0 PWL file=.*$",
             lambda m: f"Vsel{m.group(1)} sel{m.group(1)} 0 DC {1 if int(m.group(1)) <= 32 else 0}", src, flags=re.M)
src = re.sub(r"^Vpwa pwa 0 PULSE.*$", "Vpwa pwa 0 DC 1", src, flags=re.M)
src = re.sub(r"^Vpwb pwb 0 PULSE.*$", "Vpwb pwb 0 DC 1", src, flags=re.M)
src = re.sub(r"^Vnsch nsch 0 PWL.*$", "Vnsch nsch 0 DC 0", src, flags=re.M)
# --- rail/reference noise copiers ---
def noisy(name_regex, node, val, key):
    global src
    pat = rf"^{name_regex}\s+{node}\s+0\s+DC\s+{val}\s*$"
    rep = (f"Vi_{key} {node}_i 0 DC {val}\n"
           f"Rn_{key} n_{key} 0 {RN[key]:.4g}\n"
           f"E_{key} {node} {node}_i n_{key} 0 1")
    src, n = re.subn(pat, rep, src, flags=re.M)
    assert n == 1, (pat, n)
noisy("V_ref", "vref", "1.25", "ref")
noisy("V_fr", "vfr", "1.75", "vfr")
noisy("Vb1", "vb1", "5.94", "vb1")
noisy("Ve1", "ve1", "7.2", "ve1")
noisy("Vpadb", "padb_base", "0", "padb")
# casb2 p/m share one reference
src, n = re.subn(r"^Vcb2p casb2_p 0 DC 4.37\nVcb2m casb2_m 0 DC 4.37$",
                 f"Vcb2 cb2_i 0 DC 4.37\nRn_cb2 n_cb2 0 {RN['cb2']:.4g}\nE_cb2p casb2_p cb2_i n_cb2 0 1\nE_cb2m casb2_m cb2_i n_cb2 0 1",
                 src, flags=re.M)
assert n == 1
# FF rail noise into the 64x2 CMOS outputs (common to all FFs)
src, n1 = re.subn(r"V=\{3\.3\*V\(sel", "V={(3.3+V(n_ff))*V(sel", src)
src, n2 = re.subn(r"V=\{3\.3\*\(1-V\(sel", "V={(3.3+V(n_ff))*(1-V(sel", src)
assert n1 == n2 == 64, (n1, n2)
src = src.replace("* node: Vb 2.97..4.62 V", f"Rn_ff n_ff 0 {RN['ff']:.4g}\n* node: Vb 2.97..4.62 V")
# --- plant variants ---
if PADMOS:
    src, n = re.subn(r"^Qpad_(p|m) bus_(plus|minus) padb_base padb_e(p|m) QNPN_THAT_NS$",
                     lambda m: f"Mpad_{m.group(1)} bus_{m.group(2)} padb_base padb_e{m.group(3)} padb_e{m.group(3)} Si1555DL_N",
                     src, flags=re.M)
    assert n == 2, n
if RG5 != 100:
    src, n = re.subn(r"^(Rg5_[pm] casb_[pm] m5g_[pm]) 100$", rf"\1 {RG5:g}", src, flags=re.M); assert n == 2
if VPADRAIL != -15:
    src, n = re.subn(r"^V_n15r  vee15  0  DC -15$", "V_n15r  vee15  0  DC -15\nV_padr  vpadr  0  DC %g" % VPADRAIL, src, flags=re.M); assert n == 1
    src, n = re.subn(r"^(Rpad_[pm] padb_e[pm]) vee15 286$", rf"\1 vpadr {RPAD:.1f}", src, flags=re.M); assert n == 2
if MIS:
    src, n = re.subn(r"^(Rg5_m casb_m m5g_m) (\S+)$", lambda m: f"{m.group(1)} {float(m.group(2))*(1+MIS):.4g}", src, flags=re.M); assert n == 1
    src, n = re.subn(r"^C_bus_m  bus_minus  0  \{cbus\}$", f"C_bus_m  bus_minus  0  {{cbus*{1+MIS}}}", src, flags=re.M); assert n == 1
# --- remove proxy loads, add I/V ---
src, n = re.subn(r"^R_load_[pm] vp8 col_[pm] \{rload\}\n", "", src, flags=re.M); assert n == 2
src, n = re.subn(r"^B_diff  diffout  0  V=\{V\(col_p\)-V\(col_m\)\}$",
                 f"B_diff  diffout  0  V={{(V(out_p)-V(out_m))*28/{RF}}}", src, flags=re.M); assert n == 1

def amp(side):
    # behavioral OPA1612-class: e_n in series with +in, i_n into the summing node
    return f"""Rn_en_{side} n_en_{side} 0 {RN['en_'+side]:.4g}
E_en_{side} vgp_{side} v_vg n_en_{side} 0 1
Rn_in_{side} n_in_{side} 0 {R_IN:.4g}
G_in_{side} 0 col_{side} n_in_{side} 0 {G_IN:.4g}
G_a_{side} 0 int_{side} VALUE={{ilim*tanh((V(vgp_{side})-V(col_{side}))*gmv/ilim)}}
R_a_{side} int_{side} 0 {{r1}}
C_a_{side} int_{side} 0 {{c1}}
E_b_{side} out_{side} 0 int_{side} 0 1"""

iv = f"""* ===== P5 I/V (behavioral amp + OPA1612 e_n/i_n copiers, NPAR {NPAR}), sum at {VVG} V, R_off feed +{VRAIL} V, out DC {VOUTDC} V =====
.param gbw=40Meg slw=27Meg aol=1e6 c1=100p
.param gmv={{2*pi*gbw*c1}} ilim={{slw*c1}} r1={{aol/gmv}}
""" + (f"""V_roff_i v_roff_i 0 DC {VRAIL}
Rn_roff n_roff 0 {RN['roff']:.4g}
E_roff v_roff v_roff_i n_roff 0 1
""" if EROFF else f"V_roff v_roff 0 DC {VRAIL}\n") + f"""VG_I v_vg_i 0 DC {VVG}
Rn_vg n_vg 0 {RN['vg']:.4g}
E_vg v_vg v_vg_i n_vg 0 1
R_off_p v_roff col_p {ROFF['p']:.2f}
R_off_m v_roff col_m {ROFF['m']*(1+MIS):.2f}
{amp('p')}
R_f_p out_p col_p {RF}
C_f_p out_p col_p {CF:.4g}
R_ld_p out_p 0 300
{amp('m')}
R_f_m out_m col_m {RF*(1+MIS):.4g}
C_f_m out_m col_m {CF/(1+MIS):.4g}
R_ld_m out_m 0 300
Vin nin 0 AC 1
R_in nin 0 1k
"""
src = src.replace("V_fr2 vfr2 0 DC 3.0\n", iv + "V_fr2 vfr2 0 DC 3.0\n")
# --- analysis ---
src = re.sub(r"^\.tran .*$", ".noise V(diffout) Vin dec 40 20 20k\n.meas NOISE vn_out INTEG V(onoise)", src, flags=re.M)
src = re.sub(r"^\.save .*$", "", src, flags=re.M)
src = src.replace(".options gmin=1e-10 abstol=1e-10 reltol=1e-5 plotwinsize=0",
                  ".options gmin=1e-12 abstol=1e-12 reltol=1e-4 plotwinsize=0")
src = src.replace("* BFDAC CO-SIM v93 - FFT GATE", f"* BFDAC N7 gate {TAG} - FULL-PLANT .noise (static midcode, behavioral I/V + noise copiers) from v93")
cir = os.path.join(LT, f"bfdac_cosim{TAG}.cir")
open(cir, "w").write(src)
print(f"wrote {cir}: VVG {VVG} V, feed +{VRAIL} V, R_off p/m {ROFF['p']:.0f}/{ROFF['m']*(1+MIS):.0f}, Rf {RF:.0f}, NPAR {NPAR}, "
      f"padmos {PADMOS}, Rg5 {RG5:g}, mis {MIS*100:g}%, duty {DUTY:g}, pad rail {VPADRAIL:g} V / Rpad {RPAD:.0f}")

CELL_GROUPS = ("v(Rt#)", "v(Q#)", "v(QS#a)", "v(QS#b)")   # RTZ-windowed: scaled by DUTY in the report

def breakdown(raw, top=14):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from read_ltraw import read_raw
    names, data = read_raw(raw)
    f = np.real(data[0])
    integ = lambda y: np.sqrt(np.trapezoid(np.abs(y) ** 2, f))
    grp = {}
    for i, n in enumerate(names):
        if i < 2 or n in ("v(onoise)", "v(inoise)") or "." in n:
            continue
        k = re.sub(r"\d+", "#", n)
        grp[k] = grp.get(k, 0.0) + integ(data[i]) ** 2
    cell = sum(v for k, v in grp.items() if k in CELL_GROUPS)
    rest = sum(v for k, v in grp.items() if k not in CELL_GROUPS)
    for v, k in sorted(((np.sqrt(v), k) for k, v in grp.items()), reverse=True)[:top]:
        print(f"   {v*1e9:7.1f} nV  {k}" + ("  [x sqrt(DUTY)]" if k in CELL_GROUPS else ""))
    return np.sqrt(cell), np.sqrt(rest)

if len(sys.argv) > 1 and sys.argv[1] == "run":
    try:
        subprocess.run([LTEXE, "-b", cir], timeout=int(os.environ.get("TIMEOUT", 1800)))
    except subprocess.TimeoutExpired:
        print("TIMEOUT - killed"); sys.exit(1)
    log = open(os.path.join(LT, f"bfdac_cosim{TAG}.log"), errors="replace").read()
    m = re.search(r"vn_out: INTEG\(V\(onoise\)\)=(\S+)", log)
    if not m:
        print(log[-1500:]); sys.exit(1)
    v = float(m.group(1))
    cell, rest = breakdown(os.path.join(LT, f"bfdac_cosim{TAG}.raw"))
    v_duty = np.sqrt(DUTY * cell ** 2 + rest ** 2)
    jit, quant = 150e-9, 26e-9
    tot = np.sqrt(v_duty ** 2 + jit ** 2 + quant ** 2)
    print(f"SPICE (core+P6+I/V+refs, 28R domain): {v*1e9:.1f} nV static-ON (cell groups {cell*1e9:.1f}, rest {rest*1e9:.1f}); "
          f"duty {DUTY:g} -> {v_duty*1e9:.1f} nV; + jitter 150 + quant 26 analytic -> "
          f"{tot*1e9:.1f} nV = {20*np.log10(0.624/tot):.2f} dB0 (target 245 nV = 128.1)")
