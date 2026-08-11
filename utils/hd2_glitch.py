# Round 59b: HD2 ~ A^1 (amp discriminator) + inversion-invariant (R58)
# => rectification-class mechanism. Candidate: per-period error proportional
# to |dN| (code-step glitch energy) or DEM cell-switch count. Joint LS fit:
# harmonics + drift + candidate regressor, fitted per gate; coefficient
# cross-checked across 55 (normal), 58 (inverted), 59 (-7dB) - three
# independent stimuli, so a real physical kt must agree on all three.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

M = 16384
BIN = 17
DISCARD = 512
NH = 8
LT = r"C:\Users\ccros\Documents\LTspice"

def analyze(tag, extra=None):
    a = np.load(rf"{LT}\cosim{tag}_pavg.npy")
    code = np.load(rf"{LT}\cosim{tag}_code.npy").astype(float)
    gain = np.polyfit(code[DISCARD:], a[DISCARD:], 1)[0]
    x = (a / gain)[DISCARD:]
    n = np.arange(len(x), dtype=float)
    ph = 2 * np.pi * BIN * (n + DISCARD) / M
    cols = [np.ones_like(n), n / len(n), (n / len(n)) ** 2]
    for h in range(1, NH + 1):
        cols.append(np.cos(h * ph))
        cols.append(np.sin(h * ph))
    nreg = 0
    if extra is not None:
        for r in extra:
            r = r[DISCARD:].astype(float)
            cols.append(r - r.mean())
            nreg += 1
    A = np.vstack(cols).T
    coef, *_ = np.linalg.lstsq(A, x, rcond=None)
    amps = np.hypot(coef[3:3 + 2 * NH:2], coef[4:4 + 2 * NH:2])
    fund = amps[0]
    kt = coef[3 + 2 * NH:] if nreg else []
    return 20 * np.log10(amps[1] / fund), 20 * np.log10(amps[2] / fund), kt

def regs(tag):
    code = np.load(rf"{LT}\cosim{tag}_code.npy").astype(float)
    dN = np.diff(code, prepend=code[0])
    return {"|dN|": np.abs(dN), "dN^2": dN ** 2, "|N-32|": np.abs(code - 32)}

print(f"{'tag':>5} {'reg':>8} {'HD2':>8} {'HD3':>8}   kt")
for tag in ("55", "58", "59"):
    h2, h3, _ = analyze(tag)
    print(f"{tag:>5} {'none':>8} {h2:8.1f} {h3:8.1f}")
    for name, r in regs(tag).items():
        h2, h3, kt = analyze(tag, [r])
        print(f"{tag:>5} {name:>8} {h2:8.1f} {h3:8.1f}   kt={kt[0]*1e6:+.3f} u/unit")
