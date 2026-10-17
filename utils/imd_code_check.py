# P2 pre-flight: IMD products of the two-tone CODE stream alone (NS+DEM floor)
# so the analog reading has a reference. python imd_code_check.py <tag> <M> <B1> <B2>
import numpy as np
import sys
TAG, M, B1, B2 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
c = np.load(rf"C:\Users\ccros\Documents\LTspice\cosim{TAG}_code.npy").astype(float)[:M]
X = np.abs(np.fft.rfft((c - c.mean()) * np.kaiser(M, 38)))
ref = X[B1] + X[B2]
fs = 6.144e6
for i, j, l in [(-1, 1, "f2-f1"), (1, 1, "f1+f2"), (2, -1, "2f1-f2"), (-1, 2, "2f2-f1"),
                (2, 0, "2f1"), (0, 2, "2f2"), (3, 0, "3f1"), (2, 1, "2f1+f2")]:
    b = i * B1 + j * B2
    print(f"{l:7s} bin {b:5d} {b*fs/M/1e3:8.3f} kHz  {20*np.log10(X[b]/ref):7.1f} dB re peak")
