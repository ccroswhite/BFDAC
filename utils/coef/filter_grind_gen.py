import numpy as np
from scipy import signal
import os
import struct
import time

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

# Sweeping Theta / Kaiser Beta (Smoothness dimension)
# 4.0 = Gentle/Warm, 14.0 = Surgical/dCS style
THETAS = [4.0, 8.0, 14.0, 20.0]  

# Phase types
PHASES = ['linear', 'minimum']

def generate_profile(cutoff, theta, phase):
    nyq = 0.5 * FS_OUT
    normalized_cutoff = cutoff / nyq
    
    # 1. Generate the Baseline Sinc + Kaiser Window
    taps = signal.firwin(TOTAL_TAPS, normalized_cutoff, window=('kaiser', theta), pass_zero='lowpass')
    
    # 2. Minimum Phase Conversion (Homomorphic)
    if phase == 'minimum':
        # Minimum phase destroys symmetry. To keep our folded DSP pre-adder happy, 
        # we still output it as a padded array to fit the engine, but the physical 
        # acoustic center shifts.
        taps = signal.minimum_phase(taps, method='homomorphic')
        
    # 3. Apply Interpolator Gain Correction
    # Since we are inserting 15 zeros between samples, we must scale the sum to 16, not 1.0.
    taps_normalized = (taps / np.sum(taps)) * OVERSAMPLE_RATE
    
    # 4. Quantize to 18-bit Signed Integer
    max_val = (2**(COEF_BIT_WIDTH - 1)) - 1
    quantized_taps = np.round(taps_normalized * max_val).astype(int)
    
    # 5. Hardware Folding (Extract the 512K slice for the BRAMs)
    # The FPGA will mirror this in real-time.
    folded_taps = quantized_taps[0:STORED_TAPS]
    
    # Pad to exactly 524,288 (512K) to perfectly fill the QSPI memory blocks
    padded_taps = np.pad(folded_taps, (0, 524288 - len(folded_taps)), 'constant')
    
    return padded_taps

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
    
    print(f"--- Starting 1M-Tap Grid Search ---")
    print(f"Targeting: {len(CUTOFFS) * len(THETAS) * len(PHASES)} Total Profiles\n")
    
    total_start = time.time()
    
    for phase in PHASES:
        for cutoff in CUTOFFS:
            for theta in THETAS:
                start_time = time.time()
                name = f"profile_{phase}_fc{cutoff}_th{theta}.bin"
                print(f"Computing {name}...")
                
                # Generate
                final_taps = generate_profile(cutoff, theta, phase)
                
                # Export to 3MB binary payload
                export_to_bin(final_taps, os.path.join(out_dir, name))
                
                print(f"  -> Saved {len(final_taps)} padded taps. Took {time.time() - start_time:.2f}s")
                
    print(f"\n--- Grid Search Complete in {time.time() - total_start:.2f} seconds ---")
    print(f"Flash these .bin files directly to your 32MB Winbond QSPI.")