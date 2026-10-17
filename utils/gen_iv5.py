# P5 stand-alone I/V stage decks (TI OPA1612 + BUF634A macro-models, values
# from iv_n5.py). DAC core = behavioral RTZ current sinks (50 mA pad +
# 0.75 mA x N(t) x RTZ window) behind the cascode output impedance and the
# 12 nF C_col.  Two decks from one template:
#   bfdac_iv5n.cir  .noise 20 Hz-20 kHz, differential, .meas integrates it
#   bfdac_iv5t.cir  .tran with a 1 kHz FS sweep of N(t): slam handling,
#                   summing-node residual, output swing/DC, .four THD.
# Usage: python gen_iv5.py [run]    (run = launch both in LTspice, print .log)
import os
import subprocess
import sys
import re

LT = r"C:\Users\ccros\Documents\LTspice"
LTEXE = r"C:\Program Files\ADI\LTspice\LTspice.exe"
RF = float(os.environ.get("RF", 270.0))
ROFF = float(os.environ.get("ROFF", 190.0))
CF = 1 / (2 * 3.141592653589793 * RF * 450e3)
VVG = float(os.environ.get("VVG", 7.0))
NPAR = int(os.environ.get("NPAR", 1))          # parallel OPA1612s per rail
TIMEOUT = int(os.environ.get("TIMEOUT", 600))   # s; a hung macro-model tran once ran 3 days

def amp(side):
    # NPAR op-amps share +in/-in, outputs summed through 22R into the buffer input
    s = [f"XU{j}_{side} vref sum_{side} vcc15 vee15 oa{j}_{side} OPA161x\n"
         f"R_oa{j}_{side} oa{j}_{side} oav_{side} 22" for j in range(NPAR)]
    return "\n".join(s)

TEMPLATE = f"""* BFDAC P5 I/V stage stand-alone (@MODE@) - OPA1612 + BUF634A, Rf {RF:.0f} || Cf, R_off {ROFF:.0f}
.lib {LT}\\OPA161x.LIB
.lib {LT}\\ti_models\\buf634a\\buf634a_a.lib
.param Ts=162.7604n tc={{Ts/8}} tedge=3n
.param rf={RF} cf={CF:.4g} roff={ROFF} vvg={VVG} cin=12n icell=0.75m ipad=50m
V_p15 vcc15 0 DC 15
V_n15 vee15 0 DC -15
V_ref vref 0 DC {{vvg}}
Vpw pw 0 PULSE(0 1 {{tc}} {{tedge}} {{tedge}} {{6*tc-tedge}} {{Ts}})
* ----- code: N_p(t) = 32 + 28 sin(2 pi 1 kHz t)  (FS), N_m = 64 - N_p -----
B_np np 0 V={{32+28*sin(2*pi*10k*time)}}
* ----- PLUS rail -----
B_dac_p sum_p 0 I={{ipad+icell*V(np)*V(pw)}}
R_o_p sum_p 0 1Meg
C_o_p sum_p 0 50p
C_col_p sum_p 0 {{cin}}
R_off_p vcc15 sum_p {{roff}}
{amp('p')}
XB_p oav_p out_p vcc15 vee15 BUF634A
R_f_p out_p sum_p {{rf}}
C_f_p out_p sum_p {{cf}}
R_ld_p out_p 0 300
* ----- MINUS rail -----
B_dac_m sum_m 0 I={{ipad+icell*(64-V(np))*V(pw)}}
R_o_m sum_m 0 1Meg
C_o_m sum_m 0 50p
C_col_m sum_m 0 {{cin}}
R_off_m vcc15 sum_m {{roff}}
{amp('m')}
XB_m oav_m out_m vcc15 vee15 BUF634A
R_f_m out_m sum_m {{rf}}
C_f_m out_m sum_m {{cf}}
R_ld_m out_m 0 300
* ----- readouts -----
B_diff diffout 0 V={{(V(out_p)-V(out_m))*28/rf}}
R_do diffout 0 1Meg
Vin nin 0 AC 1
R_in nin 0 1k
@ANALYSIS@
.end
"""

NOISE = """.noise V(out_p,out_m) Vin dec 100 20 20k
.meas NOISE vn_out INTEG V(onoise)
.options plotwinsize=0"""

TRAN = """.options gmin=1e-10 abstol=1e-10 reltol=1e-5 plotwinsize=0
.tran 0 300u 0 5n
.save V(sum_p) V(out_p) V(out_m) V(oav_p) V(diffout) I(R_f_p)
.meas TRAN vsum_pp PP V(sum_p) FROM 200u TO 300u
.meas TRAN vsum_avg AVG V(sum_p) FROM 200u TO 300u
.meas TRAN out_max MAX V(out_p) FROM 200u TO 300u
.meas TRAN out_min MIN V(out_p) FROM 200u TO 300u
.meas TRAN out_dc AVG V(out_p) FROM 200u TO 300u
.meas TRAN oav_pp PP V(oav_p) FROM 200u TO 300u
.meas TRAN irf_max MAX I(R_f_p) FROM 200u TO 300u
.meas TRAN irf_min MIN I(R_f_p) FROM 200u TO 300u
.meas TRAN dout_rms RMS V(diffout) FROM 200u TO 300u
.four 10k 9 1 V(diffout)"""

sfx = "" if NPAR == 1 else f"p{NPAR}"
decks = {f"iv5n{sfx}": NOISE, f"iv5t{sfx}": TRAN}
for tag, ana in decks.items():
    path = os.path.join(LT, f"bfdac_{tag}.cir")
    open(path, "w").write(TEMPLATE.replace("@MODE@", tag).replace("@ANALYSIS@", ana))
    print("wrote", path)

if len(sys.argv) > 1 and sys.argv[1] in ("run", "noise"):
    for tag in decks:
        if sys.argv[1] == "noise" and not tag.startswith("iv5n"):
            continue
        cir = os.path.join(LT, f"bfdac_{tag}.cir")
        print(f"\n=== {tag} ===")
        try:
            subprocess.run([LTEXE, "-b", cir], check=False, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            print(f"  TIMEOUT after {TIMEOUT} s - LTspice killed, deck left for inspection")
            continue
        log = open(os.path.join(LT, f"bfdac_{tag}.log"), errors="replace").read()
        keep = [l for l in log.splitlines()
                if re.match(r"^(vn_out|vsum|out_|oav|irf|dout|Fourier|Harmonic|\s+\d+\s|Total Harmonic|.*(error|Error|ERROR|failed|Warning)).*", l)]
        print("\n".join(keep[:60]))
