# Round 37: GOLD-STANDARD FFT GATE. Real EF3 noise-shaper (integer-exact,
# ns_ef3_gen.step) + real dem_sort selection (integer-exact, dem_sort_gen
# algorithm) -> per-cell PWL drives for the v36g analog deck (BJT steering,
# double LOW-C MOSFET cascode, replica-ff casb, q4_base bypass, 12n C0G
# termination). One 2.67ms transient; analysis = per-period boxcar decimation
# + Kaiser(beta=38) FFT vs the ideal popcount stream of the SAME vectors.
import numpy as np
import os
import sys

sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import step as ns_step, FRAC, LSB

M = 16384                # fs periods
BIN = 17                 # 6.375 kHz, HD2 12.75k / HD3 19.125k in-band
TS = 162.7604e-9
NCELL = 64
OUT = r"C:\Users\ccros\Documents\LTspice"
PWLDIR = os.path.join(OUT, "pwl37")
os.makedirs(PWLDIR, exist_ok=True)

# ---- stimulus -> EF3 -> code ----
rng = np.random.default_rng(5)
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)
st = (0, 0, 0, 0, 0, 0)
code = np.empty(M, dtype=np.int64)
for i in range(M):
    code[i], st = ns_step(int(u[i]), int(dith[i]), st)

# ---- dem_sort integer-exact selection ----
A1 = np.zeros(NCELL, dtype=np.int64)
A2 = np.zeros(NCELL, dtype=np.int64)
sels = np.zeros((M, NCELL), dtype=np.uint8)
idx = np.arange(NCELL)
for i in range(M):
    c = int(code[i])
    Mm = 2 * A1 + A2
    order = np.lexsort((idx, Mm))
    sel = np.zeros(NCELL, dtype=np.uint8)
    sel[order[:c]] = 1
    sels[i] = sel
    A1 += 64 * sel.astype(np.int64) - c
    A2 += A1
assert (sels.sum(axis=1) == code).all()
np.save(os.path.join(OUT, "cosim37_code.npy"), code)

