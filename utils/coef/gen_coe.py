import numpy as np
from scipy.signal import firwin, minimum_phase
import argparse

# The 357 MHz Systolic Architecture Limits
UPSAMPLE_FACTOR = 81
CYCLES_PER_SAMPLE = 100 
DSP_SLICES = 128

TAPS_PER_PHASE = CYCLES_PER_SAMPLE * DSP_SLICES
NUM_TAPS = TAPS_PER_PHASE * UPSAMPLE_FACTOR # 1,036,800 Taps!
HALF_TAPS = NUM_TAPS // 2 # Symmetry fold for BRAM limits

BIT_DEPTH = 18
FS_IN = 44100
FS_OUT = FS_IN * UPSAMPLE_FACTOR

def generate_megafilter(flavor):
    print(f"Generating {NUM_TAPS}-tap FIR filter ({FS_OUT / 1e6:.3f} MHz Output)...")

    if flavor == 'chord':
        print("Flavor: CHORD (Linear Phase, Transient Aligned)")
        taps = firwin(NUM_TAPS, 20000, fs=FS_OUT, window='blackmanharris')
        
    elif flavor == 'msb':
        print("Flavor: MSB (Minimum Phase, Zero Pre-Ringing)")
        base_taps = firwin(NUM_TAPS, 20000, fs=FS_OUT, window='hann')
        taps = minimum_phase(base_taps, method='hilbert')
        
    elif flavor == 'dcs':
        print("Flavor: dCS (Apodizing, Relaxed Kaiser)")
        taps = firwin(NUM_TAPS, 18500, fs=FS_OUT, window=('kaiser', 8.0))
        
    else:
        raise ValueError("Invalid flavor.")

    # Polyphase DC Gain Correction
    taps = taps * (UPSAMPLE_FACTOR / np.sum(taps))

    # Scale to 18-bit Two's Complement
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    scale_factor = max_val / np.max(np.abs(taps))
    taps_quantized = np.round(taps * scale_factor).astype(int)

    # ---------------------------------------------------------------------
    # THE TRUE DUAL-PORT SHARDING ALGORITHM
    # ---------------------------------------------------------------------
    # Generate 64 individual .mem files tagged with the flavor
    for i in range(64): 
        filename = f"shard_{i:02d}_{flavor}.mem"
        
        with open(filename, "w") as f:
            for c in range(CYCLES_PER_SAMPLE): 
                for p in range(UPSAMPLE_FACTOR): 
                    global_idx = (c * DSP_SLICES * UPSAMPLE_FACTOR) + p + (i * UPSAMPLE_FACTOR)
                    val = taps_quantized[global_idx]
                    
                    if val < 0:
                        val = (1 << BIT_DEPTH) + val
                        
                    f.write(f"{val:05X}\n")

    print(f"Success! {HALF_TAPS} sharded coefficients written to shard_00_{flavor}.mem through shard_63_{flavor}.mem")
    print(f"Memory Footprint: {(HALF_TAPS * 18) / 1048576:.2f} Megabits (Fits in ~256 XC7A200T BRAMs)")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--flavor', type=str, choices=['chord', 'msb', 'dcs'], required=True)
    args = parser.parse_args()
    generate_megafilter(args.flavor)