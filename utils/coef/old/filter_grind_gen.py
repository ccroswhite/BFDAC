import numpy as np
from scipy import signal
from scipy.signal import firwin, minimum_phase, firls
import os
import struct
import time
import math

# --- Hardware System Parameters ---
FS_BASE = 48000                 # Base sample rate (44.1kHz or 48kHz)
OVERSAMPLE_RATE = 16            # 16x Interpolator
FS_OUT = FS_BASE * OVERSAMPLE_RATE
COEF_BIT_WIDTH = 18             # 18-bit signed (DSP48E2 / Q1.17)

# --- The 1M Tap Folded Architecture (QSPI .bin output) ---
# Type I Linear Phase: odd number of taps
TOTAL_TAPS = 1000001
STORED_TAPS = (TOTAL_TAPS // 2) + 1  # 500,001 (folded, symmetric)
BIN_PAD = 524288                # Pad to 512K for QSPI alignment

# --- URAM Architecture (XCVU13P, .txt output for coef_bank_loader) ---
URAM_NUM_MACS       = 4         # simulation scale (production = 1024)
URAM_TAPS_PER_PHASE = 64        # hardcoded in dac_dsp_core RTL
URAM_NUM_PHASES     = 16
URAM_COEF_DEPTH     = URAM_NUM_PHASES * URAM_TAPS_PER_PHASE   # 1024
URAM_TOTAL_TAPS     = URAM_NUM_MACS * URAM_COEF_DEPTH          # 4096 (sim)
Q1_17_SCALE         = 2**17     # 131072
Q1_17_MAX           =  131071
Q1_17_MIN           = -131072

# --- The Acoustic Matrix (Grid Search Parameters) ---
# Six named DAC personas (the curated presets):
# F1 (Reference) preset per persona — used for the URAM pass in this script.
# Full 6x6 matrix (all variations) is in gen_coe_super.py DAC_LIBRARY.
# Use: python gen_coe_super.py --generate-all --architecture uram
NAMED_PERSONAS = {
    'dcs-vivaldi':    {'cutoff': 20500, 'window': 'kaiser',  'beta':  8.0, 'phase': 'linear',
                       'desc': 'dCS Vivaldi Apex — F1 Reference, Apodising, Kaiser b=8'},
    'chord-dave':     {'cutoff': 20000, 'window': 'kaiser',  'beta': 14.0, 'phase': 'linear',
                       'desc': 'Chord DAVE — F1 Reference, Brick-Wall, Kaiser b=14'},
    'msb-reference':  {'cutoff': 20000, 'window': 'hann',    'beta': None, 'phase': 'minimum',
                       'desc': 'MSB Reference — F1 Reference, Min-Phase, Hann'},
    'berkeley-alpha3':{'cutoff': 18500, 'window': 'bh-firls', 'beta': None, 'phase': 'linear',
                       'desc': 'Berkeley Audio Alpha 3 — F1 Reference, Apodising FIRLS+BH'},
    'merason':        {'cutoff': 20000, 'window': 'kaiser',  'beta': 11.0, 'phase': 'linear',
                       'desc': 'Merason DAC1 — F1 Reference, Smooth, Kaiser b=11'},
    'mola-mola':      {'cutoff': 20000, 'window': 'kaiser',  'beta': 16.0, 'phase': 'linear',
                       'desc': 'Mola Mola Tambaqui — F1 Reference, Neutral, Kaiser b=16'},
}

# Grid search sweeps (for exhaustive exploration)
CUTOFFS = [20000, 19200, 18500]
KAISER_BETAS   = [4.0, 8.0, 14.0, 20.0]
GAUSSIAN_ALPHAS = [2.5, 3.0, 3.5, 4.0]
PHASES = ['linear', 'minimum']

# Tap Pruning Threshold (in dB relative to peak)
PRUNE_THRESHOLD_DB = -120

def gaussian_window(N, alpha=3.0):
    """Gaussian window: higher alpha = tighter energy concentration."""
    mid = (N - 1) / 2.0
    n = np.arange(N)
    return np.exp(-0.5 * (alpha * (n - mid) / mid) ** 2)


def normalize_gain(taps, upsample_factor):
    """Normalize so DC gain = upsample_factor. Safe for near-zero sum."""
    s = np.sum(taps)
    if abs(s) > 1e-9:
        return taps * (upsample_factor / s)
    return taps * upsample_factor


def prune_taps(taps, threshold_db=-120):
    """Zero out taps below threshold_db relative to peak. Returns (pruned, n_pruned, pct)."""
    peak = np.max(np.abs(taps))
    if peak < 1e-12:
        return taps, 0, 0.0
    threshold = peak * (10 ** (threshold_db / 20.0))
    pruned = np.where(np.abs(taps) >= threshold, taps, 0.0)
    n = int(np.sum(np.abs(taps) < threshold))
    return pruned, n, (n / len(taps)) * 100


def generate_prototype(n_taps, cutoff_hz, fs_out, window_type, window_param, phase):
    """
    Generate a float prototype FIR of length n_taps.
    window_type: 'kaiser', 'gaussian', 'hann', 'blackmanharris', 'bh-firls'
    phase: 'linear', 'minimum', 'hybrid'
    Returns float taps (un-normalized, un-quantized).
    """
    nyq = fs_out / 2.0
    norm_fc = cutoff_hz / nyq

    if window_type == 'kaiser':
        beta = window_param if window_param is not None else 14.0
        h = firwin(n_taps, norm_fc, window=('kaiser', beta))
    elif window_type == 'gaussian':
        alpha = window_param if window_param is not None else 3.5
        h = firwin(n_taps, norm_fc, window='rectangular')
        h = h * gaussian_window(n_taps, alpha=alpha)
    elif window_type == 'hann':
        h = firwin(n_taps, norm_fc, window='hann')
    elif window_type == 'blackmanharris':
        h = firwin(n_taps, norm_fc, window='blackmanharris')
    elif window_type == 'bh-firls':
        # Berkeley-style: FIRLS + Blackman-Harris apodising window
        # firls requires odd tap count and one gain value per frequency edge
        n_firls = n_taps if n_taps % 2 == 1 else n_taps - 1
        fc_lo   = max(cutoff_hz - 500, 100)
        fc_hi   = min(cutoff_hz + 500, fs_out / 2 - 100)
        bands   = [0, fc_lo, fc_hi, fs_out / 2]
        desired = [1, 1, 0, 0]
        h_raw   = firls(n_firls, bands, desired, weight=[1, 200], fs=fs_out)
        h       = np.zeros(n_taps); h[:len(h_raw)] = h_raw
        h       = h * signal.windows.blackmanharris(n_taps)
    else:
        raise ValueError(f"Unknown window_type: {window_type}")

    if phase == 'minimum':
        h_min = minimum_phase(h, method='homomorphic')
        h = np.zeros(n_taps)
        h[:len(h_min)] = h_min
    elif phase == 'hybrid':
        h_lin = h.copy()
        h_min_raw = minimum_phase(h_lin, method='homomorphic')
        h_min = np.zeros(n_taps)
        h_min[:len(h_min_raw)] = h_min_raw
        h = 0.6 * h_min + 0.4 * h_lin

    return h


def generate_profile(cutoff, window_param, phase, window_type='kaiser',
                     prune_threshold_db=-120, enable_pruning=True):
    """Generate 1M-tap folded .bin profile. Returns (padded_512k, prune_stats)."""
    h = generate_prototype(TOTAL_TAPS, cutoff, FS_OUT, window_type, window_param, phase)
    h = normalize_gain(h, OVERSAMPLE_RATE)

    prune_stats = None
    if enable_pruning and phase == 'linear':
        h, n_pruned, pct = prune_taps(h, prune_threshold_db)
        prune_stats = (n_pruned, pct)
        h = normalize_gain(h, OVERSAMPLE_RATE)

    max_val = (2**(COEF_BIT_WIDTH - 1)) - 1
    peak = np.max(np.abs(h))
    if peak > 1e-9:
        q = np.round(h * (max_val / peak)).astype(int)
    else:
        q = np.zeros(TOTAL_TAPS, dtype=int)

    folded  = q[0:STORED_TAPS]
    padded  = np.pad(folded, (0, BIN_PAD - len(folded)), 'constant')
    return padded, prune_stats


def export_to_bin(taps, filename):
    """Write 32-bit little-endian signed binary for QSPI (ARM SPI fetch)."""
    with open(filename, 'wb') as f:
        for coef in taps:
            f.write(struct.pack('<i', int(coef)))


# --- URAM output helpers ---

def polyphase_split_uram(h_float, num_phases, taps_per_phase, num_macs):
    """Split prototype into URAM loader entries: (mac, coef_addr, coef_q1_17)."""
    total = num_macs * num_phases * taps_per_phase
    h = np.zeros(total)
    n = min(len(h_float), total)
    h[:n] = h_float[:n]
    entries = []
    for phase in range(num_phases):
        branch = h[phase::num_phases]
        for mac in range(num_macs):
            for tap in range(taps_per_phase):
                val = branch[mac * taps_per_phase + tap]
                q = int(round(val * Q1_17_SCALE))
                q = max(Q1_17_MIN, min(Q1_17_MAX, q))
                entries.append((mac, phase * taps_per_phase + tap, q))
    return entries


def generate_uram_from_persona(name, persona, num_macs=URAM_NUM_MACS,
                                taps_per_phase=URAM_TAPS_PER_PHASE,
                                num_phases=URAM_NUM_PHASES):
    """Generate URAM entries for a named persona dict."""
    fs_out     = FS_BASE * num_phases
    total_taps = num_macs * num_phases * taps_per_phase
    h = generate_prototype(
        n_taps      = total_taps,
        cutoff_hz   = persona['cutoff'],
        fs_out      = fs_out,
        window_type = persona['window'],
        window_param= persona.get('beta'),
        phase       = persona['phase'],
    )
    h = normalize_gain(h, float(num_phases))
    dc = np.sum(h)
    print(f"    DC gain = {dc:.4f}  (ideal = {num_phases})")
    return polyphase_split_uram(h, num_phases, taps_per_phase, num_macs)


def write_uram_file(filename, entries, header_lines):
    """Write URAM loader .txt file."""
    with open(filename, 'w', encoding='utf-8') as f:
        for line in header_lines:
            f.write(f"# {line}\n")
        f.write("#\n# mac_idx  coef_addr  coef_q1_17\n#\n")
        for mac, addr, val in sorted(entries, key=lambda x: (x[0], x[1])):
            f.write(f"{mac} {addr} {val}\n")


def write_ddr4_bin(filename, entries, num_macs, num_phases, taps_per_phase):
    """Write DDR4 coefficient image for coef_bank_loader (32-bit LE per coef)."""
    coef_depth = num_phases * taps_per_phase
    sorted_entries = sorted(entries, key=lambda x: (x[0], x[1]))
    with open(filename, 'wb') as f:
        for mac, addr, val in sorted_entries:
            f.write(struct.pack('<i', int(val)))
    print(f"    -> DDR4 binary: {filename}  ({len(sorted_entries)} coefs, "
          f"{num_macs}x{coef_depth}, {len(sorted_entries)*4} bytes)")


if __name__ == "__main__":
    out_bin  = "dac_profiles"
    out_uram = "dac_profiles_uram"
    os.makedirs(out_bin,  exist_ok=True)
    os.makedirs(out_uram, exist_ok=True)

    total_start = time.time()

    # ==================================================================
    #  PASS 1: Named DAC Personas — URAM format (sim-ready)
    # ==================================================================
    print("=== Named DAC Persona URAM Files ===")
    print(f"  MACs={URAM_NUM_MACS}  taps_per_phase={URAM_TAPS_PER_PHASE}  phases={URAM_NUM_PHASES}\n")
    for name, persona in NAMED_PERSONAS.items():
        start = time.time()
        print(f"  [{name}] {persona['desc']}")
        entries = generate_uram_from_persona(name, persona)
        fname   = os.path.join(out_uram, f"{name}_m{URAM_NUM_MACS}_t{URAM_TAPS_PER_PHASE}.txt")
        write_uram_file(fname, entries, [
            f"Filter: {persona['desc']}",
            f"Input: {FS_BASE} Hz  Output: {FS_BASE*URAM_NUM_PHASES} Hz",
            f"URAM: num_macs={URAM_NUM_MACS}  taps_per_phase={URAM_TAPS_PER_PHASE}  phases={URAM_NUM_PHASES}",
            f"Q1.17 signed 18-bit  scale={Q1_17_SCALE}",
        ])
        bin_fname = fname.replace('.txt', '.bin')
        write_ddr4_bin(bin_fname, entries, URAM_NUM_MACS, URAM_NUM_PHASES, URAM_TAPS_PER_PHASE)
        print(f"    -> {fname}  ({len(entries)} entries, {time.time()-start:.2f}s)")

    # ==================================================================
    #  PASS 2: Grid Search — 1M-tap folded .bin (QSPI flash)
    # ==================================================================
    total_profiles = (len(CUTOFFS) * len(KAISER_BETAS) * len(PHASES) +
                      len(CUTOFFS) * len(GAUSSIAN_ALPHAS) * len(PHASES))

    print(f"\n=== 1M-Tap Grid Search (QSPI .bin) ===")
    print(f"  Window Types: Kaiser, Gaussian")
    print(f"  Tap Pruning: {PRUNE_THRESHOLD_DB} dB threshold")
    print(f"  Targeting: {total_profiles} profiles\n")

    print("--- Kaiser Window ---")
    for phase in PHASES:
        for cutoff in CUTOFFS:
            for beta in KAISER_BETAS:
                start = time.time()
                prune_tag = "pruned" if phase == 'linear' else "noprune"
                name = f"profile_kaiser_{phase}_fc{cutoff}_beta{beta}_{prune_tag}.bin"
                print(f"  {name}...")
                taps, ps = generate_profile(cutoff, beta, phase, 'kaiser',
                                            PRUNE_THRESHOLD_DB, phase == 'linear')
                if ps:
                    print(f"    -> Pruned {ps[0]} taps ({ps[1]:.1f}%)")
                export_to_bin(taps, os.path.join(out_bin, name))
                print(f"    -> {len(taps)} taps saved. {time.time()-start:.2f}s")

    print("\n--- Gaussian Window ---")
    for phase in PHASES:
        for cutoff in CUTOFFS:
            for alpha in GAUSSIAN_ALPHAS:
                start = time.time()
                prune_tag = "pruned" if phase == 'linear' else "noprune"
                name = f"profile_gaussian_{phase}_fc{cutoff}_alpha{alpha}_{prune_tag}.bin"
                print(f"  {name}...")
                taps, ps = generate_profile(cutoff, alpha, phase, 'gaussian',
                                            PRUNE_THRESHOLD_DB, phase == 'linear')
                if ps:
                    print(f"    -> Pruned {ps[0]} taps ({ps[1]:.1f}%)")
                export_to_bin(taps, os.path.join(out_bin, name))
                print(f"    -> {len(taps)} taps saved. {time.time()-start:.2f}s")

    print(f"\n--- Complete in {time.time()-total_start:.2f}s ---")
    print(f"  URAM .txt files -> {out_uram}/")
    print(f"  QSPI .bin files -> {out_bin}/")
    print(f"  Flash .bin files to 32MB Winbond QSPI.")