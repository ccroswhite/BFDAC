# Thermal estimate of tube 3 (converter / I-V / FF-clock / HP amp) as a lumped
# network, 2026-09-30, for bom item 17 and the CASB2 realisation question.
# Zones: WALL (tube wall), W (wall-coupled bias-resistor zone), A (matched
# cell/cascode/replica array, mid-board), D (FF + translators + clock tree),
# T (TIA + reference buffers), HP (class-A headphone amp on its own wall-
# coupled heatsink).  Dissipations per bom 17(b)/(g) with the ruled +-15 V
# returns.  Steady state + first-order time constants, then extrapolation of
# the sweep sensitivities (utils/sweep_refs.ps1, 2026-09-30) to post-cal drift.
#   python utils/thermal_zones.py            default parameters
#   R_WALL_AMB=0.3 python utils/thermal_zones.py   finned / fan-assisted tube
import os
import numpy as np

P = lambda k, d: float(os.environ.get(k, d))

# ---- dissipation inventory, stereo, W --------------------------------------
I_REP = 0.080            # replica current per side (Ve1 - ns1 - Veb)/35.3
I_M6 = (0.083 + 0.095) / 2
diss = {
    "W": {  # wall-coupled bias-return zone
        "R_off 2 ch": 2 * 2.0,
        "Rpad 2 ch": 2 * 1.45,
        "Re1 35.3R x4": 4 * I_REP**2 * 35.3,
        "Ve1 LDO drop (15-7.2) x 160 mA x2": 2 * (15 - 7.2) * 2 * I_REP,
        "VFR sink 1.75 V x 160 mA x2": 2 * 1.75 * 2 * I_REP,
        "POL LDO drops ~2 V, ~0.6 A": 2.0 * 0.6,
    },
    "A": {  # matched array - must stay together
        "cells 128 x Q5551 (0.75 mA x ~3 V)": 2 * 64 * 0.75e-3 * 3.0,
        "M5+M6 cascodes 4 x ~1 V x 90 mA": 4 * 1.0 * I_M6,
        "MR replica 2 ch x2 (Vgs ~1.2 V x 80 mA)": 4 * 1.2 * I_REP,
        "QR1 2SA1036K x4 (Vce ~1.4 V x 80 mA)": 4 * 1.4 * I_REP,
        "Mpad x4 (Vds ~2 V x 50 mA)": 4 * 2.0 * 0.050,
    },
    "D": {"FF + translators 2 ch": 2 * 1.0, "clock tree 2 ch": 2 * 1.0},
    "T": {"TIA 2 ch": 2 * 0.7, "ref + bias buffers": 0.6},
}
P_HP = P("P_HP", 22.0)   # headphone amp when enabled

# ---- thermal resistances, K/W ----------------------------------------------
R = {
    "WALL-AMB": P("R_WALL_AMB", 0.6),   # bare Al tube ~0.1 m2, natural convection; 0.3 finned/fan
    "W-WALL": 0.5,                      # bias resistors on pads to the wall
    "HP-WALL": 0.3,                     # HP heatsink bolted to the wall
    "A-WALL": 12.0,                     # standoffs + inner air, mid-board
    "A-W": 9.0,                         # FR4 + 2x2oz planes, ~50 mm, 100 mm wide
    "A-D": 9.0,
    "A-T": 9.0,
    "D-WALL": 6.0,
    "T-WALL": 6.0,
}
# local junction rises inside zone A (static: dissipation is code-independent)
THJA = {"M6 SOT-363": 250.0, "MR SOT-363": 250.0, "Q5551 cell": 300.0, "QR1 SOT-23": 250.0}
JRISE = {
    "M6": THJA["M6 SOT-363"] * 1.0 * I_M6,
    "MR": THJA["MR SOT-363"] * 1.2 * I_REP,
    "QR1": THJA["QR1 SOT-23"] * 1.4 * I_REP,
    "cell": THJA["Q5551 cell"] * 0.75e-3 * 3.0,
}

# ---- sensitivities ----------------------------------------------------------
TC_VGS = -2.0e-3          # V/K, Si1555 N-half Vgs at ~90 mA (datasheet class)
TC_VEB = -2.0e-3          # V/K, 2SA1036K
TC_REF_PPM = 2.0 + 5.0    # REF7050 + matched-divider tracking, ppm/K
# sweep slopes (dB of harmonic added per +1 % of node) -> treat as 20 dB/dec
SWEEP = {  # node: (pct applied, harmonic, base dBc, new dBc)
    "CASB2 common (fixed-divider Vgs drift)": (1.0, "HD4", -132.3, -128.5),
    "VE1-equivalent (QR1 Veb drift, ratio case)": (1.0, "HD3", -134.6, -121.5),
    "VFR (MR vs M5 tracking error)": (1.0, "HD2", -128.5, -120.9),
}

def added_component(base, new):
    """dBc of the distortion that was added to reach `new` from `base` (power sum)."""
    return 10 * np.log10(max(10 ** (new / 10) - 10 ** (base / 10), 1e-30))

def hd_after(base, added):
    return 10 * np.log10(10 ** (base / 10) + 10 ** (added / 10))

