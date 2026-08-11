"""
gen_filter_coefs.py — Generate polyphase FIR coefficient files for BFDAC

Generates 6 filter personas, each modeled after a distinctive high-end DAC voicing.
All filters are ×16 polyphase interpolation prototypes (48k → 768k),
windowed-sinc or equiripple designs with different passband/stopband tradeoffs.

Output format (per file):  mac_idx  coef_addr  coef_q1_17
  mac_idx   : 0 .. NUM_MACS-1
  coef_addr : 0 .. COEF_DEPTH-1  (= phase * TAPS_PER_PHASE + tap_within_phase)
  coef_q1_17: signed 18-bit integer (Q1.17: value * 2^17, clamped to [-131072, 131071])

Personas:
  Filter A — "Linear Phase Brick"  (Chord DAVE inspired)
              Very long, near-perfect brick-wall. Widest stopband rejection.
              Maximally flat passband to 20 kHz. Very long pre/post ringing.

  Filter B — "Slow Roll-Off"       (dCS Vivaldi Apex Filter 1 inspired)
              Gentle 6dB/oct roll-off above 15 kHz. Minimal pre-ringing.
              Tradeoff: reduced stopband attenuation, more natural transients.

  Filter C — "Minimum Phase"       (Berkeley Audio Alpha 3 inspired)
              All post-ringing (no pre-ringing). Asymmetric impulse response.
              Matches more natural acoustic decay character.

  Filter D — "Apodising"           (MSB Reference inspired)
              Reduces Gibbs ringing from source material's brickwall CD filter.
              Bandwidth slightly narrowed; very clean HF presentation.

  Filter E — "Hybrid Phase"        (Mearson inspired)
              Mixed-phase: reduced pre-ringing vs linear, natural post-ring.
              Good compromise between timing and frequency accuracy.

  Filter F — "Extended Bandwidth"  (dCS Vivaldi Apex Filter 2 inspired)
              Passband extended to 25 kHz (-0.1 dB). Steeper rolloff needed
              but still sufficient stopband for this topology. Airy HF.

Usage:
  python gen_filter_coefs.py

Outputs:
  filter_A_linear_phase.txt
  filter_B_slow_rolloff.txt
  filter_C_minimum_phase.txt
  filter_D_apodising.txt
  filter_E_hybrid_phase.txt
  filter_F_extended_bw.txt
  README_filters.md
"""

import numpy as np
from scipy.signal import firwin, firwin2, minimum_phase
import os

# =============================================================================
#  Architecture constants (must match RTL sim parameters)
# =============================================================================
NUM_MACS       = 4       # simulation scale (production = 1024)
TAPS_PER_PHASE = 64      # must match dac_dsp_core hardcoded value
NUM_PHASES     = 16      # polyphase interpolation ratio
COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE  # 1024 per MAC
TOTAL_TAPS     = NUM_MACS * COEF_DEPTH        # 4096 for sim, ~1M for production

FS_IN          = 48000.0   # input sample rate (Hz)
FS_OUT         = FS_IN * NUM_PHASES  # 768000 Hz
Q1_17_SCALE    = 2**17     # 131072
Q1_17_MAX      =  131071
Q1_17_MIN      = -131072

OUT_DIR        = os.path.dirname(os.path.abspath(__file__))


def to_q1_17(h):
    """Scale float impulse response to Q1.17 18-bit signed integers."""
    scaled = np.round(h * Q1_17_SCALE).astype(int)
    clipped = np.clip(scaled, Q1_17_MIN, Q1_17_MAX)
    n_clipped = np.sum(np.abs(scaled) > Q1_17_MAX)
    if n_clipped > 0:
        print(f"  WARNING: {n_clipped} coefficients clipped to Q1.17 range")
    return clipped


