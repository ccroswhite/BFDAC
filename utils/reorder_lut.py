# R109: make an INDEPENDENT chop measurement of the same plant by re-shuffling
# the 64-code LUT deck's schedule with a new seed. The Vnsch PWL carries the
# code levels (c, 32, c, 32, ...); the k-th non-32 level is replaced by the
# k-th code of random.Random(seed).shuffle(codes) - the same recipe
# rtz_inl_full.py uses, which maps "lut<N>" in the tag to seed 43+N
# (lut -> 44, lut2 -> 45, lut3 -> 46, lut4 -> 47).
#   python reorder_lut.py <src_tag> <dst_tag>       dst must contain lut<N>
import os
import random
import re
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
src, dst = sys.argv[1], sys.argv[2]
m = re.search(r"lut(\d*)", dst)
seed = 43 + (int(m.group(1)) if m.group(1) else 1)
codes = [c for c in range(1, 65) if c != 32]
random.Random(seed).shuffle(codes)

txt = open(os.path.join(LT, f"bfdac_cosim{src}.cir")).read()

def pwl(mm):
    toks = mm.group(1).split()
    out, k, last = [], -1, None
    for i in range(0, len(toks), 2):
        v = int(toks[i + 1])
        if v != 32:
            if v != last:
                k += 1
            v = codes[k]
        last = int(toks[i + 1])
        out.append(f"{toks[i]} {v}")
    assert k == len(codes) - 1, k
    return "Vnsch nsch 0 PWL(" + " ".join(out) + ")"

txt, n = re.subn(r"^Vnsch nsch 0 PWL\((.*)\)$", pwl, txt, flags=re.M)
assert n == 1, n
first, rest = txt.split("\n", 1)
txt = first.rstrip() + f" [shuffle seed {seed}]\n" + rest
open(os.path.join(LT, f"bfdac_cosim{dst}.cir"), "w").write(txt)
print(f"wrote bfdac_cosim{dst}.cir: schedule reshuffled with seed {seed}")
