# Round 91 (2026-09-09): PASSIVE replica-ff realization on the frozen v80 plant.
# Derives deck 91x from deck 88 (gate 88: 45C plant, 45C LUT + 45C kernel,
# BIN=37, seed 130 -> HD2 -115.4 / HD3 -119.9). Only the replica-ff drive
# changes: the ideal B-sources krep*N*pw (+51.92 mA DC) from vcc15 are
# replaced by a hardware-realizable network:
#   * every reclock FF output (Q for rail m, Q-bar for rail p; 0/3.3 V CMOS,
#     modelled as ideal B-sources with the deck's own pwa/pwb timing) feeds a
#     1 k summing resistor into one node per replica
#   * node shunt 15.625 R (= 1k/64) returned to a DC bias -> V_node =
#     0.5*3.3*(64-N*pw)/64 + 0.5*Vbias, 50 pF node capacitance (64 pads)
#   * PNP V-I (THAT HF model) with 35.3 R emitter degeneration sources
#     I = (V_E - V_node - Vbe)/Re into the diode-connected replica MOSFET:
#     N=0 -> 51.9 mA (padding copy), N=64 -> 98.6 mA (krep 0.729 mA/cell)
# Leg a: both cascode replicas (casb, casb2) passive-driven (two nodes/rail).
# Leg b: replica 1 passive, second cascode gate FIXED at 4.37 V (MR2 deleted)
#        -> half the replica current/parts if the plant tolerates it.
# Rail currents are saved so the same run yields the analog power budget.
# V-I device: QPNP_THAT_HF (array part) FAILED the 8 us quick-look — beta
# collapse at 50-90 mA (Ie-Ic = 4.7 mA avg, +-20 mA dynamic base current)
# pulled the bus 22 mV low and 4x the ripple of gate 88. Default is now the
# standard-library 2SA1036K (Ikf 2 A, Tf 15 ps, SOT-23 150 mA class).
# Env: PNP=<model> RSUM=<ohms> (shunt = RSUM/64 keeps the 1/2 weight).
# Usage: python gen_cosim91.py a|b   then LTspice -b bfdac_cosim91a.cir
#        python rtz_fft39.py 91a 16384 37 512
import os
import shutil
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
LEG = sys.argv[1] if len(sys.argv) > 1 else "a"
assert LEG in ("a", "b")
TAG = f"91{LEG}"
NCELL = 64
PNP = os.environ.get("PNP", "2SA1036K")
RSUM = float(os.environ.get("RSUM", "1000"))
RSH = RSUM / NCELL

src = open(os.path.join(LT, "bfdac_cosim88.cir")).read()

# netlist decks do not auto-load the component library: inline the PNP model
BJTLIB = os.path.expandvars(r"%LOCALAPPDATA%\LTspice\lib\cmp\standard.bjt")
pnp_model = None
if not PNP.startswith("QPNP_THAT"):
    for line in open(BJTLIB, encoding="utf-16-le", errors="replace"):
        if line.lower().startswith(f".model {PNP.lower()} "):
            pnp_model = line.strip()
            break
    assert pnp_model, f"{PNP} not found in {BJTLIB}"

# ---- strip the ideal replica drives -----------------------------------------
drop = ["I_ffs_p  vcc15  casb_p  DC 51.92m", "I_ffs_m  vcc15  casb_m  DC 51.92m",
        "I_ffs2_p vcc15 casb2_p DC 51.92m", "I_ffs2_m vcc15 casb2_m DC 51.92m",
        "B_ff_p  vcc15 casb_p  I={krep*V(nsch)*V(pwa)}",
        "B_ff_m  vcc15 casb_m  I={krep*(64-V(nsch)*V(pwb))}",
        "B_ff2_p vcc15 casb2_p I={krep*V(nsch)*V(pwa)}",
        "B_ff2_m vcc15 casb2_m I={krep*(64-V(nsch)*V(pwb))}"]
for d in drop:
    assert d in src, f"anchor missing: {d}"
    src = src.replace(d + "\n", "")

if LEG == "b":
    for d in ["MR2_p casb2_p casb2_p vfr2 vfr2 Si1555DL_N",
              "MR2_m casb2_m casb2_m vfr2 vfr2 Si1555DL_N"]:
        assert d in src, f"anchor missing: {d}"
        src = src.replace(d + "\n", "")

