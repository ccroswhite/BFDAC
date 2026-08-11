# Round 30: state-aligned replay from reset (N_SKIP=0). RTL and model start
# from identical zero state -> outputs must match bit-exactly if the RTL NS
# is the reference algorithm. Report first divergence.
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

# dem stream may lag the pace stream by a fixed pipeline count; both captured
# from reset, so index i pairs directly (dem word i is the response to u[i]).
y = run(u, d)
mism = np.nonzero(y != code)[0]
print(f"mismatches: {len(mism)}/{len(u)}")
if len(mism):
    for i in mism[:10]:
        print(f"  first at i={i}: rtl={code[i]} model={y[i]} u={u[i]/LSB:+.4f} d={d[i]/LSB:+.4f}")
    # try dither offsets to rule out capture offset
    for kd in (-1, 1):
        y2 = run(u[2:-2], d[2 + kd:len(d) - 2 + kd])
        m2 = np.count_nonzero(y2 != code[2:-2])
        print(f"  kd={kd:+d}: mismatches {m2}")
