# P7 / D2 / L1 (2026-09-24): long-record floor readout for a cosim gate.
# Kaiser(beta 38) spectrum of the per-period boxcar-decimated stream, in dB0
# (re a full-scale sine, amplitude 28 code units), for three signals:
#   IDEAL  = popcount of the same code stream (NS + DEM shaped quantization)
#   ANALOG = diffout / fitted gain
#   ADDED  = ANALOG - IDEAL (what the analog plant adds: glitch, INL residue,
#            level-dependent error - the L1 quantity)
# Reports in-band (20 Hz-20 kHz) integrated power excluding the fundamental
# and harmonic (2..NH) mainlobes - the IDEAL stream carries the intentional
# predistortion harmonics, which are D1's business (rtz_fft39) - and the
# largest remaining in-band bin (spur, D2).
#   python floor_read.py <tag> <M> <BIN> [DISCARD=512]     env BETA (38)
#   env GAIN_TAG=<tag>: fit the code->volt gain/offset on that (full-scale)
#   gate's record instead of this one - a -60 dBFS or silence record spans
#   ~5 codes and its own fit is dominated by the DEM glitch (gate 109 read
#   g = +0.0029 vs the true -0.0327 V/code).
# Harmonic mainlobes are excluded only when the fundamental is > -40 dBFS;
# at 1 kHz / 65536 the harmonics are 11 bins apart, so a full-scale long
# record needs BETA ~20 (mainlobe +/-8 bins) - the harmonics themselves are
# rtz_fft39's LS job, this script reads what lies BETWEEN them.
import numpy as np
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw
from rtz_inl import period_avg, Ts

LT = r"C:\Users\ccros\Documents\LTspice"
TAG = sys.argv[1]
M = int(sys.argv[2]) if len(sys.argv) > 2 else 65536
BIN = int(sys.argv[3]) if len(sys.argv) > 3 else 11
DISCARD = int(sys.argv[4]) if len(sys.argv) > 4 else 512
FS_AMP = 28.0
BETA = float(os.environ.get("BETA", 38))
LOBE = int(np.ceil(np.sqrt(1 + (BETA / np.pi) ** 2))) + 2   # kaiser mainlobe half-width, bins
NH = 20            # harmonics excluded from the floor (when fund > -40 dBFS)

code = np.load(rf"{LT}\cosim{TAG}_code.npy").astype(float)
pav = rf"{LT}\cosim{TAG}_pavg.npy"
if os.path.exists(pav):
    a = np.load(pav)
else:
    names, data = read_raw(rf"{LT}\bfdac_cosim{TAG}.raw")
    t, d = data[0], data[names.index("V(diffout)")]
    a = np.array([period_avg(t, d, k * Ts, (k + 1) * Ts) for k in range(M)])
    np.save(pav, a)

def detrend(x):
    n = np.linspace(-1, 1, len(x))
    return x - np.polyval(np.polyfit(n, x, 2), n)

c = detrend(code[DISCARD:])
GT = os.environ.get("GAIN_TAG")
if GT:
    gc = np.load(rf"{LT}\cosim{GT}_code.npy").astype(float)[DISCARD:]
    ga = np.load(rf"{LT}\cosim{GT}_pavg.npy")[DISCARD:]
    g, o = np.polyfit(gc, ga, 1)
else:
    g, o = np.polyfit(code[DISCARD:], a[DISCARD:], 1)
an = detrend((a[DISCARD:] - o) / g)
N = len(c)
w = np.kaiser(N, BETA)
cg = w.sum() / N                       # coherent gain
fs = 1 / Ts
f = np.fft.rfftfreq(N, Ts)
inb = (f >= 20) & (f <= 20e3)
fund_bin = int(round(BIN * N / M))
fund_ideal = 2 * np.abs((c * np.exp(-2j * np.pi * BIN * np.arange(N) / M)).mean())
mask = inb.copy()
if BIN:
    nh = NH if 20 * np.log10(max(fund_ideal, 1e-12) / FS_AMP) > -40 else 1
    for h in range(1, nh + 1):
        hb = int(round(h * BIN * N / M))
        if hb - LOBE > len(mask):
            break
        mask[max(0, hb - LOBE):hb + LOBE + 1] = False
# ENBW of the window for integrated-power normalisation
enbw_bins = N * (w ** 2).sum() / w.sum() ** 2
ref = (FS_AMP / np.sqrt(2)) ** 2       # FS sine power

def spec(x):
    X = np.fft.rfft(x * w) / (N * cg)  # sine of amplitude A -> |X| = A/2
    return X

def report(x, label):
    X = spec(x)
    p_bin = 2 * np.abs(X) ** 2         # single-sided power per bin (A^2/2 for a sine)
    fund = np.sqrt(2 * p_bin[max(0, fund_bin - 3):fund_bin + 4].max()) if BIN else 0
    tot = p_bin[mask].sum() / enbw_bins
    k = np.argmax(np.where(mask, p_bin, 0))
    print(f"  {label:7s} in-band floor {10*np.log10(tot/ref):7.1f} dB0 | max in-band bin "
          f"{10*np.log10(p_bin[k]/ref):7.1f} dB0 at {f[k]/1e3:7.3f} kHz"
          + (f" | fund {20*np.log10(fund/FS_AMP):6.1f} dBFS" if BIN else ""))
    return tot

print(f"cosim{TAG}: M {M}, BIN {BIN} ({BIN/(M*Ts):.1f} Hz), {N} periods, bin {fs/N:.1f} Hz, "
      f"kaiser beta {BETA:g}; fund{' + HD2..%d' % NH if BIN and nh > 1 else ''} mainlobes (+/-{LOBE} bins) excluded; "
      f"0 dB0 = full-scale sine; {mask.sum()} in-band bins read; gain {g*1e3:.2f} mV/code"
      + (f" from gate {GT}" if GT else ""))
ti = report(c, "IDEAL")
ta = report(an, "ANALOG")
td = report(an - c, "ADDED")
print(f"  analog-added in-band floor = {10*np.log10(td/ref):.1f} dB0 "
      f"(= {np.sqrt(td/ref)*6.0*1e9:.0f} nV at 6 Vrms FS)")
