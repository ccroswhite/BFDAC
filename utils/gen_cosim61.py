# Round 61: attack the settling-class residual (R60: distortion ~ f) at its
# physical knobs on the R54 config (100R stoppers + slow bias):
#   a: faster switching edges  tedge 3n -> 1n
#   b: wider settle margin     t0 tc -> 1.5tc, twid 6tc -> 5tc ((1.5+1.5)tc gaps)
#   c: both
# Full honest pipeline per variant: "lut" decks, then (after dpd_study +
# gen_cosim41.py 61x) "gate" patcher.
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
VAR = {
    "a": [("tedge=3n", "tedge=1n")],
    "b": [(".param t0={tc} twid={6*tc}", ".param t0={1.5*tc} twid={5*tc}")],
    "c": [("tedge=3n", "tedge=1n"),
          (".param t0={tc} twid={6*tc}", ".param t0={1.5*tc} twid={5*tc}")],
    "d": [("vlo=1.1 vhi=1.7", "vlo=1.1 vhi=2.0")],
    "e": [("vlo=1.1 vhi=1.7", "vlo=0.9 vhi=1.9")],
}

def fix(src, subs):
    for old, new in subs:
        assert old in src, old
        src = src.replace(old, new)
    return src

which = sys.argv[1] if len(sys.argv) > 1 else "lut"
if which == "lut":
    base = open(os.path.join(LT, "bfdac_cosim54lut.cir")).read()
    for v, subs in VAR.items():
        src = fix(base, subs)
        src = src.replace(src.splitlines()[0],
                          f"* BFDAC CO-SIM v61{v}lut - 64-code LUT, R54 config + timing {v}")
        with open(os.path.join(LT, f"bfdac_cosim61{v}lut.cir"), "w") as f:
            f.write(src)
        print(f"bfdac_cosim61{v}lut.cir written")
else:                      # gate <variant>: patch deck emitted by gen_cosim41
    v = sys.argv[2]
    sys.argv = [sys.argv[0], "gate", f"61{v}"]
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "g54", os.path.join(os.path.dirname(__file__), "gen_cosim54.py"))
    spec.loader.exec_module(importlib.util.module_from_spec(spec))
    p = os.path.join(LT, f"bfdac_cosim61{v}.cir")
    src = fix(open(p).read(), VAR[v])
    with open(p, "w") as f:
        f.write(src)
    print(f"bfdac_cosim61{v}.cir timing-patched")
