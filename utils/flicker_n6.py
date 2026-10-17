# P6 / N6 (2026-09-19): noise lines NOT in the LTspice plant models, analytic.
# Deck facts (bfdac_cosim93.cir): bus_plus/bus_minus each carry C_bus = 47 nF
# to ground and are the SOURCE nodes of the bottom cascodes M5p/M5m (Si1555,
# gate = casb_p/m).  Any voltage noise on a cascode gate is copied to its
# source and drives  i = e_g * jwC_bus  through the cascode into the output.
# That "wC_bus conversion" (0.48 A per V/rtHz white, 20 Hz-20 kHz) turns nV
# gate noise into nA output noise, so every source reaching casb gets a line:
#   1. M5 channel noise (thermal + 1/f; VDMOS model has neither in .tran)
#   2. MR (diode-connected Si1555 that sets casb = vfr + Vgs) channel noise
#   3. replica chain: ns1 node (64x10k sum || 156R) -> QR (2SA1036K, Re 35.3)
#      collector current / gm(MR) -> casb; FF 3.3 V rail + 5.94 V + 7.2 V rails
#   4. vfr 1.75 V reference: COMMON to both sides -> cancels to the C_bus*gm
#      mismatch delta
#   5. padding mirrors Qpad + 286R to -15 V (v80): 4kT/286 per side (N4 flagged)
#   6. V_ref 1/f (ADR445-class) behind the 100R/220uF pole (N3)
# Also the OPA1612 1/f terms are already in iv_n5.py. Reported in the 28R
# domain like thermal_n4 / iv_n5 so the lines add to the same stack.
import numpy as np
import os

kT4 = 4 * 1.380649e-23 * 300
q = 1.602e-19
F1, F2 = 20.0, 20e3
f = np.logspace(np.log10(F1), np.log10(F2), 4000)
w = 2 * np.pi * f
RL = 28.0
C_BUS = 47e-9
KP = 2.0                      # Si1555DL_N model Kp
I_M5 = 68e-3                  # bottom cascode current at midcode
I_MR = float(os.environ.get("IMR", 40e-3))    # replica current in MR (vfr absorbs 100-190 mA total)
FC_MOS = float(os.environ.get("FCMOS", 100e3))  # small-signal MOSFET 1/f corner (NOT spec'd)
RE_REP, R_SUM, R_SH, N = 35.3, 10e3, 156.25, 64
E_FF_RAIL = float(os.environ.get("EFF", 15e-9))   # TPS7A4700-class 3.3 V rail, nV/rtHz
E_VB1 = float(os.environ.get("EVB", 20e-9))      # 5.94 V bias rail
E_VE1 = float(os.environ.get("EVE", 20e-9))      # 7.2 V PNP emitter rail
E_VFR = float(os.environ.get("EVFR", 20e-9))     # 1.75 V vfr reference (white part)
FC_VFR = 100.0
DELTA = float(os.environ.get("DELTA", 0.05))     # p/m C_bus*gm mismatch (common-mode leak)
R_PAD = 286.0
I_PAD = 50e-3

def rms(psd):
    return np.sqrt(np.trapezoid(psd, f))

def gm_mos(i):
    return np.sqrt(2 * KP * i)

def conv(e2_gate):            # gate-referred V^2/Hz -> output A^2/Hz via wC_bus
    return e2_gate * (w * C_BUS) ** 2

