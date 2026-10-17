# P5 / N5 (2026-09-16): I/V + output-stage design and noise budget.
# Replaces the 28R proxy loads of the cosim plant with a transimpedance stage
# whose summing node sits at the SAME DC (7.0 V) the col nodes occupy today.
# Topology per rail (x2 per channel):
#   col -> summing node (12 nF C_col kept: RTZ slam absorber)
#   OPA1612 (+in = 7.0 V ref) + BUF634A inside the loop (NPAR op-amps in
#   parallel; the OPA1612 is a dual, so NPAR=2 is the same package)
#   Rf || Cf (BOTH from the buffer output -> sum): 270R || 1.3n = 450 kHz.
#   .noise on the TI macro-models (gen_iv5.py) showed Cf taken from the
#   op-amp output lets the BUF634A input current noise reach the output
#   (+36 nV); Cf from the buffer output removes it.
#   R_off from V_RAIL -> sum must supply the cascode DC (cells SINK from col)
#   PLUS the Rf current when the output sits below the summing node:
#     I_off = I_DC + (V_VG - V_OUT_DC)/Rf,  R_off = (V_RAIL - V_VG)/I_off.
#   (gate-99 probe 2026-09-19 caught the first pass having this sign wrong.)
#   Per-side DC is ASYMMETRIC in the plant: unselected cells steer into
#   bus_minus, so I_p = 50 + k*0.5625 mA, I_m = 50 + 48 - k*0.5625 mA
#   -> 68 / 80 mA at midcode; R_off_p != R_off_m.
# Stage 2: R_STRING tap divider (K1/K2: 6/4/2 V) + OPA1612 unity buffer.
# Everything is referred to the 28R domain (diffout-equivalent nV) so it adds
# to thermal_n4 / pn_n2b / N1 / N3 lines directly; FS = +/-28 codes.
import numpy as np
import os

kT4 = 4 * 1.380649e-23 * 300
F1, F2 = 20.0, 20e3
f = np.logspace(np.log10(F1), np.log10(F2), 4000)

# ---- plant facts (thermal_n4 / gate fits) ----
RL_REF = 28.0                 # reference domain
I_CELL = 0.75e-3 * 6 / 8      # per-cell average current (duty 6/8)
NCELL = 64
I_PAD = float(os.environ.get("IPAD", 50e-3))   # v80 plant: 50 mA; lower = PLANT CHANGE (re-ID)
I_CELL_TOT = NCELL * 0.75e-3               # 48 mA always flowing (both buses)
I_DC_P = I_PAD + NCELL / 2 * I_CELL        # 68 mA at midcode
I_DC_M = I_PAD + I_CELL_TOT - NCELL / 2 * I_CELL   # 80 mA at midcode
DI_FS = 28 * 2 * I_CELL                    # differential FS peak (+/-28 codes) = 31.5 mA
V_FS_REF = DI_FS * RL_REF / np.sqrt(2)     # 0.624 Vrms in the 28R domain
CORE = {"tails 64x750R": 129e-9, "cascode shot": 19e-9}   # thermal_n4 lines
OTHER = {"jitter (CCHD-957 + FF 0.6ps, P3)": 150e-9,
         "V_ref (N3, 220uF, spec bound)": 100e-9,
         "quantization (N1)": 26e-9}

# ---- I/V design values (env-overridable for sweeps) ----
V_VG = float(os.environ.get("VVG", 7.0))       # summing-node DC
V_RAIL = float(os.environ.get("VRAIL", 15.0))  # R_off feed
V_OUT_DC = float(os.environ.get("VOUTDC", 0.0))  # I/V output DC (0 = no CM shift for stage 2)
V_SUPPLY = 15.0                                # op-amp/buffer rails +/-
RF = float(os.environ.get("RF", 270.0))
V_OUT_FS = float(os.environ.get("VOUT", 6.0))  # Vrms balanced at 0 dBFS
CIN = 12e-9
CF = 1 / (2 * np.pi * RF * 450e3)
I_RF = (V_VG - V_OUT_DC) / RF                  # DC leaving the summing node through Rf
I_OFF = {"p": I_DC_P + I_RF, "m": I_DC_M + I_RF}
R_OFF = {s: (V_RAIL - V_VG) / i for s, i in I_OFF.items()}
R_SERVO = 100e3
# OPA1612 (SBOS450C): 1.1 nV/rtHz, 1.7 pA/rtHz @1 kHz; corners approximated
NPAR = int(os.environ.get("NPAR", 1))
EN, FC_E = 1.1e-9 / np.sqrt(NPAR), 30.0
IN, FC_I = 1.7e-12 * np.sqrt(NPAR), 1e3
R_STRING = float(os.environ.get("RSTR", 600.0))   # 6/4/2 V tap string

def rms(psd):                 # psd: A^2/Hz or V^2/Hz on grid f
    return np.sqrt(np.trapezoid(psd, f))

