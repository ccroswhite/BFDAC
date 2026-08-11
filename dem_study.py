"""
BFDAC DEM study - Decision 4 evidence (transition-count limiting)
Simulates the 64-cell converter at 6.144MHz with:
  - schemes: static thermometer (no DEM), classic DWA, partial-rotation DWA (r = pointer advance/sample)
  - metrics per scheme:
      k statistics (transitions/sample): mean / p99 / max
      SNDR from 0.1% sigma element mismatch (in-band 20Hz-20kHz, fundamental excluded)
      SNDR from glitch charge using SPICE-measured q(k):
        model A (no reservoir, code-dependent): q_per_cell interpolated from cosim9 {1:-5.28, 2:-5.46, 4:-6.57, 8:-8.27} nV*s, linear extrapolation
        model B (reservoir, cosim9c): q_per_cell = -9.7 nV*s constant
Signal: coherent -1dBFS sine ~1kHz, N=2^18 samples.
"""
import numpy as np

NCELL = 64
FS = 6.144e6
TS = 1.0 / FS
NFFT = 2 ** 18
BIN = 43                      # fundamental bin -> 1007.8 Hz, coherent
F0 = BIN * FS / NFFT
AMP = 10 ** (-1 / 20)         # -1 dBFS
VCELL = 0.0868                # V per cell at diffout (774uA*2*56)
RNG = np.random.default_rng(7)

# ---------- signal -> 2nd-order delta-sigma modulator -> thermometer code 0..64 ----------
n = np.arange(NFFT)
u = 32.0 + 32.0 * AMP * np.sin(2 * np.pi * BIN * n / NFFT)   # target in level units
code = np.empty(NFFT, int)
i1 = i2 = vc = 0.0
for i in range(NFFT):
    i1 += (u[i] - 32.0) - vc
    i2 += i1 - vc
    vc = min(max(round(i2), -32), 32)
    code[i] = int(vc) + 32

# even-step variant: quantizer restricted to even levels -> dcode always even ->
# constant-k with even K needs NO parity dither (costs ~6dB SQNR)
codeE = np.empty(NFFT, int)
i1 = i2 = vc = 0.0
for i in range(NFFT):
    i1 += (u[i] - 32.0) - vc
    i2 += i1 - vc
    vc = 2 * min(max(round(i2 / 2), -16), 16)
    codeE[i] = int(vc) + 32


# ---------- element mismatch (0.1% sigma) ----------
w = 1.0 + RNG.normal(0, 1e-3, NCELL)

# ---------- q(k) glitch models (V*s at diffout) ----------
K_MEAS = np.array([1, 2, 4, 8])
QPC_MEAS = np.array([-5.28, -5.46, -6.57, -8.27]) * 1e-9   # per cell
SLOPE = (QPC_MEAS[-1] - QPC_MEAS[-2]) / (K_MEAS[-1] - K_MEAS[-2])