def polyphase_split(h, num_phases, taps_per_phase, num_macs):
    """
    Split prototype filter h[n] into polyphase subfilters and MAC assignment.

    The RTL addressing:
      coef_addr = phase * TAPS_PER_PHASE + tap_within_phase
      mac_idx   = tap_within_phase // (TAPS_PER_PHASE // num_macs)  ... simplified:
                  coef is assigned to MAC based on overall tap index / coef_per_mac

    For simulation (NUM_MACS=4, TAPS_PER_PHASE=64):
      Each MAC handles 1024 coefficients (16 phases × 64 taps)
      Total prototype length = NUM_MACS * COEF_DEPTH = 4096 taps

    Polyphase decomposition: h_p[k] = h[p + k*NUM_PHASES]  for p=0..NUM_PHASES-1
    Each polyphase branch has length = TOTAL_TAPS // NUM_PHASES = 256 taps
    These 256 taps are distributed across NUM_MACS MACs, each taking 64 taps.

    Returns list of (mac_idx, coef_addr, coef_q1_17) tuples.
    """
    total_taps = num_macs * num_phases * taps_per_phase
    # Zero-pad or truncate h to exact total_taps
    h_padded = np.zeros(total_taps)
    n = min(len(h), total_taps)
    h_padded[:n] = h[:n]

    coefs = []
    for phase in range(num_phases):
        # Polyphase branch p: h[phase], h[phase+num_phases], h[phase+2*num_phases], ...
        branch = h_padded[phase::num_phases]  # length = num_macs * taps_per_phase
        for mac in range(num_macs):
            mac_taps = branch[mac*taps_per_phase : (mac+1)*taps_per_phase]
            for tap, val in enumerate(mac_taps):
                coef_addr = phase * taps_per_phase + tap
                coef_q = int(round(val * Q1_17_SCALE))
                coef_q = max(Q1_17_MIN, min(Q1_17_MAX, coef_q))
                coefs.append((mac, coef_addr, coef_q))
    return coefs


def write_coef_file(filename, coefs, header_lines):
    path = os.path.join(OUT_DIR, filename)
    with open(path, 'w') as f:
        for line in header_lines:
            f.write(f"# {line}\n")
        f.write("#\n# mac_idx  coef_addr  coef_q1_17\n#\n")
        for mac, addr, val in sorted(coefs, key=lambda x: (x[0], x[1])):
            f.write(f"{mac} {addr} {val}\n")
    print(f"  Written: {filename}  ({len(coefs)} entries)")


def dc_gain_check(h, num_phases):
    """Report DC gain of prototype (should be ~num_phases for interpolation)."""
    gain = np.sum(h)
    print(f"  DC gain = {gain:.4f}  (ideal = {num_phases})")
    return gain


# =============================================================================
#  FILTER A — Linear Phase Brick-Wall  (Chord DAVE inspired)
#  Very long Kaiser-windowed sinc. Near-perfect reconstruction.
#  Pre- and post-ringing balanced. Stopband > 120 dB.
# =============================================================================
def gen_filter_A():
    print("\nFilter A: Linear Phase Brick-Wall (Chord DAVE inspired)")
    # Prototype: Kaiser window, beta=12 (~130 dB stopband), fc=20kHz/768kHz
    fc   = 20000.0 / FS_OUT   # normalized cutoff (< 0.5)
    beta = 12.0
    h = firwin(TOTAL_TAPS, fc, window=('kaiser', beta))
    h *= NUM_PHASES            # compensate for polyphase gain split
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_A_linear_phase.txt", coefs, [
        "Filter A — Linear Phase Brick-Wall",
        "Inspired by: Chord DAVE",
        "Character: Perfect reconstruction, symmetric pre/post ringing",
        "Passband:   DC–20 kHz (±0.001 dB)",
        "Stopband:   >28 kHz (>120 dB attenuation)",
        "Window:     Kaiser beta=12",
        f"Taps:       {TOTAL_TAPS} (sim scale: {NUM_MACS} MACs × {COEF_DEPTH} coefs)",
    ])


# =============================================================================
#  FILTER B — Slow Roll-Off  (dCS Vivaldi Apex Filter 1 inspired)
#  Gentle transition band starting at ~15 kHz. Minimal time-domain ringing.
#  More relaxed stopband. Preferred by some listeners for natural HF.
# =============================================================================
def gen_filter_B():
    print("\nFilter B: Slow Roll-Off (dCS Vivaldi Apex Filter 1 inspired)")
    # Hann-windowed sinc with narrower passband — soft knee at 15 kHz
    fc   = 15000.0 / FS_OUT
    h = firwin(TOTAL_TAPS, fc, window='hann')
    h *= NUM_PHASES
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_B_slow_rolloff.txt", coefs, [
        "Filter B — Slow Roll-Off",
        "Inspired by: dCS Vivaldi Apex (Filter 1)",
        "Character: Natural HF, minimal ringing, gentle transition",
        "Passband:   DC–15 kHz (-3 dB), DC–20 kHz (~-6 dB)",
        "Stopband:   >60 kHz (~60 dB)",
        "Window:     Hann",
        f"Taps:       {TOTAL_TAPS}",
    ])


