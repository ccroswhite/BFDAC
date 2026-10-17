"""Gate G1 (2026-09-26, hw/reconcile.md): replace the ideal per-cell base
drives of a finished cosim deck with the ratified hardware network

    LVC1G74 Q/Qb (already Bq/Bqb, 0/3.3 V) -> Rout -> rs -> bsN{1,2}d
                                                     rp -> VCM rail
so bsN1d/bsN2d see the real Thevenin source (rs||rp = 246 R) instead of the
ideal B source + 10 R stopper the ID/LUT/kernel campaign used.  DC levels are
unchanged by construction: VCM(1-k) = 1.10 V, VCM(1-k) + 3.3k = 1.70 V.

    python patch_drive.py <tag>          (patch in place, after patch_p5)
Env: RS (1350) RP (301) ROUT (25, LVC1G74 output resistance) VCM (1.345)
     CS / CP (0): compensation caps across rs / rp (Cs*rs = Cp*rp keeps the
     attenuation flat; the base node then sees 1/(jw(Cs+Cp)) at edge speeds
     instead of rs||rp - R112 finding: 246 R lets C_bc of the steering pair
     modulate the base edge with the code-dependent bus voltage -> HD2 -90)
"""
import os
import re
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
RS = float(os.environ.get("RS", 1350))
RP = float(os.environ.get("RP", 301))
ROUT = float(os.environ.get("ROUT", 25))
VCM = float(os.environ.get("VCM", 1.345))
CS = os.environ.get("CS", "0")
CP = os.environ.get("CP", "0")

tag = sys.argv[1]
path = os.path.join(LT, "bfdac_cosim%s.cir" % tag)
src = open(path).read()

# Bq/Bqb now drive an internal node; Rout brings them to q/qb (Rr1 stays on q/qb)
src, n1 = re.subn(r"^Bq(\d+)\s+q\1\s+0\s+(V=.*)$", r"Bq\1 q\1i 0 \2\nRo\1a q\1i q\1 %g" % ROUT, src, flags=re.M)
src, n2 = re.subn(r"^Bqb(\d+)\s+qb\1\s+0\s+(V=.*)$", r"Bqb\1 qb\1i 0 \2\nRo\1b qb\1i qb\1 %g" % ROUT, src, flags=re.M)
# ideal base drives -> rs from q/qb, rp to VCM
caps_a = caps_b = ""
if CS != "0":
    caps_a = r"\nCs\1a q\1 bs\1\2d %s\nCp\1a bs\1\2d vcm %s" % (CS, CP)
    caps_b = r"\nCs\1b qb\1 bs\1\2d %s\nCp\1b bs\1\2d vcm %s" % (CS, CP)
src, n3 = re.subn(r"^B(\d+)a\s+bs\1(1)d\s+0\s+V=.*$", r"Rs\1a q\1 bs\1\2d %g\nRp\1a bs\1\2d vcm %g" % (RS, RP) + caps_a, src, flags=re.M)
src, n4 = re.subn(r"^B(\d+)b\s+bs\1(2)d\s+0\s+V=.*$", r"Rs\1b qb\1 bs\1\2d %g\nRp\1b bs\1\2d vcm %g" % (RS, RP) + caps_b, src, flags=re.M)
assert n1 == n2 == n3 == n4 == 64, (n1, n2, n3, n4)
src = src.replace(".param rsum=", "V_vcm vcm 0 DC %g\n.param rsum=" % VCM, 1)
assert "V_vcm" in src
open(path, "w").write(src)
k = RP / (RS + RP)
print("patch_drive %s: rs %g rp %g rout %g vcm %g cs %s cp %s -> levels %.3f / %.3f V, Rth %.0f R"
      % (tag, RS, RP, ROUT, VCM, CS, CP, VCM * (1 - k), VCM * (1 - k) + 3.3 * k, RS * RP / (RS + RP)))
