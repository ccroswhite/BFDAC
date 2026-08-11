# Patch a gen_cosim41-generated deck (templated from the cosim72 plant) to
# the FROZEN v80 plant: C_q4 220uF + degenerated BJT padding mirrors.
# Usage: python patch_v80.py <tag> [<tag> ...]
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"

def patch(tag):
    p = os.path.join(LT, f"bfdac_cosim{tag}.cir")
    src = open(p).read()
    assert "C_q4 q4_base 0 10u" in src, f"{tag}: C_q4 anchor missing"
    src = src.replace("C_q4 q4_base 0 10u", "C_q4 q4_base 0 220u")
    old_p = "I_padb_p  bus_plus  vee15  DC 50m"
    old_m = "I_padb_m  bus_minus  vee15  DC 50m"
    assert old_p in src and old_m in src, f"{tag}: padding anchors missing"
    new = ("* v80: padding = degenerated BJT mirrors (was ideal 50mA sources)\n"
           "Vpadb padb_base 0 DC 0\n"
           "Cpadb padb_base 0 100u\n"
           "Qpad_p bus_plus padb_base padb_ep QNPN_THAT_NS\n"
           "Rpad_p padb_ep vee15 286\n"
           "Qpad_m bus_minus padb_base padb_em QNPN_THAT_NS\n"
           "Rpad_m padb_em vee15 286")
    src = src.replace(old_p, new).replace(old_m, "* (padding folded above)")
    assert "I_padb" not in src
    open(p, "w").write(src)
    print(f"{tag}: patched to v80 plant")

for t in sys.argv[1:]:
    patch(t)
