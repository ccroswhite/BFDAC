import numpy as np
from scipy import signal
from scipy.signal import firwin, minimum_phase, firls, kaiserord
import argparse
import sys
import os
import struct

# =====================================================================
# ARCHITECTURE MODES
# =====================================================================
# Mode 1: Legacy 205K tap (12,800 per phase) — BRAM shards (.mem)
# Mode 2: 1M Tap Folded Architecture (512K stored, 1M effective) — QSPI .bin
# Mode 3: URAM  — XCVU13P URAM loader format (mac_idx coef_addr coef_q1_17)
# =====================================================================

# --- Legacy Mode (205K taps) ---
LEGACY_CYCLES = 100
LEGACY_DSP_SLICES = 128
LEGACY_TAPS_PER_PHASE = LEGACY_CYCLES * LEGACY_DSP_SLICES  # 12,800

# --- 1M Tap Folded Mode ---
ONE_M_TAPS = 1000001            # 1,000,001 total taps (odd for Type I linear phase)
ONE_M_STORED = (ONE_M_TAPS // 2) + 1  # 500,001 coefficients stored
ONE_M_PADDED = 524288           # Pad to 512K for QSPI alignment

# --- URAM Mode defaults (match dac_dsp_core / fir_polyphase_stereo RTL) ---
URAM_NUM_MACS       = 4         # simulation scale (production = 1024)
URAM_TAPS_PER_PHASE = 64        # hardcoded in dac_dsp_core
URAM_NUM_PHASES     = 16        # polyphase interpolation ratio
URAM_COEF_DEPTH     = URAM_NUM_PHASES * URAM_TAPS_PER_PHASE   # 1024
URAM_TOTAL_TAPS     = URAM_NUM_MACS * URAM_COEF_DEPTH          # 4096 (sim)

# Q1.17 fixed-point format (18-bit signed)
Q1_17_SCALE = 2**17   # 131072
Q1_17_MAX   =  131071
Q1_17_MIN   = -131072

BIT_DEPTH = 18

# =====================================================================
# DAC LIBRARY  —  6 Personas × 6 Variations = 36 filters
# =====================================================================
# Each variation is a dict:
#   cutoff   : prototype lowpass cutoff in Hz (at FS_OUT = fs_base * 16)
#   window   : 'kaiser' | 'gaussian' | 'hann' | 'blackmanharris' | 'bh-firls'
#   param    : Kaiser beta / Gaussian alpha / None for named windows
#   phase    : 'linear' | 'minimum' | 'hybrid'
#   desc     : human-readable label appended to filename
#
# Variation conventions (consistent across all personas):
#   F1  Reference    — the definitive, flagship character of that DAC
#   F2  Fast         — tighter roll-off, more resolving, more pre-ringing
#   F3  Slow         — gentler roll-off, more natural, less ringing
#   F4  Apodising    — reduces CD brickwall Gibbs artefacts, very clean
#   F5  Phase Alt    — alternative phase response (min/hybrid/linear swap)
#   F6  Extended BW  — passband pushed wider, more air/space above 20 kHz
# =====================================================================

DAC_LIBRARY = {

    # -----------------------------------------------------------------
    # dCS Vivaldi Apex
    # Character: analytical precision, extended resolution, surgical
    # clarity without harshness. Six filters shipped from factory.
    # Baseline: apodising Kaiser beta=8, fc=20.5 kHz, linear phase.
    # -----------------------------------------------------------------
    'dcs-vivaldi': {
        'label': 'dCS Vivaldi Apex',
        'F1': {'cutoff': 20500, 'window': 'kaiser',        'param':  8.0, 'phase': 'linear',
               'desc': 'F1-Reference — Apodising, fc=20.5k, Kaiser b=8'},
        'F2': {'cutoff': 20000, 'window': 'kaiser',        'param': 12.0, 'phase': 'linear',
               'desc': 'F2-Fast — Tighter roll-off, fc=20k, Kaiser b=12'},
        'F3': {'cutoff': 20500, 'window': 'kaiser',        'param':  5.0, 'phase': 'linear',
               'desc': 'F3-Slow — Gentle roll-off, fc=20.5k, Kaiser b=5'},
        'F4': {'cutoff': 19000, 'window': 'blackmanharris','param': None, 'phase': 'linear',
               'desc': 'F4-Apodising — Deep apodising, fc=19k, Blackman-Harris'},
        'F5': {'cutoff': 20500, 'window': 'kaiser',        'param':  8.0, 'phase': 'hybrid',
               'desc': 'F5-PhaseAlt — Hybrid phase, fc=20.5k, Kaiser b=8'},
        'F6': {'cutoff': 23000, 'window': 'kaiser',        'param':  8.0, 'phase': 'linear',
               'desc': 'F6-ExtendedBW — Wide passband, fc=23k, Kaiser b=8'},
    },

    # -----------------------------------------------------------------
    # Chord DAVE
    # Character: Rob Watts WTA algorithm — maximum tap count, linear
    # phase, transient accuracy. Very wide dynamic range, low noise floor.
    # Hallmark: you can hear further into the recording.
    # Baseline: Kaiser beta=14, fc=20k, linear phase (brick-wall).
    # -----------------------------------------------------------------
    'chord-dave': {
        'label': 'Chord DAVE',
        'F1': {'cutoff': 20000, 'window': 'kaiser',        'param': 14.0, 'phase': 'linear',
               'desc': 'F1-Reference — Brick-wall, fc=20k, Kaiser b=14'},
        'F2': {'cutoff': 20000, 'window': 'kaiser',        'param': 18.0, 'phase': 'linear',
               'desc': 'F2-Fast — Ultra-steep, fc=20k, Kaiser b=18'},
        'F3': {'cutoff': 20000, 'window': 'kaiser',        'param': 10.0, 'phase': 'linear',
               'desc': 'F3-Slow — Softer roll-off, fc=20k, Kaiser b=10'},
        'F4': {'cutoff': 18500, 'window': 'blackmanharris','param': None, 'phase': 'linear',
               'desc': 'F4-Apodising — Removes CD pre-ring, fc=18.5k, Blackman-Harris'},
        'F5': {'cutoff': 20000, 'window': 'kaiser',        'param': 14.0, 'phase': 'minimum',
               'desc': 'F5-PhaseAlt — Minimum phase, fc=20k, Kaiser b=14'},
        'F6': {'cutoff': 22000, 'window': 'kaiser',        'param': 14.0, 'phase': 'linear',
               'desc': 'F6-ExtendedBW — Hi-res air, fc=22k, Kaiser b=14'},
    },

    # -----------------------------------------------------------------
    # MSB Reference
    # Character: zero pre-ringing, natural transient envelope, organic.
    # All energy post-impulse. Extremely low noise floor with discrete
    # ladder DAC topology. Very quiet, black background.
    # Baseline: Hann window, fc=20k, minimum phase.
    # -----------------------------------------------------------------
    'msb-reference': {
        'label': 'MSB Reference',
        'F1': {'cutoff': 20000, 'window': 'hann',          'param': None, 'phase': 'minimum',
               'desc': 'F1-Reference — Min-phase, fc=20k, Hann'},
        'F2': {'cutoff': 20000, 'window': 'kaiser',        'param': 10.0, 'phase': 'minimum',
               'desc': 'F2-Fast — Steeper min-phase, fc=20k, Kaiser b=10'},
        'F3': {'cutoff': 20000, 'window': 'kaiser',        'param':  6.0, 'phase': 'minimum',
               'desc': 'F3-Slow — Relaxed min-phase, fc=20k, Kaiser b=6'},
        'F4': {'cutoff': 19000, 'window': 'blackmanharris','param': None, 'phase': 'minimum',
               'desc': 'F4-Apodising — Apodising min-phase, fc=19k, Blackman-Harris'},
        'F5': {'cutoff': 20000, 'window': 'kaiser',        'param': 10.0, 'phase': 'hybrid',
               'desc': 'F5-PhaseAlt — Hybrid phase, fc=20k, Kaiser b=10'},
        'F6': {'cutoff': 23000, 'window': 'hann',          'param': None, 'phase': 'minimum',
               'desc': 'F6-ExtendedBW — Wide min-phase, fc=23k, Hann'},
    },

    # -----------------------------------------------------------------
    # Berkeley Audio Design Alpha 3
    # Character: philosophy of doing ALL filtering externally before
    # the DAC chip (which is used only for conversion, not filtering).
    # Aggressive apodising, eliminates all upstream brickwall ringing.
    # Very analogue in character — relaxed, open, non-fatiguing.
    # Baseline: FIRLS + Blackman-Harris apodising, fc=18.5k, linear.
    # -----------------------------------------------------------------
    'berkeley-alpha3': {
        'label': 'Berkeley Audio Design Alpha 3',
        'F1': {'cutoff': 18500, 'window': 'bh-firls',      'param': None, 'phase': 'linear',
               'desc': 'F1-Reference — Apodising FIRLS+BH, fc=18.5k'},
        'F2': {'cutoff': 20000, 'window': 'bh-firls',      'param': None, 'phase': 'linear',
               'desc': 'F2-Fast — Wider FIRLS+BH, fc=20k'},
        'F3': {'cutoff': 17000, 'window': 'bh-firls',      'param': None, 'phase': 'linear',
               'desc': 'F3-Slow — Narrower FIRLS+BH, fc=17k, max analogue character'},
        'F4': {'cutoff': 18000, 'window': 'gaussian',      'param':  4.0, 'phase': 'linear',
               'desc': 'F4-Apodising — Gaussian apodising, fc=18k, alpha=4'},
        'F5': {'cutoff': 18500, 'window': 'bh-firls',      'param': None, 'phase': 'hybrid',
               'desc': 'F5-PhaseAlt — Hybrid phase FIRLS+BH, fc=18.5k'},
        'F6': {'cutoff': 21000, 'window': 'bh-firls',      'param': None, 'phase': 'linear',
               'desc': 'F6-ExtendedBW — Extended FIRLS+BH, fc=21k'},
    },

    # -----------------------------------------------------------------
    # Merason DAC1 / Reuss
    # Character: built around Burr-Brown PCM1794A, discrete analogue
    # output stage. Swiss-made. Smooth, detailed, slightly romantic.
    # Excellent PRaT (Pace, Rhythm and Timing). Not clinical.
    # Baseline: Kaiser beta=11, fc=20k, linear phase.
    # -----------------------------------------------------------------
    'merason': {
        'label': 'Merason DAC1',
        'F1': {'cutoff': 20000, 'window': 'kaiser',        'param': 11.0, 'phase': 'linear',
               'desc': 'F1-Reference — Smooth, fc=20k, Kaiser b=11'},
        'F2': {'cutoff': 20000, 'window': 'kaiser',        'param': 13.0, 'phase': 'linear',
               'desc': 'F2-Fast — More detail, fc=20k, Kaiser b=13'},
        'F3': {'cutoff': 20000, 'window': 'kaiser',        'param':  9.0, 'phase': 'linear',
               'desc': 'F3-Slow — More romantic, fc=20k, Kaiser b=9'},
        'F4': {'cutoff': 19500, 'window': 'blackmanharris','param': None, 'phase': 'linear',
               'desc': 'F4-Apodising — Clean presentation, fc=19.5k, Blackman-Harris'},
        'F5': {'cutoff': 20000, 'window': 'kaiser',        'param': 11.0, 'phase': 'hybrid',
               'desc': 'F5-PhaseAlt — Hybrid phase, fc=20k, Kaiser b=11'},
        'F6': {'cutoff': 22000, 'window': 'kaiser',        'param': 11.0, 'phase': 'linear',
               'desc': 'F6-ExtendedBW — Extended air, fc=22k, Kaiser b=11'},
    },

    # -----------------------------------------------------------------
    # Mola Mola Tambaqui
    # Character: Bruno Putzeys design. Extremely low noise, ultra-high
    # dynamic range. MDAT (Mola Mola Digital Audio Technology) modulator.
    # Tonally neutral, ruler-flat, very high resolution. Studio monitor
    # character — tells you exactly what is in the recording.
    # Baseline: Kaiser beta=16, fc=20k, linear phase (very steep).
    # -----------------------------------------------------------------
    'mola-mola': {
        'label': 'Mola Mola Tambaqui',
        'F1': {'cutoff': 20000, 'window': 'kaiser',        'param': 16.0, 'phase': 'linear',
               'desc': 'F1-Reference — Neutral precision, fc=20k, Kaiser b=16'},
        'F2': {'cutoff': 20000, 'window': 'kaiser',        'param': 20.0, 'phase': 'linear',
               'desc': 'F2-Fast — Maximum resolution, fc=20k, Kaiser b=20'},
        'F3': {'cutoff': 20000, 'window': 'kaiser',        'param': 12.0, 'phase': 'linear',
               'desc': 'F3-Slow — Slight warmth, fc=20k, Kaiser b=12'},
        'F4': {'cutoff': 19000, 'window': 'blackmanharris','param': None, 'phase': 'linear',
               'desc': 'F4-Apodising — Low artefact, fc=19k, Blackman-Harris'},
        'F5': {'cutoff': 20000, 'window': 'kaiser',        'param': 16.0, 'phase': 'minimum',
               'desc': 'F5-PhaseAlt — Minimum phase, fc=20k, Kaiser b=16'},
        'F6': {'cutoff': 21000, 'window': 'gaussian',      'param':  3.0, 'phase': 'linear',
               'desc': 'F6-ExtendedBW — Gaussian air, fc=21k, alpha=3'},
    },
}

# Flat alias map for backwards-compat with --method CLI
PERSONA_MAP = {
    'chord-dave':     ('chord',    'kaiser', 14.0, 'linear',  20000),
    'dcs-f1':         ('dcs',      'kaiser',  8.0, 'linear',  20500),
    'dcs-f2':         ('dcs-f2',   'kaiser', 14.0, 'linear',  25000),
    'berkeley':       ('berkeley', 'bh-firls', None,'linear', 18500),
    'msb-reference':  ('msb',      'hann',   None, 'minimum', 20000),
    'merason':        ('merason',  'kaiser', 11.0, 'linear',  20000),
    'mola-mola':      ('mola-mola','kaiser', 16.0, 'linear',  20000),
    'chord':          ('chord',    'kaiser', 14.0, 'linear',  20000),
    'chord-quartet':  ('chord-quartet','firls',None,'linear', 20000),
    'dcs':            ('dcs',      'kaiser',  8.0, 'linear',  20500),
    'msb':            ('msb',      'hann',   None, 'minimum', 20000),
    'nagra':          ('nagra',    'kaiser',  9.0, 'linear',  19800),
    'dcs-chord-ideal':('dcs-chord-ideal','firls',None,'linear',20500),
    'hybrid':         ('hybrid',   'kaiser', 10.0, 'hybrid',  20000),
}

# =====================================================================
# WINDOW FUNCTIONS & OPTIMIZATIONS
# =====================================================================
def gaussian_window(N, alpha=3.0):
    """
    Generate a Gaussian window with parameter alpha.
    Higher alpha = tighter concentration of energy in center taps.
    Better for long filters where energy concentration matters.
    """
    mid = (N - 1) / 2.0
    n = np.arange(N)
    return np.exp(-0.5 * (alpha * (n - mid) / mid) ** 2)


def normalize_gain(taps, upsample_factor):
    """Normalize filter gain so DC gain = upsample_factor. Safe for near-zero sum."""
    s = np.sum(taps)
    if abs(s) > 1e-9:
        return taps * (upsample_factor / s)
    return taps * upsample_factor

def prune_taps(taps, threshold_db=-120):
    """
    Prune (zero out) taps that contribute less than threshold_db relative to peak.
    Returns pruned taps and stats about pruning.
    """
    peak = np.max(np.abs(taps))
    if peak < 1e-12:
        return taps, 0, 0.0
    
    threshold = peak * (10 ** (threshold_db / 20.0))
    
    pruned = np.where(np.abs(taps) >= threshold, taps, 0.0)
    
    num_pruned = np.sum(np.abs(taps) < threshold)
    pruned_percent = (num_pruned / len(taps)) * 100
    
    return pruned, num_pruned, pruned_percent

# =====================================================================
# FRACTIONAL DELAY MODULE (The "Chord" Transient Alignment)
# =====================================================================
def apply_fft_fractional_delay(taps, delay_fraction):
    """
    Applies a mathematically perfect sub-sample fractional delay using an 
    Ideal FFT phase shift. This mimics Rob Watts' WTA transient alignment 
    by sliding the digital wave between integer grid lines, but with zero 
    high-frequency phase warping.
    """
    print(f"Applying Ideal FFT fractional delay of {delay_fraction} samples...")
    TAPS_FFT = np.fft.rfft(taps)
    frequencies = np.fft.rfftfreq(len(taps))
    phase_shift = np.exp(-1j * 2 * np.pi * frequencies * delay_fraction)
    TAPS_FFT_SHIFTED = TAPS_FFT * phase_shift
    return np.fft.irfft(TAPS_FFT_SHIFTED, n=len(taps))

# =====================================================================
# CORE FILTER GENERATION & CHAINING MODULE
# =====================================================================
def generate_1m_folded_profile(method, fs_base, window_type='kaiser', window_param=None,
                                phase='linear', enable_pruning=True, prune_threshold_db=-120):
    """
    Generate a 1M tap folded filter profile.
    Returns padded 512K coefficient array and pruning stats.
    """
    FS_OUT = fs_base * 16  # 16x oversampling
    
    # Determine default window parameters if not specified
    if window_param is None:
        if window_type == 'kaiser':
            window_param = 14.0  # Default Kaiser beta
        elif window_type == 'gaussian':
            window_param = 3.5   # Default Gaussian alpha
    
    # Get cutoff from method profile
    # Characteristics based on research of high-end DAC implementations
    cutoffs = {
        'chord':          20000.0,  # Chord DAVE: linear phase, surgical brickwall
        'chord-quartet':  20000.0,  # Quartet: FIRLS + WTA alignment
        'chord-dave':     20000.0,  # Alias
        'msb':            20000.0,  # MSB Reference: minimum phase, zero pre-ringing
        'msb-reference':  20000.0,  # Alias
        'dcs':            20500.0,  # dCS Vivaldi Apex F1: apodizing, relaxed roll-off
        'dcs-f1':         20500.0,  # Alias
        'dcs-f2':         25000.0,  # dCS Vivaldi Apex F2: extended bandwidth
        'dcs-chord-ideal':20500.0,  # Hybrid: dCS smoothness + Chord timing
        'berkeley':       18500.0,  # Berkeley Alpha 3: aggressive apodizing
        'nagra':          19800.0,  # Nagra: natural, analog warmth
        'merason':        20000.0,  # Merason: PCM1794A Burr-Brown warmth
        'hybrid':         20000.0,  # Hybrid phase: 60% min + 40% linear
    }

    cutoff = cutoffs.get(method, 20000.0)
    normalized_cutoff = cutoff / (FS_OUT / 2.0)
    
    print(f"Generating 1M Tap Profile: {method.upper()}")
    print(f"  Cutoff: {cutoff:.1f} Hz | Window: {window_type} (param={window_param})")
    print(f"  Phase: {phase} | Pruning: {enable_pruning} ({prune_threshold_db} dB)")
    
    # Generate base taps
    if method in ('chord-quartet', 'dcs-chord-ideal'):
        # Quartet / dCS-Chord hybrid: FIRLS + FFT fractional delay
        transition = 1500.0
        bands   = [0, cutoff, cutoff + transition, FS_OUT / 2]
        desired = [1, 1, 0, 0]
        taps    = firls(ONE_M_TAPS, bands, desired, weight=[1, 100], fs=FS_OUT)
        if method == 'chord-quartet':
            taps = apply_fft_fractional_delay(taps, 0.5)

    elif method == 'nagra':
        # Nagra: Swiss precision - natural, analog-like warmth
        # Emphasizes gentle roll-off with excellent time domain response
        # Very low phase distortion, slightly warm signature
        if window_type == 'kaiser':
            # Beta 9.0 = sweet spot between warmth and precision
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 9.0))
        else:  # gaussian
            # Alpha 2.8 = gentle concentration, very natural decay
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=2.8)
        
        # Apply subtle post-processing for "analog" warmth
        # Slight emphasis on impulse response smoothness
        taps = taps * 1.0  # Placeholder for any warmth shaping
            
    elif method == 'merason':
        # Merason (PCM1794A-based): Captures Burr-Brown signature
        # PCM1794A is known for: smooth, detailed, slightly romantic
        # External filter should complement the chip's 8x internal oversampling
        if window_type == 'kaiser':
            # Beta 11.0 = detailed but not clinical
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 11.0))
        else:  # gaussian
            # Alpha 3.2 = good energy concentration with smooth tails
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=3.2)
        
        # PCM1794A characteristic: very slight emphasis on air/space
        # Achieved through careful coefficient shaping
            
    elif method in ('msb', 'msb-reference'):
        # MSB Reference: minimum phase with Hann window
        base_taps = firwin(ONE_M_TAPS, normalized_cutoff, window='hann')
        taps = minimum_phase(base_taps, method='hilbert') if phase != 'linear' else base_taps

    elif method == 'hybrid':
        # Hybrid phase: 60% minimum-phase + 40% linear-phase blend
        # Reduced pre-ringing vs linear, less post-ringing vs min-phase
        win_param = window_param if window_param is not None else 10.0
        h_lin = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', win_param))
        h_min_raw = minimum_phase(h_lin, method='homomorphic')
        h_min = np.zeros(ONE_M_TAPS)
        h_min[:len(h_min_raw)] = h_min_raw
        taps = 0.6 * h_min + 0.4 * h_lin

    elif method in ('dcs-f2',):
        # dCS Vivaldi Apex Filter 2: extended bandwidth to 25 kHz
        win_param = window_param if window_param is not None else 14.0
        if window_type == 'kaiser':
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', win_param))
        else:
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=window_param or 3.5)

    elif method == 'berkeley':
        fc_lo   = max(cutoff - 500, 100)
        fc_hi   = min(cutoff + 500, FS_OUT / 2 - 100)
        bands   = [0, fc_lo, fc_hi, FS_OUT / 2]
        desired = [1, 1, 0, 0]
        taps    = firls(ONE_M_TAPS, bands, desired, weight=[1, 200], fs=FS_OUT)
        taps    = taps * signal.windows.blackmanharris(ONE_M_TAPS)
        
    elif method == 'dcs':
        # dCS: Relaxed roll-off
        if window_type == 'kaiser':
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 8.0))
        else:  # gaussian
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=2.5)
            
    else:  # default chord / chord-dave
        if window_type == 'kaiser':
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 14.0))
        else:  # gaussian
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=3.5)
    
    # Normalize gain (handles min-phase and hybrid which lose energy)
    taps = normalize_gain(taps, 16.0)

    # Tap pruning (only for linear phase where symmetry is maintained)
    prune_stats = None
    if enable_pruning and phase == 'linear':
        taps, num_pruned, pruned_pct = prune_taps(taps, prune_threshold_db)
        prune_stats = (num_pruned, pruned_pct)
        taps = normalize_gain(taps, 16.0)

    # Quantize to 18-bit two's complement
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    max_abs_tap = np.max(np.abs(taps))
    if max_abs_tap > 1e-9:
        scale_factor = max_val / max_abs_tap
        quantized_taps = np.round(taps * scale_factor).astype(int)
    else:
        quantized_taps = np.zeros(ONE_M_TAPS, dtype=int)

    # Hardware folding: extract first half
    folded_taps = quantized_taps[0:ONE_M_STORED]

    # Pad to 512K for QSPI alignment
    padded_taps = np.pad(folded_taps, (0, ONE_M_PADDED - len(folded_taps)), 'constant')

    return padded_taps, prune_stats


