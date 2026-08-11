"""
BFDAC reclock study - FPGA direct IOB drive vs Chord-DAVE-style external
reclocking flip-flops, compared on edge-timing error physics.

Same converter model as dem_study.py: 64 cells at 6.144MHz, 2nd-order 65-level
modulator, -1dBFS ~1kHz coherent sine, in-band 20Hz-20kHz SNDR of the ERROR.

Timing error model per sample i (in level units):
  e[i] = (1/Ts) * sum_over_toggling_cells s_c * (dt_common[i] + tau_c + eta_{c,i})
       = (1/Ts) * [ dcode[i]*dt_common[i] + sum s_c*tau_c + sum s_c*eta ]
  dt_common[i] = sigma_rj*randn + beta_ssn*k[i]      (whole-edge movement)
  tau_c        = static per-cell skew (clock tree / IOB spread)
  eta_{c,i}    = per-cell independent random jitter

Mechanisms captured:
  1. random common jitter demodulating shaped HF noise in dcode -> in-band noise
  2. SSN: edge delay proportional to switching count k -> k*dcode distortion
     (const-k DEM makes k constant -> term becomes linear, benign)
  3. static skew -> DEM-decorrelated like element mismatch
  4. per-cell random jitter -> white floor

Architecture parameter sets (defaults; all bench-measurable, swept below):
  FPGA direct :  sigma_rj=10ps, beta_ssn=1.0ps/cell, skew_sigma=15ps, eta=1ps
  External FF :  sigma_rj=0.5ps, beta_ssn=0.1ps/cell, skew_sigma=10ps, eta=0.3ps
"""
import numpy as np

NCELL = 64
FS = 6.144e6
TS = 1.0 / FS
NFFT = 2 ** 18
BIN = 43
AMP = 10 ** (-1 / 20)
RNG = np.random.default_rng(7)

# ---------- signal -> 2nd-order 65-level modulator (same as dem_study) ----------
n = np.arange(NFFT)
u = 32.0 + 32.0 * AMP * np.sin(2 * np.pi * BIN * n / NFFT)
code = np.empty(NFFT, int)
i1 = i2 = vc = 0.0
for i in range(NFFT):
    i1 += (u[i] - 32.0) - vc
    i2 += i1 - vc
    vc = min(max(round(i2), -32), 32)
    code[i] = int(vc) + 32

# ---------- selection engines (subset of dem_study) ----------
def run_dwa():
    sel = np.zeros(NCELL, bool)
    p = 0
    idx = np.arange(NCELL)
    k_arr = np.empty(NFFT, int)
    tog = np.zeros((NFFT, NCELL), np.int8)   # +1 turn-on, -1 turn-off
    for i in range(NFFT):
        c = code[i]
        new = ((idx - p) % NCELL) < c
        tog[i] = new.astype(int) - sel.astype(int)
        k_arr[i] = np.abs(tog[i]).sum()
        sel = new
        p = (p + c) % NCELL
    return "DWA classic", k_arr, tog

def run_constk(K, g2=0.5):
    """const-k greedy 2nd-order (production scheme)."""
    sel = np.zeros(NCELL, bool)
    p = 0
    acc1 = np.zeros(NCELL)
    acc2 = np.zeros(NCELL)
    k_arr = np.empty(NFFT, int)
    tog = np.zeros((NFFT, NCELL), np.int8)
    def next_cell(new, start, state):
        elig = np.nonzero((new == state) & (new == start))[0]
        if elig.size == 0:
            return -1
        m = acc1[elig] + g2 * acc2[elig]
        return elig[np.argmin(m)] if not state else elig[np.argmax(m)]
    for i in range(NFFT):
        c = code[i]
        start = sel.copy()
        new = sel
        d = c - int(start.sum())
        toggles = 0
        for _ in range(abs(d)):
            q = next_cell(new, start, d < 0)
            new[q] = d > 0
            toggles += 1
        target = max(K, toggles) if (K - toggles) % 2 == 0 else K + 1
        while toggles < target:
            q_on = next_cell(new, start, False)
            if q_on < 0:
                break
            new[q_on] = True
            q_off = next_cell(new, start, True)
            if q_off < 0:
                new[q_on] = False
                break
            new[q_off] = False
            toggles += 2
        tog[i] = new.astype(int) - start.astype(int)
        k_arr[i] = np.abs(tog[i]).sum() + (toggles - np.abs(tog[i]).sum())  # swaps count
        k_arr[i] = toggles
        acc1 += new
        acc1 -= c / NCELL
        acc2 += acc1
    return f"const-k K={K} 2nd g2={g2}", k_arr, tog

