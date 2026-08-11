# Round 30: integer-exact reference for noise_shaper_ef3.sv
# NTF = (1-z^-1)^3 / (1 - z^-1/2)^3  (NTFinf 2.37, stable at +-28 levels,
# 135.9 dB in-band @ OSR 154 — exceeds the 133.5 dB code budget line).
# f[n] = 1.5 e1 - 2.25 e2 + 0.875 e3 + 1.5 f1 - 0.75 f2 + 0.125 f3
# All dyadic: implemented with arithmetic shifts (python >> == Verilog >>>).
import numpy as np

FS = 6.144e6
N = 65536
BIN = 11
FRAC = 42
LSB = 1 << FRAC
CLAMP = 63 * LSB

def step(u, dith, st):
    e1, e2, e3, f1, f2, f3 = st
    f = ((e1 + (e1 >> 1))
         - ((e2 << 1) + (e2 >> 2))
         + (e3 - (e3 >> 3))
         + (f1 + (f1 >> 1))
         - ((f2 >> 1) + (f2 >> 2))
         + (f3 >> 3))
    w = u + (32 << FRAC) + f
    d = w + dith
    code = d >> FRAC
    if code > 63:
        code = 63
    elif code < 0:
        code = 0
    e = w - (code << FRAC)
    if e > CLAMP:
        e = CLAMP
    elif e < -CLAMP:
        e = -CLAMP
    return code, (e, e1, e2, f, f1, f2)

def run(u_seq, dith_seq):
    st = (0, 0, 0, 0, 0, 0)
    out = np.empty(len(u_seq), dtype=np.int64)
    for i in range(len(u_seq)):
        out[i], st = step(int(u_seq[i]), int(dith_seq[i]), st)
    return out

if __name__ == "__main__":
    RNG = np.random.default_rng(5)
    n = np.arange(N)
    amp = 28.0 * 10 ** (-1 / 20)
    HD = LSB >> 1   # dither_in is 42-bit signed: TPDF over +-2^41 = +-0.5 level
    u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
    dith = (RNG.integers(0, HD, N) + RNG.integers(0, HD, N) - HD).astype(np.int64)
    y = run(u, dith)

    x = y - y.mean()
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy()
    mask[BIN-1:BIN+2] = False
    print(f"integer EF3: SNDR={10*np.log10(X[BIN]/X[mask].sum()):.1f} dB, "
          f"code range {y.min()}..{y.max()}")

    # golden vectors: 3000 samples, mixed sine + random walk segments
    ng = 3000
    ug = np.concatenate([
        u[:1500],
        RNG.integers(-20 * LSB, 20 * LSB, 1500),
    ]).astype(np.int64)
    dg = (RNG.integers(0, HD, ng) + RNG.integers(0, HD, ng) - HD).astype(np.int64)
    yg = run(ug, dg)
    with open("Xilinx/Testbench/ns_ef3_golden.mem", "w") as f:
        for i in range(ng):
            uu = int(ug[i]) & ((1 << 48) - 1)
            dd = int(dg[i]) & ((1 << 42) - 1)   # 42-bit two's complement
            f.write(f"{uu:012x}{dd:011x}{int(yg[i]):02x}\n")
    print("wrote Xilinx/Testbench/ns_ef3_golden.mem (3000 vectors: u[48] d[42(padded 44)] y[8])")
