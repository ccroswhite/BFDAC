# Step 6.6 (R86+): add a .temp directive to a gen_cosim41/patch_v80 deck.
# Usage: python patch_temp.py <tag> <tempC>
import os
import sys

LT = r"C:\Users\ccros\Documents\LTspice"
tag, T = sys.argv[1], float(sys.argv[2])
p = os.path.join(LT, f"bfdac_cosim{tag}.cir")
src = open(p).read()
assert ".temp" not in src, f"{tag}: already has a .temp directive"
src = src.replace("\n.tran", f"\n.temp {T:g}\n.tran")
assert f".temp {T:g}" in src
open(p, "w").write(src)
print(f"{tag}: .temp {T:g} added")