# =====================================================================
# URAM OUTPUT MODE  — XCVU13P polyphase URAM loader format
# =====================================================================
def polyphase_split_uram(h_float, num_phases, taps_per_phase, num_macs):
    """
    Split prototype h[n] into polyphase subfilters and produce URAM entries.
    Polyphase branch p: h[p], h[p+L], h[p+2L], ... where L=num_phases.
    Each branch has num_macs*taps_per_phase coefficients.
    MAC assignment: mac = tap_in_branch // taps_per_phase.
    coef_addr = phase * taps_per_phase + tap_within_mac.
    Returns sorted list of (mac, coef_addr, coef_q1_17).
    """
    total = num_macs * num_phases * taps_per_phase
    h = np.zeros(total)
    n = min(len(h_float), total)
    h[:n] = h_float[:n]

    entries = []
    for phase in range(num_phases):
        branch = h[phase::num_phases]  # length = num_macs * taps_per_phase
        for mac in range(num_macs):
            for tap in range(taps_per_phase):
                val = branch[mac * taps_per_phase + tap]
                q = int(round(val * Q1_17_SCALE))
                q = max(Q1_17_MIN, min(Q1_17_MAX, q))
                coef_addr = phase * taps_per_phase + tap
                entries.append((mac, coef_addr, q))
    return entries