QPC_RES = np.array([-9.7534, -9.7340, -9.5777, -9.2765]) * 1e-9   # cosim9e, reservoir 2.2n, full settle
SLOPE_R = (QPC_RES[-1] - QPC_RES[-2]) / (K_MEAS[-1] - K_MEAS[-2])
QPC_R10 = np.array([-10.1320, -10.1232, -10.0319, -9.8852]) * 1e-9  # cosim9f, reservoir 10n
SLOPE_R10 = (QPC_R10[-1] - QPC_R10[-2]) / (K_MEAS[-1] - K_MEAS[-2])
QPC_IIV = np.array([-9.5591, -9.5542, -9.5434, -9.5102]) * 1e-9  # cosim11c, IDEAL I/V (converter residue only)
SLOPE_IIV = (QPC_IIV[-1] - QPC_IIV[-2]) / (K_MEAS[-1] - K_MEAS[-2])
QPC_RC = np.array([-9.41533, -9.41493, -9.41198, -9.40444]) * 1e-9  # cosim12c, ideal I/V + reg cascode A=1000
SLOPE_RC = (QPC_RC[-1] - QPC_RC[-2]) / (K_MEAS[-1] - K_MEAS[-2])
QPC_STK = np.array([-9.86432, -9.86303, -9.86118, -9.85045]) * 1e-9  # cosim13b, REALISTIC composed stack:
SLOPE_STK = (QPC_STK[-1] - QPC_STK[-2]) / (K_MEAS[-1] - K_MEAS[-2])  # 40MHz amp w/ wide lin range + reg cascode
QPC_PAD = np.array([-10.1114, -10.1081, -10.1012, -10.0868]) * 1e-9  # cosim15, wide-range amp + 50mA current padding (no loop)
SLOPE_PAD = (QPC_PAD[-1] - QPC_PAD[-2]) / (K_MEAS[-1] - K_MEAS[-2])
QPC_FF = np.array([-9.848883, -9.848804, -9.848715, -9.848494]) * 1e-9  # cosim17e, replica feedforward + 100n bus caps
SLOPE_FF = (QPC_FF[-1] - QPC_FF[-2]) / (K_MEAS[-1] - K_MEAS[-2])       # + 50mA padding, REALISTIC 40MHz amp: 0.004% flat
ASYM = 0.000071   # rise/fall asymmetry REMEASURED on final stack (cosim20, worst k; old reservoir value 1.45e-4)

def qpc_noreservoir(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_MEAS),
                    QPC_MEAS[-1] + SLOPE * (k - 8))

def qpc_reservoir(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_RES),
                    QPC_RES[-1] + SLOPE_R * (k - 8))

def qpc_res10(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_R10),
                    QPC_R10[-1] + SLOPE_R10 * (k - 8))

def qpc_idealiv(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_IIV),
                    QPC_IIV[-1] + SLOPE_IIV * (k - 8))

def qpc_regcas(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_RC),
                    QPC_RC[-1] + SLOPE_RC * (k - 8))

def qpc_stack(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_STK),
                    QPC_STK[-1] + SLOPE_STK * (k - 8))

def qpc_pad(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_PAD),
                    QPC_PAD[-1] + SLOPE_PAD * (k - 8))

def qpc_ffwd(k):
    k = np.asarray(k, float)
    return np.where(k <= 8, np.interp(k, K_MEAS, QPC_FF),
                    QPC_FF[-1] + SLOPE_FF * (k - 8))

def qpc_const(k):
    """hypothetical perfectly flat q_pc (compression mechanism fixed)"""
    return np.full_like(np.asarray(k, float), QPC_RES[0])

def glitch_err(qpc_fn, k, dcode, asym=None):
    """Differential physics: ON and OFF transitions inject opposite-polarity charge.
    Net = qpc(k) * (dcode + asym*k). Uniform qpc -> mostly linear (benign);
    distortion comes from qpc(k) code-dependence and the asymmetry*k term."""
    if asym is None:
        asym = ASYM
    return qpc_fn(k) * (dcode + asym * k) / VCELL / TS

# ---------- selection engines ----------
def run_scheme(name, advance):
    """advance: callable(code_n) -> pointer increment; None = static thermometer."""
    sel = np.zeros(NCELL, bool)
    p = 0
    y_mis = np.empty(NFFT)
    k_arr = np.empty(NFFT, int)
    idx = np.arange(NCELL)
    for i in range(NFFT):
        c = code[i]
        if advance is None:
            new = idx < c
        else:
            new = ((idx - p) % NCELL) < c
        k_arr[i] = np.count_nonzero(new ^ sel)
        y_mis[i] = w[new].sum()
        sel = new
        if advance is not None:
            p = (p + advance(c)) % NCELL
    return name, y_mis, k_arr, code

