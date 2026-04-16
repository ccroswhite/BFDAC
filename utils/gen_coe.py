import numpy as np
from scipy import signal
import time

def generate_dac_filter(num_taps, fs_out, cutoff, window='blackmanharris', phase='linear'):
    """
    Generates low-pass FIR filter coefficients for audio oversampling.
    """
    # 1. Normalize the cutoff frequency to the Nyquist limit (0.5 * fs)
    nyq = 0.5 * fs_out
    normalized_cutoff = cutoff / nyq

    # Type I FIR filters (linear phase, integer delay) require an odd number of taps.
    if num_taps % 2 == 0:
        num_taps += 1

    print(f"--> Generating {num_taps}-tap '{window}' windowed FIR...")
    start_time = time.time()
    
    # 2. Generate the Linear Phase filter (The Sinc function + Window)
    taps = signal.firwin(num_taps, normalized_cutoff, window=window, pass_zero='lowpass')
    
    # 3. Convert to Minimum Phase (dCS style tuning)
    if phase == 'minimum':
        print("--> Converting to Minimum Phase (this requires heavy computation)...")
        # 'homomorphic' method is generally required for massive tap counts
        taps = signal.minimum_phase(taps, method='homomorphic')
        
    print(f"--> Computation finished in {time.time() - start_time:.2f} seconds.")
    return taps

def export_to_xilinx_coe(taps, filename="filter.coe", bit_width=18):
    """
    Quantizes floating-point coefficients and writes a Vivado-compatible .coe file.
    """
    # Quantize to fit inside the DSP48E1 18-bit coefficient register
    # We use (bit_width - 1) for the signed magnitude.
    max_val = (2**(bit_width - 1)) - 1
    
    # Normalize the taps so the peak is exactly 1.0 before scaling
    # This ensures unity gain at DC (0 Hz)
    taps_normalized = taps / np.sum(taps)
    
    quantized_taps = np.round(taps_normalized * max_val).astype(int)

    print(f"--> Exporting to {filename}...")
    with open(filename, 'w') as f:
        f.write("; Xilinx FIR Filter Coefficients\n")
        f.write(f"; Taps: {len(taps)}\n")
        f.write("; Radix: 10 (Decimal)\n")
        f.write("radix=10;\n")
        f.write("coefdata=\n")
        
        for i, coef in enumerate(quantized_taps):
            if i == len(quantized_taps) - 1:
                f.write(f"{coef};\n") # Last entry gets a semicolon
            else:
                f.write(f"{coef},\n") # Others get a comma

if __name__ == "__main__":
    # --- System Parameters ---
    FS_BASE = 44100
    OVERSAMPLE_RATE = 16
    FS_OUT = FS_BASE * OVERSAMPLE_RATE # 705.6 kHz
    CUTOFF_FREQ = 20000                # 20 kHz audio band
    COEF_BIT_WIDTH = 18                # Matches fir_polyphase_interpolator.sv
    
    # --- Warning on 1M Taps ---
    # Generating 1,000,000 taps in Python is memory intensive. 
    # Minimum phase conversion for 1M taps can take hours. 
    # We are using 65,537 taps here for rapid testing.
    TAPS = 65537 

    # Profile 1: The "Chord" Style (Linear Phase, Massive stopband attenuation)
    print("\n--- Building Profile 1: Linear Phase / Blackman-Harris ---")
    taps_linear = generate_dac_filter(TAPS, FS_OUT, CUTOFF_FREQ, window='blackmanharris', phase='linear')
    export_to_xilinx_coe(taps_linear, "coef_linear_blackman.coe", COEF_BIT_WIDTH)

    # Profile 2: The "dCS" Style (Minimum Phase, Analog warmth)
    print("\n--- Building Profile 2: Minimum Phase / Hann ---")
    taps_minimum = generate_dac_filter(TAPS, FS_OUT, CUTOFF_FREQ, window='hann', phase='minimum')
    export_to_xilinx_coe(taps_minimum, "coef_minimum_hann.coe", COEF_BIT_WIDTH)
    
    print("\nDone. COE files are ready to be loaded into Vivado BRAM.")