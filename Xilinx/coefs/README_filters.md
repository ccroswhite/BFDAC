# BFDAC Polyphase FIR Filter Library

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
