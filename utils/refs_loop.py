"""Refs-sheet loop decks (bom 9, 2026-10-06): VFR sink, VCM class-A buffer, PADB
current servo, VB1 V_eb compensator.  Same launch/report pattern as servo_loop.py
(detached LTspice, parse .log/.raw afterwards).

Blocks (one deck per block and kind):
  vfr  : U904A OPA1612 PI error amp -> R918 100 -> BCP56 sink (2.2 R emitter) on the
         VFR node (100u UKL + 1u) fed by the 150 mA replica current (MR_p/MR_m sources).
         ac = loop gain (series injection at the sense), noise = V(vfr), tran = start-up.
  vcm  : U904B OPA1612 -> 47 R -> BC847 V_be multiplier (1.43k/1k, 470 R pull-up from
         +5A) -> BCP56 / BCP53 followers, 2.2 R emitters, 2.2 R series -> VCM node
         (10u X7R + 100u UKL).  Load = 128 base networks as 12.9 R to the FF mean
         level (23.6 mA sunk) with 23 mA RTZ-edge current pulses at 98.3 kHz.
         ac = loop gain, zout = |Z(vcm)|, noise = V(vcm), tran = pulse response + start-up.
  padb : U907 OPA1656 A = diff-amp 0.25 x (padb_ep - vee15), B = integrator vs 3.568 V
         -> 1k -> padb_base (Cpadb 100u) -> Mpad_p/m (Si1555DL_N) + Rpad 286 to VEE15.
         ac = loop gain, noise = V(padb_base), tran = start-up (VEE15 ramp) with clamp.
  vb1  : DC temperature sweep: QR1 replica current with the diode-connected 2SA1036K
         compensator chain (VE1 - 57.6 R - Q902 - 590 R) versus a fixed 5.94 V VB1.
Usage: python utils/refs_loop.py launch [block ...]
       python utils/refs_loop.py report [block ...]
Transistor / diode models are the Nexperia vendor subckts in hw/models/nexperia_bjt.lib
(BCP56_16, BC847B, BC817_40, BC807_40, BAT54; fetched 2026-10-07).
"""
import os
import re
import subprocess
import sys
import numpy as np
from read_ltraw import read_raw

LT = r"C:\Users\ccros\Documents\LTspice"
LIB = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hw", "models", "nexperia_bjt.lib"))
LTS = r"C:\Program Files\ADI\LTspice\LTspice.exe"
KT4 = 1.66e-20

OPAMPS = {                      # e_n, i_n, GBW, output short-circuit current (datasheet typ)
    "opa1612": dict(en=1.1e-9, inn=1.7e-12, gbw=40e6, isc=35e-3),
    "opa1656": dict(en=2.9e-9, inn=6e-15, gbw=53e6, isc=45e-3),
}
MODELS = """.model Si1555DL_N VDMOS(Rg=3 Vto=1.1 Rd=200m Rs=150m Rb=250m Kp=2 Cgdmax=.1n Cgdmin=.005n Cgs=.01n Cjo=.01n Is=2p ksubthres=.1 Vds=20 Ron=500m Qg=.8n)
.model 2SA1036K PNP(Is=60f Bf=194.1 Vaf=31.85 Ikf=1.986 Ise=60f Ne=1.449 Br=8.869 Var=100 Ikr=59.05m Isc=60.1p Nc=1.743 Nk=1.003 Re=110m Rb=1.744 Rc=259.6m Cje=60.61p Mje=520.4m Cjc=21.13p Mjc=404.3m Tf=14.87p Xtf=121.2 Vtf=54.43 Itf=27.78m Tr=102.1n Xtb=1.5 Vceo=32 Icrating=0.5 mfg=Rohm)
.lib """ + LIB + """
.model Dcl D(Is=1e-12 N=1)
.model Dz2v7 D(Is=1e-12 N=1 BV=2.7 IBV=5m)
.model Dz6v2 D(Is=1e-12 N=1 BV=6.2 IBV=5m)
"""