# ---- passive replica network --------------------------------------------------
net = [f"* ===== v{TAG}: PASSIVE replica-ff (sum of reclock-FF outputs) ====="] + \
      ([pnp_model] if pnp_model else []) + [
       f".param rsum={RSUM:g} rsh={RSH:g} csum=50p re_rep=35.3",
       "* FF outputs: Q_i = 3.3*sel_i*pwa (rail p switch), Qb_i = 3.3*(1-sel_i*pwb) (rail m switch)"]
for i in range(1, NCELL + 1):
    net.append(f"Bq{i}  q{i}  0 V={{3.3*V(sel{i})*V(pwa)}}")
    net.append(f"Bqb{i} qb{i} 0 V={{3.3*(1-V(sel{i})*V(pwb))}}")
    net.append(f"Rr1p{i} qb{i} ns1p {{rsum}}")   # rail p replica <- 64-N
    net.append(f"Rr1m{i} q{i}  ns1m {{rsum}}")   # rail m replica <- N
    if LEG == "a":
        net.append(f"Rr2p{i} qb{i} ns2p {{rsum}}")
        net.append(f"Rr2m{i} q{i}  ns2m {{rsum}}")

net += ["* node 1 (casb replica): Vb 2.97..4.62 V, PNP emitter rail 7.2 V",
        "Vb1  vb1 0 DC 5.94",
        "Ve1  ve1 0 DC 7.2",
        "Rsh1p ns1p vb1 {rsh}", "Csh1p ns1p 0 {csum}",
        "Rsh1m ns1m vb1 {rsh}", "Csh1m ns1m 0 {csum}",
        f"QR1p casb_p ns1p e1p {PNP}", "Re1p e1p ve1 {re_rep}",
        f"QR1m casb_m ns1m e1m {PNP}", "Re1m e1m ve1 {re_rep}"]
if LEG == "a":
    net += ["* node 2 (casb2 replica): Vb 4.77..6.42 V, PNP emitter rail = vp8 (9 V)",
            "Vb2  vb2 0 DC 9.54",
            "Rsh2p ns2p vb2 {rsh}", "Csh2p ns2p 0 {csum}",
            "Rsh2m ns2m vb2 {rsh}", "Csh2m ns2m 0 {csum}",
            f"QR2p casb2_p ns2p e2p {PNP}", "Re2p e2p vp8 {re_rep}",
            f"QR2m casb2_m ns2m e2m {PNP}", "Re2m e2m vp8 {re_rep}"]
else:
    net += ["* leg b: second cascode gate fixed (3.0 V + Vgs @ 75 mA)",
            "Vcb2p casb2_p 0 DC 4.37",
            "Vcb2m casb2_m 0 DC 4.37"]

anchor = "* v80: padding = degenerated BJT mirrors"
assert anchor in src
src = src.replace(anchor, "\n".join(net) + "\n" + anchor)

# ---- bookkeeping: title, PWL dir stays pwl88, save rail currents ---------------
src = src.replace("* BFDAC CO-SIM v88 - FFT GATE, slow-bias + 100R gate stoppers, predistorted",
                  f"* BFDAC CO-SIM v{TAG} - gate 88 plant + PASSIVE replica-ff (leg {LEG})")
old_save = ".save V(diffout) V(nsch)"
assert old_save in src
rails = "I(V_p15r) I(V_n15r) I(V_p8) I(V_fr) I(V_fr2) I(Ve1) I(Vb1)"
if LEG == "a":
    rails += " I(Vb2)"
else:
    rails += " I(Vcb2p) I(Vcb2m)"
src = src.replace(old_save, f"{old_save} V(casb_p) V(bus_plus) V(ns1p) {rails}")

out = os.path.join(LT, f"bfdac_cosim{TAG}.cir")
open(out, "w").write(src)
# analysis scripts key the code stream on the TAG
shutil.copyfile(os.path.join(LT, "cosim88_code.npy"), os.path.join(LT, f"cosim{TAG}_code.npy"))
print(f"wrote {out} ({src.count(chr(10))} lines), PNP={PNP} RSUM={RSUM:g}, code stream = cosim88 (BIN 37, seed 130)")
