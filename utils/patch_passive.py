# Round 92 (2026-09-09): apply the RATIFIED passive replica-ff network (gen_cosim91
# leg b: bus-cascode replica driven by the sum of reclock-FF outputs, second
# cascode gate fixed) to ANY v80-plant deck (LUT chop, ID record, FFT gate) so
# the Round-86 recal protocol can be re-run on the passive-replica plant.
#   python patch_passive.py <src_tag> <dst_tag> [--pwl-copy]
# Copies cosim<src>_code.npy -> cosim<dst>_code.npy when present (gate/ID decks).
# Env: PNP (2SA1036K), RSUM (10000), CSUM (50p).
import os
import shutil
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
NCELL = 64
PNP = os.environ.get("PNP", "2SA1036K")
RSUM = float(os.environ.get("RSUM", "10000"))
CSUM = os.environ.get("CSUM", "50p")
RSH = RSUM / NCELL
BJTLIB = os.path.expandvars(r"%LOCALAPPDATA%\LTspice\lib\cmp\standard.bjt")


def pnp_model_line():
    for line in open(BJTLIB, encoding="utf-16-le", errors="replace"):
        if line.lower().startswith(f".model {PNP.lower()} "):
            return line.strip()
    raise SystemExit(f"{PNP} not found in {BJTLIB}")


def patch(src):
    drop = ["I_ffs_p  vcc15  casb_p  DC 51.92m", "I_ffs_m  vcc15  casb_m  DC 51.92m",
            "I_ffs2_p vcc15 casb2_p DC 51.92m", "I_ffs2_m vcc15 casb2_m DC 51.92m",
            "B_ff_p  vcc15 casb_p  I={krep*V(nsch)*V(pwa)}",
            "B_ff_m  vcc15 casb_m  I={krep*(64-V(nsch)*V(pwb))}",
            "B_ff2_p vcc15 casb2_p I={krep*V(nsch)*V(pwa)}",
            "B_ff2_m vcc15 casb2_m I={krep*(64-V(nsch)*V(pwb))}",
            "MR2_p casb2_p casb2_p vfr2 vfr2 Si1555DL_N",
            "MR2_m casb2_m casb2_m vfr2 vfr2 Si1555DL_N"]
    for d in drop:
        assert d in src, f"anchor missing: {d}"
        src = src.replace(d + "\n", "")

    net = ["* ===== PASSIVE replica-ff (R91 leg b): sum of reclock-FF outputs -> PNP V-I =====",
           pnp_model_line(),
           f".param rsum={RSUM:g} rsh={RSH:g} csum={CSUM} re_rep=35.3",
           "* FF outputs: Q_i = 3.3*sel_i*pwa (rail p switch), Qb_i = 3.3*(1-sel_i*pwb) (rail m switch)"]
    thermo = "if(V(nsch)>1-0.5,V(pwa),0)" in src   # LUT chop decks: no sel nodes
    for i in range(1, NCELL + 1):
        on = f"if(V(nsch)>{i}-0.5,1,0)" if thermo else f"V(sel{i})"
        net.append(f"Bq{i}  q{i}  0 V={{3.3*{on}*V(pwa)}}")
        net.append(f"Bqb{i} qb{i} 0 V={{3.3*(1-{on}*V(pwb))}}")
        net.append(f"Rr1p{i} qb{i} ns1p {{rsum}}")
        net.append(f"Rr1m{i} q{i}  ns1m {{rsum}}")
    net += ["* node: Vb 2.97..4.62 V (1/2 weight + 1/2 of 5.94 V bias), PNP emitter rail 7.2 V",
            "Vb1  vb1 0 DC 5.94",
            "Ve1  ve1 0 DC 7.2",
            "Rsh1p ns1p vb1 {rsh}", "Csh1p ns1p 0 {csum}",
            "Rsh1m ns1m vb1 {rsh}", "Csh1m ns1m 0 {csum}",
            f"QR1p casb_p ns1p e1p {PNP}", "Re1p e1p ve1 {re_rep}",
            f"QR1m casb_m ns1m e1m {PNP}", "Re1m e1m ve1 {re_rep}",
            "* second cascode gate fixed (3.0 V + Vgs @ 75 mA); R91 a==b within 0.7 dB",
            "Vcb2p casb2_p 0 DC 4.37",
            "Vcb2m casb2_m 0 DC 4.37"]
    anchor = "* v80: padding = degenerated BJT mirrors"
    assert anchor in src
    return src.replace(anchor, "\n".join(net) + "\n" + anchor)


if __name__ == "__main__":
    s, d = sys.argv[1], sys.argv[2]
    src = open(os.path.join(LT, f"bfdac_cosim{s}.cir")).read()
    out = patch(src)
    # keep the PWL directory of the source deck (same vectors, new plant)
    first = out.split("\n", 1)
    out = first[0].rstrip() + f" + PASSIVE replica (patched from {s})\n" + first[1]
    open(os.path.join(LT, f"bfdac_cosim{d}.cir"), "w").write(out)
    for suf in ("_code.npy",):
        p = os.path.join(LT, f"cosim{s}{suf}")
        if s != d and os.path.exists(p):
            shutil.copyfile(p, os.path.join(LT, f"cosim{d}{suf}"))
    print(f"wrote bfdac_cosim{d}.cir from {s} (PNP={PNP}, RSUM={RSUM:g}, CSUM={CSUM})")