# tunable compensation (schematic nominal values first)
# VFR: first pass (R_th 4.12k, R_ref 10k, C_pi 100n) gave 28 nV @ 10 Hz (i_n x 14k + thermal) -> divider
# 1.18k/634 (R_th 412) and R_ref 1k / C_pi 1u film / R_pi 100 (same integrator corner and zero)
VFR = dict(opamp="opa1612", r_th=412, r_ref=1e3, c_pi=1e-6, r_pi=100, r_b=100, r_e=2.2, c_bulk=100e-6, esr=0.3, c_hf=1e-6)
# VCM: 2026-10-07 rail 5 V -> 3.3 V and SOT-223 pair -> BC817-40 / BC807-40 (SOT-23); I_q target ~35 mA (> 24 mA peak)
VCM = dict(opamp="opa1612", v_rail=3.3, r_drv=47, r_pu=470, r_m1=1.43e3, r_m2=1e3, r_e=2.2, r_o=2.2, c_x7r=10e-6, c_bulk=100e-6, esr=0.3, c_f=0)
PADB = dict(opamp="opa1656", r_in=40.2e3, r_fb=10e3, r_i=100e3, c_i=1e-6, r_g=1e3, c_g=100e-6, esr=0.3, rpad=286)


def opamp(tag, p, inp, inn, out, clamp=None):
    """Single-pole behavioural op-amp with e_n / i_n copiers; nodes prefixed by tag."""
    gmv = 2 * np.pi * p["gbw"] * 100e-12
    r1 = 1e6 / gmv
    rn_e = p["en"] ** 2 / KT4
    rn_i = 1e3
    g_i = p["inn"] / np.sqrt(KT4 * rn_i)
    s = f"""* --- op-amp {tag} ({p['en']*1e9:.1f} nV, {p['inn']*1e15:.0f} fA, GBW {p['gbw']/1e6:.0f} MHz) ---
Rn_e_{tag}  ne_{tag} 0 {rn_e:.4g}
E_en_{tag}  inpi_{tag} {inp} ne_{tag} 0 1
Rn_i_{tag}  ni_{tag} 0 {rn_i}
G_in_{tag}  0 {inn} ni_{tag} 0 {g_i:.4g}
G_oa_{tag}  0 oai_{tag} inpi_{tag} {inn} {gmv:.4g}
R_oa_{tag}  oai_{tag} 0 {r1:.4g}
C_oa_{tag}  oai_{tag} 0 100p
D_rl1_{tag} oai_{tag} vpos Dcl
D_rl2_{tag} vneg oai_{tag} Dcl
E_out_{tag} oae_{tag} 0 oai_{tag} 0 1
B_out_{tag} 0 {out} I={p['isc']}*tanh((V(oae_{tag})-V({out}))/{10*p['isc']:.4g})
R_outp_{tag} {out} 0 1G
"""
    if clamp:
        s += f"D_cl_{tag} 0 {out} {clamp}\n"
    return s


def rails(kind):
    ramp = kind == "tran"
    return (f"V_pos vpos 0 DC 15 {'PWL(0 0 10m 15)' if ramp else ''}\n"
            f"V_neg vneg 0 DC -15 {'PWL(0 0 10m -15)' if ramp else ''}\n")


