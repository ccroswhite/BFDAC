# Step 4C.4: production half-band coefficients for halfband_x2.sv (HB1/2/3).
# Windowed-sinc (exactly half-band by construction: even taps = 0, center =
# 0.5). Per filter: sweep Kaiser beta, quantize to Q1.17 (18-bit signed),
# evaluate the QUANTIZED response, pick the beta maximizing worst-case
# rejection over the audio-image band [fs_in - 20k, fs_in] while keeping
# passband droop at 20k below 0.0001 dB. Prints ready-to-paste SV ROM lines.
import numpy as np
from scipy.signal.windows import kaiser

Q = 1 << 17
AUDIO = 20e3

def design(ntaps, fs_out, beta):
    n = np.arange(ntaps) - (ntaps - 1) / 2
    h = 0.5 * np.sinc(n / 2) * kaiser(ntaps, beta)
    h[np.abs(n) % 2 == 0] = 0.0          # exact half-band zeros
    h[(ntaps - 1) // 2] = 0.5            # exact center
    hq = np.round(h * Q) / Q
    hq[(ntaps - 1) // 2] = 0.5
    return hq

def metrics(hq, fs_out):
    wpass = np.linspace(1, AUDIO, 400)
    wimg = np.linspace(fs_out / 2 - AUDIO, fs_out / 2, 400)
    def H(f):
        n = np.arange(len(hq)) - (len(hq) - 1) / 2
        return np.abs(np.exp(-2j * np.pi * np.outer(f / fs_out, n)) @ hq)
    droop = np.max(np.abs(20 * np.log10(H(wpass))))
    rej = -20 * np.log10(np.max(H(wimg)))
    return droop, rej

CFG = [("HB1", 63, 1.536e6), ("HB2", 31, 3.072e6), ("HB3", 15, 6.144e6)]
for name, ntaps, fs_out in CFG:
    best = None
    for beta in np.arange(4.0, 16.01, 0.25):
        hq = design(ntaps, fs_out, beta)
        droop, rej = metrics(hq, fs_out)
        if droop <= 5e-4 and (best is None or rej > best[2]):
            best = (beta, droop, rej, hq)
    beta, droop, rej, hq = best
    print(f"\n// {name}: {ntaps}-tap half-band, Kaiser beta={beta:.2f}, "
          f"image-band rejection {rej:.1f} dB, passband droop {droop:.6f} dB "
          f"(quantized Q1.17)")
    c = (ntaps - 1) // 2
    nz = [(c - 1 - 2 * k) for k in range((ntaps + 1) // 4)]
    for k, idx in enumerate(nz):
        v = int(round(hq[idx] * Q))
        u = v & 0x3FFFF
        print(f"            coef_rom[{k:2d}] = 18'sh{u:05X};  "
              f"// h[{idx:2d}]: {v:+7d}  ({hq[idx]:+.5f})")
    dc = int(round(0.5 * Q)) + 2 * sum(int(round(hq[i] * Q)) for i in nz)
    print(f"// DC gain = {dc} (Q1.17 unity = {Q}; error {dc - Q:+d})")
