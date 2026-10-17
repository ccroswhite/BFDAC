"""CASB2 servo loop deck (bom 17(k), 2026-10-01): stability, noise, start-up.

Reduced plant: the M6p cascode leg of the locked deck (Si1555DL_N model, Rg6
100 R, R_off 132.4 from +15, C_col 12 n) with the M5/tail current replaced by
a 75 mA sink whose compliance collapses below 0.3 V (so start-up with M6 off is
represented).  Servo: FET/bipolar op-amp as integrator, sense R_s1 + C_f + R_s2
from mid_p, reference 3.0 V (filtered REF7050 tap, treated noise-free), output
R_o -> casb2 node with local C_g, output clamp VCLAMP.

Per variant three decks: AC loop gain (voltage injection), .noise at casb2,
and a 20 s start-up transient (rails ramp 10 ms).  Results parsed from .log /
.raw.
Loop gain L = V(mid)/V(mid_s) with 1 V injected between mid (follower, low-Z)
and the sense resistor (high-Z); PM = 180 - |phase(L)| at |L| = 1.
Usage: python utils/servo_loop.py launch [variant ...]   write decks, start LTspice detached
       python utils/servo_loop.py report [variant ...]   parse finished runs
"""
import os
import re
import subprocess
import sys
import numpy as np
from read_ltraw import read_raw

LT = r"C:\Users\ccros\Documents\LTspice"
LTS = r"C:\Program Files\ADI\LTspice\LTspice.exe"
KT4 = 1.66e-20

OPAMPS = {                      # e_n [V/rtHz] @1 kHz, i_n [A/rtHz], GBW, slew
    "opa1612": dict(en=1.1e-9, inn=1.7e-12, gbw=40e6, slw=27e6),
    "opa1656": dict(en=2.9e-9, inn=6e-15, gbw=53e6, slw=24e6),
}
VARIANTS = {                    # name: (opamp, C_i, R_s each half, R_o, C_g)
    "a1612_1u":  ("opa1612", 1e-6,   499e3, 100, 100e-6),
    "a1656_1u":  ("opa1656", 1e-6,   499e3, 100, 100e-6),
    "a1656_220n": ("opa1656", 220e-9, 499e3, 100, 100e-6),
    "a1656_1u_10u": ("opa1656", 1e-6, 499e3, 100, 10e-6),
}
VCLAMP = 6.0


def opamp_block(p, inject):
    """Single-pole behavioural op-amp: inputs inp/inn, output 'oa'; clamp; noise copiers."""
    gmv = 2 * np.pi * p["gbw"] * 100e-12
    r1 = 1e6 / gmv
    rn_e = p["en"] ** 2 / KT4
    rn_i = 1e3
    g_i = p["inn"] / np.sqrt(KT4 * rn_i)
    out = "oa"
    return f"""* --- op-amp ({p['en']*1e9:.1f} nV, {p['inn']*1e15:.0f} fA, GBW {p['gbw']/1e6:.0f} MHz) ---
Rn_e  ne 0 {rn_e:.4g}
E_en  inp_i inp ne 0 1
Rn_i  ni 0 {rn_i}
G_in  0 inn ni 0 {g_i:.4g}
G_oa  0 oa_int inp_i inn {gmv:.4g}
R_oa  oa_int 0 {r1:.4g}
C_oa  oa_int 0 100p
E_out oa_e 0 oa_int 0 1
R_out oa_e {out} 10
D_cl1 0 {out} Dcl
D_cl2 {out} vclamp Dcl
V_clamp vclamp 0 DC {VCLAMP}
.model Dcl D(Is=1e-12 N=1)
"""