# NOTE on const-k swap pairs: a swap toggles one cell ON and one OFF within the
# same sample. Both edges carry timing error, so the toggle matrix `tog` above
# (net per-cell change) misses swap pairs where a cell turns on AND off... it
# cannot within one sample (each cell toggles at most once per sample in
# run_constk), so tog captures every physical edge. k_arr == |tog|.sum() checked.

F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)
SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2

def err_sndr(e):
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

def timing_sndr(k_arr, tog, sigma_rj, beta_ssn, skew_sigma, eta_sigma, rng):
    """Return dict of SNDRs: each term alone + combined. Times in seconds."""
    dcode = tog.sum(axis=1)                       # net level change per sample
    # 1. common random jitter
    dt_rj = sigma_rj * rng.standard_normal(NFFT)
    e_rj = dcode * dt_rj / TS
    # 2. SSN (data-correlated common delay)
    e_ssn = dcode * (beta_ssn * k_arr) / TS
    # 3. static per-cell skew
    tau = skew_sigma * rng.standard_normal(NCELL)
    e_skew = (tog @ tau) / TS
    # 4. per-cell random jitter (only toggling cells)
    e_pc = np.zeros(NFFT)
    if eta_sigma > 0:
        # sum of |tog| independent gaussians with sign s_c: variance = k*eta^2
        e_pc = np.sqrt(k_arr.astype(float)) * eta_sigma * rng.standard_normal(NFFT) / TS
    e_all = e_rj + e_ssn + e_skew + e_pc
    return {
        "rj": err_sndr(e_rj), "ssn": err_sndr(e_ssn),
        "skew": err_sndr(e_skew), "pc": err_sndr(e_pc) if eta_sigma > 0 else np.inf,
        "all": err_sndr(e_all),
    }

ARCHS = {
    #                 sigma_rj  beta_ssn  skew    eta
    "FPGA direct":   (10e-12,   1.0e-12,  15e-12, 1.0e-12),
    "External FF":   (0.5e-12,  0.1e-12,  10e-12, 0.3e-12),
}

schemes = [run_dwa(), run_constk(4, g2=0.5)]

print(f"reclock study: {NFFT} samples @ {FS/1e6:.3f}MHz, -1dBFS {BIN*FS/NFFT:.0f}Hz sine")
print(f"in-band 20Hz-20kHz SNDR of timing-error sequence vs carrier (higher=better, target >=130dB per contributor)\n")
print(f"{'scheme':<24}{'architecture':<14}{'rj':>7}{'ssn':>7}{'skew':>7}{'pc':>7}{'ALL':>8}")
for name, k_arr, tog in schemes:
    assert (np.abs(tog).sum(axis=1) == k_arr).all(), "toggle bookkeeping broken"
    for aname, (srj, bssn, ssk, eta) in ARCHS.items():
        r = timing_sndr(k_arr, tog, srj, bssn, ssk, eta, np.random.default_rng(11))
        print(f"{name:<24}{aname:<14}{r['rj']:7.1f}{r['ssn']:7.1f}{r['skew']:7.1f}{r['pc']:7.1f}{r['all']:8.1f}")
    print(f"    k: mean={k_arr.mean():.1f} p99={int(np.percentile(k_arr,99))} max={k_arr.max()}")

# ---------- sweeps: where does direct drive break? ----------
print("\nsweep A: common random jitter (const-k K=4, other terms zero)")
name, k_arr, tog = schemes[1]
for srj in [1e-12, 3e-12, 5e-12, 10e-12, 20e-12, 30e-12]:
    r = timing_sndr(k_arr, tog, srj, 0, 0, 0, np.random.default_rng(11))
    print(f"  sigma_rj={srj*1e12:5.1f}ps  SNDR={r['rj']:7.1f} dB")

print("\nsweep B: SSN coefficient (const-k K=4 vs DWA, other terms zero)")
for bssn in [0.2e-12, 0.5e-12, 1e-12, 2e-12, 5e-12]:
    r_ck = timing_sndr(schemes[1][1], schemes[1][2], 0, bssn, 0, 0, np.random.default_rng(11))
    r_dwa = timing_sndr(schemes[0][1], schemes[0][2], 0, bssn, 0, 0, np.random.default_rng(11))
    print(f"  beta={bssn*1e12:4.1f}ps/cell  const-k SNDR={r_ck['ssn']:7.1f}  DWA SNDR={r_dwa['ssn']:7.1f} dB")

print("\nsweep C: static skew sigma (const-k K=4, other terms zero)")
for ssk in [5e-12, 15e-12, 30e-12, 50e-12, 100e-12]:
    r = timing_sndr(k_arr, tog, 0, 0, ssk, 0, np.random.default_rng(11))
    print(f"  skew={ssk*1e12:5.1f}ps  SNDR={r['skew']:7.1f} dB")