def run_random(name, max_adv=None):
    """dCS-style decorrelation. max_adv=None: fully random subset every sample.
    max_adv=int: rotation with random pointer advance in [1, max_adv]."""
    sel = np.zeros(NCELL, bool)
    p = 0
    y_mis = np.empty(NFFT)
    k_arr = np.empty(NFFT, int)
    idx = np.arange(NCELL)
    for i in range(NFFT):
        c = code[i]
        if max_adv is None:
            new = np.zeros(NCELL, bool)
            new[RNG.choice(NCELL, c, replace=False)] = True
        else:
            new = ((idx - p) % NCELL) < c
            p = (p + int(RNG.integers(1, max_adv + 1))) % NCELL
        k_arr[i] = np.count_nonzero(new ^ sel)
        y_mis[i] = w[new].sum()
        sel = new
    return name, y_mis, k_arr, code

def run_constk(K, carr=None, shape_par=False, greedy=False, g2=0.0, name=None):
    """Chord-style constant activity: every sample toggles exactly K cells
    (K+-1 when |dcode| parity mismatches). Net code moves first, then padding
    with code-neutral ON/OFF swap pairs (each cell toggles at most once per sample).
    shape_par: noise-shape the K-1/K+1 parity choice (1st-order, zero-mean k error)
    greedy: choose cells by shaping metric acc1 + g2*acc2 instead of rotation
            (g2=0: 1st-order usage balancing; g2>0: 2nd-order vector shaping)"""
    if carr is None:
        carr = code
    sel = np.zeros(NCELL, bool)
    p = 0
    acc_par = 0
    acc1 = np.zeros(NCELL)
    acc2 = np.zeros(NCELL)
    y_mis = np.empty(NFFT)
    k_arr = np.empty(NFFT, int)
    def next_cell(new, start, p0, state):
        if greedy:
            elig = np.nonzero((new == state) & (new == start))[0]
            if elig.size == 0:
                return -1
            m = acc1[elig] + g2 * acc2[elig]
            return elig[np.argmin(m)] if not state else elig[np.argmax(m)]
        q = p0
        for _ in range(NCELL):
            if new[q] == state and new[q] == start[q]:
                return q
            q = (q + 1) % NCELL
        return -1
    for i in range(NFFT):
        c = carr[i]
        start = sel.copy()
        new = sel
        d = c - int(start.sum())
        toggles = 0
        for _ in range(abs(d)):
            q = next_cell(new, start, p, d < 0)
            new[q] = d > 0
            toggles += 1
            p = (q + 1) % NCELL
        if (K - toggles) % 2 == 0:
            target = max(K, toggles)
        elif shape_par and K - 1 >= toggles and acc_par > 0:
            target = K - 1
        else:
            target = K + 1
        acc_par += target - K
        while toggles < target:
            q_on = next_cell(new, start, p, False)   # OFF, untouched -> turn ON
            if q_on < 0:
                break
            new[q_on] = True
            q_off = next_cell(new, start, (q_on + 1) % NCELL, True)  # ON, untouched -> turn OFF
            if q_off < 0:
                new[q_on] = False
                break
            new[q_off] = False
            toggles += 2
            p = (q_off + 1) % NCELL
        k_arr[i] = toggles
        acc1 += new
        acc1 -= c / NCELL
        acc2 += acc1
        y_mis[i] = w[new].sum()
    return name or f"constant-k K={K}", y_mis, k_arr, carr

F_AX = np.fft.rfftfreq(NFFT, TS)
BAND = (F_AX >= 20) & (F_AX <= 20e3)
SIG_P = None  # set below from ideal code spectrum

def err_sndr(e):
    """SNDR (dB): ideal-signal power vs in-band power of the ERROR sequence
    (fundamental bin of the error excluded as gain error; quantization not counted)."""
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