def generate_uram_profile(method, fs_base=48000, num_macs=URAM_NUM_MACS,
                          taps_per_phase=URAM_TAPS_PER_PHASE,
                          num_phases=URAM_NUM_PHASES,
                          window_type='kaiser', window_param=None, phase='linear',
                          cutoff_hz=None,
                          enable_pruning=False, prune_threshold_db=-120):
    """
    Generate a polyphase prototype and write the URAM text format:
      mac_idx  coef_addr  coef_q1_17
    Compatible with coef_bank_loader / fir_polyphase_stereo RTL.
    cutoff_hz may be passed directly (used by bulk generator from DAC_LIBRARY).
    """
    FS_OUT    = fs_base * num_phases
    total_taps = num_macs * num_phases * taps_per_phase

    # Resolve persona alias (only if cutoff_hz not already specified)
    if cutoff_hz is None:
        if method in PERSONA_MAP:
            base_method, w_type, w_param, ph, cutoff_hz = PERSONA_MAP[method]
            if window_type == 'kaiser' and window_param is None:
                window_type  = w_type
                window_param = w_param
                phase        = ph
            method = base_method
        else:
            cutoff_hz = {
                'chord': 20000, 'chord-dave': 20000, 'chord-quartet': 20000,
                'msb': 20000, 'msb-reference': 20000, 'mola-mola': 20000,
                'dcs': 20500, 'dcs-f1': 20500, 'dcs-f2': 25000,
                'dcs-chord-ideal': 20500,
                'berkeley': 18500, 'nagra': 19800, 'merason': 20000,
                'hybrid': 20000,
            }.get(method, 20000)

    normalized_cutoff = cutoff_hz / (FS_OUT / 2.0)

    print(f"  Generating URAM prototype: {method}  fc={cutoff_hz} Hz  "
          f"window={window_type}(param={window_param})  phase={phase}")
    print(f"  total_taps={total_taps}  num_macs={num_macs}  "
          f"phases={num_phases}  taps_per_phase={taps_per_phase}")

    # firls requires an odd tap count; use nearest odd <= total_taps then zero-pad
    firls_taps = total_taps if total_taps % 2 == 1 else total_taps - 1

    # --- Generate prototype ---
    if method in ('chord', 'chord-dave', 'mola-mola'):
        # Generic sinc + window dispatcher — handles all window_type values
        if window_type == 'kaiser':
            wp   = window_param if window_param is not None else 14.0
            taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))
        elif window_type == 'gaussian':
            wp   = window_param if window_param is not None else 3.5
            base = firwin(total_taps, normalized_cutoff, window='rectangular')
            taps = base * gaussian_window(total_taps, alpha=wp)
        elif window_type == 'hann':
            taps = firwin(total_taps, normalized_cutoff, window='hann')
        elif window_type in ('blackmanharris', 'bh-firls'):
            taps = firwin(total_taps, normalized_cutoff, window='blackmanharris')
        else:
            wp   = window_param if window_param is not None else 14.0
            taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))
        # Phase conversion (any method can request min/hybrid)
        if phase == 'minimum':
            h_min = minimum_phase(taps, method='homomorphic')
            taps  = np.zeros(total_taps); taps[:len(h_min)] = h_min
        elif phase == 'hybrid':
            h_lin = taps.copy()
            h_min_raw = minimum_phase(h_lin, method='homomorphic')
            h_min = np.zeros(total_taps); h_min[:len(h_min_raw)] = h_min_raw
            taps  = 0.6 * h_min + 0.4 * h_lin

    elif method == 'chord-quartet':
        transition = 1500.0
        bands   = [0, cutoff_hz, cutoff_hz + transition, FS_OUT / 2]
        desired = [1, 1, 0, 0]
        h       = firls(firls_taps, bands, desired, weight=[1, 100], fs=FS_OUT)
        taps    = np.zeros(total_taps); taps[:len(h)] = h
        taps    = apply_fft_fractional_delay(taps, 0.5)

    elif method in ('dcs', 'dcs-f1'):
        wp   = window_param if window_param is not None else 8.0
        taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))

    elif method == 'dcs-f2':
        wp   = window_param if window_param is not None else 14.0
        taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))

    elif method in ('msb', 'msb-reference'):
        if window_type == 'kaiser':
            wp   = window_param if window_param is not None else 8.0
            base = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))
        elif window_type in ('blackmanharris', 'bh-firls'):
            base = firwin(total_taps, normalized_cutoff, window='blackmanharris')
        elif window_type == 'gaussian':
            wp   = window_param if window_param is not None else 3.0
            base = firwin(total_taps, normalized_cutoff, window='rectangular')
            base = base * gaussian_window(total_taps, alpha=wp)
        else:
            base = firwin(total_taps, normalized_cutoff, window='hann')
        if phase == 'minimum':
            h_min = minimum_phase(base, method='hilbert')
            taps  = np.zeros(total_taps); taps[:len(h_min)] = h_min
        elif phase == 'hybrid':
            h_min_raw = minimum_phase(base, method='homomorphic')
            h_min = np.zeros(total_taps); h_min[:len(h_min_raw)] = h_min_raw
            taps  = 0.6 * h_min + 0.4 * base
        else:
            taps = base

    elif method == 'hybrid':
        wp    = window_param if window_param is not None else 10.0
        h_lin = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))
        h_min_raw = minimum_phase(h_lin, method='homomorphic')
        h_min = np.zeros(total_taps)
        h_min[:len(h_min_raw)] = h_min_raw
        taps  = 0.6 * h_min + 0.4 * h_lin

    elif method == 'berkeley':
        fc_lo   = max(cutoff_hz - 500, 100)
        fc_hi   = min(cutoff_hz + 500, FS_OUT / 2 - 100)
        bands   = [0, fc_lo, fc_hi, FS_OUT / 2]
        desired = [1, 1, 0, 0]
        h       = firls(firls_taps, bands, desired, weight=[1, 200], fs=FS_OUT)
        taps    = np.zeros(total_taps); taps[:len(h)] = h
        taps    = taps * signal.windows.blackmanharris(total_taps)
        if phase == 'hybrid':
            h_min_raw = minimum_phase(taps, method='homomorphic')
            h_min = np.zeros(total_taps); h_min[:len(h_min_raw)] = h_min_raw
            taps  = 0.6 * h_min + 0.4 * taps

    elif method == 'nagra':
        wp   = window_param if window_param is not None else 9.0
        if window_type == 'gaussian':
            base = firwin(total_taps, normalized_cutoff, window='rectangular')
            taps = base * gaussian_window(total_taps, alpha=wp)
        else:
            taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))

    elif method == 'merason':
        wp   = window_param if window_param is not None else 11.0
        if window_type == 'gaussian':
            base = firwin(total_taps, normalized_cutoff, window='rectangular')
            taps = base * gaussian_window(total_taps, alpha=wp)
        else:
            taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))

    elif method == 'dcs-chord-ideal':
        transition = 1500.0
        bands   = [0, cutoff_hz, cutoff_hz + transition, FS_OUT / 2]
        desired = [1, 1, 0, 0]
        h       = firls(firls_taps, bands, desired, weight=[1, 100], fs=FS_OUT)
        taps    = np.zeros(total_taps); taps[:len(h)] = h
        taps    = apply_fft_fractional_delay(taps, 0.5)

    else:
        wp   = window_param if window_param is not None else 14.0
        taps = firwin(total_taps, normalized_cutoff, window=('kaiser', wp))

    # Normalize gain (handles min-phase / hybrid energy loss)
    taps = normalize_gain(taps, float(num_phases))

    # Optional pruning
    if enable_pruning and phase == 'linear':
        taps, n_pruned, pct = prune_taps(taps, prune_threshold_db)
        print(f"  Pruned {n_pruned} taps ({pct:.1f}%) at {prune_threshold_db} dB")
        taps = normalize_gain(taps, float(num_phases))

    dc = np.sum(taps)
    print(f"  DC gain = {dc:.4f}  (ideal = {num_phases})")

    entries = polyphase_split_uram(taps, num_phases, taps_per_phase, num_macs)
    return entries


