# R109: anti-leakage pre-filter for the LS harmonic / IMD readers.
# The per-period streams carry ~-30 dBc of shaped out-of-band noise; LS
# projection on a record truncated by DISCARD (non-integer periods) leaks that
# noise into the in-band product bins at ~-110 dB (M 16384) / ~-125 dB
# (M 65536), which is exactly where the D1/D3 limits sit. A zero-phase
# Kaiser-windowed-sinc lowpass (default 130 kHz, ~100 dB stopband) removes the
# leakage source; in-band content passes unchanged (passband ripple < 1e-4).
import numpy as np
from scipy.signal import fftconvolve

FS = 1 / 162.7604e-9

def lowpass(x, fc=130e3, taps=2049, beta=10.0):
    n = np.arange(taps) - (taps - 1) / 2
    h = 2 * fc / FS * np.sinc(2 * fc / FS * n) * np.kaiser(taps, beta)
    h /= h.sum()
    y = fftconvolve(x.astype(float), h, mode="same")
    return y, taps // 2          # filtered stream, edge length to discard each side