schemes = [
    run_scheme("thermometer (no DEM)", None),
    run_scheme("DWA classic (r=code)", lambda c: c),
    run_scheme("partial rot r=1",  lambda c: 1),
    run_scheme("partial rot r=2",  lambda c: 2),
    run_scheme("partial rot r=4",  lambda c: 4),
    run_scheme("partial rot r=8",  lambda c: 8),
    run_scheme("partial rot r=16", lambda c: 16),
    run_random("random subset (dCS-ish)"),
    run_random("random rot r~U[1,8]", max_adv=8),
    run_constk(4),
    run_constk(8),
    run_constk(16),
    run_constk(4, shape_par=True, name="const-k K=4 par-shaped"),
    run_constk(4, greedy=True, name="const-k K=4 greedy 1st"),
    run_constk(4, greedy=True, g2=0.25, name="const-k K=4 2nd g2=.25"),
    run_constk(4, greedy=True, g2=0.5, name="const-k K=4 2nd g2=.5"),
    run_constk(4, greedy=True, g2=1.0, name="const-k K=4 2nd g2=1"),
    run_constk(8, greedy=True, g2=0.5, name="const-k K=8 2nd g2=.5"),
    run_constk(4, shape_par=True, greedy=True, g2=0.5, name="K=4 par+2nd g2=.5"),
]

SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2
dcode = np.diff(code, prepend=code[0])

# code-stream quality: in-band shaped quantization noise vs signal
s_code = err_sndr(code - u)
s_codeE = err_sndr(codeE - u)
print(f"signal: {F0:.1f}Hz sine at -1dBFS, {NFFT} samples at {FS/1e6:.3f}MHz, mismatch sigma=0.1%, asym={ASYM:.4%}")
print(f"modulator: 2nd-order 65-level delta-sigma, in-band SNDR of code stream = {s_code:.1f} dB")
print(f"even-step modulator (33-level): in-band SNDR of code stream = {s_codeE:.1f} dB")
print(f"dcode stats: mean|d|={np.abs(dcode).mean():.2f}, p99={int(np.percentile(np.abs(dcode),99))}, max={np.abs(dcode).max()}")
print(f"{'scheme':<24}{'k_mean':>7}{'k_p99':>7}{'k_max':>6} | {'SNDR_mis':>9} | {'gl_res2n2':>10}{'gl_pad':>8}{'gl_ffwd':>9}{'gl_stack':>9}{'gl_asymOnly':>12}")
for name, y_mis, k, carr in schemes:
    e_mis = y_mis - carr                      # mismatch-induced error only
    dc = np.diff(carr, prepend=carr[0])
    e_rs = glitch_err(qpc_reservoir, k, dc)                  # full model, C_sum=2.2n (cosim9e)
    e_pd = glitch_err(qpc_pad, k, dc)                        # wide-range amp + 50mA padding, no loop (cosim15)
    e_ff = glitch_err(qpc_ffwd, k, dc)                       # replica ff + bus caps + padding, realistic amp (cosim17e)
    e_stk = glitch_err(qpc_stack, k, dc)                     # realistic composed stack (cosim13b)
    e_asy = glitch_err(qpc_const, k, dc)                     # asymmetry only (compression removed)
    s_mis = err_sndr(e_mis)
    p99 = int(np.percentile(k, 99))
    print(f"{name:<24}{k.mean():7.1f}{p99:7d}{k.max():6d} | {s_mis:9.1f} | "
          f"{err_sndr(e_rs):10.1f}{err_sndr(e_pd):8.1f}{err_sndr(e_ff):9.1f}{err_sndr(e_stk):9.1f}{err_sndr(e_asy):12.1f}")

print("\nNotes:")
print(" SNDR_mis     = mismatch-shaping quality (0.1% sigma), higher is better; target >=128dB relative contribution")
print(" gl_res2n2    = glitch SNDR, reservoir C_sum=2.2n, measured q_pc(k) + asym (cosim9e/10)")
print(" gl_pad       = wide-linear-range amp + 50mA current padding, NO feedback loop (cosim15)")
print(" gl_ffwd      = replica feedforward + 100n bus caps + 50mA padding, realistic 40MHz amp (cosim17e)")
print(" gl_stack     = REALISTIC composed stack: 40MHz amp w/ wide-linear-range input + reg cascode (cosim13b)")
print(" gl_asymOnly  = asymmetry term alone (flat q_pc): the floor if compression were fully fixed")