def deck_vfr(kind):
    c, p = VFR, OPAMPS[VFR["opamp"]]
    inject = kind == "ac"
    ramp = kind.startswith("tran")
    s = f"* VFR sink loop / {kind}\n{MODELS}{rails('tran' if ramp else kind)}"
    # tran  = realistic: ref and replica current both follow the REF5F 3.2 Hz node (tau 50 ms), current starts at ~10 % of the ramp
    # tran2 = stress: ref up in 10 ms, replica current absent until 50 ms (op-amp winds up against the clamp)
    irep = ('PWL(0 0 15m 0 40m 60m 80m 110m 130m 135m 200m 148m 300m 150m)' if kind == 'tran'
            else 'PWL(0 0 50m 0 60m 150m)')
    vref = 'PWL(0 0 50m 1.10 100m 1.51 150m 1.66 200m 1.72 300m 1.7475)' if kind == 'tran' else 'PWL(0 0 10m 1.7475)'
    s += f"""* --- plant: 150 mA replica current into vfr, node caps ---
I_rep  vfrsrc vfr DC 150m {irep if ramp else ''}
V_src  vfrsrc 0 DC 5
C_bulk vfr cb1 {c['c_bulk']:.4g}
R_esr  cb1 0 {c['esr']}
C_hf   vfr 0 {c['c_hf']:.4g}
* --- sink: BCP56, 2.2 R emitter ---
XQ1    vfr qb qe BCP56_16
R_e    qe 0 {c['r_e']}
R_b    oa qb {c['r_b']}
XD_cl  0 oa BAT54
* BAT54 on the op-amp output: (1) Q901 base never goes below -0.4 V (V_EBO 5 V), (2) anti-windup - C_pi can only charge to
* V(inn) - V(oa) <= ~2.1 V instead of ~16 V while the replica current is still absent (worst-case ordering, see tran)
* worst-case start-up ordering (tran): ref ramps 0-10 ms, replica current 50-60 ms -> op-amp drives negative until the current arrives
* --- error amp: +in = vfr (sense), -in = ref via R_ref, PI network out -> -in ---
V_ref  vref 0 DC 1.7475 {vref if ramp else ''}
R_th   vref vrefo {c['r_th']}
R_ref  vrefo inn {c['r_ref']:.4g}
C_pi   inn npi {c['c_pi']:.4g}
R_pi   npi oa {c['r_pi']:.4g}
{opamp('a', p, 'vfr_s' if inject else 'vfr', 'inn', 'oa')}"""
    if inject:
        s += "V_inj vfr_s vfr AC 1\n"
    s += ".nodeset V(vfr)=1.75 V(oa)=1.1\n"
    if kind == "ac":
        s += (".ac dec 50 1m 100Meg\n"
              ".meas AC fc WHEN mag(V(vfr)/V(vfr_s))=1\n"
              ".meas AC T_at_fc FIND V(vfr)/V(vfr_s) AT fc\n"
              ".meas AC T_1Hz FIND V(vfr)/V(vfr_s) AT 1\n"
              ".meas AC T_1k FIND V(vfr)/V(vfr_s) AT 1k\n")
    elif kind == "noise":
        s += ("V_dummy dummy 0 AC 1\n.noise V(vfr) V_dummy dec 20 1 1Meg\n"
              + "".join(f".meas NOISE n{f} FIND V(onoise) AT {f}\n" for f in (1, 10, 100, "1k", "10k")))
    else:
        s += ".tran 0 0.6 0 10u\n.options method=gear\n.save V(vfr) V(oa) V(qb) V(qe) I(XD_cl:D1)\n"
    return s + ".end\n"


def deck_vcm(kind):
    c, p = VCM, OPAMPS[VCM["opamp"]]
    inject = kind == "ac"
    ramp = kind == "tran"
    s = f"* VCM class-A buffer / {kind}\n{MODELS}{rails(kind)}"
    s += f"""V_5a   p5a 0 DC {c['v_rail']} {f"PWL(0 0 10m {c['v_rail']})" if ramp else ''}
* --- output stage ---
R_pu   p5a bn {c['r_pu']}
XQ5    bn mb bp BC847B
R_m1   bn mb {c['r_m1']:.4g}
R_m2   mb bp {c['r_m2']:.4g}
R_drv  oa bp {c['r_drv']}
XQ3    p5a bn en BC817_40
XQ4    0 bp ep BC807_40
R_e3   en o {c['r_e']}
R_e4   ep o {c['r_e']}
R_o    o vcm {c['r_o']}
C_x7r  vcm cx 10u
R_esrx cx 0 0.01
C_bulk vcm cb1 {c['c_bulk']:.4g}
R_esr  cb1 0 {c['esr']}
* --- load: 128 base networks (301 + 1.35k each) to the FF mean level, RTZ-edge pulses ---
R_L    vl vcm 12.9
V_L    vl 0 DC 1.65 {'PULSE(1.65 1.35 11m 1n 1n 50n 10.17u)' if ramp else ''}
* --- error amp: +in = ref, -in = vcm ---
V_ref  vref 0 DC 1.3437 {'PWL(0 0 10m 1.3437)' if ramp else ''}
R_th   vref inp 1.97k
{opamp('b', p, 'inp', 'vcm_s' if inject else 'vcm', 'oa')}"""
    if c["c_f"]:
        s += f"C_f oa {'vcm_s' if inject else 'vcm'} {c['c_f']:.4g}\n"
    if inject:
        s += "V_inj vcm_s vcm AC 1\n"
    s += ".nodeset V(vcm)=1.34 V(oa)=0.7\n"
    if kind == "ac":
        s += (".ac dec 50 1m 100Meg\n"
              ".meas AC fc WHEN mag(V(vcm)/V(vcm_s))=1\n"
              ".meas AC T_at_fc FIND V(vcm)/V(vcm_s) AT fc\n"
              ".meas AC T_1k FIND V(vcm)/V(vcm_s) AT 1k\n"
              ".meas AC T_100k FIND V(vcm)/V(vcm_s) AT 100k\n")
    elif kind == "zout":
        s += ("I_z 0 vcm AC 1\n.ac dec 20 1 100Meg\n"
              + "".join(f".meas AC z{f} FIND mag(V(vcm)) AT {f}\n" for f in (10, "1k", "10k", "100k", "1Meg", "10Meg")))
    elif kind == "noise":
        s += ("V_dummy dummy 0 AC 1\n.noise V(vcm) V_dummy dec 20 1 1Meg\n"
              + "".join(f".meas NOISE n{f} FIND V(onoise) AT {f}\n" for f in (10, 100, "1k", "10k")))
    else:
        s += ".tran 0 12m 0 20n\n.options method=gear\n.save V(vcm) V(oa) V(en) V(ep) I(R_e3) I(R_e4) I(R_L)\n"
    return s + ".end\n"


