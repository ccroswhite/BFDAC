# BFDAC Implementation Plan

> **⚠ ARCHIVED / HISTORICAL (Round 30, 2026-07-22).** This document predates
> Rounds 27–30 and is NOT authoritative. Known-stale content includes: LVDS
> cell outputs (now 128 single-ended LVCMOS18 pins → MC100EP52 reclock FFs),
> "XDC blocked on pin assignment" (pins assigned Round 30, XDC §8), DWA-only
> DEM (now dem_dwa per current RTL with 7th-order NS), and the old two-register
> clock control (single SPI reg 0x03 since Round 30). **Authoritative sources:
> `bom.md` (hardware), `Xilinx/*.sv` + `vu13p_dac_top.xdc` (FPGA), and
> `progress.md` (decision log).**
>
> **EXCEPTION (2026-07-26):** the "Predistortion & Calibration" section and
> Phase 6 below are CURRENT (added after cosim rounds 41–71).
> **EXCEPTION (2026-09-03):** "Design Decisions — Confirmed" and "Filter UX
> Features" are CURRENT and maintained (rulings dated 2026-08-22 / 2026-09-03).

**Last Updated:** 2026-06-29 (archived 2026-07-22)  
**Target FPGA:** Xilinx XCVU13P on Alinx ACVU13 SOM  
**Vivado Version:** 2026.1 (Core License — full synth + P&R enabled)  
**RTL Directory:** `c:\Users\ccros\src\BFDAC\Xilinx\`

---

## Confirmed Architecture

### Signal Chain
```
48/44.1 kHz PCM (I2S stereo)
    ↓
[Polyphase FIR ×16]       — 1M taps, 1024 MACs, URAM288 coef storage
    ↓ 768 / 705.6 kHz
[Half-band FIR ×2 — HB1]  — 63 taps
    ↓ 1.536 / 1.411 MHz
[Half-band FIR ×2 — HB2]  — 31 taps
    ↓ 3.072 / 2.822 MHz
[Half-band FIR ×2 — HB3]  — 15 taps
    ↓ 6.144 / 5.645 MHz
[Volume Multiplier]        — DSP48, 4-stage pipeline
[TPDF Dither]
[7th-Order Noise Shaper]   — error-feedback, pipelined, WITH predistortion in
                             the quantizer feedback (static LUT + Volterra kernel,
                             see Predistortion & Calibration below)
[64-Element DWA DEM]       — Data-Weighted Averaging, first-order mismatch shaping
    ↓ 64 × 1-bit direct GPIO per channel
[Cascode DAC — 64 cells/channel, 128 stereo]
```

### Predistortion & Calibration (CURRENT — 2026-07-26, cosim rounds 41–71)
The NS quantizer feedback subtracts the DAC's ACTUAL emitted level, not the
ideal code. Per output sample k with code c_k (c̃ = c − 32):

```
L_k = c_k + LUT_static[c_k]                     — static INL (64-entry LUT)
    + Σ q_t · Π c̃_{k-lag}   (39 Volterra terms) — dynamic transition error
    − stat[c_k] − Σ firw_j·c̃_{k-j} − const      — kernel nuisance decomposition
