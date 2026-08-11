# N1: code-domain quantization/dither floor of the SHIPPING NS config
# (noise_shaper_ef3 + TPDF dither, 6.144 MHz, OSR 153.6). RTL reconciliation:
# noise_shaper_7th_order was REPLACED by EF3 in Round 30 (dac_dsp_core.sv
# instantiates noise_shaper_ef3 + dem_sort) - cosim config IS the shipping one.
# Long records x multiple seeds, in-band 20Hz-20kHz noise vs the -1dBFS fund,
# reported in dB (SNR) and nVrms against the 245nV total budget line
# (fund 0.62 Vrms diff at -1dBFS).
import numpy as np
import sys
import os
sys.path.insert(0, r"C:\Users\ccros\src\BFDAC")
from ns_ef3_gen import run, FRAC, LSB, FS

N = int(os.environ.get("N", str(1 << 20)))
SEEDS = [int(s) for s in os.environ.get("SEEDS", "201,202,203,204").split(",")]
VRMS_FUND_M1DB = 0.62          # diff Vrms at -1dBFS (progress.md reference)

n = np.arange(N)
freqs = np.fft.rfftfreq(N, 1 / FS)
band = (freqs >= 20) & (freqs <= 20e3)

for ampdb in (-1.0, -60.0):
    amp = 28.0 * 10 ** (ampdb / 20)
    BIN = int(round(997.0 / FS * N))          # ~997 Hz, non-round bin
    u = (amp * np.sin(2 * np.pi * BIN * n / N) * LSB).astype(np.int64)
    fund_ref = 28.0 * 10 ** (-1 / 20)         # SNR always re -1dBFS fund
    snrs = []
    for sd in SEEDS:
        rng = np.random.default_rng(sd)
        HD = LSB >> 1
        dith = (rng.integers(0, HD, N) + rng.integers(0, HD, N) - HD).astype(np.int64)
        y = run(u, dith).astype(float)
        x = y - y.mean()
        # R37 methodology: Kaiser beta=38 + mainlobe exclusion (rect window is
        # seed-bimodal from edge leakage of the shaped OOB noise)
        from scipy.signal.windows import kaiser
        w = kaiser(N, 38)
        cg = (w ** 2).sum() / N                        # noise power gain
        X = np.abs(np.fft.rfft(x * w)) ** 2 / (N / 2) / N / cg
        K = 12
        mask = band.copy()
        mask[max(BIN - K, 0):BIN + K + 1] = False
        pn = X[mask].sum()
        snr = 10 * np.log10((fund_ref ** 2 / 2) / pn)
        snrs.append(snr)
        nv = VRMS_FUND_M1DB * 10 ** (-snr / 20) * 1e9
        print(f"drive {ampdb:6.1f} dB  seed {sd}: in-band SNR (re -1dBFS fund) "
              f"= {snr:6.1f} dB  -> {nv:7.1f} nVrms")
    m = np.mean(snrs)
    print(f"drive {ampdb:6.1f} dB  MEAN over {len(SEEDS)} seeds: {m:6.1f} dB "
          f"({VRMS_FUND_M1DB*10**(-m/20)*1e9:.1f} nVrms; budget total 245 nV)\n")