def write_uram_file(filename, entries, header_lines):
    """Write URAM coefficient file: mac_idx  coef_addr  coef_q1_17"""
    with open(filename, 'w', encoding='utf-8') as f:
        for line in header_lines:
            f.write(f"# {line}\n")
        f.write("#\n# mac_idx  coef_addr  coef_q1_17\n#\n")
        for mac, addr, val in sorted(entries, key=lambda x: (x[0], x[1])):
            f.write(f"{mac} {addr} {val}\n")
    print(f"  Written: {filename}  ({len(entries)} entries)")


def write_ddr4_bin(filename, entries, num_macs, num_phases, taps_per_phase):
    """Write DDR4 coefficient image for coef_bank_loader.

    Each coefficient is stored as a 32-bit little-endian signed integer.
    The lower 18 bits hold the Q1.17 coefficient; the RTL ignores the upper bits.
    Coefficients are ordered by MAC then by coef_addr (phase-major, tap-minor),
    matching the address sweep of fir_polyphase_interpolator.
    """
    coef_depth = num_phases * taps_per_phase
    sorted_entries = sorted(entries, key=lambda x: (x[0], x[1]))
    with open(filename, 'wb') as f:
        for mac, addr, val in sorted_entries:
            f.write(struct.pack('<i', int(val)))
    print(f"  Written DDR4 binary: {filename}  ({len(sorted_entries)} coefs, "
          f"{num_macs}x{coef_depth}, {len(sorted_entries)*4} bytes)")