# per-side current-noise PSDs at the summing node (A^2/Hz)
en2 = EN**2 * (1 + FC_E / f)
in2 = IN**2 * (1 + FC_I / f)
def side_lines(r_off):
    return {
        "R_off (%.0f/%.0fR) from +%.0fV" % (R_OFF["p"], R_OFF["m"], V_RAIL): kT4 / r_off * np.ones_like(f),
        "Rf %.0fR" % RF: kT4 / RF * np.ones_like(f),
        "op-amp i_n (1/f fc %.0f Hz)" % FC_I: in2,
        "op-amp e_n / (R_off||Rf)": en2 * (1 / RF + 1 / r_off) ** 2,
        "op-amp e_n * wC_in": en2 * (2 * np.pi * f * CIN) ** 2,
        "servo inject %.0fk" % (R_SERVO / 1e3): kT4 / R_SERVO * np.ones_like(f),
    }

# differential = RSS of the two (unequal) sides; referred x RL_REF
lp, lm = side_lines(R_OFF["p"]), side_lines(R_OFF["m"])
iv = {k: np.hypot(rms(lp[k]), rms(lm[k])) * RL_REF for k in lp}
iv_tot = np.sqrt(sum(v**2 for v in iv.values()))
swing = DI_FS / 2 * RF
clip = "OK" if abs(V_OUT_DC) + swing < V_SUPPLY - 1.5 else "CLIPS (+/-15 V rails)"

print(f"P5 I/V design ({NPAR}x OPA1612 + BUF634A): sum node {V_VG:.1f} V, out DC {V_OUT_DC:.1f} V, "
      f"R_off feed +{V_RAIL:.0f} V; I_DC p/m {I_DC_P*1e3:.0f}/{I_DC_M*1e3:.0f} mA, Rf DC {I_RF*1e3:.1f} mA")
for s in ("p", "m"):
    print(f"  R_off_{s} {R_OFF[s]:.0f}R carries {I_OFF[s]*1e3:.0f} mA, {I_OFF[s]**2*R_OFF[s]*1e3:.0f} mW")
print(f"  Rf {RF:.0f}R, Cf {CF*1e12:.0f} pF (450 kHz); FS diff +/-{DI_FS*1e3:.1f} mA -> "
      f"{DI_FS*RF/np.sqrt(2):.2f} Vrms balanced; per-side swing {V_OUT_DC:+.1f} +/- {swing:.2f} V pk -> {clip}")
print(f"  buffer sinks {(I_RF-DI_FS/2)*1e3:.0f}..{(I_RF+DI_FS/2)*1e3:.0f} mA; noise gain plateau 1+Cin/Cf = "
      f"{1+CIN/CF:.1f} -> loop xover ~{40e6/(1+CIN/CF)/1e6:.1f} MHz")
print(f"\n28R-domain FS = {V_FS_REF*1e3:.0f} mVrms; budget 245 nV = "
      f"{20*np.log10(V_FS_REF/245e-9):.1f} dB")
print("I/V stage lines (differential, 20 Hz-20 kHz):")
for k, v in iv.items():
    print(f"  {k:34s}: {v*1e9:6.1f} nV")
print(f"  {'I/V TOTAL':34s}: {iv_tot*1e9:6.1f} nV")

stack = dict(CORE); stack.update(OTHER); stack["I/V stage (this)"] = iv_tot
tot = np.sqrt(sum(v**2 for v in stack.values()))
print("\nBudget stack (28R domain):")
for k, v in stack.items():
    print(f"  {k:34s}: {v*1e9:6.1f} nV")
print(f"  {'TOTAL (core+jitter+ref+quant+I/V)':34s}: {tot*1e9:6.1f} nV = "
      f"{20*np.log10(V_FS_REF/tot):.1f} dB0  (target <= 245 nV / 128 dB)")

# ---- stage 2: tap string + unity buffer, per output level ----
print(f"\nStage 2 ({R_STRING:.0f}R tap string + OPA1612 unity buffer/side), "
      f"totals at the XLR:")
gain_ref = RF / RL_REF                      # 28R domain -> I/V output
for lvl in (6.0, 4.0, 2.0):
    a = lvl / V_OUT_FS
    r_th = R_STRING * a * (1 - a)           # Thevenin of the tap
    s2 = np.sqrt(2) * np.sqrt(rms(en2)**2 + kT4 * r_th * (F2 - F1))
    core_out = tot * gain_ref * a
    tot_out = np.hypot(core_out, s2)
    print(f"  {lvl:.0f} V: tap Rth {r_th:5.0f}R, stage-2 {s2*1e9:5.0f} nV, "
          f"upstream {core_out*1e6:.2f} uV -> total {tot_out*1e6:.2f} uV = "
          f"{20*np.log10(lvl/tot_out):.1f} dB0")
