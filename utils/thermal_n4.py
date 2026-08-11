# N4: analytic thermal-noise budget of the DAC core (current deck values:
# Rt=750R tails, rload=28R proxy, RTZ duty 6/8, 64 cells). Key structural
# fact: p-side conducts k cells, m-side 64-k -> total active tails = 64
# ALWAYS -> tail thermal line is CODE-INDEPENDENT.
# Shot noise suppressed by emitter degeneration (gm*Rt ~ 22).
# Line items reported in nV/rtHz at diffout and nVrms 20Hz-20kHz vs the
# 245 nVrms (128dB) budget. Padding sources (2x50mA) and the real I/V stage
# are flagged as open dependencies (ideal in the deck).
import numpy as np

kT4 = 4 * 1.380649e-23 * 300
RT = 750.0
RL = 28.0
NCELL = 64
DUTY = 6 / 8
BW = 20e3 - 20
GAIN = 0.0310                    # V diffout per code (measured, gate fits)
FUND = 24.955 * GAIN / np.sqrt(2)   # Vrms diff at -1dBFS
IC = 0.75e-3                     # per-cell current
gm = IC / 25.85e-3
VT_DEG = 1 + gm * RT

items = {}
# 64 active tail resistors total (both sides), duty-weighted
items["tails 64x750R"] = RL * np.sqrt(NCELL * kT4 / RT * DUTY)
# cascode shot noise, degeneration-suppressed
items["cascode shot"] = RL * np.sqrt(NCELL * 2 * 1.602e-19 * IC * DUTY) / VT_DEG
# two 28R load resistors (full period)
items["loads 2x28R"] = np.sqrt(2 * kT4 * RL)

tot = np.sqrt(sum(v ** 2 for v in items.values()))
print(f"fund = {FUND*1e3:.1f} mVrms diff; budget 245 nVrms (128 dB)")
for k, v in items.items():
    print(f"  {k:16s}: {v*1e9:6.3f} nV/rtHz -> {v*np.sqrt(BW)*1e9:6.1f} nVrms "
          f"({20*np.log10(FUND/(v*np.sqrt(BW))):6.1f} dB)")
print(f"  {'TOTAL core':16s}: {tot*1e9:6.3f} nV/rtHz -> {tot*np.sqrt(BW)*1e9:6.1f} nVrms "
      f"({20*np.log10(FUND/(tot*np.sqrt(BW))):6.1f} dB)")
print("\nopen items (ideal in deck): 2x50mA padding sources (real: degenerated")
print("mirrors - spec their Rdeg for <=50nV line), replica-FF B-sources,")
print("real I/V stage (OPA1612 core) replaces the 28R proxy - separate budget.")