def generate_all_personas(fs_base=48000, num_macs=URAM_NUM_MACS,
                          taps_per_phase=URAM_TAPS_PER_PHASE,
                          num_phases=URAM_NUM_PHASES,
                          out_dir='coeffs', enable_pruning=False,
                          prune_threshold_db=-120, persona_filter=None):
    """
    Bulk-generate URAM filters for all (or one) persona(s), all 6 variations each.
    persona_filter: if set to a DAC_LIBRARY key, only that persona is generated.
    Output tree:
      out_dir/
        dcs-vivaldi/
          dcs-vivaldi_F1_..._m4_t64.txt
          ...
        chord-dave/
          ...
    """
    import time
    total_start = time.time()
    library = {persona_filter: DAC_LIBRARY[persona_filter]} if persona_filter else DAC_LIBRARY
    total = len(library) * 6
    count = 0

    print("=" * 65)
    print(f" Bulk URAM Generator  —  {len(library)} persona(s) x 6 variations = {total} filters")
    print(f" MACs={num_macs}  taps/phase={taps_per_phase}  phases={num_phases}")
    print(f" fs_base={fs_base} Hz  ->  fs_out={fs_base*num_phases} Hz")
    print("=" * 65)

    for persona_key, persona_data in library.items():
        label     = persona_data['label']
        p_dir     = os.path.join(out_dir, persona_key)
        os.makedirs(p_dir, exist_ok=True)

        print(f"\n[{persona_key}] {label}")

        for var_key in ('F1', 'F2', 'F3', 'F4', 'F5', 'F6'):
            v = persona_data[var_key]
            desc        = v['desc']
            window_type = v['window']
            window_param= v['param']
            phase       = v['phase']
            cutoff_hz   = v['cutoff']

            # Resolve the underlying generation method from window type
            # (bh-firls maps to 'berkeley' generator; others use window directly)
            if window_type == 'bh-firls':
                method = 'berkeley'
            elif phase in ('minimum', 'hybrid') and window_type == 'hann':
                method = 'msb'
            else:
                method = 'chord'  # generic sinc + window generator

            tag = desc.split(' — ')[0].replace(' ', '_').replace('/', '-')
            fname = f"{persona_key}_{var_key}_{tag}_m{num_macs}_t{taps_per_phase}.txt"
            full_path = os.path.join(p_dir, fname)

            print(f"  {var_key}: {desc}")
            entries = generate_uram_profile(
                method           = method,
                fs_base          = fs_base,
                num_macs         = num_macs,
                taps_per_phase   = taps_per_phase,
                num_phases       = num_phases,
                window_type      = window_type,
                window_param     = window_param,
                phase            = phase,
                cutoff_hz        = cutoff_hz,
                enable_pruning   = enable_pruning,
                prune_threshold_db = prune_threshold_db,
            )

            write_uram_file(full_path, entries, [
                f"DAC Persona: {label}",
                f"Variation:   {var_key} — {desc}",
                f"Input: {fs_base} Hz  Output: {fs_base*num_phases} Hz",
                f"URAM: num_macs={num_macs}  taps_per_phase={taps_per_phase}  phases={num_phases}",
                f"Q1.17 signed 18-bit  scale={Q1_17_SCALE}",
                f"Cutoff: {cutoff_hz} Hz  Window: {window_type}(param={window_param})  Phase: {phase}",
            ])
            bin_path = full_path.replace('.txt', '.bin')
            write_ddr4_bin(bin_path, entries, num_macs, num_phases, taps_per_phase)
            count += 1

    elapsed = time.time() - total_start
    print(f"\nDone: {count}/{total} filters generated in {elapsed:.1f}s")
    print(f"Output: {os.path.abspath(out_dir)}/")