```

- **Volterra kernel**: 20 quadratic terms (lags 0..5) + 19 cubic terms (lags 0..3);
  ~78 multiplies/sample @ 6.144 MHz (or pre-computed product LUTs); per-channel
  coefficient registers, loaded from QSPI
- **Measured effect (cosim)**: worst-case in-band-edge tone 13.875 kHz @ 0 dBFS:
  HD2 −96.6 → −118.7 dBc, HD3 −103.8 → −120.0 dBc, ALL harmonics ≤ −118 dBc
- **Calibration requirement**: coefficients are PER-BOARD (they encode that
  board's transition physics) and must be identified post-burn-in via the
  external fixture (Phase 6). Accuracy tolerance ~10% to hold −118 dBc —
  factory/service cal only, no owner cal
- **ID protocol (proven in cosim, non-negotiable)**: independent dither seeds
  per record; in-band spectral-projection fitting; nuisance (statics+FIR+drift)
  orthogonalization; raw-action decomposition before embed; held-out validation
  of HD2/HD3 amplitude AND phase before loading coefficients
- **RTL impact**: `noise_shaper_7th_order.sv` needs the predistortion feedback
  path (LUT + kernel MAC + decomposition subtraction) — NOT yet implemented

### Key Parameters
| Parameter | Value | Notes |
|---|---|---|
| NUM_MACS | 1024 | Upgrade path: 2048 (change one parameter) |
| TAPS_PER_PHASE | 64 | 16 phases × 64 = 1024 coefs/MAC |
| Total FIR taps | 1,048,576 | 1M taps/channel |
| Final output rate | 6.144 MHz (48k) / 5.6448 MHz (44.1k) | |
| Noise shaper order | 7th | Upgrade from current 5th |
| DEM cells | 64/channel | Upgrade from current 256 |
| DAC cells | 64/channel, 128 stereo | |
| DSP clock | 350–400 MHz | |
| Theoretical SNR | ~152 dB | 7th-order NS, OSR=153 |

### Sample Rate Clock Sources (on ACVU13 SOM carrier board)
| Clock | Frequency | Derived from |
|---|---|---|
| clk_49m | 49.152 MHz | External OCXO (1024 × 48 kHz) |
| clk_45m | 45.1584 MHz | External OCXO (1024 × 44.1 kHz) |
| DDR4 / local clk | on-module | ACVU13 SOM — no pin consumed |

### XCVU13P Resource Budget
| Resource | Used (1024 MACs) | Available | % |
|---|---|---|---|
| DSP48E2 | ~1,090 | 12,288 | 9% |
| URAM288 | 512 | 1,250 | 41% |
| RAMB36E2 | ~132 | 2,625 | 5% |
| LUTs | ~est. 150K | 1,728K | ~9% |
| HP IOs | ~279 | 377 (SOM exposed) | 74% |

### ACVU13 SOM Pin Budget
| Function | Pins |
|---|---|
| DAC cascode L (64 cells LVDS) | 128 |
| DAC cascode R (64 cells LVDS) | 128 |
| I2S stereo input | 4 |
| SPI control | 4 |
| OCXO A 49.152 MHz (LVDS diff) | 2 |
| OCXO B 45.1584 MHz (LVDS diff) | 2 |
| Ext reset, LEDs, JTAG, misc | 15 |
| **Total** | **283 of 377** |

---

## Existing RTL — Status

### Complete / Recently Updated
| File | Status | Notes |
|---|---|---|
| `fir_polyphase_stereo.sv` | ✅ Updated | URAM288 coef storage, 2 MACs/URAM, NUM_MACS=1024 |
| `fir_polyphase_interpolator.sv` | ✅ OK | Parameterized, no changes needed |
| `polyphase_mac_engine.sv` | ✅ Updated | Comments corrected |
| `polyphase_adder_tree.sv` | ✅ OK | |
| `coef_bank_loader.sv` | ✅ Updated | NUM_MACS=1024 default, parameterized widths |
| `dac_coef_subsys.sv` | ✅ Updated | NUM_MACS=1024 |
| `dac_ctrl_plane.sv` | ✅ Updated | Dual-FPGA ports removed |
| `dac_dsp_core.sv` | ✅ Updated | HB1/HB2/HB3, 7th-order NS, dem_dwa, IOB cascode outputs, single clock |
| `vu13p_dac_top.sv` | ✅ Updated | cascode_l/r[63:0], DDR4 ref clk removed, lvds_bit_clk removed |
| `noise_shaper_5th_order.sv` | ✅ Superseded | Replaced by noise_shaper_7th_order.sv |
| `dem_mapper.sv` | ✅ Superseded | Replaced by dem_dwa.sv (DWA, first-order mismatch shaping) |
| `dem_64.sv` | ✅ Superseded | Replaced by dem_dwa.sv — keep as fallback reference |
| `lvds_serial_tx.sv` | 🗑️ Obsolete | No external FPGA — remove from project |
| `lvds_blade_tx.sv` | 🗑️ Obsolete | No external FPGA — remove from project |
| `sys_clock_gen.sv` | ✅ Updated | lvds_bit_clk removed, single dsp_clk, CLKOUT0_DIVIDE_F=3.5 (280 MHz conservative) |
| `dac_ddr4_if.sv` | ⚠️ Partial | ddr4_refclkp/n ports removed ✅; MIG IP regeneration blocked pending SOM docs |

### Obsolete / To Remove from Project
| File | Action |
|---|---|
| `fpga_sync_if.sv` | Remove — dual-FPGA, not used |
| `artix_dac_top.sv` | Remove — old target |
| `dac_role_cfg.sv` | Remove — dual-FPGA role config |
| `fir_polyphase_mono.sv` | Remove — replaced by stereo |
| `fir_bram_controller.sv` | Remove — replaced by URAM in stereo module |
| `coef_bram.sv` | Remove — replaced by URAM |
| `fir_rom_shard.sv` | Review — may be obsolete |

### New Files to Create
| File | Purpose |
|---|---|
| `halfband_x2.sv` | Parameterized half-band ×2 FIR (shared for HB1, HB2, HB3) |
| `noise_shaper_7th_order.sv` | 7th-order pipelined NS (extend from 5th-order) |
| `dem_64.sv` | 64-element DEM, barrel-shift rotation |
| `vu13p_dac_master.xdc` | Pin assignments — **BLOCKED pending SOM docs** |

---

## Implementation Steps

### Phase 1 — New Vivado Project + RTL Baseline (unblocked, do now)
- [ ] **Step 1.1** — Create new Vivado 2026.1 project, part: `XCVU13P-2FHGB2104I`
- [ ] **Step 1.2** — Add all current `.sv` files from RTL directory as sources
- [ ] **Step 1.3** — Run elaboration only (no XDC yet) — fix any compile errors
- [ ] **Step 1.4** — Remove obsolete files from project (fpga_sync_if, artix_dac_top, dac_role_cfg, fir_polyphase_mono, fir_bram_controller, coef_bram)

### Phase 2 — New Signal Chain Modules (unblocked, do now)
- [x] **Step 2.1** — Create `halfband_x2.sv` — parameterized half-band ×2 FIR ✅
- [x] **Step 2.2** — Create `noise_shaper_7th_order.sv` — extend 5th-order to 7th ✅
- [x] **Step 2.3** — Create `dem_64.sv` — 64-element DEM barrel-shift wrapper ✅
- [x] **Step 2.4** — Update `dac_dsp_core.sv` — HB1/HB2/HB3 inserted, 7th-order NS, dem_64, direct IOB cascode outputs ✅
- [x] **Step 2.5** — Create `dem_dwa.sv` — 64-element Data-Weighted Averaging DEM, first-order mismatch noise shaping ✅
- [x] **Step 2.6** — Update `dac_dsp_core.sv` — swap dem_64 → dem_dwa for L and R channels ✅

### Phase 3 — Top Level + Constraints (partially blocked)
- [x] **Step 3.1** — Update `vu13p_dac_top.sv` — cascode_l/r[63:0] ports, removed DDR4 ref clk, removed lvds_bit_clk, updated header ✅
- [x] **Step 3.2** — Update `sys_clock_gen.sv` — removed lvds_bit_clk port/BUFG, single dsp_clk domain, XCVU13P header ✅
- [x] **Step 3.3** — Pin assignments DONE — Alinx delivered the ACVU13P pin CSVs (`Alinx/ACVU13P-Pin-Assignment-20260703.csv` + per-subsystem sheets); all 273 PACKAGE_PINs live in the single master `vu13p_dac_top.xdc` (audit 2026-08-22: every top-level port pin-referenced) ✅
- [x] **Step 3.4** — DDR4 MIG generated (`Xilinx/scripts/gen_ddr4_mig.tcl` → `Xilinx/ip/ddr4_0/ddr4_0.xci` + .dcp) per the SOM 5× MT40A1G16KD topology; `dac_ddr4_if_mig.sv` wraps it ✅

### Phase 3C — Flash / DDR4 Write Subsystem (2026-08-22, user-directed — all RTL in the P&R budget)
- [x] **Step 3C.1** — DDR4 write path: un-tied the AXI write channels through `axi_dwc_coef` (IP was already READ_WRITE) and the MIG slave; `dac_ddr4_if` (both MIG wrapper and sim stub) now exposes a 128-bit AXI write port for the boot loader ✅
- [x] **Step 3C.2** — `qspi_flash_ctrl.sv`: single x1-SPI engine, dual target (Flash 1 coef on bank-65 pins / Flash 0 bin via STARTUPE3), 4-byte-address opcodes (0x13/0x12/0xDC — both flashes >16 MB), 50 MHz SCK from clk_200m, ARM erase/program/read + boot streaming port with back-pressure. SUPERSEDES `flash_bridge.sv` (3-byte addr, 90 MHz assumption — file retained as reference, unused) ✅
- [x] **Step 3C.3** — `qspi_boot_loader.sv`: **FPGA boots on its own (user ruling)** — at STARTUPE3.EOS + MIG calib, walks the Flash 1 record chain ({magic 'BFDC', dest, len, CRC32} headers), streams payloads through a gray-pointer async FIFO to a ui_clk AXI write master → DDR4; per-record CRC32 verify; boot_ok/crc_fail/axi_fail/record_count status ✅
- [x] **Step 3C.4** — Top integration: STARTUPE3 (shared CCLK, Flash 0 D0/D1 + FCSBO), qspi1 pin muxing, boot gate sync; ctrl-plane regs 0x10-0x14 (FLASH_ADDR_LO/HI+target, FLASH_CMD, FLASH_DATA auto-inc, FLASH_PTR) + status 0x1A / readback 0x1B. **Bin and coefficients are independently field-updateable over ARM SPI (user requirement)**: target bit selects flash; JTAG remains the zero-RTL bring-up/recovery path ✅
- [x] **Step 3C.5** — Multiboot safety: `BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE` in XDC; Flash 0 layout golden@0x0 (never field-written) / update@0x0400_0000, golden build sets NEXT_CONFIG_ADDR (commented template). XDC CDC constraints added for all new clk_200m↔ui_clk crossings ✅
- [x] **Step 3C.6** — Verified: `tb_qspi_subsys` (behavioral SPI flash + AXI memory models) — autonomous 2-record boot with data compare, bad-CRC fault, ARM erase/program/read-back 256 B, target mux; found+fixed an rx bit-alignment bug (last header edge sampled as data). Full regression (`tb_dac_ctrl_plane`, `tb_spi_ctrl_plane`, `tb_cal_coef_store`) + top elab clean ✅

### Phase 4 — Simulation & Verification (DDR4-independent)
- [x] **Step 4.1** — Run `tb_coef_bank_loader.sv` — 256 MACs × 1024 coefs, 4 tests, 0 errors ✅
- [x] **Step 4.2** — Fix `coef_bank_loader.sv` burst_half bug — coef_waddr +0x400 offset on half=1 ✅
- [x] **Step 4.3** — Run `tb_dsp_core.sv` — full signal chain, 0 errors ✅
- [ ] **Step 4.4** — Run `tb_system_ddr4_to_fir.sv` — *(UNBLOCKED 2026-08-22: MIG IP generated — needs the MIG sim model compiled into the xsim flow; also gates `tb_vu13p_top`)*

### Phase 4B — Verification (unblocked, do now)
- [x] **Step 4B.1** — Run `tb_noise_shaper.sv` — 6 tests, 0 errors ✅ (found and fixed: binomial NTF unstable → conservative coefficients + error clamp)
- [x] **Step 4B.2** — Create `tb_dem_dwa.sv` — 7 tests, 0 errors ✅ (found and fixed: PTR_WIDTH truncated amplitude=64 to 0)
- [x] **Step 4B.3** — `tb_halfband_x2.sv` — 9 tests, 0 errors (xsim 2025.2.1) with the Step 4C.4 production coefficients: latency=4, true ×2 rate, DC known-answer exact, impulse response symmetric and matches ROM, 31/15-tap instances live ✅
- [x] **Step 4B.4** — `tb_dac_i2s_ingress.sv` — 11 PASS / 0 FAIL: I2S capture, CDC FIFO integrity, BCLK-loss error assertion + recovery ✅

### Phase 4C — Constraints (unblocked, do now)
- [x] **Step 4C.1** — Superseded by `vu13p_dac_top.xdc` (single master XDC WITH pin locations): primary clocks (clk_200m, clk_mclk, i2s_bclk), generated clocks (dsp_clk, cell_clk), virtual ff_clk + cascode IOB output delays, SPI/relay/LED false paths, bitstream config ✅
- [x] **Step 4C.2** — CDC audit — all 8 RTL crossings verified vs XDC: clk_200m↔dsp_clk (false path), i2s_bclk→dsp_clk (false path), dsp_clk→cell_clk staging/DEM (max_delay 3.5 datapath-only), cell_clk→dsp_clk pace_tgl→pace_sync (**gap found+fixed**: max_delay 3.5 datapath-only), bclk_rst_sync CLR (**gap found+fixed**: false path), cell_rst_sync CLR (false path), ui_clk↔dsp_clk ×4 crossings in dac_coef_subsys (staged commented in XDC §9, enable with MIG merge) ✅
- [x] **Step 4C.3** — Phase 1 elaboration DONE (`scripts/elab_top.tcl`, Vivado 2025.2.1): `synth_design -rtl -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i` — **0 errors, 0 critical warnings**, XDC processed cleanly (317 warnings all from the documented MIG stub tie-offs). Found+fixed one synthesis-legality bug: `tpdf_dither_gen.sv` part-select on function call (Synth 8-12513) → materialized `s1_next/s2_next` nets; `tb_ns_ef3` golden re-run bit-exact (3000 samples, 0 mismatches). ⚠️ Full-device `report_utilization` BLOCKED: no Vivado Synthesis license for xcvu13p on this seat (`scripts/synth_top.tcl` staged, ready to run on a licensed seat → moves to Step 5.1)
- [x] **Step 4C.4** — Design `halfband_x2.sv` coefficients properly (`utils/gen_hb_coefs2.py`, quantized-response verified: HB1 127.3 dB / HB2 140.4 dB / HB3 124.4 dB image rejection, exact unity DC, droop < 0.00001 dB) ✅

- [x] **Step 4C.5** — **FIR audio-window redesign (2026-08-01, user-ratified).** Audit found the "1M-tap" FIR was functionally 16k taps: static per-MAC audio collapsed each 64-coef phase window into one boxcar tap (history 64× too shallow). Rebuilt: per-MAC `TAPS_PER_PHASE`-deep distributed-RAM windows + systolic 4-cycle handoff (replaces NUM_MACS+1 preload), audio/coef co-timed 3-cycle paths, MAC operand pipelines depth-matched (new A2 stage), accumulator load d8→d6, SHADOW_DELAY 8+TL→6+TL. Coefficient layout defined: `c_m[p·TPP+t] = h[p+16·(TPP·m+t)]`. **Bit-exact `tb_fir_window` PASS** (random coef/audio, mod-2^48 reference) at 8×16 and 16×32 configs. Bonus: deep-sweep scaling validated — **4M taps on 1024 MACs** (TPP=256: sweep 4100 < 8333 budget, URAM depth 4096×72 exactly fits) avoids the 67%-DSP/76%-BRAM congestion corner. Follow-ups: re-run downstream TBs (stereo/impulse/dsp_core/e2e/ddr4-to-fir), coef-file tooling must emit the defined layout, re-synth (Step 5.1 numbers are for the wrong datapath) ✅

### Phase 5 — Synthesis & Implementation (MIG IP still pending for DDR4 path; ⚠️ Step 5.1 results predate the Step 4C.5 FIR datapath fix — re-synth required)
- [x] **Step 5.1** — First full synthesis DONE (2026-07-27, **Vivado 2026.1** — NOT 2025.2.1, which cannot check out the xcvu13p license; always `call C:\AMDDesignTools\2026.1\Vivado\settings64.bat` first). Two XDC bugs found+fixed: (1) `create_generated_clock -master_clock` without `-add` rejected (12-672) → dsp_clk/cell_clk kept auto-derived names and ALL CDC false paths silently matched nothing — fixed with the name-only rename idiom on the MMCM CLKOUT pins; (2) `CONFIGRATE 33` → 31.9 (valid US+ enum). Final (`synth51b.log`): **0 errors / 0 critical warnings, setup WNS +0.309 ns TNS 0 @ dsp_clk 280.87 MHz**; utilization LUT 8.6%, FF 5.7%, DSP 2062 (16.8%), URAM 512 (40%), BRAM 0.2%, IOB 177/702. Checkpoint `synth_top.dcp` + utilization/timing/exceptions reports written. Hold: pre-route intra-clock hold is router-fixed; `cell_clk→ff_clk` WHS -0.785 on the 128 cascode ports (vs ±5 ns RTZ tolerance — review output-delay -min at Step 5.2) ✅
- [x] **Step 5.2** — First implementation run — TIMING CLOSED (f13f, 2026-08-25): full production RTL (5M-tap FIR NUM_MACS=1280/TPP=256 + QSPI boot + DDR4 write + cal_coef_store + DPD + ctrl plane) routed on xcvu13p, WNS 0.000 / TNS 0.000 / 0 failing endpoints, hold +0.010, PW +0.039 — `impl_f13f_routed.dcp`. (Plan header said "350–400 MHz"; the ratified production clock is dsp_clk 280.87 MHz per Step 5.1.) Run history below ✅
  - **f12 (2026-08-23): first COMPLETE-RTL routed datum** — f9 flow (NUM_MACS=1280,
    TPP=256, SLR pblocks) + everything since: QSPI flash ctrl + boot loader,
    DDR4 write path, `cal_coef_store`, DPD engines (Step 4D.1), ctrl-plane regs.
    Routed clean, congestion NOT a problem (no windows > level 5 placer/router;
    the mid-route "4226 CLBs high pin utilization" INFO resolved). Timing:
    intra dsp_clk -0.074 (311 endpoints; boot/flash `rd_stall` decode);
    overall WNS -2.35 — see f13 root cause (CORRECTION 2026-08-23: the -0.074
    was initially misread as the design WNS; the -2.35 group is inter-clock).
    Hold clean. DPD/NS/cal logic absent from all top-50 paths. Flow files:
    `scripts/impl_top_f12.tcl`, `scripts/impl_f12_resume.tcl`.
  - **f13 (2026-08-23)**: + registered `rd_stall` in `qspi_boot_loader`
    (gray2bin+sub+compare was 5 LUT levels into the flash byte FSM CEs;
    `tb_qspi_subsys` re-passed — 1 clk stall latency vs 3-word headroom).
    dsp_clk group down to -0.090 (112 endpoints, hb1 DSP→acc CARRY8 chains).
    **Design WNS -2.054 root-caused**: 513 clk_200m→mmcm_clkout0 (ui_clk)
    endpoints — `m_axi_wdata = fifo_rdata` leaves the boot loader
    COMBINATIONALLY, so the async-FIFO read CDC lands in the AXI upsizer
    WDATA regs; the XDC exception's `-to u_boot_loader/*wdata*` matched
    NOTHING and the group was timed at the 0.336 ns unrelated-edge
    requirement (unmeetable by construction; also poisoned phys_opt effort,
    TNS -1000). XDC scope-fixed (drop `-to`, keep `-from fifo_mem*`,
    3.3 ns datapath-only — safe: gray-pointer handshake guarantees word
    stability). **f13b (routed 2026-08-24)**: dsp_clk AND mmcm_clkout0 fully
    MET (hb1 acc chain closed once phys_opt stopped chasing the fake group) —
    ONE endpoint left at -1.874: `wptr_bin_reg[4]` → `wptr_gray_ui1_reg[4]`,
    a register-merge alias (gray[4]==bin[4], synthesis folded the gray MSB
    into the binary pointer, so `-from *gray_reg` missed that bit). XDC:
    added `-from *ptr_bin_reg[*] -to` sync-FF exceptions both directions.
    **f13c (routed 2026-08-24)**: alias path CLEARED; the incremental route
    perturbed 25 hb1 accumulator endpoints to -0.031 (f13c script omitted
    the post-route phys_opt that closed this group in f13b). **f13d**:
    phys_opt AggressiveExplore did NOT move the -0.031/25 group — placement
    exhausted. Path audit: `halfband_x2` products (load on valid_pipe[0]) →
    acc_filtered (captures on valid_pipe[2]) is a TRUE 2-cycle path with
    audio-rate input spacing (no intermediate capture possible) — the tools
    were timing it single-cycle. XDC: `set_multicycle_path 2 -setup / 1
    -hold` on `u_hb*/products_reg*+center_product_reg* → acc_filtered_reg*`.
    **f13e (2026-08-24)**: MCP absorbed the halfband endpoints (25→15);
    remaining 15 at -0.029 are REAL single-cycle FIR paths — `rd_addr_s2[7]`
    → `rd_addr_s3[144..159]` fanout replicas, wr_addr s2→s3, cap_s3 →
    boundary CE, one adder-tree hop (route-dominated). **f13f (2026-08-25):
    ALL CONSTRAINTS MET** — phys_opt AggressiveExplore + AggressiveFanoutOpt
    on `impl_f13e_routed.dcp` closed the last 15 endpoints once the MCP
    removed the unfixable paths from the pool. Final: WNS/TNS 0.000, WHS
    +0.010, `impl_f13f_routed.dcp` + timing/utilization reports.
    FOLLOW-UP for Step 5.3: fold the f13 lessons (registered rd_stall RTL,
    fifo_mem CDC scope, gray-MSB alias exceptions, halfband MCP — all in
    `vu13p_dac_top.xdc` already) into ONE clean synth→route confirmation
    run (`impl_top_f14.tcl` class) to prove closure from scratch before
    Step 5.4 bitstream.
  - **f14 (2026-08-25)**: clean flow launched; synth 0 err / 0 crit-warn;
    place completed; post-place phys_opt: estimated **WNS +0.199, TNS 0**
    (all setup opts skipped — nothing to fix). Then Vivado **OOM'd writing
    `impl_f14_placed.dcp`** (ShapeDB writer ballooned to a reported ~1.9 TB
    peak on this memory-tight box) — placement lost. LESSON: skip placed-
    checkpoint writes on this machine; routed-dcp writes have always
    succeeded. **f14b (routed 2026-08-26): CLEAN-FLOW CLOSURE CONFIRMED** —
    re-place+route from `impl_f14_synth.dcp` after 64 GB pagefile added
    (91.7 GB virtual total; first attempt OOM'd at the 43 GB ceiling; also
    required restarting lmgrd, which does NOT survive reboots —
    `lmgrd.exe -c C:\AMDDesignTools\Xilinx.lic`, license is served
    2100@localhost). Final: **WNS +0.024 / TNS 0 / 0 failing, hold +0.005,
    PW +0.039 — all constraints met** (`impl_f14b_route_timing.rpt`).
    CAVEAT: the final `write_checkpoint impl_f14b_routed.dcp` HUNG (zero
    CPU/IO ~6.5 h, killed) — the DCP writer is unreliable on this box for
    this design; `impl_f14b_routed.dcp` was NOT produced. Reports +
    utilization written. CONSEQUENCE for Step 5.4: generate the bitstream
    in the SAME session as place+route (no intermediate DCP), `impl_f15`
    class: synth dcp → opt/pblocks/place/route/recovery → write_bitstream.
- [ ] **Step 5.3** — Iterate on timing — adjust pipeline stages if needed
- [ ] **Step 5.4** — Generate bitstream

### Phase 4D — Runtime Predistortion + Temp-Comp Datapath (TODO-9; certified algorithm = `dpd_volt.py` R67-90)
**Architecture (proposed 2026-07-30, pending ratification).** The certified DPD is NOT a
separate pipeline block — it is embedded in the EF3 error feedback (R67):
`e = w − (y≪42) − LUT[y] − round(dyn·2^42)` where
`dyn = Σ q_t·Π hist[lag] − STAT[y] − Σ FIRW[j]·hist[j+1]`, hist = (code−32) history.
Kernel dims (frozen `cosim80c3j` class): **39 terms, orders 2+3, max lag 5**, STAT[64],
FIRW[16], max|q| ≈ 4.2 µcode/unit² → history depth 16, products ≤ 21 bits.

- [x] **Step 4D.1** — `dpd_engine.sv` DONE (2026-08-22): per-channel serial 2-lane MAC
  engine off `noise_shaper_ef3` Stage D, implementing the CERTIFIED `dpd_fx_golden.py`
  fixed point (W=18 block-fixed-point mantissas + per-class shared-exponent shifts
  shQ/shS/shF/GF, F=24 action grid, 56-bit modular accumulator — NOT the older 32-bit
  q_int sketch below, which the 2026-08-03 golden model superseded). 31 issue slots,
  measured 42-cycle corr latency (budget ≥51) ✓, one 18×17 DSP48 + one small fabric
  mult per lane (~4 DSP48/channel). `noise_shaper_ef3` Stage-E port added: Stage D
  saves unclamped e_raw + pulses y_valid; corr_valid patches e1 = clamp(e_raw − corr);
  corr_valid never pulsed ⇒ bit-identical legacy behavior (tb_ns_ef3 golden re-passed).
  Coefficients: `cal_coef_store` active bank, widened to 4 read ports (2 lanes × 2
  channels, LUTRAM replication); layout finalized (lut24[64] / Qm[39] / Fm[16] /
  shifts / Sm[64] — `utils/dpd_rtl_gen.py` is the layout+ROM source of truth; lag
  tuple ROM `dpd_lag_rom.svh` generated: 21 order-2 + 18 order-3 canonical basis,
  swap = regen + resynth when Step 6.4 tooling exports the frozen cosim80c3j tuples).
  Ctrl plane: DPD_EN write reg 0x15 (+ readback bit 2 of status 0x15), 2-FF sync to
  dsp_clk. Legacy plan text (superseded): q_int = round(q·2^48) signed 32-bit; hist
  products 21-bit; final ≫6; LUT/STAT 43-bit.
- [x] **Step 4D.2** — ~~Per-temp coefficient banks in FPGA~~ **SUPERSEDED + IMPLEMENTED (2026-08-22 ruling)**: the FPGA holds NO per-temp-point banks and NO temp index — ARM computes the temperature-corrected values and writes ONE working set into `cal_coef_store.sv` (dual-bank 2×512×24b, atomic sample-boundary commit — see Step 6.3). The lag-tuple ROM[39×3] is static and stays with the future `dpd_engine.sv` ✅
- [x] **Step 4D.3** — ~~`dpd_cal_loader.sv` FPGA-autonomous QSPI→DDR4 cal load FSM~~ **STRICKEN (2026-08-22 ruling, reverses the 2026-07-30/31 ruling for CAL DATA ONLY)**: temperature/cal coefficients now arrive over the ARM SPI control plane into `cal_coef_store` — no FPGA-side cal loader, no CRC/staging path for cal data. Retained from this step: ctrl-plane `dpd_enable` bit + status registers (fold into Step 4D.1). The QSPI→DDR4 boot path for FIR FILTER coefficients is IMPLEMENTED as `qspi_boot_loader.sv` (Phase 3C) ✅
- [x] **Step 4D.4** — ~~QSPI cal-store schema~~ **STRICKEN (2026-08-22 ruling)**: cal/temp records are REMOVED from the flash file format — the temperature-indexed cal table lives with the ARM (which needs the table format / generation formula from cal tooling, Step 6.4). Flash retains ONLY the FIR filter coefficient store (`docs/coef_format_v2.md` unchanged in scope); the flash_bridge arbitration question disappears with the loader ✅
- [½] **Step 4D.5** — Verification: BIT-EXACT RTL GATE DONE (2026-08-22):
  `utils/dpd_rtl_gen.py` (integer-exact mirror of the RTL loop, dpd_fx_golden
  semantics) → `tb_dpd_engine` — cal_coef_store + noise_shaper_ef3 + dpd_engine
  chain, 2000 vectors × 2 channels, DPD ON and OFF both 0 mismatches, latency gate
  pass; full regression (tb_ns_ef3 golden, tb_cal_coef_store, tb_dac_ctrl_plane,
  tb_dac_dsp_core) + top elab clean. REMAINING: e2e analog gates — DSP-core sim
  codes → `gen_cosim41`-class deck → LTspice FFT at 27/45 °C, -112 dBc class per
  R87/88, using the REAL cosim80c3j kernel values (needs Step 6.4 cal tooling to
  export mantissas/shifts in the Step 4D.1 layout). ~~Loader TB with QSPI flash
  model~~ (stricken with 4D.3/4D.4 — covered by `tb_cal_coef_store`).

**Decision status (user rulings 2026-07-30):**
(a) ~~RATIFIED (refined 2026-07-31): FPGA loads ALL coefficient data from QSPI→DDR4~~
**PARTIALLY SUPERSEDED (2026-08-22 user ruling)**: the QSPI→DDR4 path now carries
FIR FILTER coefficients ONLY (unchanged: `dac_coef_subsys` sources from DDR4 over
ui_clk). Predistortion/temperature-correction coefficients NO LONGER touch flash or
DDR4 — the ARM computes the corrected values and delivers them over the SPI control
plane into `cal_coef_store` (dual-bank, atomic commit). The old sub-question (DDR4
direct vs on-chip active banks) is CLOSED: on-chip banks, ARM-refreshed.
(b) ~~OPEN — TODO-14: temperature-correction runtime process undefined~~ **CLOSED
(Aug 2026 rulings)**: temperature is captured by sensors on the ARM's I2C bus; the
correction computation (nearest-point ≤ 9 °C table per Step 6.6, interpolation at
ARM's discretion) runs ENTIRELY on the ARM; the FPGA applies whatever values are in
the active `cal_coef_store` bank on every conversion. Remaining artifact: the table
format + generation formula belong to cal tooling (Step 6.4) and ARM software.
(c) **C5 STUDY COMPLETE (2026-08-01, user-commissioned) — data favors C1;
ratification pending.** `utils/mpc_c5_study.py` ran lookahead code-selection
(C5: branch nearest±2, horizons L=0/1/2, cost=Σe²) against the certified C1
(EF3-embedded, `dpd_volt.py` exact) on the cosim80c3j plant, 5 BINs × matched +
×1.1-mismatch legs (results: `sim_run/mpc_c5_results.txt`):
- C1: uniformly stable, SNDR 101.9–104.1, HDs −115…−120 across ALL 10 legs.
- C5 greedy (L=0): +0.5…+2 dB on 4 bins but **collapses −11 dB at BIN 17**;
  C5 look1: +1 dB at 17 but **collapses −12 dB at BIN 11**, loses 1–2.5 dB at
  27/37; C5 look2: no collapses but never beats C1 (−0.4…−1 dB typical).
  Collapse mechanism: code freedom under a raw Σe² cost fights the NTF
  (limit-cycle class) — bin-dependent, unpredictable.
- Zone traffic (code 20–28): NOT consistently reduced (greedy −20% w/ collapse
  risk; look1 +20%). The hypothesized trajectory-steering benefit did not
  materialize.
- Mismatch ×1.1: both controllers degrade gracefully (1–4 dB HDs) — loop
  self-heal reconfirmed.
CAVEAT: cost was Σe² (not NTF/in-band-weighted); a weighted cost could in
principle do better but adds further RTL complexity — burden of proof now on C5.
**DECISION (USER RATIFIED 2026-08-03): C1 — EF3-embedded correction engine,
as certified R67–90. RTL to be structured so the quantize stage remains
replaceable (coef banks / temp indexing / QSPI→DDR4 path are controller-
agnostic).** Step 4D.1 candidate details may now be re-ratified per decision (d).
(d) **FIXED-POINT STUDY COMPLETE (2026-08-03) — data supports fixed point;
format recommendation below, ratification pending.** `utils/dpd_fx_study.py`
ran the ratified C1 controller with quantized model (block fixed-point W-bit
coefficient mantissas + shared per-array power-of-2 exponent; action/LUT on a
2^-F code-LSB grid) against the exact plant, bins 11/17/37
(results: `sim_run/dpd_fx_results.txt`):
- Measured magnitudes: |Q|max 4.2e-6, |STAT|max 1.2e-2, |FIRW|max 3.4e-4,
  |LUT err|max 4.3e-4 code-LSB → total dyn action is ~1e-2 code-LSB scale;
  exponents are static and known → block fixed-point is natural, float's
  dynamic range buys nothing.
- Knee: W=12 loses HD3 to −114 (consistent); W=8 broken (HD3 −97). F=16
  loses ~1 dB; F≤8 is coarser than the entire action (zero correction).
- **W=18, F=24 is transparent on all bins** (HDs −119…−121 ≡ exact) and W=18
  is the native DSP48E2 port width (free). W=14/F=20 also clean → ≥2 format
  steps of margin.
- CAVEAT: two isolated non-monotonic outliers (W=18/F=20 and W=12/F=16 at
  BIN 37, ~91 dB) — dither-seed sensitivity class, not precision-systematic;
  final RTL verification must sweep dither seeds (Step 4D.5 gate).
RECOMMENDED FORMATS: coefficients 18-bit signed mantissa + static per-array
exponent; history samples (code−32) 7-bit; 3rd-order history product ≤16-bit
→ 16×18 fits one DSP48E2; action accumulator ≥24 fraction bits of a code-LSB
(e.g. 32-bit in 2^-24 code-LSB units); static LUT stored on the same grid.
CONSEQUENCE for the NS integration: the EF3 error word must carry ≥24
fraction bits below the code LSB at the correction injection point.
Verification strategy: bit-exact golden model (python-int, ns_ef3 house
pattern) + dither-seed sweep + e2e gate.
**DECISION (USER RATIFIED 2026-08-09): FIXED POINT, W=18 coefficient
mantissas + static per-array exponents, action/LUT on the 2^-24 code-LSB
grid (F=24); W=14/F=20 proven as margin.** Validated by the PURE-INTEGER
golden model `utils/dpd_fx_golden.py` (2026-08-03,
`sim_run/dpd_fx_golden_results.txt`): 8 dither seeds × 5 bins — integer
tracks exact within tenths of a dB; worst-case-over-seeds identical
(~91 dB / −108 worstHD appears in EXACT arithmetic too — the known R30
seed-sensitivity class, NOT precision; Step 4D.5 gate must sweep seeds).
DSP48E2 mapping confirmed: 6-bit history, 3rd-order product exactly 16-bit
signed, term = 16×18 → one DSP48E2, 39-term accumulation ≈40 bits < 48.
`dpd_fx_golden.py` is RETAINED as the Step 4D.5 golden model.
Decisions (a)–(d) now closed → Step 4D.1 (correction engine RTL) unblocked
(TODO-12 MIG still blocks only the DDR4 loader half).

### Phase 6 — Calibration SOP & Tooling (per-board static LUT + Volterra kernel, cosim rounds 41–77)
- [ ] **Step 6.1** — Write calibration SOP document: burn-in (24–72 h powered) → warm-up → static INL chop (R54 protocol) → **≥4 dynamic gate records at tone frequencies spanning the band (e.g. bins 5/11/17/27/37 class) with independent dither seeds** → offline kernel fit → coefficient load → verification gates **at ≥2 frequencies NOT in the fit set plus the worst-case high-frequency tone** (all harmonics below target). Include ADC-distortion defenses: fundamental notch before capture ADC + R58 signal-inversion discriminator. **MANDATORY (TRAP 4, R72/74): the stat/FIR nuisance decomposition of the kernel's raw action must be computed jointly on ALL ID records — it is stream/frequency-dependent, and a single-frequency decomposition over-injects predistortion at every other tone frequency (~17 dB HD2 penalty observed)**. **MANDATORY (TRAP 6, R80): the vector generator's static-LUT input must be the board's OWN current LUT, passed explicitly (no defaults) — a stale LUT injects deterministic static HD (identical across seeds/BINs = the tell)**. **MANDATORY (TRAP 7, R80): fit with ridge shrinkage (RIDGE=1e8 class) and check the raw-action decomposition BEFORE embedding: |static| must be < 1 mV — an unregularized fit can pass held-out validation while carrying tens of mV of null-space content that embeds as a flat ~-98 dBc broadband floor**
- [ ] **Step 6.2** — External calibration fixture (no capture hardware on the product board): audio ADC (AK5572/ES9822-class), passive notch filter, differential buffer. Plugs onto DAC board via cal connector / pogo test points. Fixture ADC is clocked FROM the DUT master clock (exported on the cal connector) for bin-coherent capture
- [ ] **Step 6.2a** — Product board provisions only: cal connector or test points carrying (1) differential DAC output tap per channel, (2) buffered master-clock output, (3) trigger/sync line — plus ground. Keep stubs short/switchable so the tap does not degrade the output net in normal operation
- [ ] **Step 6.3** — FPGA calibration support: code-stream playback from known vectors, cal trigger output for fixture sync, dither seed control. **PARTIALLY DONE (Aug 2026): coefficient store implemented** — `cal_coef_store.sv` dual-bank 2×512×24b store (per channel: stat[64] @ 0-63, kernel[39] @ 64-102, FIR[16] @ 103-118, addr[8]=L/R), ARM writes the shadow bank over SPI (regs 0x0C CAL_ADDR / 0x0D CAL_DATA auto-inc / 0x0E CAL_COMMIT / 0x0F CAL_RDADDR; status 0x18, readback 0x19), commit swaps banks atomically at the 768k sample tick (gapless, FIR bank_select pattern); verified by `tb_cal_coef_store` (6 tests incl. isolation + atomicity). Non-volatile storage of cal tables moved to the ARM side (temperature-indexed table lives with the processor that computes the correction). Remaining: playback vectors, cal trigger, dither seed control, and the Phase 6 DPD datapath that consumes the store's `dpd_rd_*` port
- [ ] **Step 6.4** — Port ID pipeline to production tooling: `volterra_id2.py` fit (in-band spectral projection, nuisance orthogonalization, **joint multi-record raw-action decomposition — V80/NUALL path with RIDGE=1e8, reference kernel `cosim80c3j`**) + `dpd_study.py` vector generation (explicit LUT arg — TRAP 6) → single operator-runnable cal script with pass/fail report incl. the |static| < 1 mV pre-embed check (TRAP 7)
- [x] **Step 6.5** — Cal tolerance sims DONE (gates 83/84/85, v80 plant, BIN=37): kernel ×1.1/×0.9 → ≤4 dB movement, all harmonics ≤ -104 (core ≤ -114) — **kernel amplitude accuracy not critical**; `.temp 45` with 27 °C cal → HD2/HD3 degrade to -104/-105 (~13 dB) — **temperature is the limiter: hold ±5 °C of cal temp (≈ -115 dBc class) or use a temperature-indexed kernel; factory cal at steady-state operating temp** ✅
- [x] **Step 6.6** — DECIDED (R86-90 recal-at-temperature experiment): **temperature-indexed cal table, NO thermal regulation**. Full 45 °C cal (45 °C LUT `cosim86lut` + 45 °C kernel `cosim86c3j`) restores 27 °C-class performance at 45 °C (gates 87/88: HD2 -112.2/-115.4, HD3 -117.1/-119.9 — vs -104/-105 with stale cal). dT ladder (gates 88/90/89/85): HD2 loss ~2.6 dB @ ±4.5 °C, ~10 dB @ ±9 °C (NOT linear — saturates). **Spec: table spacing ≤ 9 °C (nearest-point), 3 factory cal points (~27/36/45 °C), table indexes BOTH static LUT and kernel (LUT decorrelates over 18 °C, corr -0.17), temp sensor (NTC) at the cell array, recal advisory if outside table range.** Feeds 6.1 (SOP: cal at 3 chamber temps post-burn-in) and 6.3 (temp-indexed coefficient store in QSPI) ✅
- [ ] **Step 6.7** — Temperature sensors (4 total, per 6.6 decision): (1) converter/cell-array section, (2) I-V + reconstruction filter section, (3)+(4) one per V section (L/R). Update: **architectural documentation** (system doc + Fig block diagram — sensor placement, cal-table temp-index data path), **schematic** (sensor MPN selection — I2C digital sensors e.g. TMP117/MCP9808 class or NTC + ADC; placement adjacent to the cell array / IV opamps / V-stage heatsinks; I2C bus routing to the APPLICATION PROCESSOR — not the FPGA, per RTL decision below), **RTL** — LOCKED + IMPLEMENTED (Aug 2026): the **application processor reads the temperature sensors AND computes the corrected coefficient values** (nearest-cal-point / interpolation — all temperature math on ARM); the FPGA only stores and applies them. NO FPGA I2C master, NO cal-fixture ADC near the analog sections, no new isolated IO spanning app board → FPGA board. Implemented as `cal_coef_store.sv` + SPI regs 0x0C-0x0F/0x18-0x19 (see Step 6.3): ARM writes the shadow bank, commit flips active↔shadow atomically at a sample boundary; active values are consumed by the datapath on every conversion from local LUTRAM — no per-sample fetch. Recal-advisory is an ARM-side function. Remaining here: sensor MPN/placement (schematic) + block-diagram update (docs).

---

## ~~Blocked Items — Waiting on Alinx ACVU13 SOM Docs~~ ALL CLEARED (audit 2026-08-22)
1. ~~XDC pin assignments~~ — **RESOLVED**: Alinx pin CSVs in `Alinx/` (2026-07-03 delivery); `vu13p_dac_top.xdc` carries all 273 PACKAGE_PINs, every top port covered
2. ~~DDR4 MIG configuration~~ — **RESOLVED**: `ddr4_0` MIG generated (`Xilinx/ip/ddr4_0/`, 5× MT40A1G16KD per SOM topology, `gen_ddr4_mig.tcl`)
3. ~~`sys_clock_gen.sv` MMCM source~~ — **RESOLVED by design**: external OCXOs via LMK00304 mux (single 0x03 register drives DSP family + mclk mux); Step 3.2 done
4. ~~LVDS I/O standard~~ — **RESOLVED**: only the clk_200m/mclk differential inputs use LVDS; XDC commits to LVDS (1.8 V HP) on CSV-assigned pins

Remaining external dependency: NONE for P&R. Next hardware gate is the circuit
diagram (manufacturing release). ~~which also gates the tap-count re-evaluation~~
— tap count for initial release was settled 2026-09-03 by coefficient-storage
capacity (see Design Decisions: FIR taps).

---

## Design Decisions — Confirmed
| Decision | Value | Confirmed |
|---|---|---|
| Target FPGA | XCVU13P on ACVU13 SOM | ✅ RE-RATIFIED 2026-08-11 — KU15P rejected on CX tenets, see below |
| Single FPGA (no dual-FPGA) | Yes | ✅ |
| Coefficient storage | URAM288, 2 MACs/URAM | ✅ |
| NUM_MACS production | ~~1280 × TPP=256~~ → **1M geometry TBD: 1024×64 (original TB-verified) or 256×256 (keeps f15b deep-sweep geometry)** | ⏳ RULING NEEDED (2026-09-03); 1280×256 stays the proven 5M configuration (f15b WNS 0.000) |
| FIR taps | **1,048,576 (1M) for INITIAL RELEASE** — 5.24M retained as a proven, future option | ✅ RULING 2026-09-03 (supersedes 2026-08-22 "hold at 5M / defer"): driver is coefficient STORAGE, not FPGA cost — see next row |
| Coefficient storage / filter count | SOM Flash 1 (MT25QU01G, 128 MiB) holds ALL coefficient records; Flash 0 = golden + update bitstreams (64 MiB slots). Per filter: 5M taps = 21.0 MB (32-bit records) → **6 filters**, 11.8 MB (18-bit packed) → **10**; 1M taps = 4.19 MB → **31**, 2.36 MB packed → **56**. Halve for separate 44.1k/48k designs. | ✅ RULING 2026-09-03: target ≥32 selectable filters for the "sounding" phase → 1M taps; 18-bit record packing is OPTIONAL headroom (31 fit unpacked). Exceeding ~10 filters at 5M needs baseboard flash or ARM→DDR4 filter streaming |
| Filter switch mechanism | Dual-bank, ON-DEMAND load into the shadow bank while audio plays from the active bank, atomic swap, no fade (gapless). Latency: ~4.4 ms @ 1M, ~22 ms @ 5M (drain-bus bound, 1 coef/cycle @ 300 MHz) | ✅ RULING 2026-09-03: next-entry PRELOAD DROPPED as a requirement — UX is "select any filter at any time"; on-demand latency is imperceptible |
| Half-band stages | 3× ×2 post-FIR | ✅ |
| Final output rate | 6.144 / 5.6448 MHz | ✅ |
| Noise shaper | EF3 — 3rd-order error feedback, IIR NTF (Round 30; replaced 7th-order FIR-EF) | ✅ |
| DEM cells | 64/channel | ✅ |
| DAC cascode cells | 64/channel, 128 stereo | ✅ |
| Vivado version | 2026.1, Core license | ✅ |
| Sample rates | 48 kHz + 44.1 kHz, dual OCXO | ✅ |

### FPGA Target Re-evaluation (2026-08-09, user-initiated — competitive/cost review)
CONTEXT: build cost ~$22k vs Schiit ($3.5k retail, modest FPGA + SHARC DSP,
7-bit ΣΔ @ ~6 MHz) and dCS Vivaldi (4 small FPGAs, Ring DAC ~5-bit onto ~48
current sources). User challenge: are we over-provisioned?

FINDINGS OF THE REVIEW:
1. **Converter architecture question CLOSED (user-reviewed)**: our 6-bit/64-cell
   EF3 stream @ 6.144 MHz is ALREADY the dCS/Schiit architecture class. Moving
   to 7-bit/128-cell was evaluated and REJECTED: ~6 dB quantizer headroom we
   don't need (floor is DEM/analog, not quantizer bits), against 2× cell BOM,
   2× IOB/reclock flops, DEM sort network redesign, full re-certification.
   Our differentiation within the class = sort-DEM + RTZ + EF3-embedded
   Volterra DPD + temp-indexed per-board cal (R41–90 campaign).
2. **The NS+DEM+DPD core is tiny** (few hundred LUTs + a handful of DSPs per
   channel) — FPGA size pressure is 100% the FIR tap-count ambition.
3. **The P&R failure that drove the VU13P choice is STALE EVIDENCE**: it was
   the old BRAM-shard engine (deleted 2026-08-01 as dead code). The Step 4C.5
   systolic engine (URAM coef columns, LUTRAM window) has never been placed at
   production scale. Precedent: Chord MScaler runs 1M taps on an Artix-7
   XC7A200T (740 DSPs) — megataps ≠ mega-FPGA if the engine is efficient.
4. **Compute/storage arithmetic** (K taps × 48 kHz/channel): 1M stereo =
   96 GMAC/s ≈ 135–270 DSP48 @ 357 MHz (with/without symmetric pre-add);
   4M = 384 GMAC/s ≈ 540–1080 (or ~350 @ 500 MHz FIR clock). Coef storage,
   symmetric + L/R-shared: 1M ≈ 9 Mb; 4M ≈ 36 Mb — KU15P URAM = 36.9 Mb
   (4M fits ONLY without ping-pong banking → coef switch reloads via DDR4).
5. **4M-tap caveats to resolve before adopting the target**: linear-phase
   group delay ~2.9 s (needs min-phase or short "video mode" filter — Chord
   precedent); filter design tooling at 4M taps is a real task (remez/firls
   numerically hostile — segmented/analytic design); 18-bit coefs bound
   stopband ~−105 dB class regardless of tap count.

DECISION (user-directed): run **synthesis AND IMPLEMENTATION (P&R)** of the
Step 4C.5 engine at production scale as a device matrix before re-ratifying
the target FPGA. Decisive corners:
  (a) 1M taps on KU15P-class (the original smaller-target hypothesis);
  (b) 4M taps on KU15P (storage-marginal, single-bank + DDR4 reload);
  (c) VU13P datum (current SOM; also derisks TODO-22 either way).
Optional middle: VU7P/VU9P if (a)/(b) fail timing/congestion. The pinout
budget (128 cell pins + reclock + DDR4 + QSPI + I2S + clocks vs bank count)
rides along with the matrix. SOM availability for the winning part is part
of the decision (ACVU13 is committed only if VU13P wins).

REVISED PLAN (2026-08-10, USER RATIFIED): tap target = **2M (not 4M)**;
KU15P-FIRST with FULL RTL incl. DDR4 MIG (if it closes, the VU13P run is
redundant — strict superset). SOM identified: **Alinx ACKU15**
(XCKU15P-2FFVE1517I, ~$3.9k, 344 IOs = 256 HP + 88 HD, 10 GB 80-bit DDR4 —
SAME 5× MT40A1G16KD topology as ACVU13 C0 → one MIG config serves both).
KEY FINDING: URAM count is bound by coef READ BANDWIDTH (2 MACs/URAM), not
capacity — current RTL (1024 MACs, TPP=64, dual-bank-in-word) needs 512
URAMs vs KU15P's 128. Ratified RTL changes to make KU15P honest:
  1. Plumb TAPS_PER_PHASE to top (hardcoded 64 at dac_dsp_core instantiation);
  2. Symmetric coefficient fold — **CORRECTED 2026-08-10**: for even-length
     linear-phase, mirror pairs span phases (p,k)↔(15−p,2K−1−k) and feed
     DIFFERENT outputs in DIFFERENT sweep passes → the DSP48 pre-adder CANNOT
     halve multiplies in this time-multiplexed engine (the RTL hook comment
     was wrong). The fold halves STORAGE only: store phases 0..7; mirrored
     phases read with reversed tap address (global transform) + reversed MAC
     index (kept LOCAL by hosting mirror-pair MACs {m, N−1−m} in the same
     URAM → lane mux, no cross-connect);
  3. 8-MACs/URAM packing: 2 ports × 4 single-bank 18b lanes (port A is
     write-only today; loading occurs only under mute, so both ports can
     read during sweeps). Dual-bank gapless switching REPLACED by
     DDR4-reload-under-automute: ~2.9 ms @ 357 MHz for 1M unique coefs,
     hides inside the existing 20 ms MUTE_DELAY relay window — coefficient
     switches already only occur under mute (rate change / filter select).
Decisive run: KU15P full RTL, NUM_MACS=512/ch, TPP=256, storage-folded →
2M taps: 1024 DSP (52%), 64 URAM (50%, 98% internal fill), sweep 4100/7437
(55%), window LUTRAM ~19%. Fold is REQUIRED for KU15P (unfolded 2M = 97.6%
of device URAM). Loader + coef-layout tooling change with the fold.

**DECISION (USER RATIFIED 2026-08-11): KU15P campaign TERMINATED — target
remains XCVU13P on ACVU13 SOM.** The KU15P plan was tested against customer-
experience tenets and failed on two counts:
1. **Min-phase / short-latency filter options are a COMMITTED product tenet.**
   Min-phase coefficients are asymmetric → cannot use the symmetric storage
   fold. The fold was REQUIRED for KU15P (unfolded 2M = 97.6% URAM), so
   KU15P architecturally excludes min-phase filters. Tenet-breaking.
2. **Instant A/B filter switching is a differentiating feature.** KU15P
   memory scarcity forced dual-bank removal → reload-under-mute (~23 ms
   audible blip on filter change). Dual-bank gapless switching is RETAINED
   on VU13P.
3. Additional headroom motive: future features (digital EQ etc.) need spare
   DSP/URAM/routing; KU15P was already congestion-marginal with zero margin.
CONSEQUENCES: fold (f3) and dual-bank removal (f4) are CANCELLED as
requirements — coefficient storage stays unfolded, dual-bank-in-word,
supporting symmetric AND asymmetric (min-phase) filter sets uniformly.
The TAPS_PER_PHASE plumbing + multi-burst loader (f2, verified) is KEPT —
it is target-independent and needed for any tap-count growth. Fitment
campaign redirects to the VU13P datum run (former corner (c)): full RTL
synth + P&R at production scale, DDR4 MIG included. Tap target (2M vs 4M
headline) to be settled by that run's resource/timing margins.

### Filter UX Features (2026-08-11, user-directed — codified, final ratification pending)
**FEATURE 1 — VIDEO MODE (Chord-style low-latency mode).** Rationale:
linear-phase megatap group delay (~0.7 s @ 1M … ~2.9 s @ 4M) breaks lip
sync; min-phase group delay is ms-class regardless of tap count.
~~Video mode = a curated low-latency subset with published latency
figures.~~ **REVISED 2026-09-04 (user):** video mode = **exactly ONE reserved
filter** (min-phase or short, zero-padded to the 4 MB bank at staging);
**customers are never shown latency numbers**. Manual engagement (no video
signaling on I2S/USB/SPDIF inputs). Latency budget ≤20 ms end-to-end incl.
halfbands and ingress buffering, checked by the filter builder from the
`.bfc` `latency_us` field — comfortably inside lip-sync tolerance (audio lag
is the tolerant direction: ITU-R BT.1359 ~125 ms detectable, ATSC IS-191
≤45 ms). Mode entry = DAC_MODE 0x0B[0]=1 + FILTER_SELECT_ID 0x17 with the
video filter ID: a normal on-demand dual-bank gapless load (~4.4 ms). **No
RTL beyond what exists**; no latency readback (progress.md TODO-20 closed).

**FEATURE 2 — NAMED FILTERS + USER-CURATED TOGGLE LIST (A/B/x playlist).**
The customer specifies, by name, an explicit ordered list of filters to
cycle through with the filter-toggle control — a single favorite as
default, an A/B pair for comparison, or a longer evaluation sequence.
~~Toggling through the list is seamless (dual-bank preload of the next
entry).~~ **REVISED 2026-09-03 (user):** the list is up to **32 entries**
("sounding" phase will evaluate many designs), and the user may select ANY
filter at ANY time (e.g. 16, then 2, then 29) — not only the next list
entry. Switching is therefore ON-DEMAND: shadow bank fills while the active
bank plays, atomic swap, no fade (gapless); ~4.4 ms @ 1M taps. Next-entry
preload is DROPPED. The first list entry is the user's default; the FPGA
cannot know it at boot (list lives in ARM RAM + FPGA volatile regs), so
**default-filter load at boot is ARM policy**: on BOOT_STATUS(0x1A).boot_ok
the ARM writes the list and issues FILTER_SELECT index 0 (progress.md
TODO-16). Required work — status:
1. **SPI command set** — DONE (regs 0x08 clear / 0x09 append / 0x0A
   advance-or-index / 0x0B DAC_MODE; readback 0x16/0x17; `tb_spi_ctrl_plane`
   20/20). 16→32 entries + direct FILTER_SELECT_ID 0x17 DONE 2026-09-03
   (progress.md TODO-23); latency readback CLOSED as not needed (TODO-20);
2. **Named filter loading from DDR4** — DONE (2026-09-02): `coef_bank_loader`
   directory walk (32-byte entries at DIR_BASE_ADDR, FILT_NOTFOUND /
   FILT_SIZE errors via sticky[6] + CMD_ERR_INFO); routed at 5M, f15b WNS
   0.000;
3. **Coefficient file format v2** — DRAFT `docs/coef_format_v2.md` (header +
   directory spec); 4 open questions pending ratification; record payload
   stays 32-bit/coef (18-bit packing optional, see Design Decisions);
4. **Tooling update** — OPEN (host): emit v2 headers, build the DDR4
   directory at staging, `payload_bytes` = NUM_MACS×COEF_DEPTH×4 exactly
   (4,194,304 B at 1M).

**STORAGE RULING (2026-09-03)** — see Design Decisions table: SOM Flash 1
(128 MiB) is the entire coefficient store; 32 filters at 5M taps cannot fit
(≈380 MB even packed). Initial release ships **1M taps** (31 filters
unpacked, 56 packed); 5M remains a proven future option gated on added
storage (baseboard flash or ARM→DDR4 streaming).

---

## Notes
- The ACVU13 SOM has on-module 20GB DDR4, QSPI Flash, and local clock — these consume NO exposed HP IOs
- All 377 exposed HP IOs are available for user functions
- `coef_bank_loader.sv` has a known bug: last MAC (MAC N-1) writes incorrect data on tests 2/3/4 — fix in Step 4.2
- **RTL Audit complete** — all inter-module port mismatches resolved
- ~~DEM upgraded from LFSR barrel-shift to Data-Weighted Averaging (DWA)~~ **SUPERSEDED (Round 30):** DWA had real idle tones (peak −129.9 dBFS, dwa_tones legs) — production DEM is `dem_sort` (64-element sort-based 2nd-order vector shaper, tones ≤ -168 dBFS, ratified with RTZ)
- ~~`halfband_x2.sv` coefficients are PLACEHOLDER values~~ **RESOLVED (Step 4C.4):** production coefficients designed and quantization-verified via `utils/gen_hb_coefs2.py` — HB1 127.3 dB / HB2 140.4 dB / HB3 124.4 dB image rejection, exact unity DC, droop < 0.00001 dB
- IOB constraint required in XDC: `set_property IOB TRUE [get_cells {*cascode_iob_l_reg[*]}]` and `[*cascode_iob_r_reg[*]]`
- `lvds_serial_tx.sv`, `lvds_blade_tx.sv`, `async_fifo_wide.sv` are now obsolete — remove from Vivado project
- ~~The 5th-order noise shaper is pipelined and verified — 7th-order extends same architecture~~ **SUPERSEDED (Round 30):** the 7th-order FIR-EF had NO DC zero (placeholder coefs, -16 dB SNDR) — production shaper is `noise_shaper_ef3` (3rd-order EF, IIR NTF (1-z)³/(1-z/2)³, verified integer-exact vs `ns_ef3_gen.py`, 136.0 dB in-band SNDR); `noise_shaper_5th_order.sv`/`noise_shaper_7th_order.sv` are obsolete
- ~~`dem_mapper.sv` ARRAY_SIZE=256 will be replaced by `dem_64.sv`~~ **SUPERSEDED (Round 30):** production module is `dem_sort` (ARRAY_SIZE=64, AMP_WIDTH=7), instantiated in `dac_dsp_core`; `dem_mapper.sv` is obsolete
- Upgrade from 1M to 2M taps = change `NUM_MACS` from 1024 to 2048 at top level only — all RTL is parameterized
