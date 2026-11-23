# Round 30: DWA idle-tone check (leg 4b of RTZ-DEM verification)
# DWA classic is re-eligible under RTZ (transition count benign). Its known
# weakness: idle tones / mismatch-noise modulation at small and DC-adjacent
# inputs. Check in-band mismatch SNDR (0.1% sigma + 0.2% duty-spread class)
# across amplitudes and a worst-case DC offset case, vs const-k K=4 par+2nd.
import numpy as np

NCELL = 64
FS = 6.144e6
TS = 1.0 / FS
NFFT = 2 ** 18
BIN = 43
RNG = np.random.default_rng(7)
W = 1.0 + np.sqrt(1e-3**2 + 2e-3**2) * RNG.standard_normal(NCELL)

F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)
n = np.arange(NFFT)

def modulate(u):
    code = np.empty(NFFT, int)
    i1 = i2 = vc = 0.0
    for i in range(NFFT):
        i1 += (u[i] - 32.0) - vc
        i2 += i1 - vc
        vc = min(max(round(i2), -32), 32)
        code[i] = int(vc) + 32
    return code

def run_dwa(code):
    sel = np.zeros(NCELL, bool)
    p = 0
    idx = np.arange(NCELL)
    y = np.empty(NFFT)
    for i in range(NFFT):
        c = code[i]
        new = ((idx - p) % NCELL) < c
        y[i] = W[new].sum()
        sel = new
        p = (p + c) % NCELL
    return y

def run_dwa_dith(code, prob=0.25):
    """DWA with dithered pointer: with probability prob, advance by +1 extra.
    Standard tone-decorrelation; costs a small amount of shaping."""
    rng = np.random.default_rng(3)
    sel = np.zeros(NCELL, bool)
    p = 0
    idx = np.arange(NCELL)
    y = np.empty(NFFT)
    for i in range(NFFT):
        c = code[i]
        new = ((idx - p) % NCELL) < c
        y[i] = W[new].sum()
        sel = new
        p = (p + c + (rng.random() < prob)) % NCELL
    return y

def inband_err_dbfs(code, y):
    """in-band error power of (y - code), dB rel. FULL SCALE sine (32 amp),
    fundamental excluded (gain). Tone-revealing metric independent of signal size."""
    e = y - code
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    sig_fs = (32.0 * NFFT / 2) ** 2   # FS sine bin power
    ib = E[mask].sum()
    # also peak single-bin tone in band
    pk = E[mask].max()
    return 10 * np.log10(ib / sig_fs), 10 * np.log10(pk / sig_fs)

print(f"{'stimulus':<34}{'DWA ib/pk dBFS':>20}{'dithered ib/pk dBFS':>22}")
for label, amp, dc in [
    ("-1 dBFS sine", 10**(-1/20), 32.0),
    ("-20 dBFS sine", 10**(-20/20), 32.0),
    ("-60 dBFS sine", 10**(-60/20), 32.0),
    ("-60 dBFS sine + 0.5-level DC", 10**(-60/20), 32.5),
    ("-80 dBFS sine", 10**(-80/20), 32.0),
    ("silence + 0.25-level DC", 0.0, 32.25),
]:
    u = dc + 32.0 * amp * np.sin(2 * np.pi * BIN * n / NFFT)
    code = modulate(u)
    ib, pk = inband_err_dbfs(code, run_dwa(code))
    ib2, pk2 = inband_err_dbfs(code, run_dwa_dith(code))
    print(f"{label:<34}{ib:9.1f}/{pk:8.1f}{ib2:12.1f}/{pk2:8.1f}")
