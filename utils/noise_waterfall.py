# noise_waterfall.py — analyze tb_noise_waterfall captures (NOISE_BUDGET.md §5)
#
# Per-node integrated 20 Hz-20 kHz noise power, re each node's own fundamental
# (SNR-style; the level differences across domains cancel) plus an absolute
# floor in dBFS. Node scalings from dac_dsp_core.sv:
#   interp/vox : 2^41 = 1.0 FS   | hb3 : 2^47 | paced : 28 x 2^42
#   dem_cmd    : cell count, FS swing = 28 | pop : frame popcount /6 = cells-on
# P6 correlation: pop/6 must equal countones(dem_out) frame-for-frame —
# deterministic cell_shadow frame-slip check (not an SNR comparison).
#
# Usage: python utils/noise_waterfall.py <capture_dir>

import numpy as np
import sys
from pathlib import Path

CAP = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
K = 12          # Kaiser beta=38 mainlobe half-width (bins)
BETA = 38
F_LO, F_HI = 20.0, 20e3

def load_hex(path, bits):
    """Two's-complement decode of %x dumps of signed vectors."""
    v = np.array([int(s.strip(), 16) for s in open(path)], dtype=np.int64)
    v[v >= (1 << (bits - 1))] -= 1 << bits
    return v.astype(np.float64)

def popcount_file(path):
    return np.array([bin(int(s.strip(), 16)).count("1") for s in open(path)], dtype=np.float64)

def waterfall(name, x, fs, lsb_fs):
    """x: float64 raw codes, fs: sample rate, lsb_fs: codes == 1.0 FS."""
    x = x - x.mean()
    n = x.size
    w = np.kaiser(n, BETA)
    cg = (w ** 2).sum() / n
    X = np.abs(np.fft.rfft(x * w)) ** 2 / (n / 2) / n / cg
    f = np.fft.rfftfreq(n, 1 / fs)
    band = (f >= F_LO) & (f <= F_HI)
    # fundamental: loudest in-band bin
    bi = np.argmax(X * band)
    mask = band.copy()
    mask[max(bi - K, 0):bi + K + 1] = False
    fund = X[bi]
    noise = X[mask].sum()
    snr = 10 * np.log10(fund / noise) if noise > 0 else 999.0
    # absolute floor: noise power re full-scale sine power (FS^2/2)
    floor_dbfs = 10 * np.log10(noise / (lsb_fs ** 2 / 2)) if noise > 0 else -999.0
    print(f"P {name:8s} fs={fs/1e6:7.3f}MHz  fund@{f[bi]:8.1f}Hz  "
          f"SNR={snr:7.1f} dB  floor={floor_dbfs:7.1f} dBFS")
    return snr, floor_dbfs

print("=== D1 RTL noise waterfall ===")
r = {}
r["P1 interp"] = waterfall("interp", load_hex(CAP / "nw_interp.txt", 48), 768e3, 2.0 ** 41)
r["P2 vox"]    = waterfall("vox",    load_hex(CAP / "nw_vox.txt", 48),    768e3, 2.0 ** 41)
r["P3 hb3"]    = waterfall("hb3",    load_hex(CAP / "nw_hb3.txt", 48),    6.144e6, 2.0 ** 47)
r["P4 paced"]  = waterfall("paced",  load_hex(CAP / "nw_paced.txt", 48),  6.144e6, 28.0 * 2.0 ** 42)
r["P5 demcmd"] = waterfall("demcmd", load_hex(CAP / "nw_demcmd.txt", 7),  6.144e6, 28.0)

# P6 correlation: pop frames are per pace_div wrap (includes stall frames
# where the accelerated TB cell_clk underruns the pace FIFO -> cell_alive
# drops -> cascode 0). dem_out is per dem_valid — a different index space.
# Check: dedup'd nonzero pops must be an in-order subsequence of 6*dem_out
# (a shadow/cap frame slip breaks the subsequence); partial frames
# (pop%6 != 0) are alive-drop transitions, reported not scored.
pop = np.loadtxt(CAP / "nw_pop.txt", dtype=np.int64)
dem_out = popcount_file(CAP / "nw_demout.txt")
exp = 6 * dem_out
stall = int((pop == 0).sum())
partial = int((((pop % 6) != 0) & (pop != 0)).sum())
full = pop[(pop != 0) & (pop % 6 == 0)]
nz_dedup = full[np.concatenate(([True], np.diff(full) != 0))]
j = 0
mism = 0
for v in nz_dedup:
    while j < len(exp) and exp[j] != v:
        j += 1
    if j >= len(exp):
        mism += 1
        break
print(f"\nP6: {len(pop)} frames ({stall} stall / {partial} partial — TB clock "
      f"artifact, cell_clk/8 > 6.144 MHz fill) | dedup'd words {len(nz_dedup)} "
      f"vs dem_out seq: {mism} subsequence breaks"
      + (" — cell_shadow path CLEAN" if mism == 0 else ""))
r["P6 cascode"] = waterfall("cascode", pop.astype(np.float64), 6.144e6, 28.0)

print("\n--- floor progression (SNR should hold ~P1 level through P5/P6) ---")
for k, (s, fl) in r.items():
    print(f"{k:12s} SNR {s:7.1f} dB   floor {fl:7.1f} dBFS")

# basin-decay check: dem_cmd in-band floor per quarter-capture — the
# post-reset EF3 wandering basin (-60dBFS: ~130-260k samples) shows as an
# elevated early-quarter floor with a 20-200 Hz excess
print("\n--- dem_cmd quarter floors (basin-decay check) ---")
cmd = load_hex(CAP / "nw_demcmd.txt", 7)
q = cmd.size // 4
for i in range(4):
    seg = cmd[i * q:(i + 1) * q] - cmd[i * q:(i + 1) * q].mean()
    wq = np.kaiser(q, BETA)
    Xq = np.abs(np.fft.rfft(seg * wq)) ** 2 / (q / 2) / q / ((wq ** 2).sum() / q)
    fq = np.fft.rfftfreq(q, 1 / 6.144e6)
    bq = (fq >= F_LO) & (fq <= F_HI)
    biq = np.argmax(Xq * bq)
    mq = bq.copy(); mq[max(biq - K, 0):biq + K + 1] = False
    lf = Xq[(fq >= 20) & (fq <= 200) & mq].sum()
    print(f"Q{i}: floor {10 * np.log10(Xq[mq].sum() / (28.0 ** 2 / 2)):7.1f} dBFS   "
          f"20-200Hz {lf:.2e}")
