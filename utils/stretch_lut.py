# R105b: stretch a 64-code LUT chop deck's schedule from SEG=40 periods per
# code to SEG=<n> (default 80) so plants with slow passive poles settle inside
# the discard window (rtz_inl_full discards SEG/2 periods per segment).
# Rewrites the Vnsch PWL time axis and the .tran end time; the destination tag
# gets the "_s<n>" suffix that rtz_inl_full parses for SEG.
#   python stretch_lut.py <src_tag> <dst_tag_without_suffix> [SEG]
import os
import re
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
src, dst = sys.argv[1], sys.argv[2]
SEG = int(sys.argv[3]) if len(sys.argv) > 3 else 80
k = SEG / 40.0
txt = open(os.path.join(LT, f"bfdac_cosim{src}.cir")).read()

def pwl(m):
    toks = m.group(1).split()
    out = []
    for i in range(0, len(toks), 2):
        t = float(toks[i].rstrip("n")) * k
        out.append(f"{t:.4f}n {toks[i+1]}")
    return "Vnsch nsch 0 PWL(" + " ".join(out) + ")"

txt, n = re.subn(r"^Vnsch nsch 0 PWL\((.*)\)$", pwl, txt, flags=re.M)
assert n == 1, n
txt, n = re.subn(r"^\.tran 2n ([0-9.]+)u 0$",
                 lambda m: f".tran 2n {float(m.group(1))*k:.6f}u 0", txt, flags=re.M)
assert n == 1, n
first, rest = txt.split("\n", 1)
txt = first.rstrip() + f" [SEG {SEG}]\n" + rest
out = os.path.join(LT, f"bfdac_cosim{dst}_s{SEG}.cir")
open(out, "w").write(txt)
print(f"wrote {os.path.basename(out)}: schedule x{k:g}, SEG {SEG}")
