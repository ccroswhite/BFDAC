import numpy as np
import matplotlib.pyplot as plt
from scipy.fft import fft, fftfreq

# 1. Load the data
filename = 'dsp_output.txt'
try:
    # Read the first column (dem_drive_command amplitude)
    data = np.loadtxt(filename, delimiter=',', usecols=0)
except FileNotFoundError:
    print(f"Error: {filename} not found. Run the Vivado simulation first.")
    exit()

# 2. Parameters
# Interpolated sample rate = 44.1kHz * 16x oversampling (assuming 16x for your FIR)
fs = 44100 * 16  
N = len(data)

# 3. Apply Blackman-Harris Window to reduce leakage
window = np.blackman(N)
windowed_data = data * window

# 4. Perform FFT
yf = fft(windowed_data)
xf = fftfreq(N, 1 / fs)[:N//2]

# Convert magnitude to dB
magnitude = 2.0/N * np.abs(yf[0:N//2])
# Avoid log(0)
magnitude = np.maximum(magnitude, 1e-12) 
magnitude_db = 20 * np.log10(magnitude)

# 5. Plot the Spectrum
plt.figure(figsize=(10, 6))
plt.plot(xf, magnitude_db, color='blue', linewidth=1)
plt.title('DAC DSP Pipeline - Frequency Spectrum (Noise Shaper Output)')
plt.xlabel('Frequency (Hz)')
plt.ylabel('Magnitude (dBFS)')
plt.grid(True, which="both", ls="-", alpha=0.5)
plt.xscale('log')
plt.xlim([20, fs/2])
plt.ylim([-150, 10])

# Highlight the audio band
plt.axvspan(20, 20000, color='green', alpha=0.1, label='Audio Band (20Hz-20kHz)')
plt.legend()
plt.tight_layout()
plt.show()