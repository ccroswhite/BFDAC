import numpy as np
import random

# --- System Parameters (Matching your SystemVerilog) ---
FRAC_WIDTH = 42
OUT_WIDTH = 9
MAX_LEVEL = 256
CENTER_OFFSET = 128
CLAMP_OFFSET = MAX_LEVEL << FRAC_WIDTH

# Test Vector Parameters
NUM_SAMPLES = 100000  # Generate 100k samples for the testbench
SINE_FREQ = 1000.0    # 1 kHz test tone
SAMPLE_RATE = 3571400 # Over-sampled 3.57 MHz rate

def generate_golden_vectors():
    # 1. Generate Pure Sine Wave (Scaled to 48-bit input equivalent)
    t = np.arange(NUM_SAMPLES) / SAMPLE_RATE
    # Scale to roughly 90% of full scale to avoid clipping the modulator bounds
    amplitude = int((0.9 * CENTER_OFFSET) * (1 << FRAC_WIDTH))
    audio_in = (amplitude * np.sin(2 * np.pi * SINE_FREQ * t)).astype(np.int64)

    # 2. State Variables for the 5th-Order Delay Line
    e_z1, e_z2, e_z3, e_z4, e_z5 = 0, 0, 0, 0, 0

    # 3. Open file to write Hex vectors for SystemVerilog
    with open("golden_vectors.txt", "w") as f:
        
        for i in range(NUM_SAMPLES):
            # --- A. Grab Data and Generate TPDF Dither ---
            data_in = int(audio_in[i])
            
            # TPDF is the sum of two uniform random variables.
            # Using Python's native random avoids numpy's 32-bit C-integer overflow on Windows.
            dither_1 = random.randint(-(1 << (FRAC_WIDTH-1)), (1 << (FRAC_WIDTH-1)) - 1)
            dither_2 = random.randint(-(1 << (FRAC_WIDTH-1)), (1 << (FRAC_WIDTH-1)) - 1)
            dither_in = dither_1 + dither_2

            # --- B. DC Offset ---
            # Shift AC audio to DC Offset (so negative troughs hit 0, center is 128)
            offset_audio = data_in + (CENTER_OFFSET << FRAC_WIDTH)

            # --- C. The 5th-Order Math (Exact integer replication of the RTL) ---
            t1 = (e_z1 * 5)
            t2 = (e_z2 * 10)
            t3 = (e_z3 * 10)
            t4 = (e_z4 * 5)
            
            sum_pos_1 = offset_audio + t1
            sum_pos_2 = t3 + e_z5
            sum_neg   = t2 + t4
            
            noise_shaped_audio = (sum_pos_1 + sum_pos_2) - sum_neg
            dithered_audio = noise_shaped_audio + dither_in

            # --- D. Quantizer & Hard Limiting ---
            # Protecting the physical 256-resistor array bounds
            if dithered_audio > CLAMP_OFFSET:
                dem_drive_out = MAX_LEVEL
                e_z0 = noise_shaped_audio - CLAMP_OFFSET
            elif dithered_audio < 0:
                dem_drive_out = 0
                e_z0 = noise_shaped_audio
            else:
                # Safe Truncation
                dem_drive_out = dithered_audio >> FRAC_WIDTH
                # Track the true error: Pure Target - Physical Output
                e_z0 = noise_shaped_audio - (dem_drive_out << FRAC_WIDTH)

            # --- E. Shift the delay line ---
            e_z5 = e_z4
            e_z4 = e_z3
            e_z3 = e_z2
            e_z2 = e_z1
            e_z1 = e_z0

            # --- F. Hex Formatting for SystemVerilog ---
            # Apply a bitmask to simulate Two's Complement for the SV $fscanf to read cleanly
            mask_64b = (1 << 64) - 1
            mask_dither = (1 << (FRAC_WIDTH + 1)) - 1 # Dither is a signed signal

            hex_data_in = format(data_in & mask_64b, '016X')
            hex_dither  = format(dither_in & mask_dither, '011X')
            hex_out     = format(dem_drive_out, '03X')

            # Write row: DATA_IN  DITHER_IN  EXPECTED_OUT
            f.write(f"{hex_data_in} {hex_dither} {hex_out}\n")

    print(f"Successfully generated {NUM_SAMPLES} golden vectors in 'golden_vectors.txt'")

if __name__ == "__main__":
    generate_golden_vectors()