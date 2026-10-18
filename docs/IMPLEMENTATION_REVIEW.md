# BFDAC Implementation Review and Gap Analysis

**Document role:** implementation evidence, review findings and qualification
gates. For the intended product and its architecture, start with the
[System Design Specification](SYSTEM_ARCHITECTURE.md).

This companion preserves the previous architecture-audit document, including
its supporting implementation description and finding identifiers R01–R20.
Its original audited baseline is named below. The subsequent stream-rate RTL
draft was committed as `2a5b0f869cbd9a1e0b31ec302b1af4598e7261da`; references
below to that draft as a “working-tree update” describe its state when written.
No detached-job results were inspected as part of the documentation rebuild.
Baseline findings require reconciliation against later changes and evidence;
their presence here is not a claim that each remains unchanged in current RTL.
Conversely, new RTL alone does not establish closure.

**Physical status:** PCB layout has not started. References below to placement,
routing or floorplanning describe intended constraints or future work. The SoM
connector seed is a mechanical reference, not a started carrier layout.

**Later RTL follow-up (working tree; simulation evidence recorded below):** the DSP MMCM divider is
now 3.25 (about 277.9/302.5 MHz; 49.23 DSP clocks per conversion). A Stage-A
DPD-correction deadline fault is sticky and inhibits playback; the coefficient
store now waits for DPD idle before swapping and rejects/reports writes during a
pending commit. Rate changes reset calibration-valid; DPD enable is gated on
valid calibration and muted/stopped playback. The FIR bank manager now waits
for the last active phase of a native input frame before swapping banks.
Halfband products are accumulated at full precision then shifted once at Q1.17;
the bypass center sample uses a matched pipeline stage. Automute timers are
scaled for the 302.474 MHz family clock and `switch_busy` marks relay
transitions rather than every non-PLAYING state. Dither now uses separate L/R
seeds and a full 42-bit uniform difference carried in a signed 43-bit value.
The coefficient loader waits a cycle before its first FIFO pop, rejects AXI
RRESP errors without activating the partial bank, and resets the FIFO epoch
before retry. QSPI boot staging now uses a correct Gray-pointer FIFO full
comparison and earlier read backpressure, rejects record addresses outside its
30-bit DDR aperture, and runs SoM flash targets at 25 MHz pending exact MPN
confirmation.

The expanded 24-job suite passed after these changes, including DPD golden runs
at periods 49 and 50, the independent/full-range TPDF check, the AXI-response
failure/retry test, QSPI boot/readback/backpressure/bounds checks,
deadline-boundary scenarios, RTZ inter-capture checks, calibration race/reset
cases and top-level elaboration/simulation. The DPD period tests exercise the
pipeline, not a routed XCVU13P implementation; real MMCM jitter, feedback-path
timing, FIR-bank behavior in the actual URAM/MAC implementation, STA/CDC,
real-MIG behavior and hardware remain open. Previous noise/performance studies
used the half-range dither and must be rerun against the current full-range
configuration before citing those results as current.

**Revision:** 0.2 — review draft with clock/rate ownership locked 2026-10-16, not release approval

**Audited implementation baseline:** `a7483c1bce6efacb386d27e6f2965bb8e24da593`

The 2026-10-16 ownership/rate ruling below is a subsequent design decision. It does not imply that the audited RTL has been updated or that findings R01–R04 are closed.

**Working-tree RTL update (2026-10-16):** implementation drafts now include
`stream_rate_controller.sv`, `i2s_master_ingress.sv`, 16/8/4/2 active FIR phases,
filter-rate metadata validation, explicit AP readiness and synchronized path
reset. The FPGA clock-copy input now uses IBUF/LVCMOS18 and the physical
oscillator-select polarity matches the generator. These changes postdate the
audited baseline. Compile/elaboration and new rate-matrix regressions are
pending; the baseline descriptions/findings below remain evidence, not claims
that this draft is verified. See `coef_format_v2.md` for the proposed register
and coefficient-layout extension. No synthesis/place-and-route has been run
for this update. In particular, R03 enable voltage levels, physical return-data
timing and R05 DPD deadlines remain open.

**Audience:** senior FPGA, mixed-signal/analog, PCB, firmware and verification engineers

**Purpose:** explain the intended DAC, describe what the repository actually implements, and identify what must be reconciled before a hardware/bitstream release.

> **Read this first:** the design is not established as correct merely because RTL unit tests and schematic ERC pass. The baseline has concrete RTL/schematic interface disagreements and unclosed system-level timing, calibration and power questions. The highest-priority findings are in Section 12. This document does not change the circuit or RTL and does not resolve those findings by choosing whichever source looks newer.

## Contents

