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
# Mode 1: Legacy 205K tap (12,800 per phase)
# Mode 2: 1M Tap Folded Architecture (512K stored, 1M effective)
# =====================================================================

# --- Legacy Mode (205K taps) ---
LEGACY_CYCLES = 100
LEGACY_DSP_SLICES = 128
LEGACY_TAPS_PER_PHASE = LEGACY_CYCLES * LEGACY_DSP_SLICES  # 12,800

# --- 1M Tap Folded Mode ---
ONE_M_TAPS = 1000001            # 1,000,001 total taps (odd for Type I linear phase)
ONE_M_STORED = (ONE_M_TAPS // 2) + 1  # 500,001 coefficients stored
ONE_M_PADDED = 524288           # Pad to 512K for QSPI alignment

BIT_DEPTH = 18

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
        'chord': 20000.0,           # Standard Chord: Linear phase, surgical
        'chord-quartet': 20000.0,   # Quartet: FIRLS + WTA alignment
        'msb': 20000.0,             # MSB: Minimum phase, zero pre-ringing
        'dcs': 20500.0,             # dCS: Apodizing, relaxed roll-off
        'dcs-chord-ideal': 20500.0, # Hybrid: dCS smoothness + Chord timing
        
        # Berkeley: Aggressive apodizing, external filter before DAC chip
        # Uses DAC chip ONLY for conversion, all filtering done externally
        'berkeley': 18500.0,        # Very early roll-off, extreme apodizing
        
        # Nagra: Swiss precision, natural analog-like sound
        # Likely uses quality external upsampling + PCM1794A internal filter
        'nagra': 19800.0,           # Slightly relaxed, natural transition
        
        # Merason (PCM1794A): Burr-Brown chip with discrete analog stage
        # PCM1794A has 8x internal oversampling - external filter is gentler
        'merason': 20000.0,         # Matches PCM1794A sweet spot
    }
    
    cutoff = cutoffs.get(method, 20000.0)
    normalized_cutoff = cutoff / (FS_OUT / 2.0)
    
    print(f"Generating 1M Tap Profile: {method.upper()}")
    print(f"  Cutoff: {cutoff:.1f} Hz | Window: {window_type} (param={window_param})")
    print(f"  Phase: {phase} | Pruning: {enable_pruning} ({prune_threshold_db} dB)")
    
    # Generate base taps
    if method == 'chord-quartet':
        # Quartet: Use FIRLS for apodizing + FFT fractional delay
        transition = 1500.0
        bands = [0, cutoff, cutoff + transition, FS_OUT / 2]
        desired = [1, 0]
        weights = [1, 100]
        taps = firls(ONE_M_TAPS, bands, desired, weight=weights, fs=FS_OUT)
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
            
    elif method == 'msb':
        # MSB: Minimum phase with Hann
        base_taps = firwin(ONE_M_TAPS, normalized_cutoff, window='hann')
        if phase == 'minimum':
            taps = minimum_phase(base_taps, method='hilbert')
        else:
            taps = base_taps
            
    elif method == 'berkeley':
        # Berkeley Alpha 3: External filter philosophy
        # ALL filtering done in FPGA before DAC chip
        # DAC chip used ONLY for conversion (no internal filter)
        # Result: Maximum control, aggressive apodizing for "analog" sound
        
        # Use FIRLS for precise band control with steep transition
        transition = 2000.0  # Wider transition for smoother roll-off
        bands = [0, cutoff - 500, cutoff + 500, FS_OUT / 2]
        desired = [1, 0]
        weights = [1, 200]  # Heavy weight on stopband for deep attenuation
        taps = firls(ONE_M_TAPS, bands, desired, weight=weights, fs=FS_OUT)
        
        # Apply Blackman-Harris window for extreme apodizing
        # This eliminates all pre-ringing
        win = signal.windows.blackmanharris(ONE_M_TAPS)
        taps = taps * win
        
    elif method == 'dcs':
        # dCS: Relaxed roll-off
        if window_type == 'kaiser':
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 8.0))
        else:  # gaussian
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=2.5)
            
    elif method == 'dcs-chord-ideal':
        # Hybrid: dCS apodizing + Chord alignment
        transition = 1500.0
        bands = [0, cutoff, cutoff + transition, FS_OUT / 2]
        desired = [1, 0]
        weights = [1, 100]
        taps = firls(ONE_M_TAPS, bands, desired, weight=weights, fs=FS_OUT)
        taps = apply_fft_fractional_delay(taps, 0.5)
        
    else:  # default chord
        if window_type == 'kaiser':
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window=('kaiser', 14.0))
        else:  # gaussian
            taps = firwin(ONE_M_TAPS, normalized_cutoff, window='rectangular')
            taps = taps * gaussian_window(ONE_M_TAPS, alpha=3.5)
    
    # Apply interpolator gain correction
    taps = (taps / np.sum(taps)) * 16.0
    
    # Tap pruning (only for linear phase where symmetry is maintained)
    prune_stats = None
    if enable_pruning and phase == 'linear':
        taps, num_pruned, pruned_pct = prune_taps(taps, prune_threshold_db)
        prune_stats = (num_pruned, pruned_pct)
        # Renormalize after pruning
        taps = (taps / np.sum(taps)) * 16.0
    
    # Quantize to 18-bit
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    max_abs_tap = np.max(np.abs(taps))
    if max_abs_tap > 1e-9:
        scale_factor = max_val / max_abs_tap
        quantized_taps = np.round(taps * scale_factor).astype(int)
    else:
        quantized_taps = np.zeros(ONE_M_TAPS, dtype=int)
    
    # Hardware folding: extract first half
    folded_taps = quantized_taps[0:ONE_M_STORED]
    
    # Pad to 512K
    padded_taps = np.pad(folded_taps, (0, ONE_M_PADDED - len(folded_taps)), 'constant')
    
    return padded_taps, prune_stats

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
    if args.architecture == '1m-folded':
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
        description="DAC Super Script for Audio Exploration - Supports 205K Legacy and 1M Folded Architectures",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Legacy 205K mode with pruning
  python gen_coe_super.py --method chord --fs_in 44100 --enable-pruning
  
  # 1M Folded mode with Gaussian window
  python gen_coe_super.py --architecture 1m-folded --method chord --window-type gaussian --window-param 3.5
  
  # New Nagra profile with optimizations
  python gen_coe_super.py --architecture 1m-folded --method nagra --window-type gaussian --enable-pruning
        """)
    
    # Core parameters
    parser.add_argument('--method', type=str,
                        choices=['chord', 'chord-quartet', 'msb', 'dcs', 'berkeley', 
                                'dcs-chord-ideal', 'nagra', 'merson', 'csv'],
                        required=True,
                        help="Filter preset style to generate")
    parser.add_argument('--fs_in', type=str, default='all',
                        help="Input sample rate (e.g. 44100, 96000) or 'all' for all rates")
    parser.add_argument('--out_dir', type=str, default='coeffs',
                        help="Top-level output directory for generated coefficient folders")
    
    # Architecture selection
    parser.add_argument('--architecture', type=str, default='legacy',
                        choices=['legacy', '1m-folded'],
                        help="Architecture mode: legacy (205K taps) or 1m-folded (1M effective taps)")
    
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

    # Parse and validate fs_in rates
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
