import numpy as np
from scipy.signal import firwin, minimum_phase, firls
import argparse
import sys
import os

# =====================================================================
# ARCHITECTURE LIMITS (Artix UltraScale+ AU25P)
# =====================================================================
CYCLES_PER_SAMPLE = 100
DSP_SLICES = 128
TAPS_PER_PHASE = CYCLES_PER_SAMPLE * DSP_SLICES  # 12,800
BIT_DEPTH = 18

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
def generate_megafilter(args, fs_in):
    # Dynamic parameter calculation
    # 44.1k Family vs 48k Family target selection
    if fs_in % 44100 == 0:
        fs_out = 705600
    else:
        fs_out = 768000
        
    UPSAMPLE_FACTOR = fs_out // fs_in
    NUM_TAPS = TAPS_PER_PHASE * UPSAMPLE_FACTOR
    
    print("=========================================================")
    print(f" Generating Coefficients for Input Rate: {fs_in} Hz")
    print(f" Style: {args.method.upper()} | Upsample Factor: {UPSAMPLE_FACTOR}x")
    print(f" Target Output Rate: {fs_out / 1e3:.1f} kHz | Taps: {NUM_TAPS}")
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
        # Predefined Styles
        if args.method == 'chord':
            cutoff = 20000.0 * scale_ratio
            print(f"Profile: CHORD DAVE (Linear Phase, Transient Aligned) | Scaled Cutoff: {cutoff:.1f} Hz")
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window=('kaiser', 14.0))

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
            print(f"Profile: BERKELEY ALPHA 3 (Aggressive Apodizing) | Scaled Cutoff: {cutoff:.1f} Hz")
            taps = firwin(NUM_TAPS, cutoff, fs=fs_out, window='blackmanharris')

        elif args.method == 'dcs-chord-ideal':
            cutoff = 20500.0 * scale_ratio
            transition_width = 1500.0 * scale_ratio
            print(f"Profile: dCS-CHORD HYBRID (Apodizing + Ideal Transient Alignment)")
            print(f"Scaled Cutoff: {cutoff:.1f} Hz | Scaled Transition Width: {transition_width:.1f} Hz")
            
            # Step 1: Generate the relaxed dCS apodizing curve via Least-Squares optimization
            bands = [0, cutoff, cutoff + transition_width, fs_out / 2]
            desired = [1, 0]
            weights = [1, 100] 
            taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=fs_out)
            
            # Step 2: Apply Chord-style sub-sample alignment via Ideal FFT
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
        # Avoid division by zero for exotic center-impulse or zero-sum filters
        taps = taps * UPSAMPLE_FACTOR

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
    for i in range(DSP_SLICES):
        filename = os.path.join(target_dir, f"coef_{i:03d}.mem")
        with open(filename, "w") as f:
            for c in range(CYCLES_PER_SAMPLE):
                for p in range(UPSAMPLE_FACTOR):
                    global_idx = (c * DSP_SLICES * UPSAMPLE_FACTOR) + p + (i * UPSAMPLE_FACTOR)
                    val = taps_quantized[global_idx] if global_idx < len(taps_quantized) else 0
                    if val < 0:
                        val = (1 << BIT_DEPTH) + val
                    f.write(f"{val:05X}\n")

    print(f"Success! {NUM_TAPS} coefficients written to {target_dir}.\n")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DAC Super Script for Audio Exploration")
    parser.add_argument('--method', type=str, 
                        choices=['chord', 'msb', 'dcs', 'berkeley', 'dcs-chord-ideal', 'csv'], 
                        required=True,
                        help="Filter preset style to generate")
    parser.add_argument('--fs_in', type=str, default='all',
                        help="Input sample rate (e.g. 44100, 96000) or 'all' to generate all supported rates")
    parser.add_argument('--out_dir', type=str, default='coeffs',
                        help="Top-level output directory for generated coefficient folders")
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