# ---- network solve -----------------------------------------------------------
nodes = ["WALL", "W", "A", "D", "T", "HP"]
def solve(T_amb, hp_on):
    Pz = {z: sum(v.values()) for z, v in diss.items()}
    Pz["HP"] = P_HP if hp_on else 0.0
    Pz["WALL"] = 0.0
    n = len(nodes); G = np.zeros((n, n)); b = np.zeros(n)
    idx = {z: i for i, z in enumerate(nodes)}
    def link(a, c, r):
        g = 1 / r; G[idx[a], idx[a]] += g; G[idx[c], idx[c]] += g
        G[idx[a], idx[c]] -= g; G[idx[c], idx[a]] -= g
    for k, r in R.items():
        a, c = k.split("-")
        if c == "AMB":
            G[idx[a], idx[a]] += 1 / r; b[idx[a]] += T_amb / r
        else:
            link(a, c, r)
    for z in nodes:
        b[idx[z]] += Pz[z]
    T = np.linalg.solve(G, b)
    return {z: T[idx[z]] for z in nodes}, Pz

print("=== dissipation inventory (stereo, ruled +-15 V returns) ===")
for z, items in diss.items():
    for k, v in items.items():
        print(f"  {z:4s} {k:44s} {v:5.2f} W")
    print(f"  {z:4s} {'zone total':44s} {sum(items.values()):5.2f} W")
print(f"  HP   headphone amp when enabled               {P_HP:5.2f} W")
print(f"  tube 3 total: {sum(sum(v.values()) for v in diss.values()):.1f} W line-out, "
      f"{sum(sum(v.values()) for v in diss.values()) + P_HP:.1f} W with HP\n")

print("=== steady state (R_WALL_AMB = %.2f K/W) ===" % R["WALL-AMB"])
print("  amb   HP   WALL     W      A      D      T     HP")
base = None
for T_amb in (20, 25, 30):
    for hp in (False, True):
        T, _ = solve(T_amb, hp)
        print(f"  {T_amb:3d}  {'on ' if hp else 'off'}  " + "  ".join(f"{T[z]:5.1f}" for z in nodes))
        if T_amb == 25 and not hp:
            base = T
T_hp_on, _ = solve(25, True)
dT_hp = T_hp_on["A"] - base["A"]
print(f"\n  array A at 25 C line-out: {base['A']:.1f} C; HP enable step on A: +{dT_hp:.1f} K")
print(f"  ambient coupling: dT_A/dT_amb = 1.0 (all paths end at ambient)")
print("  static junction rises in A (code-independent -> calibrated, NOT drift): " +
      ", ".join(f"{k} +{v:.1f} K" for k, v in JRISE.items()))

# ---- time constants -----------------------------------------------------------
C_WALL = P("C_WALL", 1350.0)   # J/K, ~1.5 kg Al tube
C_BOARD_A = 60.0               # J/K, ~40 g FR4+Cu region around the array
tau_wall = C_WALL * R["WALL-AMB"]
tau_A = C_BOARD_A / (1 / R["A-WALL"] + 1 / R["A-W"] + 1 / R["A-D"] + 1 / R["A-T"])
print(f"\n=== time constants ===\n  wall/enclosure tau ~ {tau_wall/60:.0f} min (warm-up to 1 K: ~{3*tau_wall/60:.0f} min)"
      f"\n  array-to-surroundings tau ~ {tau_A/60:.1f} min (array follows the wall)")

# ---- extrapolation --------------------------------------------------------------
print("\n=== post-cal drift extrapolation vs array temperature excursion dT ===")
for dT in (2, 5, 10, dT_hp):
    print(f"\n  dT = {dT:4.1f} K  ({'HP-enable step' if abs(dT - dT_hp) < 1e-9 else 'ambient/warm-up residual'})")
    # linearity
    d_casb2 = abs(TC_VGS) * dT / 4.37 * 100           # % of CASB2 if the gate is a fixed divider
    d_ve1 = abs(TC_VEB) * dT / 7.2 * 100               # % VE1-equivalent from QR1 Veb
    d_vfr = 0.3e-3 * dT / 1.75 * 100                   # MR-M5 tempco mismatch ~0.3 mV/K (same type, different Id)
    for (name, (pct, h, b0, b1)), d in zip(SWEEP.items(), (d_casb2, d_ve1, d_vfr)):
        add = added_component(b0, b1) + 20 * np.log10(d / pct)
        print(f"    {name:46s} {d:5.2f} %  -> {h} {b0:6.1f} -> {hd_after(b0, add):6.1f} dBc")
    # noise and reference
    print(f"    thermal noise (sqrt T)                          -> {10*np.log10((300+dT)/300):+.3f} dB")
    print(f"    REF7050 + divider ({TC_REF_PPM:.0f} ppm/K)                   -> {TC_REF_PPM*dT*1e-4:.4f} % (budget 0.05 % ratio, 0.1 % VFR)")

print("\nNOTES: fixed-divider CASB2 line applies only if the gate is NOT servoed/mirrored;")
print("QR1 Veb line is intrinsic to the plant (same for every reference realisation) unless")
print("the cal is temperature-indexed or re-identified; VFR line assumes MR and M5 co-located.")
