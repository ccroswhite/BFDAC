# R108 follow-up: is the 12.000 kHz (fs/512) line seen in the silence gate
# (110, ANALOG -131.3 dB0) a dem_sort idle pattern? Offline: run dem_sort on a
# gate's code stream, weight the selections by a random static cell-mismatch
# vector (sigma_rel), Kaiser-spectrum the mismatch error in dB0, and compare
# tie-break rules:   idx   = deterministic cell index (gen_cosim41 / RTL)
#                    rnd   = fresh random permutation per sample
#                    lfsr  = fixed random permutation (rotated per sample)
#   python dem_tone.py <tag> [sigma_rel=0.002] [seed=1]
import numpy as np
import sys
import os

LT = r"C:\Users\ccros\Documents\LTspice"
TAG = sys.argv[1] if len(sys.argv) > 1 else "110"
SIG = float(sys.argv[2]) if len(sys.argv) > 2 else 0.002
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 1
NCELL, TS, DISCARD, BETA = 64, 162.7604e-9, 512, 38
code = np.load(os.path.join(LT, f"cosim{TAG}_code.npy")).astype(np.int64)
M = len(code)
rng = np.random.default_rng(SEED)
mis = rng.normal(0, SIG, NCELL)          # relative unit-element errors
mis -= mis.mean()
# per-cell toggle glitch charge, cell units per toggle: 0.5% of a cell each
# (order of the 200 fC glitch seen in the plant) with a 20% cell-to-cell spread
gl = 0.005 * (1 + rng.normal(0, 0.2, NCELL))

def dem(code, rule):
    A1 = np.zeros(NCELL, dtype=np.int64)
    A2 = np.zeros(NCELL, dtype=np.int64)
    idx = np.arange(NCELL)
    r = np.random.default_rng(7)
    perm = r.permutation(NCELL)
    err = np.zeros(M)
    isi = np.zeros(M)
    prev = np.zeros(NCELL, dtype=np.int64)
    for i in range(M):
        c = int(code[i])
        Mm = 2 * A1 + A2
        if rule == "idx":
            tb = idx
        elif rule == "rnd":
            tb = r.permutation(NCELL)
        else:
            tb = np.roll(perm, i)
        order = np.lexsort((tb, Mm))
        sel = np.zeros(NCELL, dtype=np.int64)
        sel[order[:c]] = 1
        err[i] = (sel * mis).sum()      # static mismatch error, cell units
        isi[i] = (np.abs(sel - prev) * gl).sum()   # per-cell toggle glitch charge
        prev = sel
        A1 += 64 * sel - c
        A2 += A1
    return err, isi

N = M - DISCARD
w = np.kaiser(N, BETA)
f = np.fft.rfftfreq(N, TS)
ref = (28 / np.sqrt(2)) ** 2
inb = (f >= 2500) & (f <= 20e3)           # same band floor_read reads with BIN 11
enbw = N * (w ** 2).sum() / w.sum() ** 2
print(f"cosim{TAG}: M {M}, mismatch sigma {SIG*100:.2f}% (seed {SEED}), code range {code.min()}..{code.max()}")
for rule in ("idx", "rnd", "lfsr"):
    err, isi = dem(code, rule)
    for nm, e in (("static", err), ("ISI", isi)):
        e = e[DISCARD:] - e[DISCARD:].mean()
        P = 2 * np.abs(np.fft.rfft(e * w) / w.sum()) ** 2 / ref
        k = np.argmax(np.where(inb, P, 0))
        k12 = int(round(12012 * N * TS))
        print(f"  {rule:5s} {nm:6s} in-band(2.5-20k) floor {10*np.log10(P[inb].sum()/enbw):7.1f} dB0 | "
              f"max bin {10*np.log10(P[k]):7.1f} dB0 at {f[k]/1e3:7.3f} kHz | "
              f"12.01 kHz bin {10*np.log10(P[k12-1:k12+2].max()):7.1f} dB0")
