# Round 30: why does the from-reset EF3 trajectory carry an 84 dB floor while
# a mid-stream zero-state restart gives 137 dB? Track the internal state.
import numpy as np
from ns_ef3_gen import step, LSB, N, BIN, FS

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

st = (0, 0, 0, 0, 0, 0)
y = np.empty(len(u), dtype=np.int64)
e_trace = np.empty(len(u))
f_trace = np.empty(len(u))
for i in range(len(u)):
    y[i], st = step(int(u[i]), int(d[i]), st)
    e_trace[i] = st[0] / LSB
    f_trace[i] = st[3] / LSB

print("state |e1| stats per quarter:")
for q in range(4):
    seg = e_trace[q * len(u)//4 : (q+1) * len(u)//4]
    fseg = f_trace[q * len(u)//4 : (q+1) * len(u)//4]
    print(f"  q{q}: e rms={np.abs(seg).std():.4f} max={np.abs(seg).max():.3f}  "
          f"f rms={np.abs(fseg).std():.4f} max={np.abs(fseg).max():.3f}")

# spectra of first vs second half of the SAME trajectory
def sndr(x, n0, n):
    xx = x[n0:n0+n] - x[n0:n0+n].mean()
    X = np.abs(np.fft.rfft(xx)) ** 2
    freqs = np.fft.rfftfreq(n, 1 / FS)
    band = (freqs >= 20) & (freqs <= 20e3)
    b = int(round(BIN * n / N))
    mask = band.copy()
    mask[max(b-1,0):b+2] = False
    return 10 * np.log10(X[b] / X[mask].sum())

print(f"SNDR first  32k: {sndr(y.astype(float), 0, 32768):.1f} dB")
print(f"SNDR second 32k: {sndr(y.astype(float), 32768, 32768):.1f} dB")