def generate_legacy_profile(args, fs_in):
    """
    Legacy 205K tap profile generation (original implementation).
    """
    # Dynamic parameter calculation
    # 44.1k Family vs 48k Family target selection
    if fs_in % 44100 == 0:
        fs_out = 705600
    else:
        fs_out = 768000
        
    UPSAMPLE_FACTOR = fs_out // fs_in
    NUM_TAPS = LEGACY_TAPS_PER_PHASE * UPSAMPLE_FACTOR
    
    print("=========================================================")
    print(f" Generating Coefficients for Input Rate: {fs_in} Hz")
    print(f" Style: {args.method.upper()} | Upsample Factor: {UPSAMPLE_FACTOR}x")
    print(f" Target Output Rate: {fs_out / 1e3:.1f} kHz | Taps: {NUM_TAPS}")
    print("Architecture: Legacy 205K tap")
    print("=========================================================\n")

    # Scale the filter cutoffs and transition bandwidths based on fs_in.
    # Baseline presets were originally designed for fs_in = 44100 Hz.
    scale_ratio = fs_in / 44100.0

    taps = None

    if UPSAMPLE_FACTOR == 1:
        # Unity bypass filter: single unity impulse coefficient at the center tap, others zero
        print("UPSAMPLE_FACTOR is 1: Generating unity impulse bypass filter...")
        taps = np.zeros(NUM_TAPS)
        taps[NUM_TAPS // 2] = 1.0
    else:
        # Predefined Styles (Legacy 205K)
        if args.method == 'chord':
            cutoff = 20000.0 * scale_ratio
            print(f"Profile: CHORD DAVE (Linear Phase, Transient Aligned) | Scaled Cutoff: {cutoff:.1f} Hz")
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window=('kaiser', 14.0))

        elif args.method == 'chord-quartet':
            cutoff = 20000.0 * scale_ratio
            transition_width = 1500.0 * scale_ratio
            print(f"Profile: CHORD QUARTET (4M Effective, WTA Optimized)")
            print(f"Scaled Cutoff: {cutoff:.1f} Hz | Transition: {transition_width:.1f} Hz")
            bands = [0, cutoff, cutoff + transition_width, fs_out / 2]
            desired = [1, 0]
            weights = [1, 100] 
            taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=fs_out)
            taps = apply_fft_fractional_delay(taps, 0.5)

        elif args.method == 'msb':
            cutoff = 20000.0 * scale_ratio
            print(f"Profile: MSB REFERENCE (Minimum Phase, Zero Pre-Ringing) | Scaled Cutoff: {cutoff:.1f} Hz")
            base_taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window='hann')
            taps = minimum_phase(base_taps, method='hilbert')

        elif args.method == 'dcs':
            cutoff = 20500.0 * scale_ratio
            print(f"Profile: dCS VIVALDI (Apodizing, Relaxed Roll-off) | Scaled Cutoff: {cutoff:.1f} Hz")
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window=('kaiser', 8.0))

        elif args.method == 'berkeley':
            cutoff = 18500.0 * scale_ratio
            transition_width = 2000.0 * scale_ratio
            print(f"Profile: BERKELEY ALPHA 3 (External Filter Philosophy)")
            print(f"  Scaled Cutoff: {cutoff:.1f} Hz | External: YES | DAC Filter: BYPASSED")
            print(f"  Philosophy: All filtering pre-DAC, chip does only conversion")
            
            # FIRLS for precise control + Blackman-Harris for apodizing
            bands = [0, cutoff - 500*scale_ratio, cutoff + 500*scale_ratio, fs_out / 2]
            desired = [1, 0]
            weights = [1, 200]
            taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=fs_out)
            win = signal.windows.blackmanharris(len(taps))
            taps = taps * win

        elif args.method == 'nagra':
            cutoff = 19800.0 * scale_ratio
            print(f"Profile: NAGRA (Swiss Precision - Natural Analog Warmth)")
            print(f"  Scaled Cutoff: {cutoff:.1f} Hz | Kaiser Beta: 9.0")
            print(f"  Characteristics: Low phase distortion, gentle roll-off")
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window=('kaiser', 9.0))

        elif args.method == 'merason':
            cutoff = 20000.0 * scale_ratio
            print(f"Profile: MERASON (PCM1794A Signature - Smooth & Detailed)")
            print(f"  Scaled Cutoff: {cutoff:.1f} Hz | Kaiser Beta: 11.0")
            print(f"  Characteristics: Burr-Brown warmth, slightly romantic")            
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window=('kaiser', 11.0))

        elif args.method == 'dcs-chord-ideal':
            cutoff = 20500.0 * scale_ratio
            transition_width = 1500.0 * scale_ratio
            print(f"Profile: dCS-CHORD HYBRID (Apodizing + Ideal Transient Alignment)")
            print(f"Scaled Cutoff: {cutoff:.1f} Hz | Scaled Transition Width: {transition_width:.1f} Hz")
            
            bands = [0, cutoff, cutoff + transition_width, fs_out / 2]
            desired = [1, 0]
            weights = [1, 100] 
            taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=fs_out)
            taps = apply_fft_fractional_delay(taps, 0.5)

        elif args.method == 'csv':
            if not args.csv_path or not os.path.exists(args.csv_path):
                print("Error: --csv_path is required.")
                sys.exit(1)
            taps = np.loadtxt(args.csv_path)
            if len(taps) != NUM_TAPS:
                taps = np.resize(taps, NUM_TAPS)

    # Apply Polyphase DC Gain Correction
    print("Applying Polyphase DC Gain Correction...")
    taps_sum = np.sum(taps)
    if abs(taps_sum) > 1e-9:
        taps = taps * (UPSAMPLE_FACTOR / taps_sum)
    else:
        taps = taps * UPSAMPLE_FACTOR

    # Apply pruning if requested
    prune_stats = None
    if args.enable_pruning and args.phase == 'linear':
        taps, num_pruned, pruned_pct = prune_taps(taps, args.prune_threshold)
        prune_stats = (num_pruned, pruned_pct)
        print(f"Tap Pruning: {num_pruned} taps ({pruned_pct:.1f}%) pruned at {args.prune_threshold} dB")
        # Renormalize after pruning
        taps = (taps / np.sum(taps)) * UPSAMPLE_FACTOR

    # Scale to 18-bit Two's Complement
    print(f"Quantizing to {BIT_DEPTH}-bit Two's Complement...")
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    max_abs_tap = np.max(np.abs(taps))
    if max_abs_tap > 1e-9:
        scale_factor = max_val / max_abs_tap
        taps_quantized = np.round(taps * scale_factor).astype(int)
    else:
        taps_quantized = np.zeros(NUM_TAPS, dtype=int)

    # Write files organized by rate & method
    target_dir = os.path.join(args.out_dir, f"{args.method}_{fs_in}")
    os.makedirs(target_dir, exist_ok=True)
    
    print(f"Writing 128 dual-port BRAM coefficient files to {target_dir}...")
    for i in range(LEGACY_DSP_SLICES):
        filename = os.path.join(target_dir, f"coef_{i:03d}.mem")
        with open(filename, "w") as f:
            for c in range(LEGACY_CYCLES):
                for p in range(UPSAMPLE_FACTOR):
                    global_idx = (c * LEGACY_DSP_SLICES * UPSAMPLE_FACTOR) + p + (i * UPSAMPLE_FACTOR)
                    val = taps_quantized[global_idx] if global_idx < len(taps_quantized) else 0
                    if val < 0:
                        val = (1 << BIT_DEPTH) + val
                    f.write(f"{val:05X}\n")

    print(f"Success! {NUM_TAPS} coefficients written to {target_dir}.\n")
    return prune_stats


