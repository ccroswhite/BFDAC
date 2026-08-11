# Round 30: sample-exact comparison of the in-system NS+DEM output (popcount)
# vs the EF3 reference run on the captured u/dither streams, over alignment
# offsets. Locates WHERE the RTL diverges from the model.
import numpy as np
from ns_ef3_gen import run, LSB

def read_hex(path, bits):
    vals = []
    with open(path) as f:
        for line in f:
            v = int(line.strip(), 16)
            if v >= 1 << (bits - 1):
                v -= 1 << bits
            vals.append(v)
    return np.array(vals, dtype=np.int64)

u = read_hex("sim_run/e2e_paced_l.txt", 48)
d = read_hex("sim_run/e2e_dither_l.txt", 42)
words = []
with open("sim_run/e2e_dem_l.txt") as f:
    for line in f:
        words.append(int(line.strip(), 16))
code = np.array([bin(w).count("1") for w in words], dtype=np.int64)

best = None
for ku in range(-2, 3):
    for kd in range(-2, 3):
        n = 60000
        us = u[1000 + ku : 1000 + ku + n]
        ds = d[1000 + kd : 1000 + kd + n]
        ys = run(us, ds)
        cs = code[1000 : 1000 + n]
        mism = np.count_nonzero(ys != cs)
        err = np.abs(ys - cs)
        if best is None or mism < best[0]:
            best = (mism, ku, kd, err.max(), err.mean())
print(f"best alignment: mismatches={best[0]}/60000 at ku={best[1]} kd={best[2]}; "
      f"max|err|={best[3]} mean|err|={best[4]:.4f}")

# with best alignment, show first divergences
mism, ku, kd, _, _ = best
us = u[1000 + ku : 1000 + ku + 60000]
ds = d[1000 + kd : 1000 + kd + 60000]
ys = run(us, ds)
cs = code[1000 : 1000 + 60000]
idx = np.nonzero(ys != cs)[0][:10]
for i in idx:
    print(f"  i={i}: rtl={cs[i]} model={ys[i]} u={us[i]/LSB:+.3f} d={ds[i]/LSB:+.3f}")