def deck(name, kind):
    op, ci, rs, ro, cg = VARIANTS[name]
    p = OPAMPS[op]
    inject = kind == "ac"
    s = f"""* CASB2 servo loop deck: {name} / {kind}
.model Si1555DL_N VDMOS(Rg=3 Vto=1.1 Rd=200m Rs=150m Rb=250m Kp=2 Cgdmax=.1n Cgdmin=.005n Cgs=.01n Cjo=.01n Is=2p ksubthres=.1 Vds=20 Ron=500m Qg=.8n)
* --- plant: M6p leg ---
V_roff v_roff 0 DC 15 {'' if kind != 'tran' else 'PWL(0 0 10m 15)'}
R_off  v_roff col 132.4
C_col  col 0 12n
M6     col m6g mid mid Si1555DL_N
Rg6    casb2 m6g 100
B_sink mid 0 I=75m*V(mid)/sqrt(V(mid)**2+0.01)
C_mid  mid 0 1n
.nodeset V(casb2)=4.37 V(mid)=3.0 V(oa_int)=4.37
* --- servo ---
V_ref  vref 0 DC 3.0 {'' if kind != 'tran' else 'PWL(0 0 10m 3.0)'}
R_s1   {'mid_s' if inject else 'mid'}  ns1 {rs:.4g}
C_f    ns1  0   1n
R_s2   ns1  inn {rs:.4g}
C_i    inn  oa  {ci:.4g}
R_i    inn  oa  10G
R_ref  vref inp 1k
{opamp_block(p, inject)}"""
    if inject:
        s += "V_inj  mid_s mid AC 1\n"
    s += f"""R_o    oa casb2 {ro}
C_g    casb2 0 {cg:.4g}
"""
    if kind == "ac":
        s += (".ac dec 50 1m 1Meg\n"
              ".meas AC fc WHEN mag(V(mid)/V(mid_s))=1\n"
              ".meas AC T_at_fc FIND V(mid)/V(mid_s) AT fc\n"
              ".meas AC T_1Hz FIND V(mid)/V(mid_s) AT 1\n"
              ".meas AC T_9k FIND V(mid)/V(mid_s) AT 9k\n")
    elif kind == "noise":
        s += ("V_dummy dummy 0 AC 1\n"
              ".noise V(casb2) V_dummy dec 20 1 1Meg\n"
              ".meas NOISE n1 FIND V(onoise) AT 1\n"
              ".meas NOISE n10 FIND V(onoise) AT 10\n"
              ".meas NOISE n100 FIND V(onoise) AT 100\n"
              ".meas NOISE n1k FIND V(onoise) AT 1k\n"
              ".meas NOISE n10k FIND V(onoise) AT 10k\n")
    else:
        s += (".tran 0 20 0 1m\n"
              ".options method=gear\n"
              ".save V(casb2) V(mid) V(oa) V(col)\n")
    s += ".end\n"
    return s


def path_of(name, kind):
    return rf"{LT}\servo_{name}_{kind}.cir"


def launch(name):
    for kind in ("ac", "noise", "tran"):
        p = path_of(name, kind)
        for ext in (".log", ".raw"):
            try:
                os.remove(p.replace(".cir", ext))
            except OSError:
                pass
        with open(p, "w") as f:
            f.write(deck(name, kind))
        subprocess.Popen([LTS, "-b", p], creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  launched {name}: ac, noise, tran")


def read_log(path):
    with open(path.replace(".cir", ".log"), "rb") as f:
        b = f.read()
    txt = b.decode("utf-16-le", errors="replace") if b[:2] == b"\xff\xfe" else b.decode("latin-1")
    return txt


def meas(txt, key):
    m = re.search(rf"^{key}[:=]\s*(.*)$", txt, re.M | re.I)
    return m.group(1).strip() if m else "?"


def polar(s):
    """LTspice complex meas '(dB,deg)' -> (dB, deg)."""
    m = re.search(r"\(([-\d.eE+]+)dB,([-\d.eE+]+)[^)]*\)", s)
    return (float(m.group(1)), float(m.group(2))) if m else (None, None)


def report(name):
    op, ci, rs, ro, cg = VARIANTS[name]
    print(f"=== {name}: {op}, R_s 2x{rs/1e3:.0f}k, C_i {ci*1e6:.2g} uF, R_o {ro} / C_g {cg*1e6:.0f} uF ===")
    t = read_log(path_of(name, "ac"))
    if "failed" in t:
        print("  AC: " + next(l for l in t.splitlines() if "failed" in l))
    fc = meas(t, "fc")
    db, ph = polar(meas(t, "t_at_fc"))
    if ph is not None:
        pm = 180 - abs(ph)
        print(f"  loop: f_c {fc} | PM {pm:.0f} deg | T(1 Hz) {polar(meas(t, 't_1hz'))[0]:.1f} dB | T(9 kHz) {polar(meas(t, 't_9k'))[0]:.1f} dB")
    else:
        print(f"  loop: fc {fc} T_at_fc {meas(t, 't_at_fc')}")
    t = read_log(path_of(name, "noise"))
    vals = [meas(t, k) for k in ("n1", "n10", "n100", "n1k", "n10k")]
    print("  casb2 noise V/rtHz @ 1/10/100/1k/10k Hz: " + " | ".join(vals) + "   (req <= 20n above 10 Hz)")
    rp = path_of(name, "tran").replace(".cir", ".raw")
    if not os.path.exists(rp):
        print("  tran: not finished")
        return
    names, d = read_raw(rp)
    tt, cb, mid = d[0], d[names.index("V(casb2)")], d[names.index("V(mid)")]
    err = np.abs(mid - 3.0)
    ok = np.where(err[::-1] > 0.011)[0]
    tset = tt[len(tt) - 1 - ok[0]] if len(ok) else 0.0
    print(f"  start-up: casb2 max {cb.max():.2f} V (clamp {VCLAMP}), final {cb[-1]:.3f} V; mid final {mid[-1]:.4f} V; "
          f"settle to +-11 mV at {tset:.2f} s; mid overshoot {mid.max()-3:.3f} V")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    names = sys.argv[2:] or list(VARIANTS)
    for n in names:
        (launch if mode == "launch" else report)(n)