def deck_padb(kind):
    c, p = PADB, OPAMPS[PADB["opamp"]]
    inject = kind == "ac"
    ramp = kind == "tran"
    s = f"* PADB current servo / {kind}\n{MODELS}{rails(kind)}"
    s += f"""V_ee   vee15 0 DC -15 {'PWL(0 0 10m -15)' if ramp else ''}
V_bus  bus 0 DC 1.0
* --- plant: two padding MOSFETs sharing the gate, 286 R each to VEE15 ---
Mp     bus g ep ep Si1555DL_N
Rpad_p ep vee15 {c['rpad']}
Mm     bus g em em Si1555DL_N
Rpad_m em vee15 {c['rpad']}
C_g    g cg1 {c['c_g']:.4g}
R_esr  cg1 0 {c['esr']}
R_g    pi_out g {c['r_g']:.4g}
* --- A: diff-amp 0.25 x (ep - vee15) ---
R_933  {'ep_s' if inject else 'ep'} pd_p {c['r_in']:.4g}
R_936  pd_p 0 {c['r_fb']:.4g}
R_934  vee15 pd_n {c['r_in']:.4g}
R_935  pd_n pd_out {c['r_fb']:.4g}
{opamp('a', p, 'pd_p', 'pd_n', 'pd_out')}* --- B: integrator vs 3.568 V tap ---
V_ref  vref 0 DC 3.568 {'PWL(0 0 10m 3.568)' if ramp else ''}
R_th   vref pi_p 2.05k
R_939  pd_out pi_n {c['r_i']:.4g}
C_938  pi_n pi_out {c['c_i']:.4g}
{opamp('b', p, 'pi_p', 'pi_n', 'pi_out', clamp='Dz2v7')}"""
    if inject:
        s += "V_inj ep_s ep AC 1\n"
    s += ".nodeset V(g)=0.66 V(ep)=-0.7 V(em)=-0.7 V(pi_out)=0.66 V(pd_out)=3.568 V(pi_n)=3.568 V(pi_p)=3.568 V(pd_p)=-0.14 V(pd_n)=-0.14\n"
    if kind == "ac":
        s += (".ac dec 50 1m 10Meg\n"
              ".meas AC fc WHEN mag(V(ep)/V(ep_s))=1\n"
              ".meas AC T_at_fc FIND V(ep)/V(ep_s) AT fc\n"
              ".meas AC T_1Hz FIND V(ep)/V(ep_s) AT 1\n"
              ".meas AC T_9k FIND V(ep)/V(ep_s) AT 9k\n")
    elif kind == "noise":
        s += ("V_dummy dummy 0 AC 1\n.noise V(g) V_dummy dec 20 1 1Meg\n"
              + "".join(f".meas NOISE n{f} FIND V(onoise) AT {f}\n" for f in (1, 10, 100, "1k", "10k")))
    else:
        s += ".tran 0 20 0 1m\n.options method=gear\n.save V(g) V(ep) V(pi_out) V(pd_out) I(Rpad_p) I(Rpad_m)\n"
    return s + ".end\n"


def deck_vb1(kind):
    return f"""* VB1 V_eb compensator vs fixed bias: QR1 replica current over temperature
{MODELS}V_e1  ve1 0 DC 7.21
V_cas casb 0 DC 4.37
* --- compensator chain ---
R_928 ve1 e2 59.0
Q902  vb1 vb1 e2 2SA1036K
R_929 vb1 0 590
* --- QR1 replica biased from the chain ---
R_e1c ve1 ec 35.7
QR1c  casb vb1 ec 2SA1036K
* --- QR1 replica biased from a fixed 5.94 V ---
V_fix vb1f 0 DC 5.94
R_e1f ve1 ef 35.7
QR1f  casb vb1f ef 2SA1036K
.dc temp -20 90 5
.save V(vb1) I(R_e1c) I(R_e1f) I(R_929)
.end
"""