1. [How to use this specification](#1-how-to-use-this-specification)
2. [Design intent and acceptance criteria](#2-design-intent-and-acceptance-criteria)
3. [System partition and signal flow](#3-system-partition-and-signal-flow)
4. [FPGA datapath and numeric contract](#4-fpga-datapath-and-numeric-contract)
5. [Clocking, resets and domain crossings](#5-clocking-resets-and-domain-crossings)
6. [Boot, memory, control and calibration](#6-boot-memory-control-and-calibration)
7. [Converter and iv architecture](#7-converter-and-iv-architecture)
8. [Power, grounding and output protection](#8-power-grounding-and-output-protection)
9. [PCB and mechanical intent](#9-pcb-and-mechanical-intent)
10. [Bring-up and measurement interfaces](#10-bring-up-and-measurement-interfaces)
11. [Verification evidence and its limits](#11-verification-evidence-and-its-limits)
12. [Open findings and review actions](#12-open-findings-and-review-actions)
13. [Review gates and required handoff package](#13-review-gates-and-required-handoff-package)

## 1. How to use this specification

### 1.1 Evidence labels

- **Intent:** a recorded requirement or design decision, not proof that the implementation fulfills it.
- **Implemented:** observable in source or generated connectivity at the baseline above.
- **Reported evidence:** an existing result recorded in the repository. Unless stated otherwise, it was not rerun while writing this document.
- **Review finding:** a source discrepancy, derived timing concern or unverified electrical assumption. A finding is not automatically a reproduced hardware failure.

A reviewer should read Sections 2–3, then Section 12, before spending time on implementation detail. Assign owners and dispositions to the findings; do not issue blanket approval from this narrative alone.

### 1.2 Source hierarchy and navigation

| Information | Primary evidence |
|---|---|
| Product goals and historical rulings | [progress.md](../progress.md), especially the acceptance specification and later dated decisions |
| Parts, topology and design rationale | [bom.md](../bom.md); contains both current and superseded material |
| Actual FPGA behavior | [vu13p_dac_top.sv](../Xilinx/vu13p_dac_top.sv) and instantiated RTL, not their comments alone |
| FPGA electrical/timing assumptions | [vu13p_dac_top.xdc](../Xilinx/vu13p_dac_top.xdc), [Alinx connector assignments](../Alinx/ACVU13P-Pin-Assignment-20260703.csv) |
| Repeatable schematic construction | [gen_kicad.py](../utils/gen_kicad.py) |
| Current circuit capture | [bfdac_analog.kicad_sch](../hw/kicad/bfdac_analog.kicad_sch), opened through [the KiCad project](../hw/kicad/bfdac_analog.kicad_pro) |
| Extracted analog reference connectivity | [ref_netlist.md](../hw/ref_netlist.md), [ref_netlist.json](../hw/ref_netlist.json), [reconciliation ledger](../hw/reconcile.md) |
| Register and coefficient interfaces | [spi_regs.svh](../Xilinx/spi_regs.svh), [coef_format_v2.md](coef_format_v2.md) |
| Build/verification recipes | [Xilinx/scripts](../Xilinx/scripts), [Xilinx/Testbench](../Xilinx/Testbench), [kicad_xcheck.py](../utils/kicad_xcheck.py) |

The old [implementation plan](../BFDAC_IMPLEMENTATION_PLAN.md) is explicitly historical except for identified sections. It still describes obsolete noise-shaper, DEM, clock and cell-interface arrangements. It is not an alternate current specification. Likewise, a historical `LOCKED` label is not a substitute for an orderable part, verified footprint or current test result.

The source snapshot is a review baseline, not a production release. The analog SPICE reference is extracted from `bfdac_cosim112.cir`, while later performance claims refer to later calibration/drive models. Many LTspice decks and numeric results live outside this repository under a developer's Documents directory. Their provenance and reproduction are a handoff gap, not implicitly covered by the Git commit.

## 2. Design intent and acceptance criteria

### 2.1 Intended product

BFDAC is a stereo, FPGA-controlled discrete current-steering audio DAC. A single Alinx ACVU13P-class SoM containing an AMD/Xilinx XCVU13P drives 64 physical current cells per channel. The carrier implements the analog conversion, reclocking, references, I/V conversion, output muting and monitoring.

The recorded ambition is performance beyond the referenced dCS Vivaldi APEX noise benchmark without sacrificing distortion or low-level behavior. This is a design objective, not a measured product comparison. The architecture deliberately combines:

- Long interpolation filters and a fixed high conversion rate.
- Third-order error-feedback noise shaping and dynamic element matching.
- Externally reclocked return-to-zero cell drive.
- Cascode/replica-feedforward analog circuitry to reduce code-dependent disturbances.
- Board-specific digital predistortion, with temperature-dependent calibration computed outside the FPGA.
- Hardware output muting independent of application software.

### 2.2 Recorded analog acceptance requirements

Reference condition: **6 Vrms balanced output, 20 Hz–20 kHz unweighted, at the applicable calibration temperature**. The repository uses a positive noise-rejection figure expressed as `dB0`; retain its voltage reference when comparing results.

| Gate | Requirement | Interpretation/review need |
|---|---|---|
| N1 | Noise rejection at least 120 dB0 | At 6 Vrms, no more than 6.0 µVrms integrated noise |
| D1 | HD2–HD8 at or below −115 dBc at −1 dBFS for in-band fundamentals | Define precisely which harmonics/bandwidth are measured when harmonics fall above 20 kHz |
| D2 | No spur above −120 dB0 | Include idle, DEM, clock, supply and control-related products; define FFT window, bin integration and record length |
| D3 | Equal-amplitude 19/20 kHz IMD products at or below −115 dBc | Specify stimulus peak headroom, acquisition bandwidth and analyzer residual |
| L1 | Noise floor changes by no more than 1 dB from −60 dBFS to digital silence, without level-dependent spurs | Must include long idle records, not just a full-scale sine |
| Stretch | 128 dB0 noise; HD2/HD3 at or below −125 dBc | Desirable, not permission to weaken mandatory distortion/idle requirements |

The recorded preference is to trade a small amount of noise performance for more distortion margin. Load impedance, cable capacitance, temperature range, supply tolerances, warm-up qualification, channel gain/phase match and crosstalk limits still need a signed acceptance matrix.

Reported R114-era simulation results include 128.1 dB0 noise, HD2 −128.3 dBc and HD3 −135.1 dBc, with later-drive calibration and a +0.5-code offset. These are **model results at specified conditions**, not measurements on a completed carrier and not predictions with guaranteed manufacturing margin. See findings R05, R09 and R20 before transferring these results to the RTL/PCB.

## 3. System partition and signal flow

### 3.1 Functional block diagram

```text
Application processor / digital board              Converter carrier + SoM
(GND_AP, VAP_IO)                                     (GND, SoM V18)

Audio / UI / temperature-calculation policy
      | PCM serial data                                  |
      +------------- isolated I2S -----------------------+--> ingress [R01/R04]
      |                                                  |       |
      +------------- isolated register SPI ------------->|    FIR x16
      |                                                  |       |
      +------------- isolated I2C ---------------------->|   HB x2 x2 x2
                  TMP117 + UCD90120A                      |       |
                                                         | volume/level/envelope
SoM configuration flash --> FPGA configuration           |       |
Coefficient NOR --> boot copier --> DDR4 --> FIR banks   | elastic pacer
                                                         |       |
AP calibration writes --> dual-bank cal store ---------->| EF3 + DPD feedback
                                                         |       |
                                                         | DEM: 64-bit selection/ch
                                                         |       |
                                                         | staging / CDC / RTZ / IOB
                                                         |       |
                         128 x 1.8 V single-ended DATA ---+-------+
                                                                 |
                                          AXC translators: 1.8 -> 3.3 V
                                                                 |
Clock XOs --> fanout trees ----------------> LVC1G74 reclock FF/cell
    |                                                            |
    +--> FPGA clock copy --> MMCM [R02/R03]         Q and complement
                                                                 |
                                       64 current-steering cells/channel
                                                                 |
                                    cascodes + replica feedforward + padding
                                                                 |
                                                COL_P / COL_M per channel
                                                                 |
                                           OPA1612 + BUF634A I/V loops
                                                                 |
                                          10-ohm build-outs + mute relays
                                                                 |
                                                  balanced XLR L / R
```

The manual bring-up controller bypasses normal audio processing at the cell-selection or pre-noise-shaper point. It does not require audio traffic, filter coefficients or a successful DDR boot, but it still requires FPGA configuration, clocks and the relevant supplies.

### 3.2 Ownership boundaries

| Block | Intended responsibilities | Not established here |
|---|---|---|
| Application processor | User interface, source policy, filter selection, volume slew, temperature reading, calibration interpolation, PMBus configuration and logging | Final AP hardware/firmware and complete manufacturing-calibration software |
| FPGA | Audio DSP, cell sequencing, coefficient transport/storage, register interface, mute requests, manual diagnostic patterns | Analog voltage/current measurement; autonomous temperature fitting |
| SoM | FPGA configuration infrastructure, local regulators, DDR4 and on-module flash | Carrier analog supplies or carrier signal-integrity sign-off |
| Carrier analog section | Current conversion, references/servos, I/V conversion, clock distribution, output protection | Guaranteed performance solely from schematic topology |
| External test fixture | Precision voltage/noise/distortion/current-inference measurements and calibration identification | No onboard precision acquisition ADC is provided |

## 4. FPGA datapath and numeric contract

### 4.1 Implemented module chain

Evidence: [dac_dsp_core.sv](../Xilinx/dac_dsp_core.sv).

| Stage | Implementation | Essential contract |
|---|---|---|
| Serial ingress | [dac_i2s_ingress](../Xilinx/dac_i2s_ingress.sv), [i2s_rx](../Xilinx/i2s_rx.sv) | RTL currently receives BCLK/LRCLK, captures 32-bit slots and retains bits `[31:8]` as 24-bit audio |
| Interpolation | [fir_polyphase_stereo](../Xilinx/fir_polyphase_stereo.sv), [fir_polyphase_interpolator](../Xilinx/fir_polyphase_interpolator.sv) | Fixed x16; shared L/R coefficient storage, separate channel histories/MACs |
| Reduction | [polyphase_mac_engine](../Xilinx/polyphase_mac_engine.sv), [polyphase_adder_tree](../Xilinx/polyphase_adder_tree.sv) | Distributed MAC windows, pipelined reduction; coefficient/audio alignment is essential |
| Halfbands | [halfband_x2](../Xilinx/halfband_x2.sv) | Three x2 stages with 63, 31 and 15 taps; total interpolation x128 |
| Gain | Core volume pipeline and top-level `level_gain` | 24-bit host volume left-justified to 32 bits; boot envelope and level cap multiply into the gain |
| Pacer | `pace_fifo`, `pace_tick` | 256 stereo entries of 96 bits; drain tied to `cell_clk/8` |
| Dither | [tpdf_dither_gen](../Xilinx/tpdf_dither_gen.sv) | 42-bit signed TPDF; see identical L/R seed finding R12 |
| Noise shaper | [noise_shaper_ef3](../Xilinx/noise_shaper_ef3.sv) | Third-order EF with IIR NTF; not a seventh-order implementation |
| Predistortion | [dpd_engine](../Xilinx/dpd_engine.sv) | Per-channel static LUT plus Volterra/nuisance terms patched into EF error feedback |
| DEM | [dem_sort](../Xilinx/dem_sort.sv) | Second-order vector mismatch shaping using rank selection; not classic DWA |
| Output | Core `staging_*`, `cell_cap_*`, `rtz_phase`, `cascode_iob_*` | 64 bits/channel, synchronous RTZ, externally reclocked on the carrier |

### 4.2 Rates and capacity

**LOCKED 2026-10-16 — AP/FPGA ownership and maximum native PCM rate.**
The AP knows the stream's sample rate and PCM format and notifies the FPGA.
The FPGA validates the request and owns the coherent conversion configuration:
carrier oscillator selection, interpolation ratio, I2S clock dividers and the
safe transition sequence. The AP does not independently set the oscillator,
core-clock multiplier or interpolation multiplier. The maximum native PCM
input rate for this revision is **384 kHz**, with the following rate matrix:

| AP-reported PCM rate / FPGA LRCLK | Carrier MCLK selected by FPGA | Total interpolation | FPGA-to-AP BCLK (64 clocks/frame) | Converter update rate |
|---|---:|---:|---:|---:|
| 44.1 kHz | 45.1584 MHz | x128 | 2.8224 MHz | 5.6448 MHz |
| 48 kHz | 49.152 MHz | x128 | 3.072 MHz | 6.144 MHz |
| 88.2 kHz | 45.1584 MHz | x64 | 5.6448 MHz | 5.6448 MHz |
| 96 kHz | 49.152 MHz | x64 | 6.144 MHz | 6.144 MHz |
| 176.4 kHz | 45.1584 MHz | x32 | 11.2896 MHz | 5.6448 MHz |
| 192 kHz | 49.152 MHz | x32 | 12.288 MHz | 6.144 MHz |
| 352.8 kHz | 45.1584 MHz | x16 | 22.5792 MHz | 5.6448 MHz |
| 384 kHz | 49.152 MHz | x16 | 24.576 MHz | 6.144 MHz |

The carrier oscillators remain the physical low-jitter MCLK source, directly
feeding the converter's external reclock tree and a clock copy to the FPGA.
The FPGA is the I2S master: it supplies BCLK/LRCLK to the AP, which transmits
DATA as an I2S slave. “Setting the I2S clock” means setting these derived
serial clocks; the prior **no separate MCLK export to the AP** decision stands.
The frame uses two 32-bit slots; supported PCM word formats require explicit
validation (the current receiver retains 24 bits).

The DSP MMCM ratio is an FPGA implementation/timing choice, not a host tuning
control. It need not change between native rates within a family. The total
interpolation ratio does change. How that ratio is distributed across FIR/HB
stages, per-rate tap counts, coefficient normalization and scheduling remains
implementation work; a variable x16/x8/x4/x2 FIR followed by x8 halfbands is a
candidate, not a completed or separately ratified datapath.

Unsupported rates/formats must be rejected. This includes 705.6/768 kHz native
input for this revision; it does not prohibit those frequencies at internal
processing stages. AP filter choice remains policy, but the FPGA must validate
filter/rate compatibility before activation. A rate change must mute, quiesce
old-format traffic, apply the matching clock/filter/processing configuration,
flush or reset affected state, and report applied-rate/readiness or rejection.
The AP must supply the matching stream, with an explicit ready/underrun contract,
before the agreed unmute sequence resumes playback. FPGA-generated frame clocks
alone cannot distinguish an absent AP from legitimate zero-valued audio.

**Implementation status:** the existing RATE register is only a family bit,
not a complete stream-rate request. The new request/status encoding, I2S-master
RTL, variable interpolation, watchdog changes and end-to-end timing verification
are pending. A 384 kHz cap does not by itself qualify the isolation round trip.

For comparison, the currently implemented fixed-x128 chain corresponds to:

| Point | 44.1 kHz family | 48 kHz family |
|---|---:|---:|
| PCM input for fixed x128 chain | 44.1 kHz | 48 kHz |
| FIR x16 output | 705.6 kHz | 768 kHz |
| HB1 | 1.4112 MHz | 1.536 MHz |
| HB2 | 2.8224 MHz | 3.072 MHz |
| HB3 / converter update | 5.6448 MHz | 6.144 MHz |
| MCLK / cell launch clock | 45.1584 MHz | 49.152 MHz |

Historical claims of 384/768 kHz I2S support are not evidence that the fixed-x128 implementation supports those inputs. The locked rate matrix above is the implementation target; input-rate-dependent processing and the matching ingress/watchdog contract remain R04 work.

`vu13p_dac_top` defaults to `NUM_MACS=256`, `TAPS_PER_PHASE=256`. Stored FIR taps are:

```text
N = 16 * NUM_MACS * TAPS_PER_PHASE
```

This default is 1,048,576 taps. The 1280-by-256 build is 5,242,880 stored taps and is used in historical implementation scripts. A 10M symmetric/folded FIR is an intent, not an implemented mode in the current unfolded datapath. Select a reviewed build configuration rather than relying on differing module defaults.

Each MAC's history window has `TAPS_PER_PHASE` samples. For phase p and MAC m, tap t addresses `h[p + 16*(TPP*m+t)]` and `x[n-(TPP*m+t)]`. The RTL documents a legacy factor-of-two FIR gain. A full scaling/overflow ledger must include that gain, coefficient normalization, halfband scaling, volume truncation and the `ns_feed` conversion.

At TPP=256, the core FIR shift/sweep is approximately 4100 DSP cycles before considering all interface/pipeline constraints. At 48 kHz, the implemented MMCM offers about 5851 DSP clocks per input sample, not the 8333 clocks assumed by some older 400 MHz comments.

Long linear-phase filters also imply substantial latency: at a 768 kHz FIR output rate, `(N-1)/(2*768000)` is about 0.683 s for 1M taps and 3.413 s for 5.24M taps, before downstream/transport latency. Minimum-phase/video filters require separate validation; metadata alone does not enforce a latency budget.

### 4.3 Numeric representation

| Quantity | Implemented representation / caution |
|---|---|
| Audio samples | Signed 24-bit values taken from the top 24 bits of received 32-bit slots |
| FIR coefficients | Signed 18-bit words; normalize against the coefficient generators, not just nominal width |
| FIR/HB datapath | 48-bit signed results; review truncation and accumulator bounds stage by stage |
| Host volume | 24-bit write becomes `{data[23:0],8'h00}`; reset value is zero |
| Envelope / level | 16-bit gain words, maximum `0xFFFF`; successive `>>16` products are not mathematically exact unity |
| Volume multiply | Registered 80-bit product, selected into a 64-bit result |
| NS input | Signed 48-bit, 42 fractional bits in cell/code units; `ns_feed` maps the volume result into this domain |
| NS state/correction | Signed 56-bit internal state/correction with explicit error clamping |
| Normal quantizer output | Seven-bit container, clamped to integer codes 0..63 |
| DEM capacity | Can select 0..64 cells; normal NS maximum is 63, not 64 |
| DPD LUT | Signed 24-bit values on a 2^-24 code-LSB grid |
| DPD coefficients | Signed 18-bit mantissas plus shared shift metadata; 56-bit modular accumulator arithmetic |

The EF recurrence uses the dyadic coefficients 1.5, −2.25, 0.875, 1.5, −0.75 and 0.125, with nominal NTF `(1-z^-1)^3 / (1-z^-1/2)^3`. The center constant is **32.0**, not the **32.5 plus DCOFF 0.5** calibration operating point in the later analog performance record. Do not assume this discrepancy is corrected somewhere else without tracing it (R09).

### 4.4 DEM and RTZ intent

For requested code c, `dem_sort` selects c cells with smallest metric `2*acc1+acc2`, ties by lower index, then updates per-cell accumulators. The rank engine uses approximately 35 DSP cycles per conversion. It accepts a new request in IDLE; missed requests or changes in valid latency must be observable in system tests.

The core transfers staged stereo masks to the cell clock domain with a toggle synchronizer and held data bus. RTZ phases 1..6 are active; phases 0 and 7 are low. At 49.152 MHz, the nominal active interval is 122.07 ns in a 162.76 ns conversion period. At 45.1584 MHz, it is approximately 132.87 ns in 177.15 ns. These are six-of-eight clock intervals, not an arbitrary PWM audio output.

**A zero DATA bit is not an electrically disabled current source.** The reclock FF's complementary output steers current to the other branch. Likewise, stopping a clock does not force an external FF to a new state. Reset/clock-loss behavior must be analyzed at the physical FF and analog nodes, not inferred from the FPGA register reset alone.

## 5. Clocking, resets and domain crossings

### 5.1 Implemented clocks

Evidence: [sys_clock_gen.sv](../Xilinx/sys_clock_gen.sv), top-level clock/reset logic, XDC.

| Domain | Source | Principal consumers |
|---|---|---|
| `clk_200m` | SoM differential 200 MHz clock | SPI registers, flash engine, boot-side transport, button controller, clock-switch sequencing |
| `ddr4_ui_clk` | MIG user clock, described/configured as 300 MHz | AXI DDR transport and coefficient loader |
| `dsp_clk` | MMCM: MCLK x20 /3.5 | FIR/HB/gain, NS/DPD/DEM, diagnostic application |
| `cell_clk` | MMCM: MCLK x20 /20, phase +90 degrees | RTZ output launch and /8 pacing toggle |
| `i2s_bclk` | External input in current RTL | Serial audio capture; conflicts with schematic master intent |

The MMCM VCO is nominally 903.168 or 983.04 MHz. DSP clocks are approximately **258.048 or 280.869 MHz**. Thus the sustained conversion interval is:

```text
DSP clocks per conversion = (MCLK * 20 / 3.5) / (MCLK / 8)
                          = 160 / 3.5 = 45.714...
```

The pacer therefore presents an approximately 45/46-cycle cadence. Do not use the 56-cycle DPD unit-test cadence or old 350–400 MHz comments as proof of sufficient real-time margin (R05).

### 5.2 Physical clock network

The generated circuit uses two Crystek CCHD-957 oscillators, enabled one at a time, with outputs connected through separate 33-ohm resistors to `XOCLK`. Each channel has an LMK1C1108 root and eight leaf fanouts. One dedicated shared `V33CLK` LT3045 rail powers both channel trees and the oscillator circuitry.

A buffered/divided copy of `XOCLK` goes to SoM J6-C30/AW28 as **single-ended LVCMOS18**. In contrast, RTL still instantiates `IBUFDS` and XDC assigns LVDS to AW28/AY28. The clock-select polarity also disagrees with the register convention. These are unresolved interfaces, not acceptable timing margins (R02/R03).

The current quarter-period FPGA launch offset was justified for an older external EP52 path. The actual carrier path is FPGA -> AXC8T245 -> LVC1G74, with LMK1C1108 clock trees. Recalculate setup/hold over PVT, oscillator/fanout skew, FPGA Tco, translator delay, loading and board flight time. Retiming removes some launch uncertainty only if the external FF captures correctly; it does not eliminate its own aperture error or fanout jitter.

### 5.3 Reset and clock switching

`sys_rst_n = ext_rst_n & clk_locked`. Many DSP blocks use synchronous reset checks; the BCLK and cell-domain reset synchronizers use asynchronous assertion and synchronized release. A stopped clock cannot execute a synchronous reset. A domain-by-domain reset-release/clock-loss audit is required.

The 200 MHz clock-switch sequencer waits `MUTE_DELAY_CYCLES` (default 4,000,000, 20 ms), asserts MMCM reset, changes clock select and holds reset for 2048 control clocks (10.24 µs). The current hardware switches oscillator enables rather than the obsolete LMK00304 mux described in RTL comments. Oscillator disable/enable overlap, startup validity and externally reclocked cell behavior must be incorporated into this sequence.

### 5.4 CDC inventory

| Crossing | Mechanism | Review obligation |
|---|---|---|
| Audio BCLK -> DSP | Toggle event plus direct held stereo data capture | No audio FIFO is actually instantiated in ingress despite its header; prove bus stability and accepted sample rate |
| Control -> DSP volume | Change toggle, synchronized event, held 32-bit bus | Validate clock-reset recovery when source value stays unchanged |
| Control -> DSP level/output select | Multi-bit synchronizers and legacy request pulses | Prove event capture, coherent targets and behavior during resets |
| DDR UI -> DSP coefficients | Async FIFO/backpressure in coefficient subsystem | Gray-pointer bounds, reset ordering, overflow/underflow, valid alignment |
| Control -> DDR UI boot payload | 16-entry x128-bit async FIFO and job/done transfers | Backpressure, CRC failure, malformed record and interrupted boot |
| DSP -> cell | Held selection masks plus update toggle | Bus settling, event spacing, fixed RTZ width under worst relative phase |
| Cell -> DSP pace | /8 toggle through synchronizer | Cadence and startup behavior |
| Calibration control -> DSP | Write/commit toggles and held buses | Bank consistency across a complete DPD calculation, not just pointer atomicity |
| Manual test command -> DSP | Held command, request/acknowledge round trip | Cancel/fault while clocks stop, safe restart and applied-state feedback |
| PG/status -> control or DSP | Synchronizer chains | Active-low/high interpretation, unpowered behavior and alarm response |

Clock-wide false paths exist between control and DSP clocks. Later per-bus max-delay declarations must be checked for effective precedence; a declaration in the XDC is not proof that Vivado times that path. Require `report_exceptions`, `report_cdc`, unconstrained-path checks and a reviewed waiver list on the exact candidate build (R11).

## 6. Boot, memory, control and calibration

### 6.1 Coefficient transport and active FIR banks

1. SoM configuration infrastructure loads the FPGA bitstream.
2. After configuration EOS and MIG calibration, [qspi_boot_loader](../Xilinx/qspi_boot_loader.sv) copies records from coefficient NOR to DDR4 and checks payload CRCs.
3. Carrier flash is tried first; a missing first magic permits a one-time fallback to SoM Flash 1.
4. Successful staging does **not** itself load a FIR bank. AP policy must request a default filter.
5. [coef_bank_loader](../Xilinx/coef_bank_loader.sv) locates a numeric filter ID in the DDR directory, checks packing/size and loads the inactive FIR bank through the coefficient subsystem.
6. [coef_bank_manager](../Xilinx/coef_bank_manager.sv) swaps the bank on successful completion. A failed lookup/load retains the previous active bank.
7. `bank_valid` starts the boot gain envelope. Host volume still resets to zero, and XLR unmute is separately commanded/interlocked.

Two DDR implementations define the same module name: [dac_ddr4_if.sv](../Xilinx/dac_ddr4_if.sv) is the simulation stub; [dac_ddr4_if_mig.sv](../Xilinx/dac_ddr4_if_mig.sv) is the real MIG wrapper. Select exactly one. The SoM memory interface uses 64 DQ, not all five physical x16 devices. The described physical capacity is 8 GB, while the exposed 30-bit byte-addressed AXI interface is a **1 GB window**. Do not confuse physical capacity with the implemented address space.

Directory base is `0x3FFF0000`, with 32-byte entries and a bounded scan. Stored coefficient layouts support either one signed 18-bit value in a 32-bit word or seven 18-bit values in each 128-bit beat. Names/UI strings remain AP-side. The 10M folded-FIR payload/phase policy is still prospective.

FIR bank swaps are currently not qualified by the FIR sweep boundary; `sample_tick` is not used to time the bank-manager swap. The word "gapless" must not be taken to establish an unmixed coefficient set for every accumulated output or click-free filter changes (R10).

### 6.2 Flash protocol versus filter-file format

[qspi_flash_ctrl](../Xilinx/qspi_flash_ctrl.sv) is currently an **x1 SPI engine**, despite QSPI-capable parts and signal names. SoM targets use nominal 50 MHz SCK; carrier flash uses 25 MHz. The carrier supports chip selection by address bits for up to four 256 MiB devices; initial population and total capacity must match the assembly variant.

The boot copier consumes a **16-byte record header** with numeric magic `0x42464443`, DDR destination, payload length and payload CRC. Its little-endian packing expects initial magic bytes `43 44 46 42` in hexadecimal; do not infer byte order from the source comment's ASCII label. This is not the same header as the documented **256-byte BFC2 filter container**. A production image builder must translate/pack the required records and directory. Do not feed a raw BFC2 file to the boot copier and assume compatibility. An end-to-end production builder was not located in the inspected `utils` sources; establish its location, ownership and golden-image tests.

The current carrier x1 data-rate ceiling is approximately 25 Mbit/s before overhead, not 25/50 MB/s quad throughput. Provisioning and boot-time requirements must be budgeted accordingly. Review record bounds, directory collisions, device-boundary crossing, address narrowing, header integrity and watchdog coverage; host flash commands have a watchdog, but boot streaming does not have equivalent complete timeout coverage.

### 6.3 Register control and AP electrical interface

[spi_regs.svh](../Xilinx/spi_regs.svh) defines independent read/write address spaces. Frames are 40 bits: one R/W bit, seven address bits, 24 data bits and CRC-8 polynomial 0x07. Read responses are pipelined to a later frame. Error/IRQ handling must distinguish bad CRC, bad frame length, unsupported address, rejected command, flash faults and failed filter loads.

Primary groups are volume/level/rate/unmute, named-filter control, calibration writes/commit/readback, flash commands, diagnostics and status. See [the protocol document](coef_format_v2.md) for the full register map and manual-test status fields.

Current schematic isolation parts are MAX22445CAWE+ for SPI, MAX22445FAWE+ for I2S/IRQ with sides arranged for FPGA-master clocks, MAX22444CAWE+ for reset, and ISO1640 for sensor/PMBus I2C. SoM-side logic is 1.8 V; AP supply/ground are `VAP_IO`/`GND_AP`.

The latest BOM ruling withdrew **50 MHz isolated register SPI** at the 1.8 V operating point and discusses 10 MHz nominal operation with a possible 20–25 MHz mode. Even the claimed 10 MHz guarantee still needs a full datasheet-max delay/oversampling budget. A connector supporting 50 MHz signals does not establish an end-to-end 50 MHz isolated SPI link. No dedicated RX-training register was identified in the current register map; the magic readback is not itself an implemented training procedure.

### 6.4 Predistortion and calibration ownership

The AP is intended to read temperature sensors and compute/interpolate per-board calibration values. The FPGA does not fit models or perform temperature interpolation. [cal_coef_store](../Xilinx/cal_coef_store.sv) contains two 512x24-bit banks, covering two 256-word channel regions. The DPD engine reads two ports/channel.

Per-channel map:

| Words | Content |
|---|---|
| 0–63 | Static code-error LUT on the 2^-24 grid |
| 64–102 | 39 Volterra mantissas |
| 103–118 | 16 FIR nuisance terms |
| 119–122 | Shared shift/exponent metadata |
| 128–191 | Static-content mantissas |
| Other addresses | Reserved |

The model acts on recent **aggregate codes** and their histories. The 64-entry static LUT is not automatically a bank of 64 independent physical-cell trims. Per-cell bring-up measurements are useful diagnostics, but an identification/calibration procedure must define how measurements become the actual aggregate LUT/kernel values.

Calibration commits flip an active bank on the post-FIR sample tick. That boundary is not inherently the boundary of the serial DPD calculation at the conversion rate. Establish coefficient-set consistency throughout each DPD operation, update/reset recovery, readback/CRC/version policy, and behavior when no audio tick occurs. No completed AP firmware or factory fixture is part of this handoff.

## 7. Converter and I/V architecture

### 7.1 Cell and bus topology

Evidence: [reference netlist](../hw/ref_netlist.md), [generator](../utils/gen_kicad.py), [BOM](../bom.md).

Each channel has 64 nominally matched current sources, BJT steering pairs and per-cell reclock FFs. The hardware selection includes THAT300 current-source transistor arrays, DMMT5551 steering pairs and SN74LVC1G74 reclocking. Sixteen SN74AXC8T245 devices translate the 128 DATA signals from 1.8 V to 3.3 V.

FF Q/Q-complement outputs feed a base-drive network using nominal 1.35k series/301-ohm shunt elements referenced to VCM, with local base stoppers. The intended steering levels are approximately 1.1/1.7 V, not the raw 0/3.3 V FF levels. Output resistance and loading of the real FF are part of the identified analog plant.

The two current buses feed cascoded MOSFET stages. Replica feedforward uses sums of the actual FF output activity to influence cascode bias and reduce code-dependent disturbance. Padding current and bus capacitance keep operating points away from unfavorable low-current conditions. These mechanisms have different purposes from digital DEM and DPD; they are not interchangeable fixes.

Do not add probing loads to Q/Q-complement or change drive loading without reviewing replica scaling, calibration and edge behavior. Layout matching concerns include both logic transitions and analog current paths.

### 7.2 FPGA-to-analog interface contract

| Item | Required interpretation |
|---|---|
| Cell numbering | FPGA bit 0 maps to DAT01/DATR01; bit 63 to cell 64. Preserve any remap consistently in XDC, schematic, layout and diagnostic labeling |
| DATA electrical domain | LVCMOS18 at FPGA/translator A side, 3.3 V at FF D |
| Clocking | Externally distributed MCLK clocks every cell FF; translator data must meet that FF's setup/hold |
| RTZ | Six active clock intervals and two low intervals per conversion, with uniform packet width |
| Complement | Generated by the external FF, not by independently skewed FPGA pins |
| Analog zero | A centered average selection/current condition, not 128 low GPIOs |
| Current-source shutdown | Not provided merely by static FPGA zeros or by muting the XLR |
| Fault isolation | XLR relay protection is separate from keeping internal converter/I/V nodes within safe compliance |
| Test mode | Deliberately changes masks or codes while outputs are muted; external acquisition is required |

### 7.3 I/V loop and references

Each channel has two I/V branches, P and M, using an OPA1612 front amplifier with a BUF634A inside the feedback loop. Nominal feedback is **270 ohms with approximately 1.3 nF in parallel**, with **12 nF** summing-node capacitance. A nominal **4 V virtual-ground reference** establishes the summing-node common-mode operating point. These are not ground-referenced current-probe terminals.

Offset-injection resistors feed from `V_ROFF` (~+15 V): four 536-ohm resistors in parallel on P (134 ohms), and four 464-ohm resistors on M (116 ohms). Their power dissipation, temperature gradients and value differences from the frozen reference deck are intentional matters to review, not exact equivalence established by connectivity checks.

For a settled linear loop, an output change provides a first-order mean-current estimate `delta I ≈ -delta Vout / Rf` per branch. Confirm signs, RTZ duty, differential scaling, replica/feedforward interaction and instrument loading before using this as a calibration equation. The physical-cell test measures the difference between 32 selected cells and the same background plus one cell.

The current revision has **no separate line voltage-gain stage and no separate historical reconstruction-filter block**. Frequency response, out-of-band rejection and overload recovery belong to the complete converter/I/V/output network. Do not treat the simple Rf/Cf pole as a complete stability or reconstruction-filter model.

One REF7050 source and filtered/buffered `REF5F` serve both channels. Local reference/bias circuits derive VREF, V_VG, VCM, VFR, VB1/VE1 and cascode/padding setpoints. CASB2 P/M names intentionally join at the servo output within each channel; gate stoppers separate the physical devices. Reference-source/sink capability, stability with large capacitors, startup and temperature behavior require analog review.

## 8. Power, grounding and output protection

### 8.1 Power architecture: shared pre-regulators, per-channel analog POLs

The selected architecture is **option B**: shared upstream pre-regulator rails with separate final regulators for the two analog channels. This is neither fully shared regulation nor completely independent dual-mono power.

| Rail | Nominal | Scope/source | Main role |
|---|---:|---|---|
| V12SOM | +12 V, provision up to 15 A | Dedicated switching supply, left-side entry | SoM/FPGA subsystem; this is a capacity requirement, not a measured continuous consumption |
| V18 | +1.8 V | Exported by SoM | FPGA bank interface, translator A sides, FPGA-side isolators, control logic |
| P16A / N16A | +16.2 / −16.2 V | Shared upstream inputs through top/bottom entries | Input to positive/negative analog POLs |
| V8P3 / V4P3 | +8.3 / +4.3 V | Shared upstream inputs | VE1 and 3.3 V-class regulators |
| V_ROFF_L/R | +15 V | LT3045 on respective IV sheets | Offset injection |
| P15A_L/R | +15 V | LT3045 on REFS sheets | Analog amplifiers/reference circuitry |
| N15A_L/R | −15 V | LT3094 on REFS sheets | Analog negative supplies |
| VEE15_L/R | −15 V | Separate LT3094 on REFS sheets | Converter/padding sink return |
| VE1_L/R | Approximately +7.2 V | LT3045 with driven SET | Replica/emitter operating point |
| P5A_L/R | Approximately +3.3 V despite the historical net name | LT3045 | VCM-related analog circuitry |
| V33CLK | Approximately +3.3 V | One LT3045 on CLKR, shared L/R | Both clock trees and oscillators |
| V33FF | +3.3 V | One ADP7158 on XLAT, shared L/R | Translators and FF islands |
| V33D | +3.3 V | TPS7A2033 on CTRL | Telemetry and board digital loads |
| V33RLY | +3.3 V, switched enable | TPS7A2033 on OUT | Non-latching mute relay coils |
| VAP_IO / GND_AP | AP-side supply/return | External AP domain | AP sides of isolation; ISO1640 constrains allowable supply |

Non-pre-regulator LDOs belong on the schematic sheets of their loads. Separate clock regulation spanning both channels is intentional. Per-cell/translator ferrite-decoupling islands must not inadvertently rejoin supposedly separated noisy paths in layout.

Each rail needs a reviewed maximum-current, startup/inrush, dropout, dissipation, thermal and reverse-current budget. The old claim that every pre-regulator rail is at most 0.5 A is not valid for connector sizing: the BOM assigns **1.5 A to V4P3**, and the V33FF discussion reaches approximately 1 A. U340's recorded ~500 mA load is already near the LT3045 rating before margin; verify actual fanout/XO currents rather than copying that estimate.

### 8.2 Ground domains and isolation

The SoM's dedicated supply is physically separated from sensitive analog circuitry, but its return is the carrier `GND` net. It is **not a separate galvanically isolated FPGA-to-converter ground domain**. Plan high-current return paths, loop areas, reference returns and chassis bonds explicitly.

`GND_AP` is a separate intended domain crossing through isolators. J506 currently exposes raw `SOM_PG` alongside AP-ground signals without an isolation element. That is an unresolved functional isolation crossing (R06). The external board's supply-return topology must also preserve the intended barrier; labels alone do not do so.

XLR pin 1 and shell are currently tied to GND in the schematic. The final signal-ground/chassis/shield connection and EMC/ESD strategy remain decisions, not completed layout details.

### 8.3 Power-good and mute protection

The intended hardware condition is:

```text
UNMUTE_EN = FPGA relay request AND FPGA configuration DONE AND PG_ALL
```

`PG_ALL` combines 13 LT3045/LT3094 PG outputs plus a TPS3890 supervisor on V33FF, with a pull-up to V18. Two UCD90120A devices provide telemetry only; they are not the hardware safety path. `PG_ALL` does not independently prove every supply/reference on the entire product is healthy.

Two Omron **G6K-2F-Y DC3** non-latching relays select I/V output versus grounded XLR contacts. An ULN2003V12-class low-side driver energizes the coils while unmuted. No H-bridge or coil economizer PWM is intended. The coil rail and drivers share the hardware unmute enable.

The spring-return default gives a useful unpowered state, but **contact release is mechanical, not instantaneous**. Review power-fail warning time against rail collapse, FF behavior, amplifier saturation and flyback decay; confirm break-before-make, contact mapping, grounding, driver logic thresholds and coil voltage over PVT. No independent analog output-DC detector was established by this audit.

The top-level now receives PG_ALL on N29 for diagnostic safety, but normal automute does not consume it as a re-arm/soak input. Hardware gating can mute during a rail fault and reconnect when PG recovers if the FPGA request remains asserted. A timed, latched recovery policy must be specified and verified (R08).

## 9. PCB and mechanical intent

### 9.1 Functional sheet map

| Sheet group | Scope |
|---|---|
| CELL_L / CELL_R instances | 64 cells/channel, reclock/base-drive networks |
| CORE_L/R | Current-source arrays, cascodes, replica feedforward, padding and buses |
| IV_L/R | Composite I/V loops, offset supply/injection, summing and output test points |
| REFS_L/R | Analog POLs and bias/reference generation; shared reference source on L |
| FPGA / CLKR | SoM-facing interface and L/R clock distribution |
| XLAT | Sixteen octal DATA translators and shared FF rail |
| SOM | Remaining SoM connectors, power decoupling, JTAG and boot straps |
| CTRL | AP isolation, telemetry, temperature sensors and interface entries |
| POWER | Shared pre-regulator entries and V33FF supervisor |
| OUT | Relay safety gating and XLR connections |
| BRINGUP | Manual controls and supply-presence indicators |

### 9.2 Placement/routing priorities

- Keep the 12 V high-current/digital region on the left, away from low-level conversion/reference circuits, with deliberate return routing.
- Match cell geometry, thermal environment and parasitic loading; do not infer that DEM makes placement irrelevant.
- Preserve matched FF output loading and replica paths; isolate high-current R_off/Rpad heat from precision matching structures.
- Place reclock FFs, translator interfaces, clock terminations and local bypasses according to a recomputed timing/SI budget.
- Keep summing nodes compact, guarded from clocks/digital routing, and avoid uncontrolled probe or connector stubs.
- Provide Kelvin sensing where regulator/reference design requires it; shared reference routing must not carry unrelated load current.
- Establish stackup, reference planes, via transitions, impedance and return continuity before routing. A split ground plane is not automatically beneficial.
- Review enclosure coupling/heatsinks, SoM cooling, reference thermal isolation, relay ambient limit, mounting holes and assembly access.
- Carrier policy is 0603 R/C minimum except documented 0402 exceptions; assembly feasibility and chosen precision-footprint options need BOM/placement review.

These are review constraints, not proof that a routed implementation exists. [som_seed.kicad_pcb](../hw/kicad/som_seed.kicad_pcb) is a connector/mechanical seed, not a completed routed carrier.

### 9.3 Board-to-board interfaces are provisional

Working geometry is approximately 30 mm board separation, with separate signal and power connectors acceptable:

- Left digital entry J506: FX18 family candidate; exact mating pair/height, MF contacts, pin numbering and footprint are unclosed.
- Left V12SOM/return J507/J508: REDCUBE concept; actual parts and complete 30 mm conductive/mechanical assembly are unclosed.
- Top/bottom pre-regulator entries J603/J604: same shared rail nets; exact stacking-header pair, current derating, height/tolerances and harness/baseboard routing are unclosed.

The generator still contains `746xxxxx`, `TW-04-xxx-L-D` and missing custom connector footprint links. They are **not orderable manufacturing selections**. Both entry connectors tied to the same nets do not by themselves enforce independent channel current paths. Multiple simultaneously mated connectors need tolerance/alignment analysis and standoffs that do not introduce unwanted ground bonds.

### 9.4 Single-channel first article

Intent is to populate one analog channel initially while retaining shared infrastructure. There is no completed per-channel assembly-variant mechanism in the generator; individual DNP support is not that mechanism. In particular, REF7050 and REF5F buffering are on REFS_L and depend on left-side supplies. Omitting the entire L block for a right-only build would remove shared reference infrastructure. Define an explicit shared/L/R population matrix, regulator dependencies and PG behavior before releasing assembly files.

## 10. Bring-up and measurement interfaces

### 10.1 Physical controls and indicators

- SW9000 SELECT and SW9001 STEP: **Würth 434133025816**, top-actuated momentary SMT switches.
- D9000–D9023: **Kingbright APT1608LSECK/J3-PRV**, red 0603 LEDs, nominal **500 µA** target in the new indicator circuits.
- D9023 flashes at 1/2/3 Hz while the selected test is held active, is off during selection/handshakes, and goes off after completion/cancellation.
- D9023 draws LED current through 20k from V12SOM with an MMBT3904 sink and 10k base resistor; not from an analog rail.
- Twenty-three supply-presence indicators include pre-regulators and per-channel rails. V18 indication is transistor-sensed and LED-powered from V12SOM for headroom; precision reference/SET/bias nodes do not get LED loads.
- Indicators are rough hints, not voltage-limit comparators. LED visibility/Vf must be checked on the first board; VAP_IO at 2.25 V is dimmer than at 3.3 V.

GPIO assignment: SELECT M29/J1-D20, STEP L29/J1-D19, LED L28/J1-D17. PG_ALL is N29/J1-B7; the obsolete unused `relay_level[1]` output was moved to K28/J1-D16 in the baseline to remove its previous conflict.

### 10.2 Manual diagnostic sequences

[bench_test_controller](../Xilinx/bench_test_controller.sv) debounces inputs for nominal 10 ms and counts SELECT presses in a fixed three-second window. Unsupported counts are rejected. Tests wait for safe conditions and acknowledged commands; STEP does not auto-repeat.

| SELECT count | Stimulus sequence | Channel progression |
|---|---|---|
| 1 | For each cell: fixed 32-cell background excluding it, then same mask with it added | 128 conditions L, then 128 R |
| 2 | Offsets 0, +1, −1, +4, −4 code/cell-equivalents around digital mid-code | Five conditions L, then five R |
| 3 | Held sine, 1 kHz through 20 kHz in 1 kHz increments, approximately four-cell-equivalent peak | Twenty conditions L, then twenty R |

Each condition remains until STEP. One extra STEP after the last right-channel condition completes the sequence; no auto-wrap occurs. A two-second SELECT hold cancels. SELECT during HOLD terminates the old test and opens another selection window. Completion/cancellation leaves the XLR muted; no measurements are acquired or declared passing by these controls.

[bench_test_stimulus](../Xilinx/bench_test_stimulus.sv) uses a 32-bit phase accumulator and a 1024x16 sine ROM. DC/tone bypass FIR/volume/boot envelope/DPD but use NS, DEM and RTZ; CELL overrides selection masks. This DDS is a bring-up/frequency-response source, **not a qualified −115/−125 dBc distortion stimulus**. Physical tone frequency depends on resolving R03.

Local mode refuses takeover from an active/pending SPI cell test and blocks competing SPI cell writes, rate changes and unmute. SPI read `0x1F` exposes ownership, LED, mode, channel, step, state and fault. Clock/power-good loss requests abort; if clocks stop, handshake draining waits for their return. There is no separate test-sync output or precision acquisition ADC.

### 10.3 Probe map and procedure

| Channel | Summing P / M | Dedicated ground pads | Pre-relay I/V P / M |
|---|---|---|---|
| L | TP987 / TP988 via R688/R689 | TP992 / TP993 | TP985 / TP986 |
| R | TP787 / TP788 via R788/R789 | TP792 / TP793 | TP785 / TP786 |

Summing taps are through 1k isolation resistors. They reduce loading; they do not eliminate it. A 10 pF probe gives an approximately 16 MHz pole in that probe path and cannot establish nanosecond edge fidelity. Use an appropriately rated low-capacitance active probe and short local return; do not use 50-ohm termination on a summing tap.

Use summing taps for compliance/settling observations. Obtain cell-weight information from settled **pre-relay output differences** at the same cell index. Do not connect an ammeter directly across a summing node. The normal XLR is grounded/disconnected while diagnostic mode is active.

The SPI cell register interface exists independently, but its enable path is blocked by the current automute status contract (R07). The manual button path and isolated unit-test successes do not establish that the documented SPI procedure works at top level.

## 11. Verification evidence and its limits

### 11.1 Evidence recorded at the baseline checkpoint

| Evidence | Recorded result | What it does not establish |
|---|---|---|
| [tb_bench_controller](../Xilinx/Testbench/tb_bench_controller.sv) | 317 checks pass | Electrical button/LED wiring, full top-level system behavior |
| [tb_bench_stimulus](../Xilinx/Testbench/tb_bench_stimulus.sv) | 346 checks, including both assumed sample-rate families and channels | Actual oscillator polarity, analog amplitude/distortion |
| [tb_cell_measurement](../Xilinx/Testbench/tb_cell_measurement.sv) | 262 pattern windows plus manual DC/tone chain tests pass | Real automute integration; it supplies a simplified safety/status environment |
| [tb_dac_ctrl_plane](../Xilinx/Testbench/tb_dac_ctrl_plane.sv) and [tb_spi_ctrl_plane](../Xilinx/Testbench/tb_spi_ctrl_plane.sv) | Register/arbitration/frame tests pass | Isolator propagation, AP timing, real system status semantics |
| [tb_dpd_engine](../Xilinx/Testbench/tb_dpd_engine.sv) | ON/OFF bit-exact golden checks, 2000 vectors/channel, reported correction latency 42 cycles | Correctness at the production 45/46-cycle cadence; this TB uses EN_PERIOD=56 |
| Python compileall | Syntax checks pass | Numerical correctness or availability of external LTspice data |
| [kicad_xcheck](../utils/kicad_xcheck.py) | 1300 mapped endpoints/channel in 542 nets, plus probe/UI/LED checks | Complete analog function, part ratings, layout, or consistency with FPGA port directions |
| KiCad ERC | Zero errors; five known warnings | Correct power sequencing, isolation, MPN-to-land-pattern match, timing or manufacturing readiness |
| Historical P&R records | Earlier 5M-class timing closure recorded in progress notes | Closure for this baseline's added diagnostics, pin changes and current electrical interfaces |

The five ERC warnings are two intentional CASB2 naming ties and three missing connector-footprint links. Those three footprint warnings are unresolved deliverables, not harmless manufacturing waivers.

The connectivity checker compares the extracted mapped partition, not every component value or every newly added part. Its legacy channel-short whitelist still includes rail names such as P15A/N15A/VEE15/V_ROFF; review that against the per-channel regulation policy. Generated op-amps, supplies, isolation and safety logic require independent checking.

### 11.2 Reproduction entry points

From a suitably provisioned Windows checkout:

```text
python utils/kicad_xcheck.py
"C:\Program Files\KiCad\10.0\bin\kicad-cli.exe" sch erc --format json --severity-all -o logs/erc.json hw/kicad/bfdac_analog.kicad_sch
python -m compileall -q utils analysis_archive
```

Create the local `logs` directory if absent. Use [run_tb_ctrl_plane.ps1](../Xilinx/Testbench/run_tb_ctrl_plane.ps1) with `tb_bench_controller`, `tb_bench_stimulus`, `tb_cell_measurement` or `tb_dac_ctrl_plane` for focused XSim checks. The scripts currently contain machine-specific Vivado/repository paths; provision/adapt those paths before claiming clean-checkout reproducibility. Do not bypass local execution/security policy as a build workaround.

Real MIG testing has separate IP/model-generation requirements; see [run_tb_mig.ps1](../Xilinx/Testbench/run_tb_mig.ps1) and [gen_ddr4_example.tcl](../Xilinx/scripts/gen_ddr4_example.tcl). Full synthesis must use the real MIG wrapper, the correct XCI files and an explicitly chosen tap geometry. Long-running Vivado/route or long XSim jobs are to be detached with log paths reported, per the existing project rule.

`gen_kicad.py` regenerates schematics, symbols, footprints and the PCB seed. It is not a harmless formatting command once PCB/manual schematic work starts; preserve layout changes and settle the generator-versus-editor ownership model before regeneration. Ignored logs/raw captures are not shipped as proof; retain reviewed results with tool versions, input hashes and parameter sets in a release evidence package.

## 12. Open findings and review actions

**Priority definitions:** P0 = resolve before freezing the architecture/interface or releasing a bitstream/board based on it; P1 = resolve before relevant hardware qualification; P2 = completeness/maintainability. These priorities are proposed for review, not a claim that every failure has been reproduced. None is closed by this document.

### R01 — P0: I2S direction mismatch (confirmed source disagreement)

**Evidence:** top-level ports and `dac_i2s_ingress` define BCLK/LRCLK as inputs. `gen_kicad.py`, U502 wiring, sends FPGA-side `I2S_BCLK/LRCLK` into isolator inputs and AP-side clocks out, implementing the FPGA-master intent.

**Consequence:** the intended clock nets have no FPGA clock generator/output in the inspected RTL. An external-master testbench bypasses this physical disagreement.

**Decision locked 2026-10-16:** FPGA owns I2S timing; AP reports stream rate/format and transmits DATA as a slave. This confirms the earlier master-ownership ruling rather than reopening it.

**Action/closure:** implement the FPGA-master ports/clock generation/receiver timing, reconcile XDC and isolation directions, and run a top-level serial-audio test with the actual pin directions and isolation delay model. The decision is closed; the implementation finding remains open.

### R02 — P0: Single-ended clock drawn, differential input implemented (confirmed)

**Evidence:** generator U312/R304/R305 and J6-C30 produce a divided single-ended clock; the companion pin is not driven as its differential complement. Top instantiates `IBUFDS u_ibufds_mclk`; XDC lines around `clk_mclk` assign LVDS to AW28/AY28, with a TODO acknowledging the mismatch.

**Action/closure:** choose and verify a compatible electrical interface, including bank supply, threshold/noise margin, resistor-divider loading, edge rate and inactive-power behavior. Make schematic, primitive and XDC agree; re-run I/O DRC and SI/timing analysis.

### R03 — P0: Clock-family polarity, enable levels and timing model disagree

**Evidence:** register/RTL convention is 0=44.1k family, 1=48k family. Generator selects Y301=49.152 MHz with CLK_SEL low and Y302=45.1584 MHz high. Filter-container metadata also uses 0=48k, unlike the register convention. A 1.8 V `clk_sel` drives 3.3 V clock-domain logic/XO enable circuitry without a verified level-translation contract. XDC/RTL comments still describe LMK00304/EP52 rather than the actual oscillator-enable/AXC/LVC1G74 path.

**Consequence:** even assuming enables work electrically, physical frequency can disagree with rate metadata and DDS tuning. For example, a 5.6448 MHz-assumed DDS clocked at 6.144 MHz produces approximately 1.0884 kHz for a requested 1 kHz.

**Action/closure:** define one explicit truth table (including reset), with deliberate translation between file metadata and register encoding. Verify enable VIH/VIL over PVT, break-before-make/startup timing and the actual reclock setup/hold budget. Test both families and every switching/failure transition.

### R04 — P0: Audio-rate contract and watchdog are inconsistent

**Evidence:** ingress watchdog is fixed at 512 DSP cycles, approximately 1.82–1.98 µs at the implemented clocks. Base-rate stereo samples arrive every 20.83/22.68 µs. The DSP chain always expands by x128 and drains at MCLK/8. Older headers describe high-rate inputs and a FIFO that is not instantiated in ingress.

**Consequence:** base-rate input can assert I2S error between valid frames; feeding 384/768 kHz instead overloads or otherwise conflicts with the fixed interpolation/pacer contract. A faster test source alone is not a fix.

**Decision locked 2026-10-16:** the eight native PCM rates and total interpolation ratios in Section 4.2, up to 384 kHz, are the target. AP reports the stream; FPGA derives the complete configuration.

**Action/closure:** implement that matrix and define per-rate processing, FIR acceptance cadence, buffer depths, compatible filter sets and watchdog/stream-readiness behavior. Run sustained full-path PCM tests at every supported rate and with clock drift, missing frames, underrun and overflow. Require status-visible errors rather than simulation-only warnings. Register encoding and implementation verification remain open.

### R05 - P0: DPD real-time deadline is not covered by the passing TB

**Evidence:** implemented clock ratio gives 45/46 DSP cycles per conversion. `tb_dpd_engine` uses EN_PERIOD=56; its reported correction latency is 42 clocks after y_valid. NS Stage A reads e1 at enable, whereas y_valid is generated several clocks after the preceding enable.

**Concern:** the end-to-end correction path may miss the next Stage-A feedback deadline despite meeting the 56-cycle test. Returning before the next Stage-D commit is not sufficient if Stage A already used stale e1.

**Action/closure:** measure enable -> Stage D/y_valid -> corr_valid -> e1 patch -> next Stage A cycle-by-cycle at the actual pacer cadence and clock phases. Compare a complete real-cadence NS/DPD chain against the fixed-point golden model. Close both throughput and routed timing; do not simply relax a TB limit.

### R06 — P0: Raw SOM_PG crosses the intended AP isolation boundary

**Evidence:** `SOM_PG` is wired from SoM VCCAUX_PG to J506 pin 23, alongside AP-domain signals/returns, without an isolator or stated voltage/return contract.

**Action/closure:** remove or isolate/translate that crossing deliberately, and audit every connector, power return, programmer/debug cable and shield for other bypasses. Verify the SoM pin's direction and voltage. Do not claim AP isolation until the full assembled system is reviewed.

### R07 — P0: SPI cell-test enable is blocked by automute status semantics

**Evidence:** `dac_ctrl_plane` rejects cell-test enable if `cmd_unmute`, either relay-drive status or `switch_busy_r` is high. `automute_controller` assigns `switch_busy = (state != ST_PLAYING)`: it is high in ST_MUTED. In ST_PLAYING, a relay drive is asserted instead. Unit tests supply a benign independent switch_busy value.

**Consequence:** the intended safe, muted state does not satisfy the SPI enable condition in the assembled RTL. Manual control uses a different safe-start path.

**Action/closure:** define an explicit safe-to-test/transition-busy contract and test it with the real automute instance, synchronized statuses and actual SPI transactions. Keep output safety while removing the contradictory gating.

**RTL follow-up:** `switch_busy` now asserts only in FLUSHING, SWITCHING,
RAIL_SETTLING or SETTLING. It is low while stably muted and safe for a
diagnostic. The automute timing/state and muted cell-test unit regressions pass;
an assembled hardware/relay qualification is still required.

### R08 — P1: Mute, soak and rail-fault recovery are not a complete safety case

**Evidence:** hardware PG/DONE gates exist, but normal automute has no PG input/thermal-soak timer. The audited baseline's timer assumptions did not match its DSP clock. Current defaults are 15.125M flush clocks (~50.0ms), 3.025M relay-settle clocks (~10.0ms) and 151.25M rail-settle clocks (~500ms) at 302.474MHz. The recorded approximately 120s heat-soak policy is not present as an explicit RTL timer. Host policy is not supplied in this repository.

**Action/closure:** allocate soak/readiness/re-arm responsibility, model mechanical relay release versus supply collapse, verify power restoration cannot reconnect unexpectedly, and test AP failure, stuck request, missing clock, regulator faults, configuration and partial-power states. Reconcile legacy headphone controls with their removed hardware. Quantify analog safe states even while XLR is disconnected.

### R09 — P1: Simulation operating point versus RTL calibration contract

**Evidence:** acceptance results cite MIDCODE 32.5 and DCOFF 0.5. EF3's center is 32.0, DPD histories use code−32, and no explicit DCOFF control was found in inspected RTL. R_off values and calibration sources changed after the extracted cosim112 reference.

**Action/closure:** define the intended mean code, offset placement, LUT index mapping and actual calibration dataset/version. Run the same operating point through Python, RTL and current analog models. Verify idle spectra, DC offset and saturation, not just arithmetic agreement against older vectors.

### R10 — P1: Bank-pointer atomicity does not prove computation atomicity

**Evidence:** FIR bank manager swaps after load completion without a FIR sweep boundary. Calibration store swaps on a post-FIR tick while DPD reads multiple coefficient words serially at the faster conversion cadence.

**Action/closure:** prove each output calculation sees one complete coefficient set, or explicitly define and bound the transition. Stress commits/swaps at every pipeline phase with deliberately distinguishable banks; cover reset, duplicate commits, pending writes and no-audio conditions. Decide whether any update must mute, drain or crossfade.

**Current RTL follow-up (simulation pending):** the FIR bank manager no longer
swaps directly on loader `load_done`. A new `fir_frame_done` pulse follows the
last active interpolation phase for a native input sample; the manager waits
for that pulse before changing `bank_select`, leaving the distributed select
tree time to settle before the next input-frame sweep. The controller unit test
and eight-rate pipeline test cover boundary waiting and per-frame pulse counts.
Process 33632 completed all 20 configured simulations, including the new
boundary and frame-count checks; see `logs/fir_bank_boundary_v1/summary.log`.
This is simulation evidence only; high-resource URAM/MAC route and physical
clock-pipeline margin still need qualification.

### R11 — P1: CDC/reset sign-off and historical timing assumptions

**Evidence:** clock-wide false paths coexist with held-bus max-delay constraints; reset deassertion and source/destination reset epochs differ among blocks. The DSP reset is derived directly from lock; volume and calibration use toggles with independently reset destinations. Current board interfaces differ from the historically routed timing model.

**Action/closure:** review effective exceptions and constraint matches, CDC protocols and MTBF, reset recovery with unchanged source words, stopped clocks and lost/replayed events. Produce fresh timing/CDC reports on the exact build, including diagnostics and current I/O budgets, with no unexplained unconstrained paths.

### R12 - P1: L/R dither correlation and amplitude contract

**Baseline evidence:** both core instances of `tpdf_dither_gen` shared clock,
enable, reset and identical seeds. They produced identical channel sequences.
The generator also used 41-bit uniforms for a 42-bit fractional quantizer,
limiting the triangular dither to approximately +/-0.5 LSB.

**Current RTL follow-up:** the R channel now has distinct nonzero seeds; the
two 42-bit uniforms are subtracted in a 43-bit signed result and the noise
shaper carries that width to its quantizer. The updated Python golden generator
uses the same full-range distribution. A 4096-sample simulation checks that
the L/R streams are distinct and exceed +/-0.5 LSB; the TPDF and DPD golden
regressions pass. This does not qualify analog idle spectra, measured stereo
correlation, or the project noise/distortion targets. Historical noise studies
using the smaller dither range are not evidence for the current implementation.

### R13 — P1: Unclosed power/reference/telemetry electrical details

**Evidence:** generator/BOM retain VERIFY items for UCD90120A address straps, negative-rail MON networks, device straps/footprints and some regulator pin assumptions. Distinct resistor values do not prove distinct valid PMBus addresses. Shared pre-regulator current and thermal budgets are not reconciled with all later loads.

**Action/closure:** datasheet-review every regulator/supervisor/telemetry pin, PG threshold and startup condition; include inactive-domain clamp/back-power currents. Close reference source/sink and loop-stability budgets, unpowered PG behavior, current limits, inrush and worst-case temperature. Check shared REF5F dependency on L-side power and isolation of load currents from reference returns.

### R14 — P0: Connector/footprint selections are not release-ready

**Evidence:** FX18 mating pair and special contacts unresolved; REDCUBE `746xxxxx`; stacker `TW-04-xxx-L-D`; three missing footprint links. Translator MPN uses SN74AXC8T245RHLR while the imported footprint/source naming uses RGY; equivalence has not been established by this audit.

**Action/closure:** verify every orderable MPN against package drawing/pin numbering/land pattern. Select complete 30 mm mating assemblies, power AND return capacity/derating, alignment, clearances and assembly tooling. Correct BOM and symbols before board routing relies on them.

### R15 — P1: Single-channel population and shared dependencies

**Evidence:** channel construction draws both channels; only selected parts have DNP flags. Shared REF7050/REF5F lives on REFS_L and uses L analog supplies. PG_ALL behavior with omitted rails is not captured in an assembly-variant specification.

**Action/closure:** issue explicit first-article/production BOM and placement variants preserving shared references and their supply dependencies. Verify each variant's power-up, PG, clock loading and bring-up test coverage. Do not DNP a whole sheet by channel name.

### R16 — P1: Flash image and AP policy are incomplete handoff items

**Evidence:** BFC2 file and BFDC boot-record formats differ; rate-family encoding differs from SPI convention; boot staging does not choose/load the default FIR bank; header validation, bounds and boot timeout behavior need review. AP calibration/provisioning/power-monitor policy is not included as executable firmware here.

**Action/closure:** provide a production image builder and golden flash image, bounded-memory map and corruption tests, explicit boot/default-filter sequence, and calibration/PMBus configuration ownership. Test real MIG and flash timing, not only a RAM stub. Prove interrupted provisioning cannot silently play invalid data.

### R17 — P1: Isolated serial-interface timing claims need reconciliation

**Evidence:** schematic text still mentions a 50 MHz SPI option, while the later BOM ruling withdrew it for the 1.8 V MAX2244x timing row. SPI uses asynchronous oversampling rather than a demonstrated source-synchronous high-speed return. The latest BOM itself leaves propagation-delay checks open.

**Action/closure:** sign a full AP/isolator/FPGA round-trip and pulse-width budget at worst PVT for every supported rate. Verify no missing SCLK edges, setup/hold on MOSI/MISO and framing/CRC response under jitter. Specify any training/sample-delay procedure and implement it before advertising a fast mode.

### R18 — P1: Analog stability, thermal and fault verification is incomplete

**Evidence:** the physical carrier has not been qualified. The reference extraction contains behavioral amplifier/drive models and later component substitutions; large capacitors, feedforward, high-current offset injection and shared reference loops are not certified by netlist equivalence.

**Action/closure:** review every loop and compliance limit, real component/macromodel accuracy, PVT/mismatch/temperature gradients, capacitive output loading, overload recovery, startup/power-down and injected faults. Include relay release timing, output DC, ESD, chassis return strategy and instrument loading in the bench plan.

### R19 — P2: Documentation and verification scope can mask integration gaps

**Evidence:** historical headers conflict with executable source; testbench clock ratios/status inputs differ from top-level conditions; checker whitelist retains older shared-rail assumptions; existing ERC passes include intentional warning exclusions and unresolved footprints.

**Action/closure:** retain history but label it; make current interface contracts and build manifests explicit. Add integration assertions for rate conservation, latency/deadlines, valid events, no illegal unmute, no mixed banks and reset recovery. Audit checker coverage and compare actual synthesized I/O against generated schematic nets, not only a pin-name list.

### R20 — P1: Analog evidence and manufacturing calibration are not reproducible from Git alone

**Evidence:** performance records refer to external LTspice decks/results and board-specific identified LUT/kernel files. The committed golden vectors validate a particular numerical model, not every later analog plant or a manufactured board.

**Action/closure:** archive the exact decks, model versions, seeds, temperatures, waveforms, identification scripts/configuration, calibration coefficients and held-out validation results. Establish fixture residuals, uncertainty, temperature indexing, storage/versioning, service/recalibration policy and production pass/fail limits.

## 13. Review gates and required handoff package

### Gate A — Architecture/interface reconciliation, before layout freeze

- [ ] Reviewer dispositions for R01–R07 and R14, with chosen contracts reflected in RTL, XDC, generator and documents.
- [ ] One signed truth table for I2S ownership, rate-family encoding, oscillator enables, reset and power-good polarity.
- [ ] Supported sample rates and latency/cycle budgets, including real-cadence DPD feedback deadline.
- [ ] All connector mating pairs and MPN/package/pad mappings resolved; no placeholder manufacturing fields.
- [ ] Shared/L/R population and power dependencies explicit.

### Gate B — FPGA verification and implementation

- [ ] Full top-level tests with the actual automute, isolation directions/delays, clocks, rate ratios and reset/fault behavior.
- [ ] Golden numerical comparison at production cadence, including idle/low-level/overload, DPD on/off and calibration updates.
- [ ] Assertions for FIFO conservation, no dropped valid events, exact RTZ pulse width and stable acknowledged commands.
- [ ] FIR/calibration bank update coherence proven under adversarial phase alignment.
- [ ] Real MIG/flash image tests, CRC/bounds/error handling and boot/default-filter/provisioning recovery.
- [ ] Current synthesis, timing, CDC/RDC, I/O DRC, utilization and constraint-coverage reports with reviewed waivers and exact tool/build hashes.

### Gate C — Circuit and layout review, before fabrication

- [ ] Independently reviewed power/reference/servo calculations and current/thermal budgets.
- [ ] Hardware mute/fault timing analysis; dangerous power-down/output-DC cases tested or bounded.
- [ ] Stackup and routing/matching rules translated into PCB constraints; SI/PI and return-path review.
- [ ] AP isolation, chassis/shield/ESD and partial-power behavior closed.
- [ ] Test access/ground placement, thermal isolation and assembly/rework access checked in the actual layout.
- [ ] BOM/CPL variant, assembly-catalogue/consignment availability and manufacturer DFM checks complete.

### Gate D — Physical qualification

- [ ] Current-limited first power-up with outputs externally disconnected; confirm supplies, references, temperatures and clock logic before enabling conversion.
- [ ] Manual cell/DC/frequency tests captured with known probe/analyzer loading and adequate settling.
- [ ] External fixture/identification calibration validated using held-out stimuli, not just the fit records.
- [ ] N1/D1/D2/D3/L1 measured across the signed load/temperature/supply matrix and both channels, including crosstalk and low-level idle behavior.
- [ ] Repeat tests after warm-up, faults, clock/rate changes, reboot and coefficient/calibration updates.

### Required reviewer deliverables

1. A finding-by-finding disposition: accepted, corrected, experiment required or explicitly deferred, with owner and evidence.
2. An agreed signal/rate/clock/power/reset interface contract and fixed-point scaling ledger.
3. A build manifest naming commit, FPGA geometry, IP versions, constraints, coefficient/calibration/image hashes and tool versions.
4. Circuit/layout review notes covering actual component drawings, electrical margins and thermal assumptions.
5. A verification coverage matrix linking each requirement and risk to a test, analysis or measurement.
6. A release decision separating **safe first-article bring-up**, **functional operation**, and **performance qualification**. None should be inferred from the other two.

**Bottom line:** the architectural approach and substantial implementation work are present, but the current baseline contains unresolved cross-domain contracts. Review and reconcile those contracts before treating this repository as a correct, manufacturable high-performance DAC.