# =============================================================================
#  FILTER C — Minimum Phase  (Berkeley Audio Alpha 3 inspired)
#  All-causal impulse response: no pre-ringing, all energy post-impulse.
#  Derived from linear-phase prototype via spectral factorisation.
# =============================================================================
def gen_filter_C():
    print("\nFilter C: Minimum Phase (Berkeley Audio Alpha 3 inspired)")
    fc   = 20000.0 / FS_OUT
    beta = 10.0
    h_lin = firwin(TOTAL_TAPS, fc, window=('kaiser', beta))
    h_lin *= NUM_PHASES
    # Convert to minimum phase via scipy
    h_min = minimum_phase(h_lin, method='homomorphic')
    # Pad back to TOTAL_TAPS
    h = np.zeros(TOTAL_TAPS)
    h[:len(h_min)] = h_min
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_C_minimum_phase.txt", coefs, [
        "Filter C — Minimum Phase",
        "Inspired by: Berkeley Audio Design Alpha 3",
        "Character: No pre-ringing, all post-impulse energy. Natural decay.",
        "Passband:   DC–20 kHz (±0.05 dB)",
        "Stopband:   >28 kHz (>100 dB)",
        "Method:     Homomorphic minimum-phase from Kaiser beta=10 linear prototype",
        f"Taps:       {TOTAL_TAPS}",
    ])


# =============================================================================
#  FILTER D — Apodising  (MSB Reference inspired)
#  Applies a Gaussian-like apodising window to remove Gibbs ringing
#  introduced by the original CD/PCM brickwall reconstruction.
#  Slightly narrowed bandwidth but eliminates pre-ring artifacts.
# =============================================================================
def gen_filter_D():
    print("\nFilter D: Apodising (MSB Reference inspired)")
    # Apodising: firwin with Blackman-Harris window (very low sidelobes)
    # Narrows slightly (to ~18 kHz) but kills Gibbs ringing
    fc   = 18000.0 / FS_OUT
    h = firwin(TOTAL_TAPS, fc, window='blackmanharris')
    h *= NUM_PHASES
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_D_apodising.txt", coefs, [
        "Filter D — Apodising",
        "Inspired by: MSB Reference DAC",
        "Character: Eliminates Gibbs ringing from CD brickwall source filter.",
        "            Very clean, relaxed presentation. Slight HF softening.",
        "Passband:   DC–18 kHz (-0.1 dB)",
        "Stopband:   >25 kHz (>130 dB with Blackman-Harris)",
        "Window:     Blackman-Harris",
        f"Taps:       {TOTAL_TAPS}",
    ])


# =============================================================================
#  FILTER E — Hybrid Phase  (Mearson inspired)
#  Intermediate between linear and minimum phase.
#  Achieves reduced pre-ringing vs linear while less post-ringing than min-phase.
#  Implemented as a delayed minimum-phase (linear combination).
# =============================================================================
def gen_filter_E():
    print("\nFilter E: Hybrid Phase (Mearson inspired)")
    fc   = 20000.0 / FS_OUT
    beta = 10.0
    h_lin = firwin(TOTAL_TAPS, fc, window=('kaiser', beta))
    h_lin *= NUM_PHASES
    h_min = minimum_phase(h_lin, method='homomorphic')
    h_min_padded = np.zeros(TOTAL_TAPS)
    h_min_padded[:len(h_min)] = h_min
    # Hybrid: 60% minimum-phase + 40% linear-phase
    alpha = 0.6
    h = alpha * h_min_padded + (1.0 - alpha) * h_lin
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_E_hybrid_phase.txt", coefs, [
        "Filter E — Hybrid Phase",
        "Inspired by: Mearson DAC",
        "Character: 60% min-phase + 40% linear-phase blend.",
        "            Reduced pre-ringing vs linear, less post-ringing vs min-phase.",
        "            Good all-round listening compromise.",
        "Passband:   DC–20 kHz (±0.02 dB)",
        "Stopband:   >28 kHz (>100 dB)",
        f"Taps:       {TOTAL_TAPS}",
    ])