BLOCKS = {
    "vfr": (deck_vfr, ("ac", "noise", "tran", "tran2")),
    "vcm": (deck_vcm, ("ac", "zout", "noise", "tran")),
    "padb": (deck_padb, ("ac", "noise", "tran")),
    "vb1": (deck_vb1, ("dc",)),
}


def path_of(block, kind):
    return rf"{LT}\refs_{block}_{kind}.cir"


def launch(block):
    fn, kinds = BLOCKS[block]
    for kind in kinds:
        p = path_of(block, kind)
        for ext in (".log", ".raw"):
            try:
                os.remove(p.replace(".cir", ext))
            except OSError:
                pass
        with open(p, "w") as f:
            f.write(fn(kind))
        subprocess.Popen([LTS, "-b", p], creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"  launched {block}: {', '.join(kinds)}")


def read_log(path):
    lp = path.replace(".cir", ".log")
    if not os.path.exists(lp):
        return ""
    with open(lp, "rb") as f:
        b = f.read()
    return b.decode("utf-16-le", errors="replace") if b[:2] == b"\xff\xfe" else b.decode("latin-1")


def meas(txt, key):
    m = re.search(rf"^{key}[:=]\s*(.*)$", txt, re.M | re.I)
    return m.group(1).strip() if m else "?"


def polar(s):
    m = re.search(r"\(([-\d.eE+]+)dB,([-\d.eE+]+)[^)]*\)", s)
    return (float(m.group(1)), float(m.group(2))) if m else (None, None)


def loop_line(t, keys):
    if not t:
        return "  AC: not finished"
    if "failed" in t.lower():
        return "  AC: " + next(l for l in t.splitlines() if "failed" in l.lower())
    fc = meas(t, "fc")
    db, ph = polar(meas(t, "t_at_fc"))
    extra = " | ".join(f"T({k}) {polar(meas(t, 't_' + k))[0]} dB" for k in keys)
    return (f"  loop: f_c {fc} | PM {180 - abs(ph):.0f} deg | {extra}" if ph is not None
            else f"  loop: fc {fc} T_at_fc {meas(t, 't_at_fc')}")


def noise_line(t, freqs, what):
    if not t:
        return "  noise: not finished"
    return f"  {what} noise V/rtHz @ {'/'.join(map(str, freqs))} Hz: " + " | ".join(meas(t, f"n{f}") for f in freqs)


def raw(block, kind):
    rp = path_of(block, kind).replace(".cir", ".raw")
    if not os.path.exists(rp):
        return None, None
    names, d = read_raw(rp)
    return [n.lower() for n in names], d


def report_vfr():
    print(f"=== VFR sink: {VFR}")
    print(loop_line(read_log(path_of("vfr", "ac")), ("1hz", "1k")))
    print(noise_line(read_log(path_of("vfr", "noise")), (1, 10, 100, "1k", "10k"), "vfr") + "   (req <= 20n above 10 Hz)")
    for kind, label in (("tran", "realistic REF5F ramp (ref + current together)"), ("tran2", "STRESS: ref at 10 ms, current delayed to 50 ms")):
        names, d = raw("vfr", kind)
        if names is None:
            print(f"  {kind}: not finished"); continue
        t, v = d[0], d[names.index("v(vfr)")]
        oa, qb, qe = d[names.index("v(oa)")], d[names.index("v(qb)")], d[names.index("v(qe)")]
        icl = d[names.index("i(xd_cl:d1)")]
        late = t > 0.4
        err = np.abs(v - 1.7475)
        bad = np.where(err > 0.0018)[0]
        tset = t[bad[-1]] if len(bad) else 0.0
        print(f"  start-up [{label}]: vfr max {v.max():.3f} V, final {v[-1]:.4f} V (err {1e3*(v[-1]-1.7475):+.2f} mV), "
              f"settle to +-0.1 % at {1e3*tset:.1f} ms, ripple(>0.4 s) {1e6*(v[late].max()-v[late].min()):.1f} uV")
        print(f"    op-amp out min {oa.min():.2f} V, Q901 base min {qb.min():.3f} V, V_EB(rev) min {(qb-qe).min():.2f} V (limit -5 V), "
              f"BAT54 clamp current max {1e3*np.abs(icl).max():.0f} mA (op-amp I_sc modelled)")
        if kind == "tran":
            print(f"  dissipation: Q901 {(v[-1]-qe[-1])*0.15:.2f} W, R_e {qe[-1]*0.15:.2f} W")


