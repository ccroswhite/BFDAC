import numpy as np
from scipy.signal import firwin, minimum_phase, firls
import argparse
import sys
import os

# =====================================================================
# 1. ARCHITECTURE LIMITS (Artix UltraScale+ AU25P)
# =====================================================================
# The physical constraints of your 357 MHz systolic array.
UPSAMPLE_FACTOR = 81
CYCLES_PER_SAMPLE = 100
DSP_SLICES = 128

# Total taps = 100 * 128 * 81 = 1,036,800 Taps
TAPS_PER_PHASE = CYCLES_PER_SAMPLE * DSP_SLICES
NUM_TAPS = TAPS_PER_PHASE * UPSAMPLE_FACTOR  
BIT_DEPTH = 18
FS_IN = 44100
FS_OUT = FS_IN * UPSAMPLE_FACTOR

# =====================================================================
# 2. FRACTIONAL DELAY MODULE (The "Chord" Transient Alignment)
# =====================================================================
def apply_fft_fractional_delay(taps, delay_fraction):
    """
    Applies a mathematically perfect sub-sample fractional delay using an 
    Ideal FFT phase shift. This mimics Rob Watts' WTA transient alignment 
    by sliding the digital wave between integer grid lines, but with zero 
    high-frequency phase warping.
    """
    print(f"Applying Ideal FFT fractional delay of {delay_fraction} samples...")
    
    # Step A: Move the entire 1-million tap filter into the frequency domain
    TAPS_FFT = np.fft.rfft(taps)
    frequencies = np.fft.rfftfreq(len(taps))
    
    # Step B: Apply a linear phase rotation to every frequency bin.
    # This alters the timing (phase) without changing the volume (magnitude).
    phase_shift = np.exp(-1j * 2 * np.pi * frequencies * delay_fraction)
    TAPS_FFT_SHIFTED = TAPS_FFT * phase_shift
    
    # Step C: Return the shifted coefficients back to the time domain
    return np.fft.irfft(TAPS_FFT_SHIFTED, n=len(taps))

# =====================================================================
# 3. CORE FILTER GENERATION & CHAINING MODULE
# =====================================================================
def generate_megafilter(args):
    print("=========================================================")
    print(f" Generating {NUM_TAPS}-tap FIR filter (SUPER SCRIPT)")
    print(f" Output Rate: {FS_OUT / 1e6:.3f} MHz")
    print("=========================================================\n")

    taps = None

    # --- PRESET 1: CHORD DAVE (The "Perfect Timing" Approach) ---
    # Uses a massive linear-phase Windowed Sinc filter. 
    # High Kaiser beta (14.0) guarantees >110dB stop-band attenuation.
    if args.method == 'chord':
        print("Profile: CHORD DAVE (Linear Phase, Transient Aligned)")
        taps = firwin(NUM_TAPS, 20000, fs=FS_OUT, window=('kaiser', 14.0))

    # --- PRESET 2: MSB REFERENCE (The "Analog" Approach) ---
    # Mathematically shifts impulse energy to the right to completely 
    # eliminate pre-ringing, yielding a warmer, less fatiguing sound.
    elif args.method == 'msb':
        print("Profile: MSB REFERENCE (Minimum Phase, Zero Pre-Ringing)")
        base_taps = firwin(NUM_TAPS, 20000, fs=FS_OUT, window='hann')
        taps = minimum_phase(base_taps, method='hilbert')

    # --- PRESET 3: dCS VIVALDI (The "Relaxed Apodizing" Approach) ---
    # Drops the cutoff to 20.5kHz to round off harsh transient edges and 
    # mask the pre-ringing from the studio's ADC.
    elif args.method == 'dcs':
        print("Profile: dCS VIVALDI (Apodizing, Relaxed Roll-off)")
        taps = firwin(NUM_TAPS, 20500, fs=FS_OUT, window=('kaiser', 8.0))

    # --- PRESET 4: BERKELEY ALPHA 3 (The "Aggressive Apodizing" Approach) ---
    # Aggressive cutoff at 18.5kHz using a Blackman-Harris window for maximum 
    # masking of studio ringing.
    elif args.method == 'berkeley':
        print("Profile: BERKELEY ALPHA 3 (Aggressive Apodizing)")
        taps = firwin(NUM_TAPS, 18500, fs=FS_OUT, window='blackmanharris')

    # --- PRESET 5: THE HYBRID CHAIN (dCS + Chord Ideal) ---
    # This chains two advanced techniques together for the ultimate profile.
    elif args.method == 'dcs-chord-ideal':
        print("Profile: dCS-CHORD HYBRID (Apodizing + Ideal Transient Alignment)")
        
        # Step 1: Generate the relaxed dCS apodizing curve via Least-Squares optimization
        print("Step 1: Generating relaxed dCS apodizing curve (firls at 20.5kHz)...")
        cutoff = 20500
        transition_width = 1500  
        bands = [0, cutoff, cutoff + transition_width, FS_OUT / 2]
        desired = [1, 0]
        
        # DIAL: [Passband_Weight, Stopband_Weight]. 
        # [1, 100] forces massive noise floor crushing over perfect passband flatness.
        weights = [1, 100] 
        taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=FS_OUT)
        
        # Step 2: Apply Chord-style sub-sample alignment via Ideal FFT
        # DIAL: 0.5 shifts the transient mathematically directly between integer grid lines
        print("Step 2: Applying Chord-style sub-sample alignment via Ideal FFT...")
        taps = apply_fft_fractional_delay(taps, 0.5)

    # --- OPTIONAL: CUSTOM EXTERNAL CSV ---
    elif args.method == 'csv':
        if not args.csv_path or not os.path.exists(args.csv_path):
            print("Error: --csv_path is required.")
            sys.exit(1)
        taps = np.loadtxt(args.csv_path)
        if len(taps) != NUM_TAPS:
            taps = np.resize(taps, NUM_TAPS)

    # =====================================================================
    # 4. POST-PROCESSING & HARDWARE EXPORT
    # =====================================================================
    print("\nApplying Polyphase DC Gain Correction...")
    taps = taps * (UPSAMPLE_FACTOR / np.sum(taps))

    print(f"Quantizing to {BIT_DEPTH}-bit Two's Complement...")
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    scale_factor = max_val / np.max(np.abs(taps))
    taps_quantized = np.round(taps * scale_factor).astype(int)

    # Export to 128 shards for the AU25P dual-port UltraRAM
    print("\nWriting 128 shards to disk for dual-port ROM...")
    for i in range(DSP_SLICES):
        filename = f"shard_{i:03d}.mem"
        with open(filename, "w") as f:
            for c in range(CYCLES_PER_SAMPLE):
                for p in range(UPSAMPLE_FACTOR):
                    global_idx = (c * DSP_SLICES * UPSAMPLE_FACTOR) + p + (i * UPSAMPLE_FACTOR)
                    val = taps_quantized[global_idx] if global_idx < len(taps_quantized) else 0
                    if val < 0:
                        val = (1 << BIT_DEPTH) + val
                    f.write(f"{val:05X}\n")

    print(f"\nSuccess! {NUM_TAPS} sharded coefficients written.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DAC Super Script for Audio Exploration")
    parser.add_argument('--method', type=str, 
                        choices=['chord', 'msb', 'dcs', 'berkeley', 'dcs-chord-ideal', 'csv'], 
                        required=True)
    parser.add_argument('--csv_path', type=str)
    args = parser.parse_args()
    generate_megafilter(args)
