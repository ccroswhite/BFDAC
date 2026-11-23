# Round 30: integer-exact reference for dem_sort.sv (sort-based 2nd-order
# vector shaper) + accumulator bound check + golden vector generation.
# Integer scaling: A1 += 64*sel_i - c ; A2 += A1 ; metric M = 2*A1 + A2.
# Selection: the c cells with smallest M (tie-break: lower index wins).
# Equivalent to dwa_tones3.run_sort(g2=0.5) up to the tie-break rule.
import numpy as np

NCELL = 64
NFFT = 2 ** 18
BIN = 43
RNG = np.random.default_rng(7)

def modulate(u):
    code = np.empty(len(u), int)
    i1 = i2 = vc = 0.0
    for i in range(len(u)):
        i1 += (u[i] - 32.0) - vc
        i2 += i1 - vc
        vc = min(max(round(i2), -32), 32)
        code[i] = int(vc) + 32
    return code

def run_int_sort(code):
    A1 = np.zeros(NCELL, dtype=np.int64)
    A2 = np.zeros(NCELL, dtype=np.int64)
    sels = np.zeros((len(code), NCELL), dtype=np.uint8)
    max1 = max2 = maxm = 0
    for i, c in enumerate(code):
        M = 2 * A1 + A2
        # rank with index tie-break: stable argsort on (M, index)
        order = np.lexsort((np.arange(NCELL), M))
        sel = np.zeros(NCELL, dtype=np.uint8)
        sel[order[:c]] = 1
        sels[i] = sel
        A1 += 64 * sel.astype(np.int64) - c
        A2 += A1
        max1 = max(max1, np.abs(A1).max())
        max2 = max(max2, np.abs(A2).max())
        maxm = max(maxm, np.abs(M).max())
    return sels, max1, max2, maxm

n = np.arange(NFFT)
worst1 = worst2 = worstm = 0
for label, amp, dc in [("-1dBFS", 10**(-1/20), 32.0), ("-60dBFS+0.5DC", 10**(-60/20), 32.5),
                       ("silence+0.25DC", 0.0, 32.25), ("full-scale 0dBFS", 1.0, 32.0)]:
    u = dc + 32.0 * amp * np.sin(2 * np.pi * BIN * n / NFFT)
    code = modulate(u)
    sels, m1, m2, mm = run_int_sort(code)
    ok = (sels.sum(axis=1) == code).all()
    print(f"{label:<18} max|A1|={m1:6d} max|A2|={m2:7d} max|M|={mm:7d} popcount_ok={ok}")
    worst1, worst2, worstm = max(worst1, m1), max(worst2, m2), max(worstm, mm)

print(f"\nbit widths needed (signed): A1 {int(np.ceil(np.log2(worst1)))+2} bits, "
      f"A2 {int(np.ceil(np.log2(worst2)))+2} bits, M {int(np.ceil(np.log2(worstm)))+2} bits")

# golden vectors for tb_dem_sort: 2000 samples of the -1dBFS case
u = 32.0 + 32.0 * 10**(-1/20) * np.sin(2 * np.pi * BIN * np.arange(2000) / NFFT)
code = modulate(u)
sels, _, _, _ = run_int_sort(code)
with open("Testbench/dem_sort_golden.mem", "w") as f:
    for i in range(2000):
        word = 0
        for b in range(NCELL):
            word |= int(sels[i, b]) << b
        f.write(f"{code[i]:02x}_{word:016x}\n".replace("_", ""))
print("wrote Testbench/dem_sort_golden.mem (2000 vectors: [71:64]=amplitude, [63:0]=selection)")
