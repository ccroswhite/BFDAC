# Round 30: RTZ noise re-budget (leg 3 of RTZ-DEM verification)
# RTZ timing-error physics per sample i (level units, level = I*t_pulse):
#   - pulse POSITION jitter (both edges move together): charge invariant -> CANCELS.
#     OCXO/tree close-in phase noise is common to adjacent edges -> cancels too.
#   - pulse WIDTH jitter dw[i] (broadband floor, uncorrelated between the rise
#     and fall launch edges): e = code[i]*dw[i]/t_pulse   (COMMON to all cells)
#   - per-cell independent edge jitter eta (FF additive, thermal): rise and fall
#     independent -> per-cell charge sigma = sqrt(2)*eta*I ->
#     e = sqrt(2*code[i])*eta/t_pulse
#   - SSN: rise edges of ALL active cells launch together (count=code), fall
#     edges likewise (count=code) -> common delay shifts BOTH edges equally ->
#     cancels; only the rise-vs-fall SSN coefficient DIFFERENCE dbeta survives:
#     e = code[i]^2 * dbeta / t_pulse   (pure even-order distortion term)
#   - static per-cell duty spread: leg 1 (rtz_study.py), DEM-shaped mismatch.
# Amplitude cost: 50% duty -> -6.0dB fundamental; 75% duty -> -2.5dB.
# Thermal floor restatement: 138dB (NRZ) -> 132dB (50%) / 135.5dB (75%).
import numpy as np

NCELL = 64
FS = 6.144e6
TS = 1.0 / FS
NFFT = 2 ** 18
BIN = 43
AMP = 10 ** (-1 / 20)

n = np.arange(NFFT)
u = 32.0 + 32.0 * AMP * np.sin(2 * np.pi * BIN * n / NFFT)
code = np.empty(NFFT, int)
i1 = i2 = vc = 0.0
for i in range(NFFT):
    i1 += (u[i] - 32.0) - vc
    i2 += i1 - vc
    vc = min(max(round(i2), -32), 32)
    code[i] = int(vc) + 32

F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)
SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2

def err_sndr(e):
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

RNG = np.random.default_rng(11)
codef = code.astype(float)

for duty, label in ((0.5, "50% duty (t_pulse=81.4ns)"), (0.75, "75% duty (t_pulse=122.1ns)")):
    tp = duty * TS
    print(f"=== RTZ {label}; amplitude cost {20*np.log10(duty):+.1f} dB ===")
    print("  width jitter sigma_w (uncorrelated edge pair, tree broadband floor):")
    for sw in (20e-15, 50e-15, 80e-15, 150e-15, 300e-15, 1e-12):
        e = codef * sw * RNG.standard_normal(NFFT) / tp
        print(f"    sigma_w={sw*1e15:6.0f} fs  SNDR={err_sndr(e):7.1f} dB")
    print("  per-cell FF edge jitter eta (rise/fall independent, sqrt(2*code) scaling):")
    for eta in (0.1e-12, 0.3e-12, 0.5e-12, 1e-12, 2e-12):
        e = np.sqrt(2 * codef) * eta * RNG.standard_normal(NFFT) / tp
        print(f"    eta={eta*1e12:5.2f} ps  SNDR={err_sndr(e):7.1f} dB")
    print("  SSN rise-vs-fall coefficient difference dbeta (code^2 distortion):")
    for db in (0.05e-12, 0.1e-12, 0.5e-12, 1e-12):
        e = codef ** 2 * db / tp
        print(f"    dbeta={db*1e12:5.2f} ps/cell  SNDR={err_sndr(e):7.1f} dB")
    print()

# NRZ context: common broadband jitter acts on dcode (transitions only)
dcode = np.diff(codef, prepend=codef[0])
e_nrz = dcode * 80e-15 * RNG.standard_normal(NFFT) / TS
print(f"NRZ context: common 80fs broadband jitter on transitions -> SNDR={err_sndr(e_nrz):7.1f} dB")