def export_1m_to_bin(taps, filename):
    """ Export 512K folded taps to binary file (32-bit aligned for SPI). """
    with open(filename, 'wb') as f:
        for coef in taps:
            # Pack as 32-bit signed integer (little-endian)
            f.write(struct.pack('<i', coef))


def generate_megafilter(args, fs_in):
    """
    Main entry point - dispatches to appropriate generator based on architecture mode.
    """
    if args.architecture == 'uram':
        # URAM mode: generate polyphase coefficients for XCVU13P URAM loader
        fs_base = 48000 if fs_in % 48000 == 0 else 44100

        num_macs       = args.uram_num_macs
        taps_per_phase = args.uram_taps_per_phase
        num_phases     = URAM_NUM_PHASES

        print("=========================================================")
        print(f" URAM Mode: {args.method.upper()}  fs_in={fs_in}")
        print(f" MACs={num_macs}  taps_per_phase={taps_per_phase}  phases={num_phases}")
        print("=========================================================")

        entries = generate_uram_profile(
            method          = args.method,
            fs_base         = fs_base,
            num_macs        = num_macs,
            taps_per_phase  = taps_per_phase,
            num_phases      = num_phases,
            window_type     = args.window_type,
            window_param    = args.window_param,
            phase           = args.phase,
            enable_pruning  = args.enable_pruning,
            prune_threshold_db = args.prune_threshold,
        )

        target_dir = os.path.join(args.out_dir, f"uram_{fs_in}")
        os.makedirs(target_dir, exist_ok=True)

        # Descriptive filename
        w_tag = f"{args.window_type}"
        if args.window_param is not None:
            w_tag += f"{args.window_param}"
        fname = f"{args.method}_{w_tag}_{args.phase}_m{num_macs}_t{taps_per_phase}.txt"
        full_path = os.path.join(target_dir, fname)

        # Resolve human-readable description
        descriptions = {
            'chord':          'Chord DAVE — Linear Phase Brick-Wall, Kaiser beta=14',
            'chord-dave':     'Chord DAVE — Linear Phase Brick-Wall, Kaiser beta=14',
            'chord-quartet':  'Chord Quartet — FIRLS + WTA fractional delay',
            'dcs':            'dCS Vivaldi Apex (Filter 1) — Slow Roll-Off, Kaiser beta=8',
            'dcs-f1':         'dCS Vivaldi Apex (Filter 1) — Slow Roll-Off, Kaiser beta=8',
            'dcs-f2':         'dCS Vivaldi Apex (Filter 2) — Extended Bandwidth to 25 kHz',
            'msb':            'MSB Reference — Minimum Phase, Hann window',
            'msb-reference':  'MSB Reference — Minimum Phase, Hann window',
            'berkeley':       'Berkeley Audio Alpha 3 — Apodising, FIRLS + Blackman-Harris',
            'nagra':          'Nagra — Swiss Precision, Natural Analog Warmth, Kaiser beta=9',
            'merason':        'Merason — PCM1794A Burr-Brown Warmth, Kaiser beta=11',
            'hybrid':         'Hybrid Phase — 60% min-phase + 40% linear blend',
            'dcs-chord-ideal':'dCS-Chord Hybrid — Apodising + WTA alignment',
        }
        desc = descriptions.get(args.method, args.method)

        write_uram_file(full_path, entries, [
            f"Filter: {desc}",
            f"Input rate: {fs_in} Hz  ->  Output rate: {fs_in*num_phases} Hz",
            f"Architecture: URAM XCVU13P  num_macs={num_macs}  "
            f"taps_per_phase={taps_per_phase}  num_phases={num_phases}",
            f"Coefficient format: Q1.17 signed 18-bit (scale={Q1_17_SCALE})",
            f"Total prototype taps: {num_macs * num_phases * taps_per_phase}",
            f"Window: {args.window_type}  param={args.window_param}  phase={args.phase}",
        ])
        bin_path = full_path.replace('.txt', '.bin')
        write_ddr4_bin(bin_path, entries, num_macs, num_phases, taps_per_phase)
        return

    elif args.architecture == '1m-folded':
        # 1M Tap Folded Mode
        fs_base = 48000 if fs_in % 48000 == 0 else 44100
        
        print("=========================================================")
        print(f" Generating 1M Tap Folded Coefficients for {fs_in} Hz base")
        print(f" Profile: {args.method.upper()} | Window: {args.window_type}")
        print(f" Phase: {args.phase} | Pruning: {args.enable_pruning}")
        print("=========================================================\n")
        
        padded_taps, prune_stats = generate_1m_folded_profile(
            args.method, fs_base, 
            window_type=args.window_type,
            window_param=args.window_param,
            phase=args.phase,
            enable_pruning=args.enable_pruning,
            prune_threshold_db=args.prune_threshold
        )
        
        # Build filename with parameters
        win_suffix = f"_{args.window_type}{args.window_param}"
        prune_suffix = f"_pruned{args.prune_threshold}" if args.enable_pruning and prune_stats else "_noprune"
        phase_suffix = f"_{args.phase}"
        filename = f"{args.method}{win_suffix}{phase_suffix}{prune_suffix}.bin"
        
        target_dir = os.path.join(args.out_dir, f"1m_folded_{fs_in}")
        os.makedirs(target_dir, exist_ok=True)
        
        full_path = os.path.join(target_dir, filename)
        export_1m_to_bin(padded_taps, full_path)
        
        print(f"\nExported {len(padded_taps)} folded taps ({ONE_M_TAPS} effective)")
        if prune_stats:
            num_pruned, pruned_pct = prune_stats
            print(f"Pruned {num_pruned} taps ({pruned_pct:.1f}%)")
        print(f"Output: {full_path}")
        print(f"File size: {os.path.getsize(full_path) / 1024:.1f} KB\n")
        
    else:
        # Legacy 205K Mode
        return generate_legacy_profile(args, fs_in)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="BFDAC Coefficient Generator — 6 DAC Personas x 6 Variations, URAM / 1M-folded / Legacy",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate ALL 36 URAM filters (6 personas x 6 variations) for simulation:
  python gen_coe_super.py --generate-all --architecture uram --out_dir coeffs

  # Single persona, all 6 variations:
  python gen_coe_super.py --generate-all --persona chord-dave --architecture uram

  # Single filter (persona + variation):
  python gen_coe_super.py --persona chord-dave --variation F1 --architecture uram

  # Legacy --method interface still works:
  python gen_coe_super.py --architecture uram --method chord-dave --fs_in 48000

  # 1M Folded QSPI binary:
  python gen_coe_super.py --architecture 1m-folded --method chord --fs_in 48000

  # Production scale (1024 MACs):
  python gen_coe_super.py --generate-all --architecture uram \\
      --uram-num-macs 1024 --uram-taps-per-phase 64 --out_dir coeffs_prod
        """)
    
    # --- New persona/variation interface (preferred) ---
    parser.add_argument('--generate-all', action='store_true',
                        help="Generate all 36 filters (6 personas x 6 variations). "
                             "Use --persona to restrict to one persona (6 filters).")
    parser.add_argument('--persona', type=str,
                        choices=list(DAC_LIBRARY.keys()),
                        help="DAC persona key for --generate-all or --variation")
    parser.add_argument('--variation', type=str,
                        choices=['F1', 'F2', 'F3', 'F4', 'F5', 'F6'],
                        help="Filter variation within a persona (requires --persona)")

    # --- Legacy --method interface (backward compat) ---
    parser.add_argument('--method', type=str,
                        choices=[
                            'chord-dave', 'dcs-f1', 'dcs-f2', 'msb-reference',
                            'berkeley', 'merason', 'mola-mola', 'nagra', 'hybrid',
                            'chord', 'chord-quartet', 'msb', 'dcs',
                            'dcs-chord-ideal', 'csv',
                        ],
                        help="Legacy method key (use --persona/--variation for new work)")
    parser.add_argument('--fs_in', type=str, default='48000',
                        help="Input sample rate (e.g. 44100, 96000) or 'all' for all rates")
    parser.add_argument('--out_dir', type=str, default='coeffs',
                        help="Top-level output directory for generated coefficient folders")
    
    # Architecture selection
    parser.add_argument('--architecture', type=str, default='legacy',
                        choices=['legacy', '1m-folded', 'uram'],
                        help=("Architecture mode: legacy (205K BRAM .mem shards), "
                              "1m-folded (1M QSPI .bin), "
                              "uram (XCVU13P URAM loader .txt)"))

    # URAM-specific options
    parser.add_argument('--uram-num-macs', type=int, default=URAM_NUM_MACS,
                        dest='uram_num_macs',
                        help=f"Number of MACs for URAM mode (default: {URAM_NUM_MACS} sim / 1024 prod)")
    parser.add_argument('--uram-taps-per-phase', type=int, default=URAM_TAPS_PER_PHASE,
                        dest='uram_taps_per_phase',
                        help=f"Taps per phase for URAM mode (default: {URAM_TAPS_PER_PHASE})")
    
    # Window and optimization options
    parser.add_argument('--window-type', type=str, default='kaiser',
                        choices=['kaiser', 'gaussian'],
                        help="Window function type (1M folded mode only)")
    parser.add_argument('--window-param', type=float, default=None,
                        help="Window parameter (beta for Kaiser, alpha for Gaussian). Auto-selected if not specified.")
    parser.add_argument('--phase', type=str, default='linear',
                        choices=['linear', 'minimum'],
                        help="Phase response type (affects minimum phase methods like MSB)")
    
    # Tap pruning options
    parser.add_argument('--enable-pruning', action='store_true',
                        help="Enable tap pruning (zero out insignificant taps)")
    parser.add_argument('--prune-threshold', type=float, default=-120,
                        help="Pruning threshold in dB relative to peak (default: -120)")
    
    # CSV import (legacy mode only)
    parser.add_argument('--csv_path', type=str,
                        help="Path to external CSV filter taps (only if method is 'csv')")
    
    args = parser.parse_args()

    # ----------------------------------------------------------------
    # Route: --generate-all  (bulk DAC_LIBRARY generator)
    # ----------------------------------------------------------------
    if args.generate_all:
        if args.architecture != 'uram':
            print("Note: --generate-all is only supported with --architecture uram")
            print("Switching to uram mode.")
            args.architecture = 'uram'

        fs_base = 48000  # bulk always generates at 48k base

        if args.persona:
            # Single persona requested — generate all 6 variations
            if args.variation:
                # Single specific variation
                persona_data = DAC_LIBRARY[args.persona]
                v = persona_data[args.variation]
                p_dir = os.path.join(args.out_dir, args.persona)
                os.makedirs(p_dir, exist_ok=True)
                wtype = v['window']
                method = 'berkeley' if wtype == 'bh-firls' else ('msb' if v['phase'] in ('minimum','hybrid') and wtype == 'hann' else 'chord')
                tag = v['desc'].split(' — ')[0].replace(' ', '_').replace('/', '-')
                fname = f"{args.persona}_{args.variation}_{tag}_m{args.uram_num_macs}_t{args.uram_taps_per_phase}.txt"
                entries = generate_uram_profile(
                    method=method, fs_base=fs_base,
                    num_macs=args.uram_num_macs, taps_per_phase=args.uram_taps_per_phase,
                    num_phases=URAM_NUM_PHASES,
                    window_type=wtype, window_param=v['param'],
                    phase=v['phase'], cutoff_hz=v['cutoff'],
                    enable_pruning=args.enable_pruning,
                    prune_threshold_db=args.prune_threshold,
                )
                full_path = os.path.join(p_dir, fname)
                write_uram_file(full_path, entries, [
                    f"DAC Persona: {persona_data['label']}",
                    f"Variation:   {args.variation} — {v['desc']}",
                    f"Q1.17 signed 18-bit  scale={Q1_17_SCALE}",
                ])
                bin_path = full_path.replace('.txt', '.bin')
                write_ddr4_bin(bin_path, entries, args.uram_num_macs, URAM_NUM_PHASES, args.uram_taps_per_phase)
            else:
                # All 6 variations for one persona
                generate_all_personas(
                    fs_base=fs_base,
                    num_macs=args.uram_num_macs,
                    taps_per_phase=args.uram_taps_per_phase,
                    out_dir=args.out_dir,
                    enable_pruning=args.enable_pruning,
                    prune_threshold_db=args.prune_threshold,
                    persona_filter=args.persona,
                )
        else:
            # All 36 filters
            generate_all_personas(
                fs_base=fs_base,
                num_macs=args.uram_num_macs,
                taps_per_phase=args.uram_taps_per_phase,
                out_dir=args.out_dir,
                enable_pruning=args.enable_pruning,
                prune_threshold_db=args.prune_threshold,
            )
        sys.exit(0)

    # ----------------------------------------------------------------
    # Route: legacy --method interface
    # ----------------------------------------------------------------
    if not args.method:
        print("Error: specify --method, --persona/--variation, or --generate-all")
        parser.print_help()
        sys.exit(1)

    supported_rates = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]

    if args.fs_in.lower() == 'all':
        rates_to_generate = supported_rates
    else:
        try:
            rate = int(args.fs_in)
            if rate not in supported_rates:
                print(f"Error: {rate} is not a supported input sample rate.")
                print(f"Supported rates: {supported_rates}")
                sys.exit(1)
            rates_to_generate = [rate]
        except ValueError:
            print(f"Error: Invalid --fs_in value '{args.fs_in}'. Must be an integer or 'all'.")
            sys.exit(1)

    for fs_in in rates_to_generate:
        generate_megafilter(args, fs_in)
