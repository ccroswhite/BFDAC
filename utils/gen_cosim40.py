# Round 40: FULL 64-code static INL measurement on the Si1555 deck.
# Takes bfdac_cosim38b.cir (Si1555 all-real chopped deck) and replaces the
# code schedule: SEG0=40 periods at ref 32, then all 63 non-ref codes each
# followed by a ref-32 segment (40 periods each, 20 discard). 5080 periods.
# Output LUT feeds the level-aware predistortion (Round 41).
import os

TS = 162.7604e-9
import sys
SEG = int(sys.argv[2]) if len(sys.argv) > 2 else 40
OUT = r"C:\Users\ccros\Documents\LTspice"
MODE = sys.argv[1] if len(sys.argv) > 1 else "fwd"
codes = [c for c in range(1, 65) if c != 32]
if MODE == "rev":
    codes = codes[::-1]
elif MODE in ("shuf", "shuf2"):
    import random
    random.Random(44 if MODE == "shuf" else 45).shuffle(codes)
sched = []
for c in codes:
    sched += [c, 32]

# PWL: start at 32 for SEG0 periods, then each schedule entry SEG periods
pts = ["0 32"]
val = 32
t = SEG * TS
for v in sched:
    pts.append(f"{t*1e9:.4f}n {val}")
    pts.append(f"{(t+0.2e-9)*1e9:.4f}n {v}")
    val = v
    t += SEG * TS
pwl = " ".join(pts)
tend = t

src = open(os.path.join(OUT, "bfdac_cosim38b.cir")).read()
lines = src.splitlines()
out = []
for ln in lines:
    if ln.startswith("Vnsch nsch 0 PWL"):
        out.append(f"Vnsch nsch 0 PWL({pwl})")
    elif ln.startswith(".tran"):
        out.append(f".tran 2n {tend*1e6:.6f}u 0")
    elif ln.startswith("* BFDAC CO-SIM"):
        out.append("* BFDAC CO-SIM v40 - FULL 64-code INL LUT, Si1555 cascode")
    else:
        out.append(ln)
name = {"fwd": "bfdac_cosim40.cir", "rev": "bfdac_cosim40r.cir",
        "shuf": "bfdac_cosim44lut.cir", "shuf2": "bfdac_cosim44lut2.cir"}[MODE]
if SEG != 40:
    name = name.replace(".cir", f"_s{SEG}.cir")
with open(os.path.join(OUT, name), "w") as f:
    f.write("\n".join(out) + "\n")
nper = int(round(tend / TS))
print(f"{name}: {len(codes)} codes, {nper} periods, tend = {tend*1e6:.1f} us")
