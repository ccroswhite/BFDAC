"""
gen_fir_coefs.py — Generate FIR coefficients and expected FIR output for tb_dsp_core.

RTL FIR architecture (true polyphase interpolation):
  256 MACs, audio preload fills audio_shreg[m] = x[n-m] at new_sample_valid.
  During the 2048-cycle coef sweep, each MAC m receives x[n-m] as a static input.
  16 phase windows of 128 cycles each. Phase p → coef_addr in [p*128 .. p*128+127].

  Each MAC m accumulates: x[n-m] * sum_{t=0}^{127} coef[m][p*128+t]
  Only t=0 is loaded non-zero, so: sum_t = coef[m][p*128+0] = h_q[p + m*16].

  Phase p output (shadow_acc[p]):
    y[n*16 + p] = 2 * sum_{m=0}^{255} h_q[p + m*16] * x[n-m]
  Factor of 2: pre-adder computes dsp_adreg = audio_in + audio_in = 2*x[n-m].

  Prototype filter: 4096 taps (256 MACs × 16 phases).
  Coef loading:  mac=m, addr=p*128+0, data=h_q[p + m*16]  for m=0..255, p=0..15.

Outputs:
  fir_coefs.txt      — coef writes: "mac addr data_q117" per line (4096 entries)
  fir_audio_in.txt   — audio input: "idx sample24" per line
  fir_golden.txt     — expected fir_l_reg: "output_idx acc48_signed" per line
"""

import math
import os

# =============================================================================
# Parameters
# =============================================================================
NUM_MACS       = 128
NUM_PHASES     = 16       # L (interpolation factor)
TAPS_PER_WIN   = 256      # coef_addr slots per phase window
COEF_SCALE     = 1 << 17  # Q1.17
NUM_IN_SAMPLES = 32       # input samples to drive
NUM_OUT        = NUM_IN_SAMPLES * NUM_PHASES   # 512 output samples
SWEEP_LEN      = NUM_PHASES * TAPS_PER_WIN    # 4096 sweep cycles

ACTIVE_MACS    = NUM_MACS            # all 128 MACs used
PROTO_LEN      = NUM_MACS * NUM_PHASES   # 2048-tap prototype filter

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
XILINX_DIR  = os.path.join(SCRIPT_DIR, "..", "Xilinx")
COEF_FILE   = os.path.join(XILINX_DIR, "fir_coefs.txt")
AUDIO_FILE  = os.path.join(XILINX_DIR, "fir_audio_in.txt")
GOLDEN_FILE = os.path.join(XILINX_DIR, "fir_golden.txt")

# =============================================================================
# Kaiser-windowed sinc prototype lowpass, length PROTO_LEN
# Cutoff = 1/L of output Nyquist = input Nyquist
# =============================================================================
def besseli0(x):
    s, term, k = 1.0, 1.0, 1
    while True:
        term *= (x / (2 * k)) ** 2
        s += term
        k += 1
        if term < 1e-12 * s:
            break
    return s

def gen_prototype(N, L, beta=7.0):
    """
    N-tap Kaiser-windowed sinc prototype.
    Cutoff normalized to 1/L of output Nyquist (= input Nyquist).
    Scaled so sum(h) = L (unity DC gain after polyphase recombination).
    """
    cutoff = 1.0 / L        # normalized: 1.0 = output Nyquist
    mid    = (N - 1) / 2.0
    i0b    = besseli0(beta)
    h = []
    for n in range(N):
        t = n - mid
        sinc = 1.0 if abs(t) < 1e-10 else math.sin(math.pi * cutoff * t) / (math.pi * cutoff * t)
        arg  = beta * math.sqrt(max(0.0, 1.0 - ((n - mid) / mid) ** 2))
        win  = besseli0(arg) / i0b
        h.append(sinc * win * cutoff)
    # Normalize so sum = L (each phase has unity DC gain)
    s = sum(h)
    h = [v * L / s for v in h]
    return h

def q117(v):
    q = int(round(v * COEF_SCALE))
    return max(-COEF_SCALE, min(COEF_SCALE - 1, q))

# =============================================================================
# Audio: two-tone sine, 24-bit signed
# =============================================================================
def gen_audio(n):
    amp = int((2**23 - 1) * 0.45)
    out = []
    for i in range(n):
        t   = i / 44100.0
        val = amp * math.sin(2 * math.pi * 1000.0 * t) + \
              amp * math.sin(2 * math.pi * 5000.0 * t)
        out.append(max(-(2**23), min(2**23 - 1, int(round(val)))))
    return out

# =============================================================================
# Main
# =============================================================================
def main():
    # --- Prototype filter ---
    h = gen_prototype(PROTO_LEN, NUM_PHASES)  # 4096-tap prototype
    h_q = [q117(v) for v in h]
    print(f"Prototype: {PROTO_LEN} taps, sum={sum(h):.4f}, max_q={max(h_q)}, min_q={min(h_q)}")

    # --- Coefficient file ---
    # Polyphase decomposition: h_p[m] = h[p + m*L]   (p=phase, m=MAC, L=NUM_PHASES=16)
    # Prototype filter: 4096 taps (PROTO_LEN = NUM_MACS * NUM_PHASES).
    # Loading: coef[m][p*TAPS_PER_WIN + 0] = h_q[p + m*NUM_PHASES]
    # (All other t-slots for that MAC/phase are zero; sum_t = just t=0.)
    coef_lines = []
    for m in range(NUM_MACS):
        for p in range(NUM_PHASES):
            tap_idx = p + m * NUM_PHASES          # index into 4096-tap prototype h
            val     = h_q[tap_idx]
            addr    = p * TAPS_PER_WIN + 0        # slot 0 of each phase window
            coef_lines.append(f"{m} {addr} {val}")
    with open(COEF_FILE, "w") as f:
        f.write("\n".join(coef_lines) + "\n")
    print(f"Written {len(coef_lines)} coef entries ({NUM_MACS} MACs × {NUM_PHASES} phases) → {COEF_FILE}")

    # --- Audio (32 input samples → 512 FIR outputs) ---
    audio = gen_audio(NUM_IN_SAMPLES)
    with open(AUDIO_FILE, "w") as f:
        for i, s in enumerate(audio):
            f.write(f"{i} {s}\n")
    print(f"Written {NUM_IN_SAMPLES} audio samples → {AUDIO_FILE}")

    # --- Golden FIR output via cycle-accurate model ---
    # Use fir_rtl_model.run_simulation() to generate bit-exact golden values
    # matching what the RTL actually outputs (including pipeline latency).
    # warm_cycles=0: model starts fresh, no TB warm-up needed — the testbench
    # captures from the first interpolated_valid after the stimulus starts.
    import sys
    sys.path.insert(0, SCRIPT_DIR)
    from fir_rtl_model import run_simulation
    SAMPLE_CLKS = 8163
    golden_vals = run_simulation(COEF_FILE, audio,
                                 n_capture=NUM_OUT,
                                 warm_cycles=0)
    golden_lines = []
    for i, v in enumerate(golden_vals):
        golden_lines.append(f"{i} {v}")
    with open(GOLDEN_FILE, "w") as f:
        f.write("\n".join(golden_lines) + "\n")
    print(f"Written {len(golden_lines)} golden values (from model) → {GOLDEN_FILE}")

    nonzero = sum(1 for line in golden_lines if int(line.split()[1]) != 0)
    print(f"Non-zero outputs: {nonzero}/{len(golden_lines)}")
    print("First 20 golden values:")
    for line in golden_lines[:20]:
        print(f"  {line}")

if __name__ == "__main__":
    main()
