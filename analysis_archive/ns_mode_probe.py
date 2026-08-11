# One-shot discriminator for the bimodal EF3 floor (95.0 dB exact vs ~136 dB).
# Q1: are two bad-mode outputs IDENTICAL across dither seeds (deterministic lock)?
# Q2: quantizer-error spectrum in bad vs good mode (in-band lift?)
# Q3: does the bad mode persist with dither amplitude 2 LSB?
# Q4: does a tiny DC offset on u break the lock (dead-zone hypothesis)?
import numpy as np
from ns_ef3_gen import step, FRAC, LSB, N, BIN, FS

def run_tr(u_seq, d_seq):
    st = (0, 0, 0, 0, 0, 0)
    y = np.empty(len(u_seq), dtype=np.int64)
    e = np.empty(len(u_seq), dtype=np.int64)
    for i in range(len(u_seq)):
        y[i], st = step(int(u_seq[i]), int(d_seq[i]), st)
        e[i] = st[0]
    return y, e

def sndr(y):
    x = y - np.mean(y)
    X = np.abs(np.fft.rfft(x)) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    mask = band.copy(); mask[BIN-1:BIN+2] = False
    return 10 * np.log10(X[BIN] / X[mask].sum())

def inband_frac(x):
    X = np.abs(np.fft.rfft(x - np.mean(x))) ** 2
    freqs = np.fft.rfftfreq(N, 1 / FS)
    return X[(freqs >= 20) & (freqs <= 20e3)].sum() / X[1:].sum()

n = np.arange(N)
amp = 28.0 * 10 ** (-1 / 20)
u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)

def tpdf(seed, scale):
    R = np.random.default_rng(seed)
    m = int(LSB * scale)
    return (R.integers(0, m, N) + R.integers(0, m, N) - m).astype(np.int64)

y1, e1 = run_tr(u, tpdf(1, 1.0))   # bad (95.0)
y2, e2 = run_tr(u, tpdf(2, 1.0))   # bad (95.0)
y3, e3 = run_tr(u, tpdf(3, 1.0))   # good (135.8)
print(f"Q1: y(seed1)==y(seed2)? diff={np.count_nonzero(y1!=y2)}/{N}   "
      f"SNDRs: {sndr(y1):.1f} {sndr(y2):.1f} {sndr(y3):.1f}")
print(f"Q2: e in-band power frac: bad={inband_frac(e1.astype(float)):.5f} "
      f"good={inband_frac(e3.astype(float)):.5f} (white=0.0065); "
      f"e rms bad={e1.std()/LSB:.4f} good={e3.std()/LSB:.4f} lv")
y4, _ = run_tr(u, tpdf(1, 2.0))
print(f"Q3: seed1 with +-2 LSB dither: SNDR={sndr(y4):.1f} dB")
y5, _ = run_tr(u + (LSB // 3), tpdf(1, 1.0))
print(f"Q4: seed1 with +LSB/3 DC on u: SNDR={sndr(y5):.1f} dB")
