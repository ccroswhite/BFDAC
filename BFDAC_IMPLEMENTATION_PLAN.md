# BFDAC Implementation Plan
**Last Updated:** 2026-06-29  
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
[7th-Order Noise Shaper]   — upgrade from existing 5th-order
[64-Element DEM]           — barrel-shift rotation, upgrade from 256-element
    ↓ 64 × 1-bit LVDS per channel
[Cascode DAC — 64 cells/channel, 128 stereo]
```

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
| `dac_dsp_core.sv` | ⚠️ Needs update | Must add 3× HB stages, update NS/DEM to new modules |
| `vu13p_dac_top.sv` | ⚠️ Needs update | NUM_MACS=1024, DDR4 ref clk (on-module), 64-cell LVDS ports |
| `noise_shaper_5th_order.sv` | ⚠️ Needs upgrade | → 7th order |
| `dem_mapper.sv` | ⚠️ Needs update | ARRAY_SIZE=64, AMP_WIDTH=7 |
| `lvds_serial_tx.sv` | ⚠️ Needs review | Must support 64-bit output per channel |
| `lvds_blade_tx.sv` | ⚠️ Needs review | 64-cell topology |
| `sys_clock_gen.sv` | ⚠️ Needs update | MMCM for XCVU13P, pending SOM clock details |
| `dac_ddr4_if.sv` | ⏳ Blocked | Awaiting ACVU13 SOM DDR4 topology docs |

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
- [ ] **Step 2.1** — Create `halfband_x2.sv` — parameterized half-band ×2 FIR
- [ ] **Step 2.2** — Create `noise_shaper_7th_order.sv` — extend 5th-order to 7th
- [ ] **Step 2.3** — Create `dem_64.sv` — 64-element DEM barrel-shift
- [ ] **Step 2.4** — Update `dac_dsp_core.sv` — insert HB1/HB2/HB3, swap to 7th-order NS and dem_64, update LVDS port width to 64-bit

### Phase 3 — Top Level + Constraints (partially blocked)
- [ ] **Step 3.1** — Update `vu13p_dac_top.sv` — 64-cell LVDS ports, remove DDR4 ref clk input (on-module), update comments
- [ ] **Step 3.2** — Update `sys_clock_gen.sv` — MMCM config for XCVU13P *(need SOM clock routing confirmation)*
- [ ] **Step 3.3** — Create `vu13p_dac_master.xdc` — pin assignments *(BLOCKED: awaiting ACVU13 SOM connector docs from Alinx)*
- [ ] **Step 3.4** — Update `dac_ddr4_if.sv` — MIG for XCVU13P *(BLOCKED: awaiting ACVU13 SOM DDR4 topology)*

### Phase 4 — Simulation & Verification
- [ ] **Step 4.1** — Run `tb_coef_bank_loader.sv` — verify URAM write/read correctness with new behavioral model
- [ ] **Step 4.2** — Fix `coef_bank_loader.sv` known bug — MAC last-entry data error (tests 2/3/4)
- [ ] **Step 4.3** — Run `tb_dsp_core.sv` — verify full signal chain with HB stages and 7th-order NS
- [ ] **Step 4.4** — Run `tb_system_ddr4_to_fir.sv` — end-to-end with NUM_MACS=64 scaled sim

### Phase 5 — Synthesis & Implementation (blocked on XDC)
- [ ] **Step 5.1** — First synthesis run — check utilization report vs budget above
- [ ] **Step 5.2** — First implementation run — timing closure at 350–400 MHz
- [ ] **Step 5.3** — Iterate on timing — adjust pipeline stages if needed
- [ ] **Step 5.4** — Generate bitstream

---

## Blocked Items — Waiting on Alinx ACVU13 SOM Docs
1. **XDC pin assignments** — need Samtec connector pinout, HP bank assignments
2. **DDR4 MIG configuration** — need SOM DDR4 topology (ranks, speed, bus width)
3. **`sys_clock_gen.sv` MMCM** — need to confirm whether SOM local clock is used or external OCXOs only
4. **LVDS I/O standard** — need to confirm HP bank voltage (1.2V or 1.8V) for LVDS_25 vs LVDS

---

## Design Decisions — Confirmed
| Decision | Value | Confirmed |
|---|---|---|
| Target FPGA | XCVU13P on ACVU13 SOM | ✅ |
| Single FPGA (no dual-FPGA) | Yes | ✅ |
| Coefficient storage | URAM288, 2 MACs/URAM | ✅ |
| NUM_MACS production | 1024 (upgrade path: 2048) | ✅ |
| FIR taps | 1M (upgrade path: 2M) | ✅ |
| Half-band stages | 3× ×2 post-FIR | ✅ |
| Final output rate | 6.144 / 5.6448 MHz | ✅ |
| Noise shaper order | 7th | ✅ |
| DEM cells | 64/channel | ✅ |
| DAC cascode cells | 64/channel, 128 stereo | ✅ |
| Vivado version | 2026.1, Core license | ✅ |
| Sample rates | 48 kHz + 44.1 kHz, dual OCXO | ✅ |

---

## Notes
- The ACVU13 SOM has on-module 20GB DDR4, QSPI Flash, and local clock — these consume NO exposed HP IOs
- All 377 exposed HP IOs are available for user functions
- `coef_bank_loader.sv` has a known bug: last MAC (MAC N-1) writes incorrect data on tests 2/3/4 — fix in Step 4.2
- The 5th-order noise shaper (`noise_shaper_5th_order.sv`) is pipelined and verified — 7th-order extends same architecture
- `dem_mapper.sv` currently has ARRAY_SIZE=256 — will be replaced by `dem_64.sv` (ARRAY_SIZE=64, AMP_WIDTH=7)
- Upgrade from 1M to 2M taps = change `NUM_MACS` from 1024 to 2048 at top level only — all RTL is parameterized