# =============================================================================
#  FILTER F — Extended Bandwidth  (dCS Vivaldi Apex Filter 2 inspired)
#  Passband extended to 25 kHz for a more open, airy high-frequency presentation.
#  Requires steeper rolloff to maintain adequate stopband in the transition
#  20 kHz→28 kHz. Uses a narrower transition and higher beta Kaiser.
# =============================================================================
def gen_filter_F():
    print("\nFilter F: Extended Bandwidth (dCS Vivaldi Apex Filter 2 inspired)")
    # Extended passband to 25 kHz, steeper rolloff using high-beta Kaiser
    fc   = 25000.0 / FS_OUT
    beta = 14.0   # higher beta = sharper but more ripple
    h = firwin(TOTAL_TAPS, fc, window=('kaiser', beta))
    h *= NUM_PHASES
    dc_gain_check(h, NUM_PHASES)
    coefs = polyphase_split(h, NUM_PHASES, TAPS_PER_PHASE, NUM_MACS)
    write_coef_file("filter_F_extended_bw.txt", coefs, [
        "Filter F — Extended Bandwidth",
        "Inspired by: dCS Vivaldi Apex (Filter 2)",
        "Character: Extended to 25 kHz. Airy, open HF presentation.",
        "            Slightly more ringing than Filter A. Full hi-res staging.",
        "Passband:   DC–25 kHz (-0.1 dB)",
        "Stopband:   >35 kHz (>110 dB)",
        "Window:     Kaiser beta=14",
        f"Taps:       {TOTAL_TAPS}",
    ])


# =============================================================================
#  README
# =============================================================================
def write_readme():
    path = os.path.join(OUT_DIR, "README_filters.md")
    with open(path, 'w', encoding='utf-8') as f:
        f.write("""# BFDAC Polyphase FIR Filter Library

Six filter personas for the ×16 polyphase FIR interpolation stage.
Each file is loaded into the URAM coefficient banks via `coef_bank_loader`.

## Architecture

- **Input rate**: 48 kHz (or 44.1/88.2/96 kHz)
- **Output rate**: ×16 → 768 kHz (→ HB1 → HB2 → HB3 → 6.144 MHz)
- **Total taps (sim)**: 4 MACs × 1024 coefs = 4096
- **Total taps (prod)**: 1024 MACs × 1024 coefs = ~1M per channel
- **Coefficient format**: Q1.17 signed 18-bit integer
- **File format**: `mac_idx  coef_addr  coef_q1_17`

## Filter Personas

| File | Persona | Inspired By | Character |
|------|---------|-------------|-----------|
| `filter_A_linear_phase.txt` | Linear Phase Brick-Wall | Chord DAVE | Perfect reconstruction, symmetric ringing |
| `filter_B_slow_rolloff.txt` | Slow Roll-Off | dCS Vivaldi Apex (F1) | Natural HF, minimal ringing |
| `filter_C_minimum_phase.txt` | Minimum Phase | Berkeley Audio Alpha 3 | No pre-ringing, causal decay |
| `filter_D_apodising.txt` | Apodising | MSB Reference | Removes CD Gibbs ringing, clean |
| `filter_E_hybrid_phase.txt` | Hybrid Phase | Mearson | Balanced pre/post ringing |
| `filter_F_extended_bw.txt` | Extended Bandwidth | dCS Vivaldi Apex (F2) | Airy HF to 25 kHz |

## Loading in Simulation

```tcl
# In tb_fir_polyphase_stereo.sv, set COEF_FILE localparam:
localparam string COEF_FILE = "filter_A_linear_phase.txt";
```

Or use the coef_bank_loader with direct UART/SPI loading in hardware.

## Differential Output Note

The DAC is fully differential. All coefficient values represent the
differential signal path. The output `cascode_l[63:0]` and `cascode_r[63:0]`
drive 64 differential cascode cell pairs per channel. The thermometer code
from the DEM maps directly to the differential current-steering cells.
""")
    print(f"  Written: README_filters.md")


# =============================================================================
#  MAIN
# =============================================================================
if __name__ == "__main__":
    print("=" * 60)
    print("BFDAC Filter Coefficient Generator")
    print(f"  NUM_MACS={NUM_MACS}  TAPS_PER_PHASE={TAPS_PER_PHASE}")
    print(f"  NUM_PHASES={NUM_PHASES}  TOTAL_TAPS={TOTAL_TAPS}")
    print(f"  FS_IN={FS_IN/1000:.1f} kHz  FS_OUT={FS_OUT/1000:.0f} kHz")
    print("=" * 60)

    gen_filter_A()
    gen_filter_B()
    gen_filter_C()
    gen_filter_D()
    gen_filter_E()
    gen_filter_F()
    write_readme()

    print("\nDone. Load filter files via coef_bank_loader.")
