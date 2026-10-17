# Round 41 (analog leg): FFT gate with LEVEL-AWARE (predistorted) vectors.
# Loads the corrected code stream from dpd_study.py (level-aware EF3 with the
# cosim40-measured LUT), runs the same integer-exact dem_sort, emits per-cell
# PWL drives + the v39 Si1555 deck. Expect HD2/HD3 to drop from -84/-81 dBc
# to below the ~-111 dBc sensing floor.
import numpy as np
import os
import re
import sys

TAG = sys.argv[1] if len(sys.argv) > 1 else "41"
M = int(os.environ.get("M", "16384"))   # R95: 65536 for the 1 kHz long gate
TS = 162.7604e-9
NCELL = 64
OUT = r"C:\Users\ccros\Documents\LTspice"
PWLDIR = os.path.join(OUT, f"pwl{TAG}")
os.makedirs(PWLDIR, exist_ok=True)

code = np.load(os.path.join(OUT, f"cosim{TAG}_code.npy")).astype(np.int64)

# ---- cell selection: dem_sort (default) or thermometer (NODEM=1, R65) ----
sels = np.zeros((M, NCELL), dtype=np.uint8)
if os.environ.get("NODEM") == "1":
    for i in range(M):
        sels[i, :int(code[i])] = 1
    print("NODEM: thermometer selection")
else:
    A1 = np.zeros(NCELL, dtype=np.int64)
    A2 = np.zeros(NCELL, dtype=np.int64)
    idx = np.arange(NCELL)
    for i in range(M):
        c = int(code[i])
        Mm = 2 * A1 + A2
        order = np.lexsort((idx, Mm))
        sel = np.zeros(NCELL, dtype=np.uint8)
        sel[order[:c]] = 1
        sels[i] = sel
        A1 += 64 * sel.astype(np.int64) - c
        A2 += A1
assert (sels.sum(axis=1) == code).all()

tend = M * TS
for b in range(NCELL):
    s = sels[:, b]
    lines = [f"0 {int(s[0])}"]
    for i in range(1, M):
        if s[i] != s[i - 1]:
            t = i * TS
            lines.append(f"{(t)*1e9:.4f}n {int(s[i-1])}")
            lines.append(f"{(t+0.2e-9)*1e9:.4f}n {int(s[i])}")
    lines.append(f"{tend*1e9:.4f}n {int(s[-1])}")
    with open(os.path.join(PWLDIR, f"sel{b+1:02d}.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

lines = [f"0 {int(code[0])}"]
for i in range(1, M):
    if code[i] != code[i - 1]:
        t = i * TS
        lines.append(f"{t*1e9:.4f}n {int(code[i-1])}")
        lines.append(f"{(t+0.2e-9)*1e9:.4f}n {int(code[i])}")
lines.append(f"{tend*1e9:.4f}n {int(code[-1])}")
with open(os.path.join(PWLDIR, "nsch.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")

# ---- deck: current plant (R54 gate-stoppers + C_q4 10u; template = v72) ----
src = open(os.path.join(OUT, "bfdac_cosim72.cir")).read()
src = src.replace("v72", f"v{TAG}")
src = src.replace("pwl72", f"pwl{TAG}")
src = re.sub(r"^\.tran (\S+) \S+ 0", lambda m: f".tran {m.group(1)} {tend*1e6:.6f}u 0",
             src, count=1, flags=re.M)
with open(os.path.join(OUT, f"bfdac_cosim{TAG}.cir"), "w") as f:
    f.write(src)
print(f"cosim{TAG}: {M} periods, corrected code range {code.min()}..{code.max()}, "
      f"pwl{TAG}/ written")
