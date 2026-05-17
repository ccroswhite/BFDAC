import numpy as np
import soundfile as sf
from scipy.signal import upfirdn, firls
import argparse
import time
import os

# --- Hardware Limits (Mirrors gen_coe_super.py) ---
UPSAMPLE_FACTOR = 81
FS_IN = 44100
FS_OUT = FS_IN * UPSAMPLE_FACTOR
NUM_TAPS = 1036800  # 1 million+ taps
BIT_DEPTH = 18

def apply_fft_fractional_delay(taps, delay_fraction):
    """Applies Chord-style sub-sample transient alignment."""
    print(f"Applying Ideal FFT fractional delay of {delay_fraction} samples...")
    TAPS_FFT = np.fft.rfft(taps)
    frequencies = np.fft.rfftfreq(len(taps))
    phase_shift = np.exp(-1j * 2 * np.pi * frequencies * delay_fraction)
    return np.fft.irfft(TAPS_FFT * phase_shift, n=len(taps))

def generate_hardware_coefficients(profile):
    """Generates the mathematically accurate, 18-bit quantized filter."""
    print(f"--- Generating {NUM_TAPS}-tap Filter: {profile.upper()} ---")
    
    if profile == 'dcs-chord-ideal':
        cutoff = 20500
        transition_width = 1500  
        bands = [0, cutoff, cutoff + transition_width, FS_OUT / 2]
        desired = [1, 0]
        weights = [1, 100] # Crush the noise floor
        print("1. Generating firls apodizing curve...")
        taps = firls(NUM_TAPS, bands, desired, weight=weights, fs=FS_OUT)
        print("2. Applying ideal transient phase shift...")
        taps = apply_fft_fractional_delay(taps, 0.5)
    else:
        raise ValueError("Only 'dcs-chord-ideal' is enabled for this test run.")
    
    # Apply Polyphase DC Gain Correction
    taps = taps * (UPSAMPLE_FACTOR / np.sum(taps))
    
    # Emulate the FPGA's 18-bit Two's Complement Quantization
    print(f"Quantizing to {BIT_DEPTH}-bit to mirror FPGA hardware...")
    max_val = (1 << (BIT_DEPTH - 1)) - 1
    scale_factor = max_val / np.max(np.abs(taps))
    taps_quantized = np.round(taps * scale_factor)
    
    # Return the floating point equivalent of the quantized hardware math
    return taps_quantized / scale_factor

def simulate_dac(input_file, output_file, profile):
    if not os.path.exists(input_file):
        print(f"Error: Could not find '{input_file}'")
        return

    # 1. Generate the true hardware coefficients
    taps = generate_hardware_coefficients(profile)

    # 2. Ingest the Pristine Audio
    print(f"\n--- Loading Audio: {input_file} ---")
    data, fs_in = sf.read(input_file)
    
    channels = data.shape[1] if len(data.shape) > 1 else 1
    if channels == 1:
        data = data.reshape(-1, 1)

    print(f"Input Rate: {fs_in} Hz | Channels: {channels}")
    
    # We decimate the 81x signal by 9 to export a 396.9 kHz high-res file. 
    # This prevents truncating the transient benefits when writing to disk.
    down_factor = 9
    fs_export = int((fs_in * UPSAMPLE_FACTOR) / down_factor)
    
    print(f"Upsampling by {UPSAMPLE_FACTOR}x, Filtering, and Decimating to {fs_export} Hz...")
    
    # 3. The Digital Twin Processing Engine
    # upfirdn handles the massive memory arrays efficiently in C
    start_time = time.time()
    
    # Initialize output array
    output_length = int(np.ceil(len(data) * UPSAMPLE_FACTOR / down_factor))
    simulated_audio = np.zeros((output_length, channels))
    
    for c in range(channels):
        print(f" Processing Channel {c+1}/{channels} (This may take a few minutes)...")
        # Process the full stream: Upsample by 81, apply 1M taps, downsample by 9
        filtered_channel = upfirdn(taps, data[:, c], up=UPSAMPLE_FACTOR, down=down_factor)
        
        # Trim the filter delay tail to match output length
        simulated_audio[:, c] = filtered_channel[:output_length]
    
    # 4. Normalize for Playback
    print("Normalizing to 0dBFS to prevent digital clipping...")
    max_val = np.max(np.abs(simulated_audio))
    if max_val > 0:
        simulated_audio = simulated_audio / max_val

    # 5. Export as an Ultra-High-Res 24-bit FLAC
    print(f"Exporting mathematical twin to '{output_file}'...")
    sf.write(output_file, simulated_audio, fs_export, format='FLAC', subtype='PCM_24')
    
    print(f"Simulation Complete in {time.time() - start_time:.2f} seconds.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="DAC Digital Twin Simulator")
    parser.add_argument('--input', type=str, required=True, help="Input raw FLAC/WAV file")
    parser.add_argument('--output', type=str, default="simulated_twin_output.flac", help="Output FLAC file")
    parser.add_argument('--profile', type=str, default='dcs-chord-ideal', help="Acoustic profile to generate")
    args = parser.parse_args()

    simulate_dac(args.input, args.output, args.profile)