def report_vcm():
    print(f"=== VCM class-A buffer: {VCM}")
    print(loop_line(read_log(path_of("vcm", "ac")), ("1k", "100k")))
    t = read_log(path_of("vcm", "zout"))
    if t:
        print("  |Z_out| ohm @ 10/1k/10k/100k/1M/10M: " + " | ".join(meas(t, f"z{f}") for f in (10, "1k", "10k", "100k", "1Meg", "10Meg")))
    print(noise_line(read_log(path_of("vcm", "noise")), (10, 100, "1k", "10k"), "vcm"))
    names, d = raw("vcm", "tran")
    if names is None:
        print("  tran: not finished"); return
    t, v = d[0], d[names.index("v(vcm)")]
    i3, i4 = d[names.index("i(r_e3)")], -d[names.index("i(r_e4)")]
    pre = (t > 10.5e-3) & (t < 11e-3)
    pul = t > 11e-3
    if not pul.any():
        print("  tran: not finished"); return
    en, ep = d[names.index("v(en)")][pre].mean(), d[names.index("v(ep)")][pre].mean()
    print(f"  dc: vcm {v[pre].mean():.4f} V, I(Q3) {1e3*i3[pre].mean():.1f} mA, I(Q4) {1e3*i4[pre].mean():.1f} mA "
          f"(RTZ load sinks {1e3*d[names.index('i(r_l)')][pre].mean():.1f} mA); P(Q3) {(VCM['v_rail']-en)*i3[pre].mean():.3f} W, P(Q4) {ep*i4[pre].mean():.3f} W")
    print(f"  pulses (23 mA, 50 ns, 98.3 kHz): vcm excursion {1e3*(v[pul].max()-v[pre].mean()):+.2f} / {1e3*(v[pul].min()-v[pre].mean()):+.2f} mV, "
          f"I(Q4) min {1e3*i4[pul].min():.1f} mA (must stay > 0: class A)")


def report_padb():
    print(f"=== PADB current servo: {PADB}")
    print(loop_line(read_log(path_of("padb", "ac")), ("1hz", "9k")))
    print(noise_line(read_log(path_of("padb", "noise")), (1, 10, 100, "1k", "10k"), "padb_base") + "   (deck: fixed 0.6 V source)")
    names, d = raw("padb", "tran")
    if names is None:
        print("  tran: not finished"); return
    t = d[0]
    ip, im, g = d[names.index("i(rpad_p)")], d[names.index("i(rpad_m)")], d[names.index("v(g)")]
    err = np.abs(np.abs(ip) - 0.050)
    bad = np.where(err > 0.0005)[0]
    tset = t[bad[-1]] if len(bad) else 0.0
    print(f"  start-up: I_pad_p max {1e3*np.abs(ip).max():.1f} mA, final {1e3*abs(ip[-1]):.2f} / {1e3*abs(im[-1]):.2f} mA (p/m), "
          f"gate final {g[-1]:.3f} V, settle to +-1 % at {tset:.2f} s, gate max {g.max():.2f} V")


def report_vb1():
    print("=== VB1 V_eb compensator (DC temp sweep -20..90 C)")
    names, d = raw("vb1", "dc")
    if names is None:
        print("  dc: not finished"); return
    T = d[0]
    ic, if_, vb1 = np.abs(d[names.index("i(r_e1c)")]), np.abs(d[names.index("i(r_e1f)")]), d[names.index("v(vb1)")]
    i25 = np.argmin(np.abs(T - 25))
    sl = lambda y: 1e2 * (y[-1] - y[0]) / (T[-1] - T[0]) / y[i25]
    print(f"  25 C: VB1 {vb1[i25]:.3f} V, I(QR1) comp {1e3*ic[i25]:.2f} mA / fixed {1e3*if_[i25]:.2f} mA; dVB1/dT {1e3*(vb1[-1]-vb1[0])/(T[-1]-T[0]):+.2f} mV/K")
    print(f"  I(QR1) tempco: compensated {sl(ic):+.3f} %/K, fixed 5.94 V {sl(if_):+.3f} %/K  -> ratio {sl(if_)/sl(ic):.1f}x")


REPORT = dict(vfr=report_vfr, vcm=report_vcm, padb=report_padb, vb1=report_vb1)

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "report"
    names = sys.argv[2:] or list(BLOCKS)
    for n in names:
        if mode == "launch":
            launch(n)
        else:
            REPORT[n]()