lines = {}
# 1. M5 channel noise (gate-referred), 1/f with corner FC_MOS
e2_m5 = kT4 * (2 / 3) / gm_mos(I_M5) * (1 + FC_MOS / f)
lines[f"M5 cascode channel (1/f fc {FC_MOS/1e3:.0f}k)"] = conv(e2_m5)
# 2. MR diode load: its channel noise appears directly on casb
gm_mr = gm_mos(I_MR)
e2_mr = kT4 * (2 / 3) / gm_mr * (1 + FC_MOS / f)
lines["MR diode-connected Si1555"] = conv(e2_mr)
# 3. replica chain -> casb: e_casb = i_c(QR) / gm_mr,  i_c = e_ns1 / (RE_REP + re)
re_qr = 25.85e-3 / I_MR
g_rep = 1 / (RE_REP + re_qr) / gm_mr           # V(casb) per V(ns1)
r_th = 1 / (N / R_SUM + 1 / R_SH)               # ns1 Thevenin (78R)
e2_ns1 = kT4 * r_th + (0.5 * E_FF_RAIL) ** 2 + (0.5 * E_VB1) ** 2
e2_qr = kT4 * RE_REP + 2 * q * I_MR * re_qr ** 2      # Re thermal + shot (re-referred)
e2_casb_rep = (e2_ns1 + e2_qr + E_VE1 ** 2) * g_rep ** 2
lines["replica chain (ns1 R, FF/5.94/7.2 rails, Re)"] = conv(e2_casb_rep * np.ones_like(f))
# 4. vfr: common to both sides; only the mismatch fraction survives
e2_vfr = E_VFR ** 2 * (1 + FC_VFR / f)
lines[f"vfr {E_VFR*1e9:.0f} nV/rtHz x delta {DELTA:.2f}"] = conv(e2_vfr) * DELTA ** 2 / 2  # /2: undo the x2 below
# 5. padding mirror degeneration (shot suppressed by gm*Re ~ 550)
lines["padding 2x286R (v80)"] = kT4 / R_PAD * np.ones_like(f)

out = {k: rms(v) * np.sqrt(2) * RL for k, v in lines.items()}   # two independent sides
tot6 = np.sqrt(sum(v ** 2 for v in out.values()))

print(f"wC_bus conversion: {rms((w*C_BUS)**2):.3f} A rms per (V/rtHz white) over 20 Hz-20 kHz; "
      f"1/f-weighted (fc {FC_MOS/1e3:.0f}k): x{rms((w*C_BUS)**2*(1+FC_MOS/f))/rms((w*C_BUS)**2):.2f}")
print(f"gm(M5) {gm_mos(I_M5):.2f} S, gm(MR) {gm_mr:.2f} S, replica gain ns1->casb {g_rep:.4f} V/V, "
      f"ns1 Thevenin {r_th:.0f}R")
print("\nP6 lines (28R domain, differential, 20 Hz-20 kHz):")
for k, v in out.items():
    print(f"  {k:44s}: {v*1e9:6.1f} nV")
print(f"  {'P6 TOTAL':44s}: {tot6*1e9:6.1f} nV")

# derived specs: white-equivalent gate noise for a 30 nV line, per side (independent)
e_allow = 30e-9 / RL / np.sqrt(2) / rms((w * C_BUS) ** 2)
print(f"\nSPEC: any INDEPENDENT per-side noise on casb must stay <= {e_allow*1e9:.2f} nV/rtHz "
      f"white-equivalent for a 30 nV line; COMMON (vfr) noise <= {e_allow/DELTA*1e9:.0f} nV/rtHz "
      f"at delta {DELTA:.2f}")

# stack with N4 core, P3 jitter, N3 V_ref, N1 quant, P5 I/V
stack = {"core tails+shot (N4)": 130e-9, "jitter (P3, FF 0.6 ps)": 150e-9,
         "V_ref bound (N3)": 100e-9, "quantization (N1)": 26e-9,
         "I/V stage (P5)": 73e-9, "P6 lines": tot6}
tot = np.sqrt(sum(v ** 2 for v in stack.values()))
print("\nBudget stack incl. P6:")
for k, v in stack.items():
    print(f"  {k:28s}: {v*1e9:6.1f} nV")
print(f"  {'TOTAL':28s}: {tot*1e9:6.1f} nV = {20*np.log10(0.624/tot):.1f} dB0 (245 nV = 128.1 dB)")