# ---- per-cell PWL files (0/1, transitions 0.2ns after period boundary) ----
tend = M * TS
for b in range(NCELL):
    s = sels[:, b]
    lines = [f"0 {int(s[0])}"]
    for i in range(1, M):
        if s[i] != s[i - 1]:
            t = i * TS
            lines.append(f"{(t)*1e9:.4f}n {int(s[i-1])}")
            lines.append(f"{(t+0.2e-9)*1e9:.4f}n {int(s[i])}")
    lines.append(f"{tend*1e9:.4f}n {int(s[-1])}")
    with open(os.path.join(PWLDIR, f"sel{b+1:02d}.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

# nsch = popcount waveform for the replica-ff law
lines = [f"0 {int(code[0])}"]
for i in range(1, M):
    if code[i] != code[i - 1]:
        t = i * TS
        lines.append(f"{t*1e9:.4f}n {int(code[i-1])}")
        lines.append(f"{(t+0.2e-9)*1e9:.4f}n {int(code[i])}")
lines.append(f"{tend*1e9:.4f}n {int(code[-1])}")
with open(os.path.join(PWLDIR, "nsch.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")

# ---- deck ----
hdr = f"""* BFDAC CO-SIM v37 - FFT GATE: real EF3+dem_sort vectors, {M} periods, -1dBFS {BIN*6.144e6/M/1e3:.3f}kHz
.model LVFET VDMOS(Rg=3 Vto=0.6 Rd=0.3 Rs=.75 Rb=.14 Kp=.17 Lambda=.02
+ Cgdmax=80p Cgdmin=12p Cgs=50p Cjo=50p Is=.04p Ksubthres=.1)
.model LCFET VDMOS(Rg=3 Vto=0.6 Rd=0.3 Rs=.75 Rb=.14 Kp=.17 Lambda=.02
+ Cgdmax=8p Cgdmin=1.2p Cgs=5p Cjo=5p Is=.04p Ksubthres=.1)
.model Q5551 NPN(Is=2.511f Xti=3 Eg=1.11 Vaf=100 Bf=242.6 Ne=1.249
+ Ise=2.511f Ikf=.3458 Xtb=1.5 Br=3.197 Nc=2 Isc=0 Ikr=0 Rc=1
+ Cjc=4.883p Mjc=.3047 Vjc=.75 Fc=.5 Cje=5.5p Mje=.3621 Vje=.75
+ Tr=316.2n Tf=452.9p Itf=.1 Vtf=10 Xtf=2 Rb=10)
.lib THAT300series.lib

.param Ts=162.7604n tc={{Ts/8}} tedge=3n skew=1n
.param t0={{tc}} twid={{6*tc}}
.param vlo=1.1 vhi=1.7 krep=0.729m cbus=47n rload=28

V_p15r  vcc15  0  DC 15
V_n15r  vee15  0  DC -15
V_p8    vp8    0  DC 9

R_load_p vp8 col_p {{rload}}
R_load_m vp8 col_m {{rload}}
C_col_p col_p 0 12n
C_col_m col_m 0 12n
B_diff  diffout  0  V={{V(col_p)-V(col_m)}}
R_do  diffout  0  1Meg

V_fr  vfr  0  DC 1.75
V_fr2 vfr2 0 DC 3.0
M6p  col_p  casb2_p mid_p  mid_p  LCFET
M6m  col_m  casb2_m mid_m  mid_m  LCFET
M5p  mid_p  casb_p  bus_plus  bus_plus  LCFET
M5m  mid_m  casb_m  bus_minus bus_minus LCFET
MR_p casb_p casb_p vfr vfr LCFET
MR_m casb_m casb_m vfr vfr LCFET
MR2_p casb2_p casb2_p vfr2 vfr2 LCFET
MR2_m casb2_m casb2_m vfr2 vfr2 LCFET
I_ffs_p  vcc15  casb_p  DC 51.92m
I_ffs_m  vcc15  casb_m  DC 51.92m
I_ffs2_p vcc15 casb2_p DC 51.92m
I_ffs2_m vcc15 casb2_m DC 51.92m

B_ff_p  vcc15 casb_p  I={{krep*V(nsch)*V(pwa)}}
B_ff_m  vcc15 casb_m  I={{krep*(64-V(nsch)*V(pwb))}}
B_ff2_p vcc15 casb2_p I={{krep*V(nsch)*V(pwa)}}
B_ff2_m vcc15 casb2_m I={{krep*(64-V(nsch)*V(pwb))}}

I_padb_p  bus_plus  vee15  DC 50m
I_padb_m  bus_minus  vee15  DC 50m
R_bleed_plus   bus_plus   0  910
C_bus_p  bus_plus   0  {{cbus}}
C_bus_m  bus_minus  0  {{cbus}}
R_bleed_minus  bus_minus  0  910

V_ref   vref  0        DC 1.25
R_bias  vref  q4_base  100
C_q4 q4_base 0 22n

Vpwa pwa 0 PULSE(0 1 {{t0}} {{tedge}} {{tedge}} {{twid}} {{Ts}})
Vpwb pwb 0 PULSE(0 1 {{t0+skew}} {{tedge}} {{tedge}} {{twid}} {{Ts}})
R_pwa pwa 0 1Meg
R_pwb pwb 0 1Meg
Vnsch nsch 0 PWL file="{PWLDIR}\\nsch.txt"
R_nsch nsch 0 1Meg
"""

cells = "\n* ===== 64 cells: BJT steering, PWL selection =====\n"
for i in range(1, 65):
    cells += (
        f"QS{i}a bus_plus  bs{i}1 c{i}_s Q5551\n"
        f"QS{i}b bus_minus bs{i}2 c{i}_s Q5551\n"
        f"Vsel{i} sel{i} 0 PWL file=\"{PWLDIR}\\sel{i:02d}.txt\"\n"
        f"Rsel{i} sel{i} 0 1Meg\n"
        f"B{i}a bs{i}1d 0 V={{vlo+(vhi-vlo)*V(sel{i})*V(pwa)}}\n"
        f"B{i}b bs{i}2d 0 V={{vhi-(vhi-vlo)*V(sel{i})*V(pwb)}}\n"
        f"R{i}a bs{i}1d bs{i}1 10\n"
        f"R{i}b bs{i}2d bs{i}2 10\n"
        f"Q4{i} c{i}_s q4_base c{i}_e QNPN_THAT_NS\n"
        f"Rt{i} c{i}_e 0 750\n\n"
    )

tail = f"""
.options gmin=1e-10 abstol=1e-10 reltol=1e-5 plotwinsize=0
.tran 2n {tend*1e6:.6f}u 0
.save V(diffout) V(nsch)

.end
"""

with open(os.path.join(OUT, "bfdac_cosim37.cir"), "w") as f:
    f.write(hdr + cells + tail)
print(f"generated cosim37: {M} periods = {tend*1e6:.1f} us, tone bin {BIN} "
      f"({BIN/(M*TS):.1f} Hz), code range {code.min()}..{code.max()}")
