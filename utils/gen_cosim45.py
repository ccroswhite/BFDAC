# Round 45: EXTENDED FFT GATE - 65536 periods (4x) on the Round 44 slow-bias
# deck, predistorted with the cosim44lut LUT. Purpose: push the per-harmonic
# sensing floor ~6dB (to ~-112dBc class) so iteration below -100 stays honest.
# BIN=67 (prime, coprime with M=2^16) ~ 6.281kHz; harmonics 2f/3f in-band.
import numpy as np
import os
import sys
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import FRAC, LSB, CLAMP

M = 65536
BIN = 67
TS = 162.7604e-9
NCELL = 64
LT = r"C:\Users\ccros\Documents\LTspice"
PWLDIR = os.path.join(LT, "pwl45")
os.makedirs(PWLDIR, exist_ok=True)

ppm = np.load(rf"{LT}\cosim44lut_inl.npy")
err_lsb = np.zeros(65)
err_lsb[1:65] = ppm * 1e-6 * 64
LUT = np.round(err_lsb * LSB).astype(np.int64)

rng = np.random.default_rng(7)
n = np.arange(M)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / M) * LSB).astype(np.int64)
HD = LSB >> 1
dith = (rng.integers(0, HD, M) + rng.integers(0, HD, M) - HD).astype(np.int64)

# level-aware EF3 (identical structure to dpd_study.run_ef3 with LUT feedback)
st = (0, 0, 0, 0, 0, 0)
code = np.empty(M, dtype=np.int64)
for i in range(M):
    e1, e2, e3, f1, f2, f3 = st
    f = ((e1 + (e1 >> 1)) - ((e2 << 1) + (e2 >> 2)) + (e3 - (e3 >> 3))
         + (f1 + (f1 >> 1)) - ((f2 >> 1) + (f2 >> 2)) + (f3 >> 3))
    w = int(u[i]) + (32 << FRAC) + f
    cq = (w + int(dith[i])) >> FRAC
    cq = 0 if cq < 0 else (63 if cq > 63 else cq)
    e = w - (cq << FRAC) - int(LUT[cq])
    e = CLAMP if e > CLAMP else (-CLAMP if e < -CLAMP else e)
    st = (e, e1, e2, f, f1, f2)
    code[i] = cq
np.save(rf"{LT}\cosim45_code.npy", code)

# dem_sort integer-exact selection -> per-cell PWL
A1 = np.zeros(NCELL, dtype=np.int64)
A2 = np.zeros(NCELL, dtype=np.int64)
sels = np.zeros((M, NCELL), dtype=np.uint8)
idx = np.arange(NCELL)
for i in range(M):
    c = int(code[i])
    order = np.lexsort((idx, 2 * A1 + A2))
    sel = np.zeros(NCELL, dtype=np.uint8)
    sel[order[:c]] = 1
    sels[i] = sel
    A1 += 64 * sel.astype(np.int64) - c
    A2 += A1

tend = M * TS
for cell in range(NCELL):
    s = sels[:, cell].astype(int)
    lines = [f"0 {s[0]}"]
    for i in range(1, M):
        if s[i] != s[i - 1]:
            t = i * TS
            lines.append(f"{t*1e9:.4f}n {s[i-1]}")
            lines.append(f"{(t+0.2e-9)*1e9:.4f}n {s[i]}")
    lines.append(f"{tend*1e9:.4f}n {s[-1]}")
    with open(os.path.join(PWLDIR, f"sel{cell+1:02d}.txt"), "w") as f:
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

# deck: Round 44 slow-bias gate deck, pwl45 vectors, 4x transient
src = open(os.path.join(LT, "bfdac_cosim44.cir")).read().splitlines()
out = []
for ln in src:
    if ln.startswith("* BFDAC CO-SIM"):
        out.append("* BFDAC CO-SIM v45 - EXTENDED GATE 65536 periods, "
                   "slow-bias deck, predistorted, BIN=67")
    elif ln.startswith(".tran"):
        out.append(f".tran 2n {tend*1e6:.6f}u 0")
    else:
        out.append(ln.replace("pwl44", "pwl45"))
with open(os.path.join(LT, "bfdac_cosim45.cir"), "w") as f:
    f.write("\n".join(out) + "\n")
print(f"cosim45: {M} periods, BIN={BIN}, code range {code.min()}..{code.max()},"
      f" tend {tend*1e3:.2f} ms, pwl45/ + bfdac_cosim45.cir written")
