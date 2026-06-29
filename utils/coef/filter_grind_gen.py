import numpy as np
from scipy import signal
import os
import struct
import time
import math

# --- Hardware System Parameters ---
FS_BASE = 48000                 # Base sample rate (44.1kHz or 48kHz)
OVERSAMPLE_RATE = 16            # 16x Interpolator
FS_OUT = FS_BASE * OVERSAMPLE_RATE 
COEF_BIT_WIDTH = 18             # Matches Artix-7 DSP48E1 Multiplier limit

# --- The 1M Tap Folded Architecture ---
# For a Type I Linear Phase filter, we need an odd number of taps.
TOTAL_TAPS = 1000001            
# Because the FPGA uses a pre-adder (h[n] + h[N-1-n]), we only store the first half.
STORED_TAPS = (TOTAL_TAPS // 2) + 1  # 500,001 coefficients

# --- The Acoustic Matrix (Grid Search Parameters) ---
# Sweeping Cutoff Frequencies (Apodizing dimension)
CUTOFFS = [20000, 19200, 18500] 

# Window Parameters
# Kaiser: beta 4.0 = Gentle/Warm, 14.0 = Surgical/dCS style
# Gaussian: alpha 2.5 = Wide, 4.0 = Tight energy concentration
KAISER_BETAS = [4.0, 8.0, 14.0, 20.0]  
GAUSSIAN_ALPHAS = [2.5, 3.0, 3.5, 4.0]

# Phase types
PHASES = ['linear', 'minimum']

# Tap Pruning Threshold (in dB relative to peak)
PRUNE_THRESHOLD_DB = -120

def gaussian_window(N, alpha=3.0):
    """
    Generate a Gaussian window with parameter alpha.
    Higher alpha = tighter concentration of energy in center taps.
    w[n] = exp(-0.5 * (alpha * (n - mid) / mid)^2)
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
    threshold = peak * (10 ** (threshold_db / 20.0))
    
    pruned = np.where(np.abs(taps) >= threshold, taps, 0.0)
    
    num_pruned = np.sum(np.abs(taps) < threshold)
    pruned_percent = (num_pruned / len(taps)) * 100
    
    return pruned, num_pruned, pruned_percent

def generate_profile(cutoff, window_param, phase, window_type='kaiser', 
                     prune_threshold_db=-120, enable_pruning=True):
    nyq = 0.5 * FS_OUT
    normalized_cutoff = cutoff / nyq
    
    # 1. Generate the Baseline Sinc + Window
    if window_type == 'kaiser':
        taps = signal.firwin(TOTAL_TAPS, normalized_cutoff, window=('kaiser', window_param), pass_zero='lowpass')
    elif window_type == 'gaussian':
        # Generate sinc prototype
        taps = signal.firwin(TOTAL_TAPS, normalized_cutoff, window='rectangular', pass_zero='lowpass')
        # Apply Gaussian window
        win = gaussian_window(TOTAL_TAPS, alpha=window_param)
        taps = taps * win
    else:
        raise ValueError(f"Unknown window type: {window_type}")
    
    # 2. Minimum Phase Conversion (Homomorphic)
    if phase == 'minimum':
        taps = signal.minimum_phase(taps, method='homomorphic')
        
    # 3. Apply Interpolator Gain Correction
    taps_normalized = (taps / np.sum(taps)) * OVERSAMPLE_RATE
    
    # 4. Tap Pruning (Optional)
    prune_stats = None
    if enable_pruning and phase == 'linear':  # Only prune linear phase (symmetric)
        taps_normalized, num_pruned, pruned_pct = prune_taps(taps_normalized, prune_threshold_db)
        prune_stats = (num_pruned, pruned_pct)
        # Renormalize after pruning to maintain unity gain
        taps_normalized = (taps_normalized / np.sum(taps_normalized)) * OVERSAMPLE_RATE
    
    # 5. Quantize to 18-bit Signed Integer
    max_val = (2**(COEF_BIT_WIDTH - 1)) - 1
    max_abs_tap = np.max(np.abs(taps_normalized))
    if max_abs_tap > 1e-9:
        scale_factor = max_val / max_abs_tap
        quantized_taps = np.round(taps_normalized * scale_factor).astype(int)
    else:
        quantized_taps = np.zeros(TOTAL_TAPS, dtype=int)
    
    # 6. Hardware Folding (Extract the 512K slice for the BRAMs)
    folded_taps = quantized_taps[0:STORED_TAPS]
    
    # Pad to exactly 524,288 (512K) to perfectly fill the QSPI memory blocks
    padded_taps = np.pad(folded_taps, (0, 524288 - len(folded_taps)), 'constant')
    
    return padded_taps, prune_stats

def export_to_bin(taps, filename):
    """ Writes a raw binary payload. Each 18-bit coef is padded to 32-bits (4 bytes) 
        for easy 32-bit SPI fetching by the ARM processor. """
    with open(filename, 'wb') as f:
        for coef in taps:
            # Pack as 32-bit signed integer (little-endian)
            f.write(struct.pack('<i', coef))

if __name__ == "__main__":
    out_dir = "dac_profiles"
    os.makedirs(out_dir, exist_ok=True)
    
    # Calculate total profiles: Kaiser + Gaussian variants
    total_profiles = len(CUTOFFS) * len(KAISER_BETAS) * len(PHASES)
    total_profiles += len(CUTOFFS) * len(GAUSSIAN_ALPHAS) * len(PHASES)
    
    print(f"--- Starting 1M-Tap Grid Search with Optimizations ---")
    print(f"Window Types: Kaiser, Gaussian")
    print(f"Tap Pruning: {PRUNE_THRESHOLD_DB} dB threshold")
    print(f"Targeting: {total_profiles} Total Profiles\n")
    
    total_start = time.time()
    
    # Kaiser Window Profiles
    print("=== Kaiser Window Profiles ===")
    for phase in PHASES:
        for cutoff in CUTOFFS:
            for beta in KAISER_BETAS:
                start_time = time.time()
                prune_tag = "pruned" if phase == 'linear' else "noprune"
                name = f"profile_kaiser_{phase}_fc{cutoff}_beta{beta}_{prune_tag}.bin"
                print(f"Computing {name}...")
                
                final_taps, prune_stats = generate_profile(
                    cutoff, beta, phase, window_type='kaiser', 
                    prune_threshold_db=PRUNE_THRESHOLD_DB,
                    enable_pruning=(phase == 'linear')
                )
                
                if prune_stats:
                    num_pruned, pruned_pct = prune_stats
                    print(f"  -> Pruned {num_pruned} taps ({pruned_pct:.1f}%)")
                
                export_to_bin(final_taps, os.path.join(out_dir, name))
                print(f"  -> Saved {len(final_taps)} padded taps. Took {time.time() - start_time:.2f}s")
    
    # Gaussian Window Profiles  
    print("\n=== Gaussian Window Profiles ===")
    for phase in PHASES:
        for cutoff in CUTOFFS:
            for alpha in GAUSSIAN_ALPHAS:
                start_time = time.time()
                prune_tag = "pruned" if phase == 'linear' else "noprune"
                name = f"profile_gaussian_{phase}_fc{cutoff}_alpha{alpha}_{prune_tag}.bin"
                print(f"Computing {name}...")
                
                final_taps, prune_stats = generate_profile(
                    cutoff, alpha, phase, window_type='gaussian',
                    prune_threshold_db=PRUNE_THRESHOLD_DB,
                    enable_pruning=(phase == 'linear')
                )
                
                if prune_stats:
                    num_pruned, pruned_pct = prune_stats
                    print(f"  -> Pruned {num_pruned} taps ({pruned_pct:.1f}%)")
                
                export_to_bin(final_taps, os.path.join(out_dir, name))
                print(f"  -> Saved {len(final_taps)} padded taps. Took {time.time() - start_time:.2f}s")
                
    print(f"\n--- Grid Search Complete in {time.time() - total_start:.2f} seconds ---")
    print(f"Flash these .bin files directly to your 32MB Winbond QSPI.")