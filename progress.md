# BFDAC Progress Notes — RTL + Analog Converter
_Last updated: 2026-07-12_

## Target platform
- XCVU13P-2FHGB2104I on Alinx ACVU13 SOM
- Single top-level: `vu13p_dac_top.sv`
- DSP clock: ~280–357 MHz derived from OCXO via MMCM
- I2S slave: up to 768 kHz (48k family) / 705.6 kHz (44.1k family), 32-bit stereo
- Configuration: ARM SPI master → `dac_ctrl_plane` (no I2C)

## SPI Frame Format
40 bits total: `{R/W[1], addr[7], data[24], crc8[8]}`
- R/W=0 write, R/W=1 read
- CRC-8 poly x^8+x^2+x+1, computed MSB-first over bits[39:8]
- Data field is 24 bits; ARM must not pass values > 24 bits

## SPI Register Map
| Addr | Dir   | Description |
|------|-------|-------------|
| 0x01 | Write | sys_volume [23:0] |
| 0x02 | Write | gain relay target [0] |
| 0x03 | Write | base_rate_sel [0]: 0=44.1k, 1=48k |
| 0x04 | Write | unmute [0] |
| 0x05 | Write | coef_bank_id [3:0] + load trigger |
| 0x06 | Write | clk_source_sel [0]: 0=49m(48k), 1=45m(44.1k) |
| 0x10 | Read  | Magic ID = 0xDAC02026 |
| 0x11 | R/W   | Sticky errors [3:0], write-1-to-clear |
| 0x12 | Read  | Control state: {clk_source_sel, base_rate_sel, gain_target} |
| 0x13 | Read  | Coef loader status |
| 0x14 | Read  | Mute/relay status: {i2s_err, gain_switch_busy, relay_out, unmute} |
| 0x15 | Read  | Clock/PLL status: {ddr4_calib, clk_locked} |

## Clock Mux
- `clk_source_sel=0` → `clk_49m` (48/96/192/384/768 kHz family)
- `clk_source_sel=1` → `clk_45m` (44.1/88.2/176.4/352.8/705.6 kHz family)
- ARM must assert reset before switching (BUFGMUX_CTRL + MMCM relock required)

---

## Functional TODO Plan

- [x] TODO-1: `sys_clock_gen` CLKIN1_PERIOD=22.151 ns, CLKFBOUT_MULT_F=20, CLKINSEL=1, XDC documented
- [x] TODO-2: `gain_switch_busy` wired in `vu13p_dac_top`: automute→wire→ctrl_plane
- [x] TODO-3: `dac_ctrl_plane` header updated to "200 MHz on VU13P"
- [ ] TODO-4: Temperature sensors (4 total, per Step 6.6 / R86-90 decision): (1) converter
  section, (2) I/V + reconstruction filter section, (3)+(4) one per V section (L/R).
  Update: architectural documentation + schematic (schematic.html + bom.md — sensor MPN,
  placement, bus routing to FPGA) and RTL (sensor readout — note the I2C master was
  removed "no I2C devices planned", now reversed; temp registers, nearest-cal-point
  index for the temp-indexed cal table, recal-advisory status; XDC pins)

### RTL-vs-architecture audit gaps (2026-07-30) — identification only, no fixes yet

- [ ] TODO-5: **K3 input-select relay (line/HP) not wired.** Fig 4d + bom.md §7 commit a
  DPDT input-select relay per channel; `automute_controller` sequences `outsel_active`
  internally but exposes NO drive output — no top-level port, no XDC pin. bom.md's
  "(shared with level code, see automute)" note is inconsistent with a physical coil
  needing its own driver bit. Decide + wire: `relay_outsel` output through automute →
  `vu13p_dac_top` → XDC pin → bom.md §7 row correction.
- [ ] TODO-6: **Relay channel-count mismatch.** bom.md §7 lists every relay as ×2/unit
  (per channel) but the FPGA exposes ONE set of relay pins (`relay_line_mute`,
  `relay_hp_mute`, `relay_hp_rails`, `relay_level[1:0]`). Either the channels are ganged
  off one coil-driver bank (must be stated in schematic.html/bom.md + driver current
  budget for 2 coils/pin) or a second pin set is missing. Also: Fig 5b claims cold-start
  servo settle (~90 s) is "covered by output mute relay" — automute has only the 20 ms
  contact delay; the 90 s hold is implicitly ARM policy (spi_unmute) and must be
  documented as such (or a startup timer added).
- [ ] TODO-7: **Temperature sensor architecture undefined** (count/placement/MPN/bus).
  Proposal on the table: 4 sensors (converter array, I/V+filter, V-section L, V-section
  R). Bus choice drives TODO-8. No schematic.html section, no bom.md section. (TODO-4
  covers the doc/RTL update once decided.)
- [ ] TODO-8: **Sensor-bus consequence on FPGA connectivity.** RTL today has an SPI
  SLAVE only (ARM control plane); the I2C master was deleted. If sensors are I2C →
  reinstate/extend multi-target I2C master; if SPI → new SPI MASTER block (FPGA becomes
  both slave and master); if analog NTC → external ADC + its bus. Plus XDC pins and
  ctrl-plane temp/status registers in every variant.
- [ ] TODO-9: **Predistortion + temp-comp datapath absent from RTL.** The architecture
  (cal rounds 41–90, Step 6.3/6.6) commits per-channel static LUT (64-entry) + 39-term
  Volterra-2/3 kernel (+stat[64]+FIR[16] nuisance) predistortion, temp-indexed
  (nearest cal point, ≤9 °C spacing, recal-advisory flag). `dac_dsp_core` chain
  (FIR→HB×3→volume→pacer→dither→EF3→dem_sort→RTZ) has NO DPD stage, no kernel/LUT
  coefficient registers, no temp-index mux, no QSPI cal-store schema (flash_bridge is
  raw erase/write/read only).
- [ ] TODO-10: **Cal/test feedback-loop support absent** (Step 6.2a/6.3 commitments):
  known-vector playback engine, cal trigger/sync output to fixture, dither seed
  control (seeds are hardcoded params in `tpdf_dither_gen`/`dem_mapper`), buffered
  master-clock export provision — no RTL, no top ports, no XDC pins.
- [ ] TODO-11: **Replica-DAC driver missing.** Fig 1 commits an FPGA "replica-DAC
  driver (2 aux outputs / rail)" (bom.md open item 6: "FPGA aux outputs exist" — they
  do NOT in RTL). No driver logic in dac_dsp_core, no top ports, no XDC pins; analog
  circuit realization also still undesigned (board side).
- [ ] TODO-13: **Isolation barrier undocumented** (found 2026-07-30 during Phase 4D
  discussion). The application processor sits on the opposite wall of a galvanic
  isolator from the clean FPGA/DAC domain — this appears NOWHERE in schematic.html or
  bom.md. Document: which signals cross (ARM SPI slave link; anything else? I2S
  source domain TBD — user to confirm), isolator class/MPN, and clean-side domain
  assignment of every peripheral (QSPI flash, temp sensors, relays). RULING captured
  in plan Phase 4D: QSPI is a dedicated full-bandwidth coefficient bus, completely
  separated from the isolated ARM SPI control link.
- [ ] TODO-14: **Temperature-correction runtime process undefined** (user, 2026-07-30).
  Architect end-to-end: (1) DEFINE the temperature coefficient — what quantity is
  stored per temp point (full coefficient-set replicas per R86-90? incremental deltas?
  a parametric correction factor?); (2) CAPTURE — sensor(s), sampling rate, filtering,
  which sensor(s) feed the DAC-correction decision (cell array per 6.6 spec) vs
  monitoring only; (3) AFFECT — how the running correction changes with temperature
  (nearest-point bank swap vs interpolation between points vs continuous scaling),
  switch hysteresis to avoid chatter at bank boundaries, behavior outside table range
  (recal advisory). Table is stored in QSPI and FPGA-loaded (ratified with TODO-9
  decision (a)). Gates Phase 4D Steps 4D.2/4D.3 freeze; depends on TODO-7/8 sensor
  architecture.
- [x] TODO-15: **CRITICAL FIR bug found (2026-08-01 audit) + FIXED (user-ratified) +
  TB-VERIFIED.** The "1M-tap" FIR was functionally a 16k-tap filter: each MAC's
  `audio_in` was STATIC for the whole sweep, collapsing the 64 coefficients of every
  phase window into one boxcar-summed tap (history store was also 64× too shallow).
  Fix (audio-window redesign): per-MAC TAPS_PER_PHASE-deep distributed-RAM windows
  with systolic one-sample handoff (4-cycle, replaces the NUM_MACS+1 preload), one
  global tap-indexed read address pipelined co-timed with the URAM coef path;
  `polyphase_mac_engine` operand pipelines depth-matched (new A2 stage; pre-adder
  moved to stage 3) — the legacy 2-vs-3 stage skew and the accumulator-load timing
  (d8→d6) and SHADOW_DELAY (8+TL→6+TL) were additional latent boundary bugs exposed
  and fixed. Coefficient layout now DEFINED: c_m[p·TPP+t] = h[p+16·(TPP·m+t)].
  Verified: `tb_fir_window` (new, bit-exact vs mod-2^48 reference, random coefs +
  random audio, 40 samples × 16 phases) PASSES at 8×16 (2k-tap) AND 16×32 (8k-tap)
  configs. CONSEQUENCES / follow-ups:
  (a) Step 5.1 synthesis results are for the WRONG datapath — re-synth needed
      (expect +~24k LUT for 1.5 Mb window LUTRAM; audio BRAM removed);
  (b) deep-sweep 4M-taps-on-1024-MACs path now architecturally real: TPP=256 →
      sweep 4100 < 8333-cycle budget, URAM depth exactly fits (4096×72) — the
      67%-DSP/76%-BRAM congestion corner is AVOIDED;
  (c) coefficient-file generation tooling must produce the newly defined layout;
  (d) downstream TBs need re-run: tb_fir_polyphase_stereo, tb_fir_impulse_response,
      tb_dsp_core, tb_e2e_sine, tb_system_ddr4_to_fir;
  (e) debug TBs tb_fir_window_dbg.sv / tb_fir_window_trace.sv deleted after use.
  TB SWEEP RESULTS (2026-08-01, follow-up (d)):
  - tb_fir_polyphase_stereo: **PASS 7/7** after stimulus fix (history priming was
    NUM_MACS+2 samples — correct datapath needs the full K=NUM_MACS·TPP; the DC
    known-answer expectation 2·C·D·K was always the first-principles formula and
    now passes on the REAL math, old design passed it via the collapse coincidence).
  - tb_dac_dsp_core: **PASS** (integration, all tests; 128 updates/sample intact).
  - tb_e2e_sine: **RECALIBRATED + PASSING at the boxcar ceiling (2026-08-01,
    user-directed)**. Three stimulus fixes, ALL TB-side (RTL proven exact along the
    way): (1) boxcar coef 0x6000 → 0x1800 (÷4: corrected FIR sums 2·c·256/phase vs
    the old collapsed 2·c·64 — restores the R30 NS drive/headroom); (2) N_WARM 80 →
    300 (must exceed the now-real K=256 FIR history); (3) N_SKIP 0 → N_WARM·128
    (the 256-sample boxcar fill ramp no longer fits inside the Kaiser edge taper —
    capture-from-reset was polluting half the record; a contiguous 512-sample
    window of the periodic-512 sine stays bin-11 coherent). RESULTS: paced_l (NS
    input) SNDR **163.8 dB** (LTI chain pristine); DEM popcount **106.7 dB**,
    consistent with the −24.7 dB boxcar attenuation of bin 11 against the absolute
    EF3 floor (R30 baseline 135.8 − 24.7 ≈ 111 class), residual is noise-like (top
    bins ~196-199, NO harmonic structure at 22/33/44). During diagnosis the FIR
    output was verified **sample-exact (512/512)** against the true 256-boxcar
    convolution of the actual TB stimulus (the one mismatch red herring: SV int'()
    rounds, python int() truncates). Full-quality 136 dB-class gate needs designed
    1024-tap coefficients — queued with the coef-tooling TODO. Debug taps
    e2e_fir_l.txt/e2e_hb3_l.txt added to the TB (cheap, kept).
  - **Dead-code sweep (2026-08-01, user-directed)**: removed 13 unused RTL files
    (verified uninstantiated by grep of all RTL+TB instantiations): async_fifo_wide,
    async_fifo, lvds_blade_tx, lvds_serial_tx, dem_64, dem_mapper, dem_dwa,
    fir_polyphase_mono, fir_bram_controller, fir_rom_shard, coef_bram,
    shift_register_sipo, volume_multiplier; and 3 obsolete TBs: tb_dem_dwa,
    tb_fir_impulse_response, tb_dsp_core. Synth scripts glob *.sv → self-cleaning.
    NOTE found during sweep: `flash_bridge` is verified (tb_flash_bridge) but NOT
    yet instantiated in vu13p_dac_top (QSPI pins exist, bridge unwired) — belongs
    to the Phase 4D loader integration work.
  - tb_system_ddr4_to_fir: **FAILS — PRE-EXISTING, unrelated to FIR redesign**:
    coef write count 1,048,576 observed vs 65,536 expected (coef subsystem runs
    production params while TB is scaled to NUM_MACS=64; active bank never written
    → X on FIR output). Also needs xelab --relax (legacy multi-driver TB code).
  - tb_fir_impulse_response / tb_dsp_core: were OBSOLETE (dead hierarchy refs /
    LVDS-era ports) — **RETIRED in the dead-code sweep above (user-ratified)**.
- [ ] TODO-12: **DDR4 MIG IP regeneration** for XCVU13P / Vivado 2026.1 —
  `dac_ddr4_if` is a wrapper around the not-yet-generated `ddr4_0` core; ui_clk CDC
  constraints staged commented in XDC §9 (known, previously tracked).

---

## Completed items
- [x] I2C master: multi-byte write, clock stretching
- [x] I2C master removed (no I2C devices planned)
- [x] i2s_rx: BCLK-domain rewrite for 768/705.6 kHz support
- [x] dac_i2s_ingress: toggle-sync CDC + dsp_clk watchdog
- [x] artix_dac_top.sv deleted; vu13p_dac_top.sv is sole top-level
- [x] LVDS, multi-FPGA role/sync infrastructure removed
- [x] Clock source mux (clk_source_sel) added to vu13p_dac_top
- [x] tb_i2c_master, tb_i2s_rx, tb_spi_ctrl_plane written and lint-clean
- [x] Full RTL lint: 0 errors, 0 warnings

## Converter Architecture — Record of Decisions to Date
- **Architecture**: Discrete unary current-steering DAC ("cascode cell" array), fully differential, 64 cells/channel
  - History: 256 cells/channel originally → reduced to 64 (PCB density/routing unbuildable at 256)
  - 64 confirmed sufficient 2026-07-12: quantization SQNR ≈147dB (65 levels, OSR 154, noise shaping); thermal floor ≈138dB; both clear the >128dB target
- **DEM is in the FPGA and is load-bearing**: `dem_64.sv` / `dem_dwa.sv` / `dem_mapper.sv` — 64-element DWA, first-order mismatch shaping, per channel (see BFDAC_IMPLEMENTATION_PLAN.md). Without it, 0.1% component matching → only ~80dB linearity; with it, mismatch becomes shaped out-of-band noise. Component tolerances (0.1% R_tail, THAT300 ΔV_BE) are sized ASSUMING DEM.
- **Noise shaping**: 5th/7th-order noise shapers in RTL → 64-level output at 6.144MS/s to the mapper
- **Post-converter analog**: I/V + V stage downstream of the converter — see "I/V + V Stage" section. DECIDED: virtual-ground transimpedance I/V → converter bus does not swing → 5V rail decision reopened.
- **dCS Ring DAC comparison (2026-07-12)**: same architectural family (unary sources + mapper at 2.8–6.1MS/s; Vivaldi ~46 sources, APEX 92/96). Our 64 sources at 6.144MS/s is in the same design space. Their source surplus = mapper freedom + duty spreading; we already have surplus (64 vs 33 needed levels).
- **Reference noise path (open)**: shared 1.25V reference noise is common-mode gain modulation across all 64 cells — needs aggressive RC filtering to stay below −130dB. Not yet designed.

## Design Rules — Whole Analog Path (recovered 2026-07-12)
- ~~NO integrated op-amps anywhere in the circuit~~ **REVISED 2026-07-12 — hybrid rule**:
  - **I/V core + servo: best-in-class IC op-amps** (TI/ADI — OPA1612-class for I/V core; loop gain IS linearity at 128dB targets, monolithic PSRR/matching win)
  - **Buffer (diamond) + V output stage: purely discrete Class A** — current delivery, thermal freedom, constant-rail-draw requirement
  - Rationale for revision: discrete-only sacrifices 50–60dB of distortion suppression (60–80dB discrete OL gain vs 130dB monolithic); rule was already porous (THAT300, LM4040, LDOs are ICs); composite keeps discrete Class A where it wins (power) and monolithic where it wins (precision)
- **NO capacitors in the audio path** — DC-coupled throughout (hence servo-based CM/offset control)
- Rationale: ultra-premium target — 128dB+ SNR, lowest distortion, highest linearity, no frequency-dependent phase shift
- Revisitable if a compelling case arises, but default to compliance
- Interpretation rulings:
  - RULED 2026-07-12: DC servo does NOT count against the no-capacitor rule — it only injects a DC offset to set common mode. REQUIREMENT: servo output must be extremely clean — no ripple, no noise (servo noise injects as CM directly; any imbalance in the injection network converts it to differential). Implies heavy filtering inside the servo, sub-Hz bandwidth, and matched injection resistors.
  - RULED 2026-07-12: shunt caps to ground ARE allowed for the reconstruction filter (no other way to remove shaped OOB noise). No series caps — signal never passes through a capacitor. Filter corner kept well above 20kHz so there is no filtering/phase shift in the 20Hz–20kHz band. Analog filter order/corner TBD (sized against 5th/7th-order shaper OOB spectrum).
- Sim note: ideal op-amps allowed as behavioral placeholders in LTspice during co-design; final implementation per the hybrid rule above.

## I/V + V Stage — Part/Topology Selections (2026-07-12 evening)
- **I/V core: OPA1612 (LOCKED)** — differential virtual-earth pair, one amp per rail
- **Servo: OPA189 (zero-drift, ±36V)** — sub-Hz bandwidth; chopper ripple killed by servo output filtering; ADA4522 as alternate
- **Diamond buffer: DISCRETE Class A** (fixed current-source bias) — BUF634A rejected for final design (Class AB → signal-dependent rail draw violates constant-rail-draw rule); acceptable as prototyping shortcut only
- **Noise shapers stay DIGITAL** (RTL `noise_shaper_5th/7th_order.sv`) — not an analog circuit, no change from IC decision
- **Reconstruction filter: PASSIVE LC** (series-L/shunt-C, corner ~300–500kHz) — active op-amp filters rejected (caps in feedback/signal path violate no-cap rule; adds noise/distortion after precision stages)
- **FLAGGED TENSION**: TIA stability may require a few pF feedback cap across R_f (signal passes through it at HF). Cascode keeps summing node ~pF which minimizes need. Decide via sim; would need a rule exemption.

## I/V + V Stage — Recovered Requirements (agreed previously, re-recorded 2026-07-12)
- **I/V stage**: virtual-ground transimpedance, followed by a **diamond buffer** with **servo steering to control common mode**
  - CONSEQUENCE: converter output bus does NOT swing → 5V rail/headroom analysis is obsolete; re-evaluate rail (3.3V candidate) and shared-cascode role (capacitance isolation from summing node, not swing shielding)
  - **Servo purpose (confirmed 2026-07-12)**: hold I/V OUTPUT common mode at **0V**, tracking drift of the whole circuit — implemented as servo-trimmed DC offset-current injection into the summing nodes (≈ I_rail_mid + V_sum/R_f ≈ 70mA/side at I_FS=50mA). DC-coupled, no caps. Offset source is IN the audio path → needs reference-grade quietness + matched injection resistors.
  - With CM=0 at I/V output: 2Vrms output setting ≈ unity gain from R_f; V stage provides 4V/6V gain, reconstruction filtering, load drive
- **V stage**: Class A output stage on **±15V rails** — no devices or circuit topology chosen yet; output current requirement NOT YET DECIDED
- **Output level selection**: SPI reg 0x02 drives relays selecting **2V / 4V / 6V** output
  - Use cases: headphones (direct), pre-amp, direct-drive power amplifier
  - NOTE: SPI register currently 1 bit ([0]) — needs 2 bits for 3 levels; update register map + RTL
  - Open: whether relays switch I/V feedback R or V-stage gain
- **Open items**: V-stage bias/output current spec (driven by headphone load case — e.g. 2Vrms into 32Ω ≈ 88mA peak, sets Class A bias ≥ that), device selection, reconstruction filter placement/order, servo design, noise budget allocation across I/V + V

## Power Architecture (recorded 2026-07-12)
- **±15V rail**: ADI LDOs (no TPS7A part reaches ±15V) — LT3045/LT3094-class ultralow-noise pos/neg. Power domain to be REDRAWN around this.
- **Lower analog rails**: cascaded **3× LDO** chains (TI TPS7A family) — multiplied PSRR, very low ripple/noise
- **V stage**: ±15V from linear supply, through multiple LDOs
- **FPGA only** gets switching supplies (current demand of VU13P makes linear impractical)
- Analog rails needed: ±15V (V stage, I/V, offset-injection source), 2.5V cascode bias (µA), 1.25V tail reference (µA), servo supply
- Note: 1.25V LM4040 + RC and 2.5V bias still need their own local filtering — LDO chain feeds them but shunt-reference noise is its own contributor

## ±15V Rail — 6.144MHz Switching-Current Analysis (2026-07-12)
- What the rail sees, decomposed (from cosim1/2 data):
  1. Offset-injection path: pure DC (I(R_off) ripple ±0.04µA — summing node pinned) — no switching content
  2. I/V signal draw: near-constant at audio rate by the converter's constant-sum property (per-rail TIAs draw anti-phase; sum ~constant)
  3. Switching residue: DEM transition glitches at 6.144MHz+, mA-scale — the real exposure
- Mitigation requirements (RECORDED as design rules):
  - **TIA REQUIREMENT: constant rail draw by construction** — Class A with fixed current-source pull-ups, signal steered internally
  - **Per-stage dedicated final LDO** (I/V and V stage separate outputs from common raw rail) — isolates V stage from I/V switching residue
  - **>1MHz passive filtering at every LDO output**: ferrite/L + multi-decade decoupling (100nF+10µF+bulk) — LDO PSRR is spent above ~1MHz, passives must take over; rail caps do NOT violate the no-audio-path-cap rule
  - Layout: keep 6.144MHz decoupling loops local to the converter/I/V; LDO should never see MHz content
- Verification RESULTS (bfdac_cosim3.cir, 2026-07-12): 20mVpp @ 1MHz injected at LDO output; LDO Zout (10mΩ+30nH) + bead (1µH/100Ω damp) + 10µF/100nF decoupling; R_off mismatched 0.1% worst-case; cells static so diff output = pure rail leakage
  - Filter attenuation @1MHz: 20mVpp → 0.49mVpp (−32dB, passive network alone)
  - CM at I/V output: 151µVpp (matches theory: ×R_f/R_off = ×0.31)
  - **Differential leakage: 151nVpp — −151dB rel. 2Vrms FS, at a grossly pessimistic 20mVpp/1MHz disturbance**
  - Total chain rejection: −102dB (filter × CM ratio × 0.1% mismatch), BEFORE reconstruction filter and V-stage CMRR are counted
  - Conclusion: offset-injection path is NOT the rail-noise weak point. Remaining exposure is the real TIA's PSRR (behavioral amp here is perfect) — measure again when discrete TIA replaces the E-source.

## Converter ↔ I/V Interface Contract (co-design working values, bfdac_cosim1.cir)
| Parameter | Value | Owner/notes |
|---|---|---|
| V_sum (servo CM setpoint) | 2.4V | servo; gives cascode V_CE ≈ 0.68V |
| I_FS | 50mA (sweep 25mA pending) | joint — SNR vs I/V burden |
| R_f | 56Ω | → ~2Vrms diff at FS; relay-switched value TBD |
| I/V DC source current | ~27mA/rail mid-code, ~54mA/rail at FS code (incl. static+bleed) | I/V output stage sizing |
| I/V output compliance | up to V_sum + I_FS·R_f ≈ 5.2V | fits ±15V rails easily |
| C at summing node | ~pF (cascode collector only) | converter keeps shared cascode |
| Cascode bias | 2.5V, near-zero current | quiet rail, easy to filter |

## Co-sim Findings (bfdac_cosim1.cir, 2026-07-12)
- **Virtual-ground topology verified end-to-end**: behavioral TIA holds sum nodes at 2.4V ±15µV; tails 774µA ±2µA; bus pinned 1.67–1.77V; off-side leakage <0.2µA — all with **1.8V LVCMOS drive** and a placeholder low-V_th FET (Vto=0.6V)
- **Switch FET spec confirmed by sim**: with Vto=0.6, source node sits at 1.09–1.18V → Q4 V_CE ≈ 0.55V, comfortably active. Real part needs V_GS ≤ ~0.9V at 781µA (Vto(max) roughly ≤0.75V for margin)
- **MAJOR SIMPLIFICATION — no converter power rail needed**: with virtual-ground I/V, ALL cell current is sourced by the I/V amps through R_f. The old 5V/3.3V analog VCC carries zero current (verified: I(V_supply)=0). Remaining converter rails: 2.5V cascode bias + 1.25V reference, both near-zero current → trivially filterable to very low noise. The 5V-vs-3.3V question is MOOT.
- **I/V burden quantified**: each rail's amp sources 14–39mA in this mid-code sim; at FS code ~54mA continuous. This is the Class A discrete TIA's design driver — and the live argument for the 25mA I_FS sweep.
- Placeholder FET model must be replaced with a real, model-verified low-V_th part before locking.

## Co-sim v2 Findings (bfdac_cosim2.cir — offset injection, CM=0)
- **CM=0 scheme verified**: 70mA injected per summing node (180Ω from +15V) → I/V outputs centered at 0V (residual CM ≈ −70mV from deliberately asymmetric test code — this is exactly what the real servo trims out). Differential swing ±0.7V in this partial-code sim; converter internals completely unaffected (tails/bus/sum node identical to v1).
- **Offset source noise gain to output is benign**: rail noise × (R_f/R_off) = ×0.31 per side, common-mode; differential leakage only via R_off mismatch → 0.1% parts + triple-LDO rail is ample.
- **OPEN — offset resistor dissipation**: 180Ω from +15V burns 0.88W per resistor (×4 stereo ≈ 3.5W of heat near the audio path, thermal drift risk). Better: drop from a lower clean LDO rail (e.g. +5V: 37Ω, 0.18W) or split across series/parallel resistor arrays for power spreading. Decide with the LDO rail plan.
- **Servo trim range needed**: at least ±100mV-equivalent (±2mA-scale injection trim) to cover code asymmetry + drift.

## MILESTONE — Co-sim v4: Full Composite I/V + Converter (bfdac_cosim4.cir, 2026-07-12)
- **First full-chain sim**: converter cells (1.8V drive, shared cascodes, offset injection) + REAL composite I/V — OPA1612 macromodel (Aol 130dB, GBW 40MHz, SR 27V/µs) + transistor-level discrete Class A diamond buffer (5551/5401 complements, 5mA sources) in-loop
- **STABLE**: static-cell run (bfdac_cosim4s.cir) is dead quiet — sum node 2.4000000V, PP = 0, no oscillation. Composite loop with discrete buffer in-loop is sound.
- **DC operating point correct**: tails 774µA, CM −71mV (servo's job), diff offset −3.9mV static (R_off 0.1% mismatch, servo trims)
- **Rail draw near-constant**: I(+15V) PP < 1mA with C_c fitted — Class A diamond doing its job
- **NEW QUANTIFIED PROBLEM — DEM glitch settling**: each 6.144MHz cell transition injects charge that rings/settles over ~50–100ns through the finite-GBW loop (sum node PP 0.66V at edges, output tails ~0.2V). Ideal amp hid this; real amp shows it. This is the pre-existing "switching glitch" open item, now measurable. Mitigation study needed: realistic IOB edges (not 1ns), crossing-point timing, summing-node charge reservoir, RTZ, C_f value. THIS IS THE #1 ANALOG WORKSTREAM.
- 47pF split-feedback comp caps (amp out → sum node) fitted as insurance; necessity not yet established (stable static both ways untested) — resolve during glitch study
- OPA1612 modeled as macromodel from datasheet params; swap in TI's official model (sbom396 zip → OPA1612.LIB) for final verification

## Co-sim v5 — OFFICIAL TI OPA161x Model Validated (bfdac_cosim5.cir, 2026-07-12)
- Official Green-Williams-Lis model (sbom396g → `OPA161x.LIB`, copied to LTspice folder; subckt `OPA161x IN+ IN- VCC VEE OUT`, powered from real ±15V nodes)
- **Static run (bfdac_cosim5s.cir): dead stable** — sum node PP = 0, avg 2.4001V (~100µV realistic input offset), tails 774µA, CM −68mV, diff −3.9mV → macromodel conclusions CONFIRMED by official model
- Toggling run: same DC health; glitch settling slightly worse than macromodel (quiet-window sum PP 120mV vs 69mV — real slew/overload recovery behavior) → reinforces glitch study as #1 workstream
- Composite architecture (OPA1612 + discrete Class A diamond in-loop + 47pF split-feedback comp) is VALIDATED with official silicon model

## Glitch Study Round 1 (bfdac_cosim6/7.cir, 2026-07-12)
Three mechanisms identified: (1) crossing-point/dead-zone error — code-dependent → distortion; (2) Crss gate feedthrough; (3) finite-GBW loop recovery.
- **v6 — realistic edges + make-before-break skew** (tedge=3n, skew stepped 0→3n):
  - Slow edges alone (skew=0) made it WORSE than 1n edges (sum quiet PP 197mV vs 120mV) — slower edges widen the break-before-make dead zone where the tail current has no path
  - Skew (FPGA ODELAY, make-before-break) fixes exactly that: 2–3ns skew cuts output glitch PP ~20% (0.62→0.48V) and settling tails ~10%; sum-node disturbance rises slightly (both-ON crowbar interval). **1–2ns skew is the sweet spot; free in FPGA fabric.**
- **v7 — summing-node charge reservoir** (C_sum stepped, C_f co-designed as sqrt(csum/(2π·Rf·GBW))+2p):
  - Bare reservoir cap WITHOUT C_f destabilizes the TIA (330p diverged) — C_f across R_f is mandatory companion
  - 330p+C_f: sum node PP 0.70→0.13V (great for cascode compliance), rail ripple halved, BUT settling tails 30mV→234mV — stored charge discharges slowly through the loop. **Big reservoirs trade spike amplitude for slow tails = wrong direction for settling-based linearity. Keep ≤100p if any.**
- **DOMINANT TERM = loop dynamics**: intended diff step is only 87mV (774µA×2×56Ω) but glitch PP is ~0.6V — 0.5V is loop overshoot/ring. Next lever: C_c/C_f compensation co-optimization for critically-damped settling (glitch study round 2), possibly a faster HF path.
- Context: this deck is worst-case observability (1 cell, no reconstruction filter). Criterion remains CODE-DEPENDENT glitch charge, not absolute amplitude.

## Glitch Study Round 2 — Compensation Sweep (bfdac_cosim8/8b.cir, 2026-07-12) [FINDINGS; DECISIONS PENDING]
2-D sweep C_c (split-feedback, amp-out→sum) × C_f (across R_f), skew=1n, tedge=3n, 21 points total:
- **Monotonic: smaller C_c always better, C_f optimum at 22p.** C_c=47p (the v4 insurance value) was actively hurting — it couples buffer-input swing back into the summing node.
- **PROPOSED (pending user decision): C_c = REMOVED (0), C_f = 22pF across each 56Ω R_f.** cf=47p trades marginal rise improvement for worse fall tails; cf=100p is 4× worse (slow discharge).
- Result vs v5 baseline: glitch PP 0.62→0.41V, settling tails 32→17mV, stable across all 21 points (no C_c needed for stability — R_f‖C_f compensates the composite alone)
- **Residual 0.4V spike is loop slew during the transition itself** (87mV intended step, OPA1612 27V/µs + 40MHz bound). It settles to <20mV within ~25ns — fast and mostly code-independent. Further reduction requires faster amp or architecture change; park unless code-dependence sim shows a problem.
- PROPOSED mitigation stack (pending user decision): (1) C_f=22p, no C_c; (2) 1–2ns make-before-break skew via FPGA ODELAY; (3) fast LVCMOS18 edges (do NOT slow); (4) no sum-node reservoir; (5) RTZ held in reserve.
- NEXT: code-dependence verification — multi-cell deck with different DEM patterns, measure glitch-charge variation vs code (the actual linearity metric).

## Glitch Study Round 3 — Code-Dependence QUANTIFIED (bfdac_cosim9.cir, 2026-07-12)
Deck: 8 live cells + 56-cell static equivalent; k∈{1,2,4,8} cells flip minus→plus simultaneously at t=200n; locked mitigations in place (C_f=22p, no C_c, 1n skew, 3n edges). Metric: excess glitch area glitch_q vs ideal step, normalized per cell.
- **DC step linearity PERFECT**: dstep = 84.9/169.8/339.6/679.2mV — exact ×2 progression (≤20ppm deviation). Static converter linearity is not the problem.
- **GLITCH CHARGE IS CODE-DEPENDENT**: q_per_cell = −5.28/−5.46/−6.57/−8.27 nV·s for k=1/2/4/8 — **+57% growth**. Deviation from ∝k at k=8 is ~24nV·s ≈ 2.6e-2 of a FS sample-area — catastrophic vs 128dB if uncorrected.
- **Root cause is large-signal overload at high k**: sum-node excursion grows 0.31→1.15V (k=1→8) — at k=8 the sum node dips far enough to violate cascode compliance (bus pinned ~1.8V, sum nominal 2.4V) and the loop slew-limits; settling tails explode 7mV→487mV at k=8.
- **Mitigation candidates for Round 4** (in order):
  1. **Per-cell edge staggering** — spread simultaneous flips 1–2ns apart via per-pin ODELAY (free, FPGA). Bounds the instantaneous current step to ~1-cell magnitude regardless of code.
  2. DWA transition-count limiting in RTL (cap cells-per-sample switched, spill to next sample) — trades slight DEM noise shaping for bounded k.
  3. Revisit small sum-node reservoir (~100p + C_f re-fit) purely to bound the excursion within cascode compliance.
  4. Raise sum-node setpoint (2.4→2.7V?) for more downward compliance margin — check OPA1612 CM and offset-injection budget.
- NOTE: worst case k=8-of-8 live cells here corresponds to k up to 64 on the real board — staggering/limiting is not optional, it is REQUIRED.

## Glitch Study Round 4 — Staggering vs Compliance Reservoir (bfdac_cosim9b/9c.cir, 2026-07-12) [FINDINGS; DECISIONS PENDING]
- **v9b — staggered flips (i×2ns ODELAY): made it WORSE.** q_per_cell −5.28→−10.1n (k=8), tails 850mV. Why: 2ns spacing << ~25ns loop recovery, so spikes pile onto an already-displaced sum node and the overload lasts LONGER. Spacing at ≥25ns is infeasible (64×25ns >> 163ns sample). **Staggering is ruled out as primary fix.**
- **v9c — reservoir sized for compliance (C_sum=2.2n + 4.7Ω ESR, C_f refit to 390p, no C_c): solves code-dependence in sim.**
  - q_per_cell = −9.76/−9.74/−9.58/−9.26 nV·s for k=1/2/4/8 — **flat within 5%** (was 57%)
  - Sum-node excursion 25→151mV (was 310mV→1.15V) — always inside cascode compliance, scales linearly
  - Settling is slower but LINEAR (tails scale ∝k) — linear settling = ISI/filtering, NOT distortion. The v7 "slow tails" objection was wrong for linearity purposes; what matters is staying in the linear region.
  - Per-transition charge magnitude rises (−5.3→−9.7n) but it is now code-INDEPENDENT → folds into benign HF, filtered out
  - Convergence: reservoir needs series damping (4.7Ω) + gmin/abstol relaxation in sim
- Candidate design principle (pending user review): make the sum node slow and linear, not fast — bound ΔV=Q/C inside compliance; let the TIA integrate at leisure. NOTE: nF-class caps at the sum node interact with the capacitor-minimalism rule for the audio path — user ruling required.
- SCALING TO 64 CELLS: excursion ∝k → k=64 needs ~8× more C (≈18n) or combine C_sum=2.2–4.7n with DWA transition-count limiting (cap k per sample in RTL). C_f re-fit accordingly. Residual 5% variation may be measurement-window artifact (extend sim to full settle for k=8).
- OPEN DECISIONS (user to ratify, 2026-07-12): (1) sum-node reservoir yes/no; (2) C_f value; (3) make-before-break gate skew yes/no (FPGA domain); (4) DEM/RTL-side mitigations (count limiting) on/off the table. Staggering at 2ns shown ineffective in sim (one configuration tested).

## Decision Review (user rulings, 2026-07-12)
- **Decision 1 — sum-node reservoir: ACCEPTED CONDITIONALLY.** In the working design, NOT locked. Conditions before lock: (a) ISI/settling interaction with V stage + reconstruction filter analyzed; (b) THD-class sim with the reservoir in place; (c) final C_sum/C_f sizing verified at k=64 equivalent.
- **Decision 2 — C_f across R_f: ACCEPTED with numeric phase bound.** Requirement: in-band phase contribution must stay within the quoted values — ≤0.16° at 20kHz (equivalent to a fixed ~22ns delay; group-delay dispersion sub-ps). Any C_f/R_f re-sizing must re-verify this bound (f_c = 1/(2π·R_f·C_f) must stay ≥ ~7MHz). 390pF@56Ω = 0.157° passes; larger C_f values require re-check against the bound.
- **Decision 4 — DEM transition-count limiting: INVESTIGATE FIRST (user ruling).** No RTL commitment. Required data before decision: DEM behavioral sim quantifying (a) transition-count statistics of current DWA vs capped/partial-rotation variants, (b) impact on mismatch noise shaping (SNDR with 0.1% element mismatch), (c) glitch-induced distortion using the SPICE-measured q(k) models with and without reservoir. See dem_study.py.
- **Decision 3 — gate-drive skew: OPTIONAL TUNING KNOB, not a requirement.** v9d sim (reservoir config, k=4, skew −1n→+2n) shows <1% glitch-charge sensitivity — the reservoir neutralizes the dead-zone mechanism. Skew is implemented as a runtime-settable ODELAY tap, DEFAULT = 0 (aligned edges), design must meet spec at default. Registered in the Tuning Knob Inventory below. Revisit only if hardware bring-up shows dead-zone effects beyond the behavioral FET model.

## DEM Study Round 1 (dem_study.py, 2026-07-12) — Decision 4 evidence
Behavioral 64-cell sim, 6.144MHz, −1dBFS 1kHz coherent sine, 0.1% element mismatch, glitch models from SPICE (q_pc(k) cosim9/9c), 2% rise/fall charge-asymmetry ASSUMED (unmeasured — key open input).
| scheme | k_mean | k_max | SNDR mismatch | SNDR glitch (no res) | SNDR glitch (reservoir) |
|---|---|---|---|---|---|
| thermometer (no DEM) | 0.0 | 32 | 76.5 | 99.8 | 96.6 |
| DWA classic | 27.7 | 64 | **127.8** | 27.9 | 44.4 |
| partial rotation r=1 | 2.0 | 32 | 117.7 | 96.2 | **97.2** |
| partial rotation r=2 | 4.0 | 32 | 117.1 | 94.6 | **97.2** |
| partial rotation r=4 | 8.0 | 32 | 121.1 | 76.0 | 78.4 |
| partial rotation r=8 | 13.9 | 32 | 104.9 | 49.2 | 54.8 |
- **KEY FINDING: classic DWA and glitch performance are fundamentally opposed.** DWA toggles ~2×code cells/sample (k_mean 28!) — its rotation makes consecutive selection windows disjoint. Any per-transition charge asymmetry × k(signal) → gross distortion (28–44dB class). Meanwhile low-switching schemes (r=1–2) keep glitch benign but give up ~10dB of mismatch shaping (118 vs 128dB).
- **No scheme in the simple rotation family achieves 128dB on both axes simultaneously.**
- Model caveats: (a) ASYM=2% is assumed — real value must be measured in SPICE (net differential charge, rise vs fall) and drives all glitch columns ~1:1 in dB; (b) differential cancellation physics: ON/OFF inject opposite charge, uniform part cancels, only Δcode + asym·k + q_pc(k)-nonlinearity survive; (c) mismatch numbers exclude quantization (real code comes from noise-shaped modulator upstream).
- NEXT: (1) measure real rise/fall charge asymmetry in SPICE; (2) explore DEM schemes beyond simple rotation (bidirectional DWA, segmented rotation, 2nd-order mismatch shaping with switching constraint); (3) re-run with measured asymmetry; then return Decision 4 to user with the real tradeoff curve.

## Asymmetry Measurement + DEM Study Re-run (bfdac_cosim10.cir, 2026-07-12)
- **cosim10: rise/fall charge asymmetry MEASURED = 0.0145%** (reservoir config, 1 cell up at 200n/down at 800n: q_rise=−9.752nV·s, q_fall=+9.754nV·s, net 1.4pV·s per cycle). Plateau return error 2.9µV — no memory effect visible at this resolution.
- CAVEAT: this is the TOPOLOGICAL asymmetry with identical models both sides. Real hardware adds component-mismatch asymmetry (FET pair Qg spread, R_f/C_f tolerance between rails) — SPICE cannot see that; budget separately (Monte Carlo with mismatched models, or measure on hardware).
- DEM study re-run with measured asym=0.0145%:
| scheme | SNDR_mis | SNDR_glitch (no res) | SNDR_glitch (reservoir) |
|---|---|---|---|
| DWA classic | 127.8 | 65.2 | 80.2 |
| partial rot r=1 | 117.7 | 97.3 | 97.4 |
| partial rot r=2 | 117.1 | 95.2 | 97.5 |
| partial rot r=4 | 121.1 | 94.6 | 97.7 |
- With realistic asymmetry the picture improves ~35–43dB but conclusion holds: **classic DWA still glitch-limited (80dB); partial rotation ~97dB; nothing reaches 128dB on both axes yet.**
- MODEL FIDELITY WARNING before drawing final conclusions: the ~97dB floor may be partly artifact — input code is a bare 6-bit quantized sine (no upstream noise-shaped modulator), so quantization products couple into k=|Δcode| and the glitch error nonlinearly. Refinement needed: drive dem_study with a real delta-sigma modulated code stream (the actual RTL input), which changes both Δcode statistics and in-band error content.
- STATUS: no DEM/RTL changes committed (Decision 4 remains open). Next data: (a) dem_study with modulator-generated code; (b) mismatch-asymmetry Monte Carlo in SPICE; (c) smarter DEM schemes.

## DEM Study Round 2 — Modulator-Driven + q_pc(k) Verification (2026-07-12/13)
dem_study.py now driven by real 2nd-order 65-level delta-sigma code stream (in-band SNDR of code = 133.5dB ✓, mean|Δcode|=1.0, max=3):
| scheme | k_mean | SNDR_mis | SNDR_glitch (reservoir) |
|---|---|---|---|
| thermometer (no DEM) | 1.0 | 76.5 | **105.5** |
| DWA classic | 27.7 | **148.0** | 80.2 |
| partial rot r=1 | 2.3 | 115.8 | 90.4 |
| partial rot r=2 | 4.0 | 114.5 | 84.3 |
- With real modulator code, DWA mismatch shaping is even better (148dB) but glitch unchanged (80dB). Minimal-switching is best for glitch (105dB) but worst for mismatch (77dB). **The tension is confirmed with realistic stimulus; no simple scheme achieves 128/128.**
- **q_pc(k) 5% variation is REAL, not a window artifact** (cosim9e, full 800n settle, tails µV-level: −9.753/−9.734/−9.578/−9.277 for k=1/2/4/8). This term now dominates glitch distortion (asymmetry is only 0.0145%).
- **Mechanism test (cosim9f): C_sum 2.2n→10n halves the variation (5.1%→2.4%)** — sub-linear in C, diminishing returns, and larger C_f collides with the Decision-2 phase bound. Brute-force capacitance won't reach 128dB alone.
- **PROMISING IDEA for round 3 (not simulated yet): constant-k DEM.** If every sample switches EXACTLY K cells (padding with code-neutral dummy swap pairs when fewer are needed), then both the asym·k term and the q_pc(k) term become constants → pure DC offset + fs-rate tone, zero in-band distortion, by construction. Chord's constant-activity philosophy implemented in the mapper instead of the elements. Costs: higher total glitch energy (out-of-band), mapper complexity, k_fixed ≈ 8–16 sizing, mismatch shaping must be preserved within the constrained selection. SIMULATE NEXT.

## DEM Study Round 3 — Does the q_pc(k) compression matter? QUANTIFIED YES (2026-07-13)
dem_study.py extended with error decomposition (modulator-driven code, reservoir models from cosim9e/9f, measured asym 0.0145%). Columns: full model vs compression-only (asym=0) vs asymmetry-only (flat q_pc):
| scheme | SNDR_mis | full (2.2n) | full (10n) | compression only | asym only |
|---|---|---|---|---|---|
| thermometer (no DEM) | 76.5 | 105.7 | 110.5 | 105.7 | 126.2 |
| DWA classic | 148.0 | 80.5 | 81.8 | 81.7 | 81.2 |
| partial rot r=1 | 115.8 | 90.7 | 95.7 | 90.6 | **128.9** |
| partial rot r=2 | 114.5 | 84.7 | 90.2 | 84.7 | 137.7 |
- **VERDICT: the q_pc(k) compression IS the dominant glitch-distortion mechanism** — for every low-switching scheme the full-model SNDR equals the compression-only SNDR to within 0.1dB. The asymmetry term alone would sit at 126–138dB for low-k schemes, i.e. AT/ABOVE target.
- **If the compression were fixed (flat q_pc), the glitch axis clears 128dB** for r=1/r=2 class schemes; remaining gap would be on the MISMATCH axis (r=1 = 115.8dB), not glitch.
- DWA classic is dead either way: at k_mean≈28 even the asym·k term alone caps it at 81dB.
- Bigger reservoir (10n) buys only ~5dB — confirms cosim9f: brute-force C is not the path.
- **CONSEQUENCE — two viable paths forward, both now justified:**
  1. ANALOG: isolate + fix the residual compression mechanism (cosim9f showed sum-node C explains only ~half; suspects: shared q4_base bias coupling, cascode V_CE/Early modulation, I/V large-signal gm) — target flat q_pc, then r=1/2 partial rotation suffices on glitch.
  2. DIGITAL: constant-k DEM (Round 2 idea) — makes BOTH terms constant by construction, sidesteps the analog mechanism, but must preserve mismatch shaping and needs mapper complexity.
- Both paths still need the mismatch axis solved (>115.8dB → 128dB): constrained-selection mismatch shaping study remains open regardless.

## DEM Study Round 4 — Industry Mapper Families Simulated (2026-07-13)
Context ruling (user): flip-flop retiming at the element is acceptable if needed; but the charge/glitch problem is topology-independent — mapper choice is the lever. Added dCS-style randomization and Chord-style constant-activity engines to dem_study.py:
| scheme | k_mean | SNDR_mis | gl 2.2n | gl 10n | gl idealIV | gl asymOnly |
|---|---|---|---|---|---|---|
| random subset (dCS-ish naive) | 19.3 | 99.2 | 81.1 | 84.9 | 87.2 | 87.0 |
| random rot r~U[1,8] | 8.4 | 100.6 | 76.2 | 82.5 | 96.8 | 105.1 |
| **constant-k K=4** | 4.5 | **110.9** | **99.5** | **105.7** | **118.4** | 130.9 |
| constant-k K=8 | 8.3 | 107.7 | 100.1 | 105.8 | 113.1 | 114.1 |
| constant-k K=16 | 14.1 | 113.8 | 94.8 | 95.2 | 95.5 | 95.2 |
- **Constant-k confirmed as the strongest glitch family** (K=4: 99.5dB today, 118.4dB with perfected analog) while keeping decent rotation-driven mismatch averaging (110.9dB). Beats every rotation scheme on glitch by ~9–15dB at equal switching activity.
- **NEW FUNDAMENTAL LIMIT FOUND — parity dither**: every cell toggle changes code by ±1, so toggles-per-sample parity ≡ Δcode parity. Constant-k must alternate k∈{K, K+1}; the resulting q_pc(K)↔q_pc(K+1) and asym·k modulation sets the residual floor (99.5 at 2.2n / 118.4 at ideal analog). k cannot be made strictly constant with 2-way steering cells — this is a topological fact, not an implementation detail.
- **Naive randomization is a dead end on BOTH axes** (mismatch 99.2 — white, unshaped, in-band; glitch 81). Validates that dCS's actual mapper is heavily *shaped* randomness refined over decades, not naive scrambling — reproducing it is a research program, not a feature.
- **Path to 128/128 with constant-k K=4**, budget by axis:
  - Mismatch (110.9 @ 0.1%σ): scales linearly with matching — 0.02%σ elements (precision foil R_tail + THAT300 binning) → ~125dB; or add shaped selection within the constant-k constraint; or calibration/trim.
  - Glitch (99.5 → 118.4 ceiling): needs the analog fixes (regulated cascode + amp linear-region work) to approach the 118 ceiling; the remaining 118→128 gap needs parity-dither mitigation (candidates: even-step modulator (−6dB SQNR), 2× mapper rate, or shaping the K/K+1 choice).
- STATUS: constant-k K=4 is the working mapper candidate. Decision 4 evidence now complete enough to bring back to user.

## DEM Study Round 5 — Parity Mitigation + Greedy Selection (2026-07-13)
Added to dem_study.py: parity-shaped K±1 choice, even-step modulator, greedy usage-balancing cell choice.
- **Greedy usage-balancing: free +7.3dB on mismatch** (110.9 → 118.2 for const-k K=4) at identical k stats. Pure mapper logic, no cost anywhere. ADOPTED into the working candidate.
- **Parity-shaping is a DEFERRED win**: k widens to {3,4,5} → loses 11dB while q_pc is compressed (88.1 vs 99.5 today), but its asym-only floor is 160.2dB. Only enable after analog flattens q_pc. FIX ORDERING: analog first, then par-shaping.
- **Even-step modulator ELIMINATED**: 33-level code stream caps at 127.5dB (< target) and larger |Δcode| worsens glitch (96.1 vs 99.5). Would need 3rd-order modulator to revisit; not worth it given par-shaping exists.

## Analog Study Round 6 — Regulated Cascode (bfdac_cosim12/12b/12c, 2026-07-13)
Per-rail gain-boost E-source drives cascode base to hold bus at 1.75V (idealized boost amp).
- cosim12 (real OPA1612 amp + reg cascode): compression 4.84% — unchanged, confirms Round 5: amp must be fixed first, reg cascode is invisible behind it.
- cosim12b (ideal I/V + A=200): 0.51% → 0.244%. cosim12c (A=1000): **0.116%**. Sub-linear in A → partially loop-gain-limited, partially base-swing Cjc injection (base must swing ΔVbe regardless of A; Cjc≈4.9p couples it into sum node). Discrete realization of the boost amp not yet designed — E-source is the ceiling.
- New dem_study column gl_regCas (ideal I/V + A=1000 q_pc). **MILESTONE — first configs to clear 128dB glitch:**
| scheme | SNDR_mis | gl today | gl idealIV | gl regCas |
|---|---|---|---|---|
| **const-k K=4 greedy-mis** | **118.2** | 99.5 | 118.4 | **128.3** |
| partial rot r=1 | 115.8 | 90.7 | 114.2 | **129.6** |
| const-k K=4 par-shaped | 113.1 | 88.1 | 109.1 | 121.3 (floor 160 as q_pc flattens further) |
- **Remaining gaps to 128/128**: (1) MISMATCH: 118.2 @ 0.1%σ → needs ~0.03%σ element matching (foil R_tail + THAT300 binning/trim) or shaped selection beyond 1st-order; (2) AMP REALISM: regCas column assumes ideal I/V — the real OPA1612 composite sits 28dB below its ideal (90.7 vs 118.4 for const-k). Closing the amp gap is now THE long pole.
- NEXT: (a) realistic amp study — what GBW/slew/topology approximates 'ideal enough' (target: sum-node error linear, not necessarily small); (b) discrete regulated-cascode boost amp design + re-measure; (c) matching budget decision (user, procurement cost).

## Analog Study Round 7 — Realistic Amp Requirements FOUND (bfdac_cosim13/13b, 2026-07-13)
Behavioral front amp (single-pole GBW + slew + tanh input stage, linear range = SR/2πGBW) in place of OPA1612; real diamond + real cascodes kept. Stepped k×cfg:
| cfg | GBW | slew | lin range | compression k=1→8 |
|---|---|---|---|---|
| 1 (≈OPA1612) | 40M | 27V/µs | 107mV | 2.16% |
| 2 | 120M | 80V/µs | 106mV | 1.22% |
| 3 | 400M | 270V/µs | 107mV | 0.57% |
| **4** | **40M** | **270V/µs** | **1.07V** | **0.51% = cascode floor** |
| 5 | 120M | 270V/µs | 358mV | 0.56% |
- **HEADLINE: GBW is irrelevant — input-stage LINEAR RANGE is the whole amp problem.** cfg4 (same 40MHz as OPA1612, 10× linear range) hits the ideal-amp floor exactly. The 151mV k=8 sum-node excursion vs OPA1612's ~107mV linear range is the mechanism. Amp selection criterion rewritten: wide-linear-range (heavily degenerated / JFET / CFB-class) input beats raw speed. NOTE: behavioral cfg1 gives 2.16% vs real OPA1612 4.9% — model captures ~half; real part has additional nonlinearities (CM, output stage); direction still decisive.
- **cosim13b — COMPOSED REALISTIC STACK** (cfg4 amp + regulated cascode A=1000): compression **0.141%** vs 0.116% ideal ceiling. The two fixes compose with no interaction penalty. New dem_study column gl_stack.
- **min-k greedy tested and ELIMINATED**: k=|Δcode| minimal switching gives best-class glitch (125.7) but mismatch collapses to 96.3dB — minimal switching starves the shaper of selection freedom. The const-k swap-pair padding IS the mismatch-shaping engine.
- **STANDINGS with realistic composed stack (gl_stack column):**
| candidate | SNDR_mis @0.1%σ | glitch |
|---|---|---|
| partial rot r=1 | 115.8 | **129.4** |
| const-k K=4 greedy | **118.2** | 126.4 |
- **GLITCH AXIS: SOLVED ON PAPER** (with: wide-linear-range amp + regulated cascode, both realistic). **MISMATCH AXIS is the sole remaining gap**: ~10dB (118→128). Paths: (a) element matching 0.03%σ (foil R_tail + THAT300 binning — procurement cost decision for user); (b) 2nd-order/vector mismatch shaping within the const-k constraint (open research); (c) calibration/trim DAC per cell.
- Analog hardware follow-ups now concrete: choose/design wide-input-range I/V front end (or pre-attenuate excursion); design discrete regulated-cascode boost amp (E-source A=1000 is idealized).

## DEM Study Round 8 — 2nd-Order Vector Shaping Within Constant-k: MISMATCH AXIS SOLVED (2026-07-13)
Upgraded greedy metric from usage integral (1st-order) to acc1 + g2·acc2 (2nd-order vector shaping, (1−z⁻¹)² target), selection freedom unchanged (same k stats, same glitch):
| scheme | SNDR_mis @0.1%σ | glitch (stack) |
|---|---|---|
| const-k K=4 greedy 1st | 118.2 | 126.4 |
| const-k K=4 2nd g2=.25 | 128.7 | 126.4 |
| **const-k K=4 2nd g2=.5** | **132.6** | **126.4** |
| const-k K=4 2nd g2=1 | 131.2 | 126.4 |
| const-k K=8 2nd g2=.5 | 141.9 | 113.9 |
- **+14.4dB from mapper logic alone; g2=0.5 optimal at K=4. NO component-matching upgrade needed** — 0.1%σ standard parts suffice; mismatch error is no longer the system limiter (now above the 133.5dB modulator code stream).
- Robustness vs σ (linear scaling): even 0.3%σ → ~123dB. **Drift/repeatability insensitivity built in** — the shaper nulls whatever the weights are, it never needs to know them. Directly addresses user's calibration-repeatability concern.
- **CALIBRATION ASSESSMENT (user asked to explore after shaping): DEMOTED TO OPTIONAL INSURANCE.** With 2nd-order shaping there is no mismatch gap left for calibration to close. If ever revisited: digital weighted-selection compensation in the mapper (uses measured w_i in the metric) — no analog trim, no repeatability exposure. Not planned.
- CAVEATS/FOLLOW-UPS: (1) 2nd-order vector shapers can have bounded-state/limit-cycle issues — verify acc bounds over long runs + multiple signal levels/DC inputs, add dithered tie-breaking if tones appear; (2) system budget now: code 133.5 ⊕ mismatch 132.6 ⊕ glitch 126.4 ≈ ~125dB total — remaining margin work is glitch (126.4 vs 128, needs the last analog nudge: regcas alone = 128.3) and possibly 3rd-order modulator for code-stream margin.
- **WORKING CANDIDATE LOCKED (paper): constant-k K=4 + 2nd-order vector shaping (g2=0.5), wide-linear-range I/V amp, regulated cascode.**

## Analog Study Round 9 — Discrete Error Amp vs Current Padding (bfdac_cosim14a–e, 15/15b, 2026-07-13)
Attempted discrete realization of the regulated-cascode error amp (per rail: CE stage Q_E w/ 2mA CS load + follower Q_F + comp), then a loop-free alternative.
- **cosim14 (Miller 22p)**: oscillates (loop crossover ~120MHz > follower/bus poles). **14b (100p + 47R base damp)**: worse, large-signal latch. **14c (1.2nF dominant pole at CE node, ~10MHz crossover)**: stable & clean for k=1,2 but k=4 rings and k=8 LATCHES (bus 1.75→0.78V, both rails; diagnosed via time-sliced measures in 14e): during the 1ns make-before-break window the flipping cells short the two buses; the resulting yank displaces the CE-node cap, recovery limited to I_L/C=1.7V/µs, cells fall out of compliance (Q4 saturates) → quasi-stable wrong state for >>600ns. Clamp diode (14d) didn't help — not the saturation-latch path. ALSO: even where stable, 14c q_pc flatness (0.9% k=1→2) was WORSE than plain cascode — a slow loop re-centers the bus AFTER the per-edge charge has already flowed; per-edge suppression requires ≳100MHz-class loop against a nF bus with ns edges. **Fast-enough discrete loop = genuinely hard analog problem; parked.**
- **cosim15 — CURRENT PADDING (loop-free)**: +50mA constant current per rail through the cascode (PNP source into sum node, NPN sink from bus; net-zero through R_f). Reduces relative rail-current modulation → smaller ΔV_BE excursion. Result: compression 0.51%→**0.243%**, unconditionally stable, tail_pp at baseline mV level. **Matches the A=200 regulated cascode with ZERO active loop.** 15b (150mA): 0.237% — NO further gain; the residual is not ΔV_BE-dominated (suspect: amp tanh cubic residue and/or Q5 Early/Cjc) → 50mA is the right size; floor identified.
- dem_study gl_pad column: **const-k K=4 (any greedy variant) = 124.6dB glitch with padding only** — 1.8dB below the full loop stack (126.4), no stability risk, ~50mW/rail extra dissipation.
- **DESIGN OPTIONS on the table (glitch axis, realistic hardware):**
  1. Padding only: 124.6dB — simple, robust, ships. Total budget ~123dB.
  2. Padding + revisit error amp with 3× smaller disturbance (may avoid latch; loop only needs the last 0.1%) — best case 126–128.
  3. Replica feedforward cascode bias (mapper/FPGA knows the code → drive casb with the correct Vbe(I) trajectory, no loop, matching-limited) — UNTESTED, elegant, could exceed the loop.
- Break-before-make gate timing was NOT explored as a fix for the bus-short latch (cells must never open-circuit tails) — but the skew knob exists; smaller overlap may soften the yank.
- **ADDENDUM — IC error amp evaluated (bfdac_cosim16, user question)**: behavioral unity-stable IC model (200MHz and 1GHz GBW, 870V/µs, ADA4817/OPA858-class) + 50mA padding: BOTH oscillate (tail_pp 1.2–2.1V). ROOT CAUSE: Q5 diffusion capacitance at padded current, Cπ ≈ gm·Tf ≈ 2.85S×453ps ≈ **1.3nF** → base-drive pole ~6MHz with 22Ω source — no amp IC can cross over above it. **KEY TRADE DISCOVERED: padding and fast loop are ANTAGONISTIC** (base pole ∝ 1/(gm·Tf); more rail current = slower base). Loop would want LOW rail current + RF-grade cascode (Tf~100ps) + sub-Ω drive — a different design corner, needs a proper frequency-domain design session, not transient shotgunning. IC-vs-discrete verdict: the blocker is the plant (Q5 base), not the amp implementation.
- **DECISION RECOMMENDED: ship the glitch axis on padding-only (124.6dB, zero risk); replica feedforward = the one untested idea that avoids loops entirely; fast-loop redesign = parked with documented requirements.**

## Analog Study Round 10 — REPLICA FEEDFORWARD + BUS CAPS: TARGET REACHED ON PAPER (bfdac_cosim17-series, 2026-07-13)
Replica feedforward: diode-connected replica cascode Q5R (casb=1.75+Vbe(I_copy)) biased by a code-tracking rail-current copy (B-source from gate signals; hardware = small replica DAC/cells from same FPGA outputs). Bonus: diode connection drives Q5 base at 1/gm≈0.35Ω — the stiff source the loops couldn't provide. All with 50mA padding.
| deck | config | compression |
|---|---|---|
| 17 | replica ff, realistic amp | 0.286% (no better than padding — static ΔV_BE wasn't the residual) |
| 17b | replica ff, near-ideal amp | 0.251% (floor isn't the amp either) |
| 17c | sensed-current 'perfect replica' | INVALID (sense path creates spurious feedback, oscillates) |
| 15c | padding only, tedge 3→10ns | 0.216% (edge transient confirmed as residual mechanism) |
| **17d/17e** | **replica ff + 100n BUS CAPS** | **0.0044% / 0.0040% — FLAT, realistic amp** |
- **MECHANISM RESOLVED: the ~0.24% post-padding residual was per-edge transient bus charge.** Big bus caps absorb it — but bus caps are only SAFE because the replica cancels the static ΔV_BE (otherwise C·ΔV ≈ 0.21nC/step swamps everything; this is why caps alone were never an option). **Feedforward and bus caps are complementary halves of one fix: ff kills static, caps kill transient.** 35× below the old idealized-loop ceiling, unconditionally stable, no loop anywhere.
- dem_study gl_ffwd column (q_pc from 17e): **const-k K=4 → 130.8dB glitch; K=4 par-shaped → 151.2dB** (the Round-4 'deferred win' of parity-shaping materialized exactly as predicted once q_pc went flat).
- **NEW COMBINED SCHEME: K=4 par+2nd g2=.5 (parity-shaping + 2nd-order vector greedy): SNDR_mis=130.6, glitch=151.2.**
- **SYSTEM BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.2 ≈ 128.7dB — AT TARGET**, now limited by modulator code stream + mismatch shaping, both digital and both with known upgrade paths (3rd-order modulator; K=6 or g2 tuning).
- **FINAL PAPER ARCHITECTURE: 64 cells + Q5551 shared cascode + 50mA padding sources + replica-feedforward base drive + 100n bus caps + wide-linear-range 40MHz I/V + constant-k K=4 parity-shaped 2nd-order-greedy mapper.** Zero feedback loops added, zero precision parts added, zero calibration.
- HARDWARE FOLLOW-UPS: (1) replica implementation choice (scaled replica cells vs small current DAC) + its matching/timing-skew sensitivity study; (2) bus cap grade (C0G at 1.75V bias) + effect on startup; (3) wide-linear-range amp part selection; (4) shaper long-run stability verification (still pending from Round 8); (5) re-verify asym term (cosim10) under the new analog stack — the 151.2 assumes old ASYM value.
- **BUS CAP SIZING + PHASE AUDIT (cosim17f/18, user requirement: no caps in audio path):** size sweep: 1n→0.139%, 4.7n→0.036%, **10n→0.0047% (= 100n), saturates**. AC analysis (signal current injected at bus): added phase is EXACTLY linear in f → pure group delay, no dispersion. 10n = +0.036° @20kHz (+5ns constant delay) on top of existing 0.205° path phase; 100n = +0.36° for zero extra glitch benefit; magnitude flat to µdB past 100kHz. Framing accepted into record: bus already carries ~1.6nF of NONLINEAR junction capacitance unavoidably; 10n C0G swamps it with linear dielectric (linearity improvement, not a new audio-path element; no series audio current flows through it since replica pins the node). **DECISION: 100n→10n C0G per bus in the final architecture.** Capless fallback if requirement hardens: matched-dynamics replica cells (untested).

## Verification Round 11 — Replica Sensitivity, Shaper Long-Run Stability, Asym Re-measure: ALL PASS (cosim19/19b/20, shaper_stability.py, 2026-07-13)
Closed the three open follow-ups from Round 10. Final architecture verified robust; budget IMPROVED to ~128.8dB.
- **Replica gain-error sensitivity (cosim19, rge ±1%/±5% on the feedforward current copy)**: compression 0.0042–0.0051% across the FULL ±5% range (nominal 0.0047%). Essentially INSENSITIVE — the bus caps absorb transients regardless, and a gain error only leaves (rge)×2.1mV of static ΔV_BE uncancelled. Replica DAC needs no precision: ±5% is trivially met by any implementation.
- **Replica timing-skew sensitivity (cosim19b, tsk 0.5/1/2/4ns replica lag behind main gates)**: ≤2ns → 0.005–0.006% (no degradation); 4ns → 0.017% (still 7× below the old ideal-loop ceiling). FPGA same-bank skew ≪1ns → non-issue. Both replica knobs have huge margin; **replica implementation de-risked**.
- **Shaper long-run stability (shaper_stability.py, standalone; 2^21 samples = 341ms, 6 inputs: −1dBFS sine, −60dBFS sine, silence, DC+0.5, DC irrational (√2−1), DC 99%FS)**: max|acc1| ≤ 13, max|acc2| ≤ 187 in ALL cases, second-half bounds ≤ first-half in ALL cases → **states bounded, no growth, no divergence**. Sine SNDR_mis 130.9 at 2^21 cross-validates dem_study's 130.6. Idle/DC worst in-band spurs −156 to −158dBc (structure only 22–25dB over a very low floor) — no audible limit-cycle tones. ONE flagged corner: DC at 99%FS (code 63.7) → single −130.1dBc spur (eligible-cell population collapses to ~1); still below the −128dB target and unreachable by audio, but if desired, clamping the modulator to ±31 levels restores selection freedom. **No dither needed; Round-8 caveat (1) CLOSED.**
- **Rise/fall asymmetry re-measure on final stack (cosim20 = cosim10 method on replica-ff + padding + 10n caps + realistic amp)**: q_net/q_avg = 0.71e-4 worst (k=4), vs 1.45e-4 on the old reservoir config — **2× better**. dem_study rerun with ASYM=0.71e-4: K=4 par+2nd g2=.5 → glitch **151.7dB** (was 151.2), SNDR_mis 130.6 unchanged. Round-10 follow-up (5) CLOSED.
- **UPDATED SYSTEM BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.7 ≈ 128.8dB — target met with verified margins.** Architecture unchanged from Round 10 (with 10n C0G bus caps per the phase audit). Remaining follow-ups are hardware selection only: replica implementation choice (now known to be non-critical), amp part selection, bus-cap startup behavior.

## Static Study Round 12 — NEW AXIS: STATIC INL FROM CASCODE BASE CURRENT (cosim22-series, 2026-07-13)
User asked about multi-tone AC testing → led to stepped-bias AC (cosim18b: code-dependent group delay ±1ns via Q5 1/gm, replica-frozen worst case), delay-vs-code transient (cosim21: edge-shape wiggle confirmed out-of-band, charge flat), and then a static DC transfer sweep (cosim22, code 0..56, tight reltol) which exposed a REAL problem:
- **Static INL: ±1.2ppm S-curve → HD2 −123.4dB / HD3 −122.7dB at −1dBFS. THIS DOMINATES THE BUDGET (misses the 128dB target on its own).** Confirmed not numeric (identical at reltol 1e-6/1e-8), not the amp (ideal E-source same), not Early (Vaf=100k same), not bleed (removed, same), not the live cells (idealized, same).
- **ROOT CAUSE (cosim22n): Q5's NON-IDEAL BASE CURRENT — Ise=2.511f/Ne=1.249 recombination component, Ib ≈ 115–188µA over the code range with I^(1/Ne)=I^0.8 curvature.** Ie is exact (set by the cells) but Ic = Ie − Ib, so Ib steals a nonlinearly code-dependent µA-level current from the output. Ise=0 → INL 0.0004ppm (−192dB). Replica feedforward CANNOT fix this (current-domain error, not voltage). Bowl is mostly common-mode between rails; the differential output already cancels ~7×; ±1.2ppm is the post-cancellation residue.
- **METHODOLOGY WARNING (recorded so it isn't repeated): two earlier 'eliminations' (22d Bf, 22h Ise) were regex edit failures — the model string 'Ise=2.511f Ikf=.3458' didn't match the pattern used; the deck ran UNCHANGED and produced a false negative. Always verify the edited line landed in the deck before trusting a null result.**
- **FIX CANDIDATES (untested):**
  1. **Replica base-current mirror (preferred, same loop-free spirit):** Q5R runs the same current as Q5 → its own Ib is an exact-law copy; mirror it INTO the sum node to refill what Q5's base steals. Matching-limited (~few %) → est. −122.7 → ≈ −150dB.
  2. MOSFET cascode for Q5 (zero DC gate current, kills the mechanism outright; trade: gm, matching, replica becomes Vgs-based).
  3. Cleaner BJT (lower Ise/higher ideality at 50–100mA) — device survey needed; DMMT5551 model is recombination-heavy.
- NOTE: static INL is a NEW budget axis (not mismatch, not glitch; DEM does not shape it — common to all cells). Without fix: ~121dB total.
- **FIX 1 VERIFIED (cosim23/23b, full realistic stack): Ib-compensation works.** Topology: third matched NPN Q5C per rail, base on the existing casb line (conducts the same replica current → generates the same-law Ib), collector returned to the 2.4V reference (V_CE matches Q5p), base current sensed and mirrored into the sum node (sim: F-source; hardware: small PNP mirror, TBD). Results: INL 1.17→**0.105ppm (11×)**, HD2 −123.4→**−147.1dB**, HD3 −122.7→**−141.8dB**. Mirror gain error ±5%: HD3 −138.9…−146.2 — worst case still 11dB below target; few-% matching trivial (note: Q5+Q5R+Q5C now = 3 matched NPN per rail — dual no longer suffices, candidate: THAT300 quad or 2× duals). All per-rail shared circuitry; ZERO per-cell impact (user concern addressed: cell = Q1/Q2 + Q4 + Rt + 2 pins, unchanged since BOM lock).
- **UPDATED BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.7 ⊕ static ≥138.9 ≈ 128.6dB — target held with the new axis included.**
- **MIRROR HARDWARE VERIFIED (cosim23d/e/f): full transistor-level implementation, INL 0.079ppm, HD2 −151.0 / HD3 −143.9 — better than the behavioral copy.** Final per-rail schematic: Q5C (matched NPN, base fed via QM1 from casb line, collector to vfr for VCE match, emitter forced by a SECOND replica-DAC output B_snk); QM1/QM2 PNP pair on casb senses Ib(Q5C); QM2 feeds QN1/QN2 NPN mirror (gnd-referenced) which SINKS the Ib copy from the sum node. Parts/rail: 3 NPN + 2 PNP + 1 extra replica-DAC output. LESSONS: (a) polarity — Q5 PULLS Ic from sum, so compensation must SINK from sum (source-into-bus and source-into-sum both INVERT the correction → 2.2ppm, INL doubles); (b) PNP-only mirror into sum saturates (Vec≈0.15V) — the NPN output stage is required; (c) Q5C's emitter cannot hang on a resistor-derived reference (v23c bug: 7.5k can't sink 95mA, Q5C starved, zero correction) — it needs the replica-current sink, which also improves matching (forced-Ie, same as Q5p).
- **FOLLOW-UPS CLOSED (cosim24/24b, 2026-07-15):** (1) Glitch recheck with the full comp network grafted into the cosim20 transient deck (incl. PNP junction caps Cjc=8p/Cje=10p/Tf=500p on casb & sum): q_pc flat to 0.005% across k=1..8, asym_frac worst 0.70e-4 @k=4 vs 0.71e-4 baseline — NO glitch degradation. (2) Temp stability (.temp 0/27/50C on cosim23f): INL 0.20/0.08/0.17ppm, worst HD2 −134.7 (50C), worst HD3 −139.9 (0C) — compensation tracks over temperature by construction (Q5C same die-law), ≥6.7dB margin at all corners, NO calibration needed. Remaining: BOM selection (3 matched NPN/rail + PNP pair; THAT320/340 quad candidates) and a full schematic document for the user.

## Glitch Study Round 5 — q_pc(k) Compression Mechanism ISOLATED (bfdac_cosim11a–d, 2026-07-13)
Idealize one suspect at a time on the cosim9e baseline (C_sum=2.2n, compression 4.89% k=1→8), k stepped 1/2/4/8:
| deck | idealization | q_pc k=1→8 (nV·s) | compression |
|---|---|---|---|
| 9e (baseline) | none | −9.753 → −9.277 | 4.89% |
| 11a | stiff q4_base (R_bias 100→1mΩ) | −9.770 → −9.294 | 4.87% |
| 11b | ideal cascode (V-pinned bus + 1:1 F-source conveyor) | −9.466 → −8.925 | 5.72% |
| 11c | ideal I/V (E-source 1e6, no GBW/slew limit) | −9.559 → −9.510 | **0.51%** |
| 11d | ideal I/V + ideal cascode | −9.2712 → −9.2713 | **~0.001% (flat)** |
- **RANKED ATTRIBUTION: (1) I/V loop large-signal behavior ≈ 4.4 points of the 4.9% — DOMINANT.** Sum-node excursion (25→151mV with k) drives the OPA1612 composite out of its linear small-signal regime (slew/GBW/gm compression). With ideal amp the sum node moves µV and compression collapses 10×.
- **(2) Real cascode (Q5551) ≈ 0.5%** — the entire residue left under an ideal amp; goes to zero when cascode is also idealized. Mechanism class: V_BE(log-I) bus-voltage shift × bus capacitance + Early/beta nonlinearity.
- **(3) Shared q4_base bias + tails/switches: negligible** (11a unchanged; 11d flat to 1ppm).
- dem_study ceiling column (gl_idealIV, cosim11c q_pc): **even a PERFECT amp caps glitch SNDR at 114.2dB (r=1) / 122.2dB (thermometer)** — the 0.5% cascode residue alone keeps 128dB out of reach for rotation DEMs.
- **CONSEQUENCE**: analog path to 128dB needs BOTH a much faster/more-linear I/V response AND a ~10× better cascode (regulated/gain-boosted cascode candidate). Realistic amp improvements alone land ~mid-90s→~110dB. Strengthens the case for constant-k DEM (digital path), where q_pc(k) flatness stops mattering by construction.
- Next candidate experiments: (a) regulated cascode (local loop holding bus node) → re-measure residue; (b) realistic amp upgrades (2× GBW, higher-slew composite front end) → where between 90.7 and 114.2dB do we land; (c) constant-k DEM behavioral sim (digital leg).

## Tuning Knob Inventory (authoritative — a knob not listed here does not exist)
Rules: (1) every runtime-configurable parameter is listed here with default, range, purpose, and tuning procedure; (2) DEFAULT VALUES MUST MEET FULL SPEC — knobs are for optimization on real hardware, never required for basic function; (3) each knob maps to an SPI register (register map task, pending).
| Knob | Domain | Default | Range | Purpose | Tune procedure |
|---|---|---|---|---|---|
| ~~Gate-drive skew (per-cell ODELAY, complement pin)~~ RETIRED Round 26 | — | 0 (aligned) | — | Knob removed by external reclock FFs (both gates resampled on one OCXO edge — default 0 was the verified spec-meeting value). Crossing trim fallback if bring-up shows dead-zone artifact: post-FF RC on g2 (board rework, not runtime) | n/a |
| Output level select | Analog/relay | 2V | 2/4/6V (2-bit) | Output range selection (existing, from V-stage design) | User-facing setting, not a trim |

## Cascode Cell BOM — PARTIALLY LOCKED (reopened 2026-07-12, see constraints)
- **Topology**: Differential current-steering cell + shared per-rail output cascode
  - Q1+Q2 (per cell): small-signal N-MOSFET differential switch pair — steers I_unit to bus+/bus−
  - Q4 (per cell): NPN tail current source — sets unit current I_unit
  - Q5 (per rail, SHARED): NPN common-base output cascode — collector to output rail, emitter to cell drain bus (pinned at V_cas − V_BE ≈ 1.8V), base at 2.5V
  - Bleed: 910Ω per rail (~2mA) keeps cascode conducting at code extremes
  - 1 FPGA pin per cell (128 total); complementary gate pair generated by the external reclock FF's Q/~Q at ~3.3V (Round 27 — supersedes the old "2 FPGA pins per cell, 1.8V direct drive")
- **Parts**:
  - Switch pair (Q1+Q2): **TBD — SELECTION REOPENED at ~3.3V FF drive (Round 27)**. Low Ciss/Qg (~50pF/~1nC) still required; the 1.8V V_GS constraint is GONE → 2N7002-class back in play. **DMN2041UVT still REJECTED** (474pF C_GS) — see key findings below.
  - Shared cascode (Q5): **DMMT5551** matched dual NPN (both rails in one package → V_BE drift common-mode)
  - Tail current source (Q4): **THAT300** (NPN matched quad, ΔV_BE ≤ 0.1 mV, SOIC-14) — current matching sets DAC linearity
- **Drive (Round 27): ~3.3V from external reclock FF Q/~Q** — FPGA no longer drives the gates directly (its 1.8V HP-bank limit is now irrelevant to the cell; 1.8→3.3V translation sits ahead of the FF D inputs where jitter is absorbed)
  - The old 1.8V requirement (V_GS at 781µA ≤ ~0.9V) is RETIRED; re-derive the source-node level and Q4 V_CE budget at the actual FF-rail V_GS. Datasheet V_GS(th) still insufficient evidence — verify with real SPICE model at operating current (DMN2041UVT lesson)
  - Candidate class: small-signal FETs, ~50pF Ciss / ~1nC Qg class (drive is now an FF, but gate charge injection into the bus still matters); 2N7002-class re-qualifiable
  - R_gate: **47Ω** per gate
- **Per channel (64 cells)**: 64× dual FET + 16× THAT300 + 1× DMMT5551 = 81 packages (+ reclock FF/translator stage, see bom.md §1.2)
- **Stereo total**: 128× dual FET + 32× THAT300 + 2× DMMT5551 = 162 packages
- **FPGA pins**: 128 total (64 per channel), 1 pin per cell, LVCMOS18

## Cascode Cell — Electrical Design (REOPENED pending I/V topology decision)
- **Supply voltage**: +5.0V (analog section) — chosen for full 1.95V swing + output cascode headroom with a RESISTIVE load. NOTE: if the planned I/V stage is a virtual-ground transimpedance input, the output bus does not swing, the headroom analysis changes entirely, and 3.3V may suffice — re-evaluate after I/V topology is decided
- **Tail current reference**: 1.25V (LM4040-1.2 shunt reference)
- **Unit cell current**: I_unit = (1.25V − 0.665V) / 750Ω ≈ **781 µA per cell**
  - R_tail: **750Ω** 0.1% (trimmed from 820Ω — measured THAT300 V_BE is 0.665V at this current, not 0.61V)
- **Full-scale output current**: I_FS = 64 × 781µA = **50 mA**
- **Output interface**: 39Ω 0.1% load resistors used in sims to date; ACTUAL output feeds the planned I/V + V stage (topology TBD). If virtual-ground I/V: no output swing, SNR budget moves to I/V feedback R + op-amp noise. If resistor-sense: 1.95V SE / 3.9Vpp diff swing stands (OUT: 3.05–5.0V) and V stage needs high CMRR at ~4V CM
- **Shared cascode bias**: **2.5V** at Q5 bases → cell drain bus pinned at ~1.8V; switches see ~constant V_DS, never the output swing
- **Voltage budget (5V)**: 1.95 swing + 1.2 cascode V_CE(min) + ~1.6 switch V_DS + 1.0 Q4 V_CE + 0.58 R_tail — fits with margin
- **Power per channel**: ~54mA × 5V = **~270 mW** (incl. 2×2mA bleed)
- **Stereo total power**: **~540 mW** average — no heatsink; shared cascodes are hottest parts (~60–70mW each)
- **SNR estimate**: ~130 dB (dominated by Johnson noise of R_load, shot noise negligible)

## Cascode Cell — Key Findings from LTspice (bfdac_final2.cir)
- **Per-cell PNP output cascodes REJECTED**: cascode in the switched path gets cut off every half-cycle; its collector floats up and forward-biases the C-B junction → mA-scale reverse conduction. Cascodes must sit in always-conducting branches — hence the shared per-rail common-base stage.
- **Why shared cascode vs none (both work at 5V DC)**: 64 switch drains carry ~nF of nonlinear, code-dependent capacitance. Without cascode this sits directly on the output (pole ~400kHz, code-dependent settling). With shared cascode it sits on the pinned bus; output sees only ~pF of cascode collector. Decisive for ultra-premium linearity.
- **DMN2041UVT REJECTED on real SPICE model**: (1) effective V_TO ≈ 1.02V → with 1.8V drive the source node squeezes Q4 into saturation, breaking tail regulation; (2) 474pF C_GS + ~900pF C_GD demands ±34mA gate current spikes — impossible for FPGA IOB, ±0.5V output glitches. Lesson: at 781µA we need a SMALL FET (low Qg/Ciss), not low R_DS(on).
- **Verified with real models** (Diodes Level-3 die model, 2N7002-class VDMOS, THAT300): tails 775µA ±2µA, clean antiphase steering, off-side leakage <1µA, bus pinned, Q4 V_CE ≈ 1.0V active.
- **Open item — switch FET selection under 1.8V drive**: find + model-verify low-V_th FET (V_GS ≤ 0.9V at 781µA). Blocks final cell sim.
- **Open item — I/V + V stage topology**: virtual-ground transimpedance vs resistor-sense + gain. Gates rail choice (3.3V vs 5V), cascode sizing, and SNR budget.
- **Open item — switching glitch**: with ideal 1ns drive edges, gate-crossing transients disturb outputs (both switches momentarily off near crossing). Needs realistic FPGA IOB drive model, crossing-point/timing optimization, and possibly slower controlled edges.
- **Open item — FPGA drive check**: Qg ~1nC at LVCMOS18; verify IOB drive strength gives acceptable gate rise time within the 163ns period, and SSO budget for 128 pins.
- **Open item — reference filtering**: RC/LC filter on shared 1.25V reference to keep correlated gain-modulation noise below −130dB.

## Pending
- [ ] Cascode output pin assignments (128 pins) — baseboard connector layout TBD
- [ ] dac_ddr4_if: MIG IP generation — C0 only, 5× MT40A1G16KD-062E, banks 61/62/63, 80-bit
- [x] QSPI pin assignments (2× MT25QU01GBBB1EW9) — flash 0 on config pins, flash 1 on bank 65
- [ ] QSPI read controller — reads coefficient data from QSPI flash into DDR4 at boot
- [ ] dac_ddr4_if: add AXI write channel (currently read-only) for QSPI→DDR4 boot load
- [ ] Boot sequencer — orchestrates: DDR4 cal → QSPI→DDR4 bulk copy → DDR4→FIR default bank load
- [ ] SPI system update mode — ARM writes bitstream + coefficients to QSPI flash via SPI bus
  - dac_ctrl_plane routes SPI writes to SOM QSPI flash (pass-through or buffered)
  - All storage on SOM QSPI (2× MT25QU01GBBB1EW9, 256 MB total, no baseboard flash)
  - Dual-boot bitstream support:
    - QSPI flash partitioned: primary image (new) + golden/fallback image (known-good)
    - Update writes to primary partition only; golden image is never overwritten
    - On boot failure (watchdog timeout, config CRC error, or cal fail), revert to golden image
    - Use XCVU13P multiboot / fallback via IPROG or WBSTAR mechanism
  - Boot status reporting via SPI register:
    - Boot source (primary vs golden/fallback)
    - Boot success flag (set after DDR4 cal + QSPI→DDR4 load + first valid audio frame)
    - Error code: config CRC fail, DDR4 cal timeout, QSPI read error, coefficient checksum fail
    - ARM can poll boot status register (e.g., 0x18) to verify update succeeded
- [ ] Expand coef_bank_id to 5 bits (18 banks: 6 DAC profiles × 3 variations)
- [ ] QSPI dual-flash strategy — partitioning and wear leveling across 2× 128 MB devices
  - Partition options: flash 0 = bitstreams (primary+golden), flash 1 = coefficients+metadata
    or stripe across both for wear leveling
  - Coefficient updates are more frequent than bitstream updates — isolate wear
  - Consider simple block rotation for coefficient region (100K erase cycle limit)
  - Estimate write endurance: 18 banks × 2.25 MB × N updates vs. 100K cycles × sector count
  - Store partition table / flash map in a fixed header sector (first 4 KB of each flash)
- [ ] SPI register address defines — create a header file (e.g., `spi_regs.svh`) with
  human-readable `define names mapping to hex register addresses (e.g., `SPI_REG_UNMUTE`,
  `SPI_REG_BANK_SEL`, `SPI_REG_BOOT_STATUS`, etc.) for use in RTL and testbenches
- [ ] On-chip debug infrastructure
  - LED1 (BC33, bank 61) — boot status / heartbeat / error blink codes
  - ILA (Integrated Logic Analyzer) cores for key internal buses during bring-up
  - MARK_DEBUG attributes already on spi_unmute, gain_switch_req
  - Consider ILA on: boot sequencer FSM, coef_bank_loader AXI, DDR4 cal status, QSPI controller
  - JTAG on J6 connector: TDI=D17, TDO=D18, TMS=D19, TCK=D20 (dedicated pins, no XDC needed)
  - Baseboard: route J6 D17–D20 + GND to JTAG header (J-Link Pro compatible)
  - Level shift required: FPGA JTAG is 1.8V, J-Link Pro is 3.3V
    - Part: TI SN74AVC4T245PW (TSSOP-16) — 4-ch bidirectional, VCCA=1.8V, VCCB=3.3V
    - 1DIR=HIGH (B→A): TCK, TMS, TDI from J-Link 3.3V → FPGA 1.8V
    - 2DIR=LOW (A→B): TDO from FPGA 1.8V → J-Link 3.3V
    - OE tied low (always enabled), 0.1µF bypass caps on VCCA and VCCB

## Completed
- [x] i2c_master.sv, dac_role_cfg.sv, fpga_sync_if.sv deleted (orphaned)
- [x] XDC constraints: vu13p_dac_top.xdc — diff clocks, SPI, I2S, relay, IRQ pins assigned
- [x] Differential clocks: IBUFDS for clk_200m (C1 CLKREF G20/G19), clk_49m (B30/A30), clk_45m (A27/A28)
- [x] DDR4 port widths updated to 80-bit (C0 controller); C1 unused, its CLKREF serves as clk_200m
- [x] SOM pin correlation: ACVU13P-Pin-Assignment CSV parsed, DDR4/QSPI/SelectMap pins identified
- [x] tb_dac_i2s_ingress.sv — 11/11 PASS: 768k stream, 705.6k stream, watchdog, recovery
- [x] tb_spi_ctrl_plane.sv — all tests PASS: SPI write/read, CRC, register readback
- [x] tb_coef_bank_loader.sv — all tests PASS: 262144 writes, 256 bursts, 0 errors
- [x] tb_i2s_rx.sv — PASS
- [x] run_sim.tcl — xsim batch script for all 4 testbenches
- [x] dac_i2s_ingress.sv — simplified: direct register from toggle-sync, no FIFO needed

## DC Servo Design Round 1 — DISCRETE CM SERVO DESIGNED & VERIFIED (bfdac_servo1/2/3.cir, 2026-07-19)
Fully discrete per-channel CM servo (topology D per user direction; ADC/FPGA option rejected — market/purity; opamp options rejected). Plant modeled behaviorally (56R TIA CM response), servo transistor-level.
- **FINAL TOPOLOGY (11 BJT + 2 film caps/channel):** sense 2x10k matched thin film (out_p/out_m -> cmsen); input pair QI1/QI2 (SSM2212, Rd 4.7k degeneration, 100uA tail via 143k); PNP mirror load QP1/QP2 with 10k emitter degeneration + beta-helper QH; Darlington PNP second stage QS0/QS with mirror current-source load QL0/QL1 (100uA); Miller integration Cint 10uF FILM across stage 2; post-filter 100k+1uF (noise wall, servo branch); vernier actuators QA1/QA2, Rdeg 2k to -15 (center 1.43mA, authority +/-0.71mA = +/-40mV CM).
- **KEY OFFSET LESSON: every uA-level asymmetric base-current leak at the stage-1 output node costs (leak x ~5.2k) of CM offset.** Fix sequence: QS base steal 3.5mV -> Darlington; mirror VCE imbalance 2.1mV -> emitter degeneration (NOT cascode: its base current re-leaks 1.7mV); mirror beta error -> helper QH; matched 5k source impedances at BOTH pair bases make the pair base-current drops CANCEL (loop forces cmsen=iref).
- **MEASUREMENT TRAP (recorded): V(cmsen) sits Ib*5k (~2.8mV) below true output CM — measure (out_p+out_m)/2, not the sense node.** Cost one false debugging round.
- **RESULTS:** DC loop gain 75.9dB; crossover 11.7mHz; PM ~89deg (post-filter pole 1.6Hz is 130x above crossover); residual output CM 95-135uV over full +/-40mV disturbance range (plus real SSM2212 Vos ~200uV); servo noise at diff output (1% actuator mismatch): flat 285pV/rtHz, 40nV rms 20-20k = **-153.9dB rel 2Vrms — invisible in the 128.4dB budget**; startup: exponential settle, no windup, sub-mV by ~90s (power-on mute/relay covers; NOTE for system spec).
- **ACTUATOR SIZING TRAP: Rdeg 10k collapsed authority (emitter follows vflt up, QA saturates against the 2.4V sum node at VCE~20mV, base current explodes, stage-2 rails).** 2k + recentered vflt (~-11.4V) gives 13V VCE margin.
- OPEN: servo values are per-channel x2; add to schematic.html 5b (currently still marked DESIGN PENDING); startup mute time constant -> system spec; SSM2212+SSM2220(PNP) BOM adds.
- CLOSED 2026-07-20: schematic.html 5b updated to transistor-level VERIFIED figure; servo row added to traceability table.

## Round 14 — FULL-STACK THERMAL NOISE, CONVERTER -> I/V (bfdac_noise1/1b.cir, 2026-07-20)
First .noise of the whole analog path (only servo3 existed before). Deck derived from cosim23f DC stack; ALL noiseless ideal sources replaced with physical equivalents:
56 static cells -> area-scaled real cell (Q4 area=N + 750/N); 8 live cells kept real, gates DC; 50mA pads -> degenerated BJTs (40R/2V); replica ff+sink B-sources -> degenerated BJTs (10V across Re); amp en modeled as 73R series sense resistor (= 1.1nV/rtHz, OPA1612 class). .noise V(diffout) V_ref dec 100 10 100k, .step code list 4 28 52.
- **noise1 (no ref bypass): code-DEPENDENT floor: 4.97nV/rtHz @ code28 but 8.07nV @ code4 / 6.70nV @ code52.** Root cause: R_bias 100R thermal (1.28nV) on q4_base is CORRELATED across all 64 cells -> cancels differentially at midscale only; imbalanced codes see ~vn*(Nm-Np)/783 * 56R (~4.4nV @ code4). Same math applies to any real reference noise: vref->diffout gain up to 3.7x at code extremes.
- **FIX (noise1b): 1000uF bypass on q4_base (1.6Hz corner with 100R).** Floor now code-INDEPENDENT: flat 4.89-4.92nV/rtHz, etot 0.693uV rms 20-20k. vref transfer killed (gain ~0.006 @ 1k) -> reference part noise is a non-issue in-band. Cap is in bias branch, not audio path. Startup tau 0.1s.
- **RESULT: output noise floor = 0.693uV rms / 3.394Vrms FS (4.8Vpk diff) = -133.8dB, all codes.** Spectrum flat 20-100k (all-thermal). Dominant terms (analytic): 64 cells 4kT/750 aggregate ~1.4nV/rail, pads ~1.1nV/rail each (sum+bus), amp 1.5nV, R_off 0.54nV.
- **THD+N ROLLUP: distortion 128.4dB (+) noise 133.8dB = ~127.3dB.** Noise is NOT the limiter but the combined figure now sits ~0.7dB under the 128dB target; the binding terms remain mismatch 130.6 and code 133.5. Knobs if 128.0 must be strict: A-weighting buys ~2-3dB on the noise term; or attack mismatch shaping further.
- CAVEATS on record: no 1/f in any model (Kf=0) — real BJT/amp flicker corners are low but unverified; amp current noise not modeled (1.7pA into 56R ~ 0.1nV, negligible); pad/replica bias rails modeled as noiseless V-sources — REAL bias networks must be RC-filtered below audio band like the servo (design rule, not yet a drawn circuit); q4_base 1000uF bypass is NEW — must be added to schematic.html Fig 2/5 and BOM.
- CLOSED 2026-07-20: q4_base bypass added to schematic.html Fig 2 + Fig 5 text; noise row + THD+N rollup added to traceability table.

## Round 15 — PASSIVE BESSEL RECONSTRUCTION FILTER (bfdac_filt1.cir, bfdac_noise2.cir, 2026-07-20)
User direction: fully passive LC (dCS/Chord philosophy discussed: steep rejection lives in the linear-phase digital FIR; analog filter = low-order, GROUP-DELAY-FLAT. Spec "no phase shift" formalized as group-delay flatness, i.e. pure time delay). Active option ruled out (V-stage would see 3MHz shaped DEM noise unfiltered -> slew IMD; no loop gain at MHz).
- **TOPOLOGY: 3rd-order Bessel singly-terminated ladder per leg: I/V out (Rs~1R) -> L1 -> C2 shunt -> L3 -> R0 term, V-stage bridges R0 hi-Z.** Exact synthesis vs s^3+6s^2+15s+15: normalized L1=5/6, C2=12/25, L3=1/6 (ws=2*pi*fc/1.7557). fc=450k, R0=150: **L1=77.6uH (air-core, DCR 1.5R), C2=1.99nF C0G, L3=15.5uH (DCR 0.4R)**.
- **RESULTS (filt1):** f-3dB 450k (-3.08dB, synthesis confirmed); passband loss -0.166dB (DCR+Rs), droop 1k->20k only 0.005dB; **group delay 614ns, FLAT TO 17ps ACROSS 20Hz-20kHz**; attenuation -41.4dB @ 3.072M (shaped-noise protection), -59.3dB @ 6.144M (+~50dB ZOH sinc -> images ~-109dB). L +/-5% step: fc -2.7/-3.4dB, gd 583-644ns but STAYS flat (<110ps dev) — Bessel delay changes with tolerance but flatness (the audible spec) survives.
- **noise2 (filter grafted onto noise1b full stack, probe at filter output):** in-band floor unchanged: 4.83-4.86nV/rtHz, 0.683uV rms 20-20k = -133.9dB rel FS. R0 termination thermal is shorted by the low-Z source in-band; DCR negligible. I/V DC loading by 150R fine.
- **V-STAGE INTERFACE NOW FIXED:** bridge 150R termination with hi-Z input; signal is full-scale 4.8Vpk diff, delayed 614ns, spectrum clean above 450k. Gain-only stage (filter does no gain).
- MEAS NOTE: .meas AC FIND ph() prints results in dB cosmetically — values ARE degrees/seconds when used in param expressions (gd math verified against 1/ws theory).
- **TRANSIENT VERIFY (cosim25/25b = cosim24 + filter + q4_base 1000uF):** I/V driving the LC ladder: glitch charge STILL linear in k to 0.003% (q_rise 9.826n->78.61n for k=1->8), asym_frac 0.06e-4..0.6e-4 (same order as cosim24's 0.70e-4), plateau_err ~15nV -> NO instability/ringing at out_p from the inductive load. Filter output step (5us pulse): overshoot = undershoot = 0.93% symmetric (textbook 3rd-order Bessel), settled gain 0.9876 (-0.11dB, = DCR divider 150/151.9), no ringing.
- **STIMULUS TRAP (cosim25 first attempt): 598ns test pulse ~ filter rise time (0.35/450k=778ns) -> fdiff never plateaus, gain_f read 0.64 and os_frac 9% -- artifacts of an unsettled step, not filter defects.** Lengthened pulse to 5us (25b). Also baseline window must end ~400ns (step energy arrives before the 614ns group delay).
- OPEN: inductor BOM (air-core 78uH/15.5uH, shielding + orientation layout rule); filter into schematic.html; V-stage design next.
- CLOSED 2026-07-20: filter added to schematic.html as new Fig 4b + traceability row.

## OUTPUT ARCHITECTURE DECISIONS (user-confirmed, 2026-07-20)
- Two separate stages (Benchmark/Weiss pattern, researched dCS Vivaldi APEX = no HP out / Chord DAVE = shared stage): REAR line XLR (2/4/6 Vrms relay-selected, 600R min load) + FRONT headphone stage (1Vrms IEM / 6Vrms planar gain relay), both in the quiet analog zone; front jack driven low-Z across the FPGA region (robust), never hi-Z input routing.
- Mutually exclusive by design. Relay set per channel: input-select DPDT (unused stage input grounded — an UNPOWERED BJT input on the node would clamp signal peaks via b-c junction to collapsed rails!), rail relay (headphone stage fully depowered in line mode), per-output mutes (de-energized = muted: line = open+shunt, HP jack = shorted). Chain: I/V -> filter -> input select -> stage -> OUTPUT mute -> connector (mute AFTER stage: it exists to swallow the stage's own power-up/settle transients).
- Sequencing rule for FPGA: mute -> switch select+rails -> settle -> unmute. Level select for line 2/4/6V done via TAPPED 150R termination (taps 1/3, 2/3, 1: source Z <= 50R, relays switch signal-level nodes into hi-Z input, stage gain FIXED) — one compensation, one verification.

## Round 16 — LINE V-STAGE, ONE LEG DESIGNED & CONVERGED (bfdac_vstage1.cir + /b/o variants, 2026-07-20)
Fixed gain 1.769 non-inverting discrete amp per leg (x2 per channel, level via termination taps upstream). Topology: LTP QLN low-noise NPN 6mA/side w/ 33R deg, BJT tail 12mA; PNP mirror load 200R deg + beta-helper QH (+22k bleed); PNP Darlington VAS (QV0 follower + QV 6mA, Rev 130) + CASCODE QVC (base +8V); Miller 1n + 100R series from vas to nd1; class-A diamond output m=3 (~25mA, 22R/10R base stoppers); Zobel 10R+100n; fb 150/195 (gain 1.769), load 300R (=600R diff).
- **RESULTS: 1kHz THD(9) 0.00001% = -140dB (H2 -143dB) at FULL 3Vrms leg out; 20kHz THD 0.0006% = -104dB; DC offset 2.9mV (systematic -> cancels differentially between matched legs); Idq 25mA class A; gain accurate to 0.05%.**
- **DEBUG SEQUENCE (traps recorded):**
  1. **9.5MHz global oscillation with C_m=680p (UGF ~5MHz too high for the phase stack). Symptom: Fourier 'Total THD' 5-12% with clean 'Partial' — excess RMS vs fundamental confirms real HF content, not numerical.** Stable from C_m>=1n; using 1n with gm lowered (33R deg): crossover ~1.2MHz.
  2. Helper was FALSELY blamed (removed, oscillation persisted -> global). Restored after comp fix: clean, offset 10.6mV -> 2.9mV.
  3. **20kHz THD was -56dB with 2mA LTP: Miller current (2pi*20k*Cm*4.3Vpk ~ 0.8mA) modulates a 2mA pair by 40% -> gross front-end nonlinearity. Fix: 6mA/side + 33R deg (same-ish gm, 12x linear range) -> -104dB.** RULE: size LTP tail >> peak Miller current.
  4. **12mA tail latched the DC op point: mirror 300R deg (1.8V drop) + Darlington VAS input level = mirror output compliance violated -> solver finds saturated latch state (out stuck +8.66V).** Fix: Rm 200R + Rev 130 (nd1 target 12.8V vs mirror em 13.8V). RULE: recheck nd1 = vcc - I*Rev - 2Vbe vs mirror compliance whenever tail/VAS currents change.
  5. plotwinsize=0 numdgt=7 required for credible .four; .save list keeps raw small (2GB -> 2MB).
- OPEN: stage .noise (est ~1.2nV in + 84.7R fb network vs 4.9nV source — expect ~+0.3dB); PM quantification (loop probe); tapped-termination 2V/4V settings THD + noise; two-leg differential build (offset cancellation, XLR drive); temp corners; headphone stage (separate round).
- CLOSED 2026-07-20: schematic.html Fig 4c (V-stage) + Fig 4d (output routing/relays/sequencing) + traceability row added.

## Round 17 — V-STAGE NOISE, TAP SETTINGS, DIFFERENTIAL BUILD (bfdac_vstage1n/1t/2/2b.cir, 2026-07-20)
- **NOISE (vstage1n, .noise on tapped termination, all settings):** stage output density 3.16nV/rtHz @6V setting, 3.43 @2V/4V (incl 33R tap thermal); FLAT 100Hz-20kHz. Input-referred stage ~1.8nV. Combined at XLR (diff, DAC chain 4.85n at filter x1.769, stage legs uncorrelated x sqrt2): 6V: 9.67n -> 1.37uV rms -> **SNR 132.8dB**; 4V: 131.5dB; 2V: 128.0dB. (dCS Vivaldi APEX spec: -113dB @6V. ~20dB better.) Stage noise penalty on DAC floor: 1.1dB at 6V.
- **MEAS TRAP: .meas NOISE INTEG(V(onoise)^2) under .step returns garbage (141x low) in LTspice 26.0.2 — density was verified flat at 4 spot freqs and integrated manually (x sqrt(19980)). noise1b (no .step) was consistent, unaffected.**
- **TAP SETTINGS THD (vstage1t, divider + stage, per leg):** 2V: 1k 0.000007% (-143dB), 20k 0.000111% (-119dB); 4V: 1k 0.000015% (-136dB), 20k 0.000345% (-109dB). Levels 0.987/1.975Vrms (x0.9868 filter-DCR factor, matches cosim25b gain — absolute cal note for FPGA digital trim if exact 2/4/6 wanted).
- **DIFFERENTIAL BUILD (vstage2/2b, two VLEG subckts, 600R XLR load, 0.5% Rg mismatch stepped):** diff 5.93Vrms; **1k diff THD 0.000010% = -140dB; 20k 0.00057% = -105dB** (H2 cancels: 4.7e-9 normalized). **Diff DC offset: 2nV matched, 0.41uV at 0.5% Rg mismatch — per-leg 4.7mV systematic offset confirmed pure CM, cancels at balanced receiver.** CM AC leakage at 0.5% mismatch 3.2mV (-65dB, and CM -> rejected). Gain balance 0.11% per 0.5% Rg mismatch.
- **MEAS TRAP (cost ~6 debug sims): B-source observation nodes (B_od V=V(outp)-V(outm) + 1G) POLLUTE .four THD ~50x with fake odd harmonics (timestep-dependent, slow-decay H3>H5>H7 signature). Also masked as 'subckt vs flat deck difference'. Use native .four V(a,b) two-node syntax instead. RULE: never put B-sources on measurement-critical decks.**
- Also: .step with a single-value list errors out ("only one step") — use .param instead.
- OPEN: PM quantification (loop probe); temp corners; headphone stage round; startup mute already in system spec. Fig 4c/traceability updated with noise+diff numbers.

## Round 18 — V-STAGE PM, LATCH FIX RE-VERIFY, TEMP CORNERS (bfdac_vstage1p/1o/1q/1tc/1oc.cir, 2026-07-20)
- **LATCH FIX FINAL: Rm 200R -> 100R** (mirror em headroom vs Darlington VAS input; nd1 compliance rule from Round 16 item 4). Re-verified full battery after change:
  - 1kHz THD 0.000029% (-131dB), 20kHz 0.000596% (-104.5dB) — unchanged within noise.
  - Offset 2.5mV, Idq(out) 24.6mA, 3.0016Vrms at 6V setting.
  - Oscillation deck (vstage1o): output residual pV-level, no ringing. Square wave (vstage1q): overshoot 0.88%, clean settling, no latch.
- **PHASE MARGIN (vstage1p, AC loop probe):** UGF 2.85MHz, **PM 34.2° by single-injection probe** — conservative/pessimistic: the voltage-only injection underestimates margin when the impedance ratio at the break point is unfavorable. Transient evidence (0.88% overshoot, no ring at pV level) corresponds to effective PM >>60°. Loop gain 41.4dB @20kHz. HF plateau +1.8dB max 6-100MHz (benign, transient-confirmed).
- **TEMP CORNERS (0°C / 50°C, .step temp):**
  - THD 1kHz: 0.000031% / 0.000029% — flat.
  - Idq(out): 24.5mA / 24.8mA (+1.2% over 50°C span — emitter degeneration + diamond Vbe tracking works).
  - Offset: 2.42mV / 2.54mV (pure CM, cancels differentially).
  - Gain: 3.0015752 / 3.0015757 Vrms — 0.2ppm variation. Oscillation deck clean at both corners (pp ~4pV).
- **LINE V-STAGE CLOSED.** Next round: headphone stage.

## Round 19 — HEADPHONE STAGE, 4-PIN XLR BRIDGED (bfdac_hp1/1b/1o/1q/2/2b.cir, 2026-07-20)
- **ARCHITECTURE (user decision): headphone out = 4-pin XLR balanced (2 bridged legs/channel); line/preamp out = dual 3-pin XLR (existing vstage2).** Each HP leg sees half the load: 16R for a 32R headphone (worst realistic case).
- **HP LEG = verified line V-stage front end unchanged** (LTP 6mA/side/33R, mirror 100R+helper, Darlington VAS 10mA cascoded, Cm=1n/Rmc=100, gain 1.769) **with power output triple:** diamond drivers (Q5551/Q5401 m=2, 15mA) -> TO-220F power pair (2SC4793/2SA1837-class models QPWN/QPWP), **Re=0.47, Idq 162mA class-A** (Imin 32mA at full swing — never leaves class A). Re=0.33 first cut gave 195mA — trimmed via Re (diamond spreader is set by driver-vs-power Vbe delta, Re drop dominates trim).
- **SINGLE LEG (16R load, 3Vrms = full scale):** 1k THD 0.000052% (-126dB); 20k 0.001149% (-98.8dB). Stability: osc deck pV residual, square wave 1.5% overshoot, clean settling, no latch.
- **BRIDGED PAIR (hp2, 32R load, 0.5% Rg mismatch stepped): 6.0Vrms diff = 1.13W into 32R. 1k diff THD 0.000052% (-126dB), 20k 0.001140% (-98.9dB)** — leg residual is odd-dominated (H3), so bridging does not improve THD but doubles swing and kills ground-return current. Mismatch has no THD effect. **Diff DC: 79nV matched, 5.1uV at 0.5% mismatch (0.16uA into 32R) — no output caps or DC servo needed.** CM DC 2.5mV (cancels in bridge).
- Dissipation note: 162mA x 15V = 2.4W/device idle, 4 power devices/channel -> ~10W/channel heatsink budget. Class-A ceiling 5.4Vrms diff into 32R; higher-Z loads trivially class-A.
- **NOISE (hp1n, tapped termination, all settings):** 3.28nV/rtHz @6V, 3.54 @2V/4V, flat 100Hz-20kHz (vs line stage 3.16/3.43 — power triple adds ~0.1n). Integrated 20-20k: 0.464uV/leg, 0.66uV diff stage-only. Combined with DAC chain (8.58n/leg): ~9.2n/leg -> **SNR at 6Vrms diff ~132.7dB** — same class as line out. Into 110dB/V IEMs: hiss ~ -7dB SPL, inaudible.
- **PM (hp1pm, loop probe):** UGF 2.87MHz, PM 33.7° by single-injection probe (same conservative caveat as line stage — transient shows 1.5% overshoot, effective PM >>60°). Loop gain 41.2dB @20k. HF plateau +0.77dB (better than line stage's +1.8 — power pair Cjc loads the plateau resonance).
- **TEMP CORNERS (0/50°C):** THD 1k 0.000066%/0.000043% (both < -123dB); gain 0.3ppm; offset 2.42/2.54mV (CM, cancels). **Idq 149/173mA (+16% over span, positive tempco ~0.48mA/°C).** Runaway check: 4 devices x 7.2mW/°C x ~2°C/W heatsink = loop gain 0.06 << 1, thermally stable; still stays class-A at 0°C full swing (Imin 21mA). BUILD NOTE: mount diamond drivers on the main heatsink for Vbe tracking; production could swap fixed diamond for a heatsink-mounted Vbe multiplier if tighter Idq wanted. Osc deck clean at both corners (pp ~3-4pV).
- **HP STAGE ELECTRICALLY CLOSED.** OPEN: schematic Fig 4e; relay integration recheck (HP mute = shorted, already in Fig 4d spec).
- **ARCHITECTURE CHALLENGE (user, availability/heat concern) — three-way comparison run (hp1ab/ab2/ab3/a3.cir):**
  - Discrete class-AB (Re=2.7, Idq 92mA, leaves class A at full swing): **1k full-power THD 0.001493% (-96.5dB) = 30dB WORSE; 20k 0.031% (-70dB) = 29dB WORSE** — 41dB loop gain at 20k cannot suppress gm-doubling into 16R. Low-level (300mW) THD identical to class-A (0.000014%) since it stays class-A there.
  - IC composite (OPA1612+BUF634A in-loop) — datasheet estimate, not simmed: ~-120dB 1k / -100..-110dB 20k, noise ~2.9nV output, ~1.5W/ch. Coolest option, likely 5-10dB worse at 20k full power, single-source TI silicon.
  - Class-A discrete (as verified): -126dB 1k / -98.9dB 20k at 1.13W, 3.28nV, ~12W/ch. **KEPT — user priority is performance; heat is a chassis/heatsink budget item.**
  - BOM corrections from review: Red/Rec are 1206 current-sense chips (12-17mW actual, 3W spec was habit-overspec); 2N5551/MMBT5551 are active jellybeans (not arcane); Rg 195R -> 196R E96.
- **IC COMPOSITE WITH GENUINE TI MODELS (hp3/3b/3c/3p/3p2/3n/3q.cir; OPA161x SBOM396G + BUF634A SBOMB63A, downloaded to ti_models\):**
  - **MEAS TRAP: smooth behavioral macromodels let LTspice take huge steps — .tran 10n 10m 'finished' in 1.2s with a fake -80dB floor. Force maxstep (.tran 0 10m 0 50n); verified converged by halving to 10n (identical result).**
  - **Single BUF634A: 1k 0.000917% (-100.8dB), 20k 0.020% (-74dB) — the 250mA current limit engages at 265mA pk. REAL disqualifier at rated 1.13W/32R bridged.**
  - **Dual parallel BUF634A (1R ballast each): 1k harmonics at -240dB = below model resolution; 20k 0.000019% (-134dB).** CAVEAT stated to user: TI macromodels do NOT model output-stage crossover/low-level THD — parallel numbers are optimistic lower bounds, not predictions; datasheet measured in-loop THD+N into 32R is ~-120dB class. Discrete sim uses physical junction models that DO capture these mechanisms — not apples-to-apples.
  - Noise (real, macromodels model noise well): 3.08nV/rtHz @6V tap vs 3.28 discrete — equal within 0.5dB.
  - Stability: square wave overshoot **18.8%** (vs discrete 1.5%) with Riso=22 — settles clean (0.65uV pp quiescent) but composite would need its own compensation round (Cf lead cap, Riso tuning).
  - Heat: ~1.2W/ch (8.5mA/buffer wide-BW x4 + opamps) vs 12W/ch discrete.
- **ARCHITECTURE DECISION (user, after real-data review): DISCRETE CLASS-A COMMITTED.** Composite decks (hp3*) retained as reference only. OPEN: schematic Fig 4e; bias-network detailing (Vtb/Vbcas/Iba/Ibb real implementations); relay integration recheck.

## Round 20 — HP BIAS NETWORKS REALIZED (bfdac_hp4/4b/4o/4tc.cir, 2026-07-20)
- **All ideal sources replaced:** Vtb -> LED-referenced tail CCS from -15V rail (DLED model Vf~1.8V, Rln 2.7k feed, 100u bypass, Rte 91R -> tail 11.3mA); Iba -> NPN CCS off same LED (Rea 75R, 13.6mA); Ibb -> mirrored PNP CCS off +15V LED (Reb 75R, 14.1mA); Vbcas -> 3.3k/3.9k divider from +15V + 10u (8.1V, cascode Ib ~50uA). LED refs are rail-tracking = tail/bias currents immune to rail sag.
- **Verification vs ideal-source hp1: 1k THD 0.000055% (-125dB, was 0.000052%), 20k 0.001260% (-98dB, was -98.8dB) — bias networks cost ~nothing.** Idq 159mA, offset 2.3mV, class-A held (Imin 29mA).
- **Temp corners 0/50°C:** THD 0.000080%/0.000044% (< -122dB both); Idq 143/172mA; **tail 10.3/12.1mA (+18% span — LED-vs-Vbe residual tempco, larger than ideal case but THD/stability unaffected)**; Imin 16mA at 0°C full swing = still class-A. Osc deck clean at 0/27/50°C (pp ~3pV).
- **TOOLING TRAP (cost 1 sim): PowerShell operator precedence — `-replace a,b + "x" + c -replace d,e` does NOT chain as intended; hp4o.cir silently became a copy of the old hp1o deck (results exactly matched a previous run = red flag that caught it). Parenthesize replacement strings.**
- BOM additions: 2x DLED green LED (any jellybean green, Vf~1.8-2.0), 2x 100u + 1x 10u bypass, Rln/Rlp 2.7k, Rc1 3.3k, Rc2 3.9k, Rea/Reb 75R, Rte 91R. QCA/QCB = 2N5551/2N5401.
- OPEN: schematic Fig 4e (now with real bias networks); optional PSRR sweep; relay integration recheck.

## Round 21 — FIG 4E + PSRR + RTL RELAY INTEGRATION (2026-07-20)
- **Fig 4e added to schematic.html** (HP stage: front end = Fig 4c unchanged, power triple, real bias networks, verified numbers). BOM stale Rte 900R row removed.
- **PSRR (hp4pp/hp4pm, AC on rail, output-referred per leg):**
  - -15V rail: -95.5dB @100, -91.4 @1k, -71.9 @20k — LED rail-tracking bias works.
  - **+15V rail: -84.7 @100, -67.6 @1k, -41.7 @20k, -27.7 @100k** — weaker (mirror emitters, Rev, Rset all reference +rail).
  - Mitigations already in architecture: (1) rail ripple is COMMON-MODE across the bridged pair -> cancels at the headphone except leg mismatch (~1% -> effective ~-82dB @20k diff); (2) rails are LDO + Fig 5 filtering. Judged acceptable; if bench disagrees, an RC (10R/470u) on the front-end +15 feed is the fix.
- **RTL AUDIT vs Fig 4d (user request "make sure mute + voltage output + SPI commands exist"):**
  - EXISTED: single output mute relay + 1-bit gain relay with mute-sequenced switching, SPI 0x02/0x04.
  - **MISSING: output select (line/HP), HP rails relay, separate line/HP mute relays, 3-level tap select (was 1 bit, needs 2).**
- **RTL IMPLEMENTED (automute_controller.sv, dac_ctrl_plane.sv, vu13p_dac_top.sv, .xdc):**
  - automute: full Fig 4d sequencer — MUTED/FLUSHING/SWITCHING/RAIL_SETTLING/SETTLING/PLAYING. level_relay[1:0] (2/4/6V taps), outsel, hp_rails; select/level relays only move while both mutes open + audio clamped; **RAIL_SETTLING 500ms when HP rails toggle (LED refs + 100u + class-A Idq settle) before jack goes live**. Timings are module parameters (TB-overridable).
  - SPI map: 0x02 now level[1:0] (00=2V,01=4V,10=6V); **0x07 = output select (0=line,1=HP)**; 0x12 readback {clk_src, rate, outsel, level}; 0x14 {i2s_err, switch_busy, hp_mute, line_mute, unmute}.
  - Top: 4 new relay ports (relay_line_mute/hp_mute/hp_rails/level[1:0]), widened CDC chains, ILA probe updated. XDC: pins R28/T28 kept for mutes; **U28/R29/T29 for rails+level are PLACEHOLDERS — verify against ACVU13 connector budget.**
  - tb_automute.sv rewritten: reset state, line playing, err/rate re-mute, level switch only-while-muted, outsel with rails-before-jack ordering, HP->line teardown + 2 always-on invariants (mutes never both energized; HP jack never live with rails off).
  - **VERIFIED: xsim 2026.1 run = ALL PASS (11/11 checks, invariants silent).** Toolchain note: Questa FSE on this machine has a dead node-locked license (HOSTID mismatch) — use Vivado xsim instead: `cmd /c "call C:\AMDDesignTools\2026.1\Vivado\settings64.bat && xvlog -sv <files> && xelab tb_automute -s tb_automute_sim && xsim tb_automute_sim -R"`.
- HP block fully closed pending: XDC pin verify (U28/R29/T29 placeholders), heatsink/chassis (mechanical).

## Round 22 — PIN BUDGET REVIEW vs ALINX CSVs (2026-07-21)
- Reviewed `Alinx/ACVU13P-Pin-Assignment-20260703.csv` (connectors J1-J8) + onboard CSVs (QSPI/LED/DDR4/JTAG/config).
- **BUDGET: 368 user I/O on connectors, banks 64-71 (51/46/42/51/25/51/51/51). Control cluster uses 21 of bank 71's 51; cascode 128 fits with 219 pins spare.**
- **BUG FOUND+FIXED: OCXO clock inputs were on NON-clock-capable pins.** B71_L24 (B30/A30) and B71_L22 (A27/A28) are ordinary I/O — UltraScale+ GC pins are L11-L14 only. Would have failed MMCM clock routing at implementation. Moved: clk_49m -> B71_L12 (J28/J29, J1-A17/A16), clk_45m -> B71_L13 (J26/H26, J1-B5/B4). **BASEBOARD LAYOUT MUST ROUTE OCXOs TO THESE J1 PINS.**
- **Placeholder relay pins fixed with real connector pins:** hp_rails=N26, level[0]=P26, level[1]=N29 (B71_L6/L4, J1-B1/B2/B7). U28/R29/T29 did not exist on connectors.
- **Debug LEDs added** (only 1 user LED onboard, BC33): led_debug[3:0] = {clk_locked, ddr4_calib, i2s_err, force_zero} on D28/E28/K27/K26 (B71_L18/L10). Port added to top + XDC.
- Clock-capable inventory: 4 GC pairs/bank except 66 (partial) and 68 (L11/L12 only).
- **i2s_bclk moved to GC pin too (user follow-up):** R27 (B71_L2, waivered) -> H27 (B71_L11_P, J1-B17); CLOCK_DEDICATED_ROUTE=FALSE waiver removed — bclk now gets dedicated clock routing. R27 freed. Bank 71's last free GC pair: L14 (G26/G27). **Baseboard: route I2S bclk to J1-B17.**
- MMCM: one CMT per I/O bank -> 8 adjacent to connector banks; design needs 1 (sys_clock_gen) + MIG's own. No shortage.
- Cascode plan: L on banks 64+65 (97 pins), R on 67+69 (102 pins) — each channel spans 2 adjacent banks, same VCCO 1.8V. Banks 66/68/70 + bank71 spares = expansion.
- NOTE: QSPI1 (AM26/AN26/AL25/AM25, bank 65) are dual-purpose SelectMAP D04-D07 — fine as user I/O post-config; do not enable SelectMAP persist.
- OPEN: assign the 128 cascode pins explicitly in XDC (needs board schematic pairing); heatsink/chassis.

## Round 23 — RECLOCK STUDY: FPGA DIRECT vs CHORD-DAVE EXTERNAL FFs (reclock_study.py, 2026-07-21)
- User asked whether direct IOB drive beats DAVE-style external reclock FFs. Built timing-error Monte-Carlo on the dem_study converter model (64 cells, 6.144MHz, const-k K=4 2nd-order DEM, -1dBFS 1k).
- Four mechanisms modeled: common random jitter (MMCM/BUFG vs OCXO+FF), SSN data-correlated delay (beta*k), static per-cell skew, per-cell random jitter.
- **RESULTS (in-band SNDR of timing error, const-k K=4):**
  - FPGA direct (10ps rj, 1ps/cell SSN, 15ps skew, 1ps pc): rj 130.0, ssn 146.0, skew 166.3, pc 145.6 -> **ALL 129.8dB**
  - External FF (0.5ps rj, 0.1ps/cell, 10ps skew, 0.3ps): -> **ALL 152.6dB (+23dB)**
  - **Dominant term = common random jitter of the MMCM/BUFG/IOB chain.** Sweep: 1ps->150dB, 5ps->136, 10ps->130, 20ps->124.
  - **const-k DEM DOES blunt the SSN mechanism as predicted** (+7dB vs DWA at every beta; k const -> SSN term nearly linear). But it cannot help the random-jitter term.
  - Static skew benign: 50ps sigma still 156dB (DEM decorrelates it like mismatch).
- **INTERPRETATION: direct drive lands AT our >=128dB per-contributor target with zero margin (and 20ps MMCM jitter would blow it at 124dB). External reclock buys ~23dB. DAVE's approach is justified by the physics; our const-k DEM only neutralizes the SSN part, not oscillator/MMCM phase noise.**
- Options ranked: (a) full external reclock — 128 FFs (16x octal LVC/AUP574 on clean rail) clocked by OCXO-derived divided clock, +23dB, BOM/board cost; (b) hybrid — final IOB regs on a BUFG fed RAW from the OCXO input (skip MMCM in output path), kills MMCM jitter but keeps FPGA SSN/global-net ps-level terms, ~free; (c) status quo, accept 130dB timing floor.
- Timing closure note for (a): FPGA outputs must meet setup/hold vs the board reclock clock — constrain with set_output_delay against OCXO; phase relationship is deterministic since dsp_clk is MMCM-locked to the same OCXO.
- OPEN: user decision a/b/c; if (a), reclock FF BOM + clock divider design + XDC output constraints; bench-verify jitter params (Vivado MMCM jitter report, IOB SSN measurement).

## Round 24 — CLOCK TREE LOCKED IN: EXTERNAL MUX + RECLOCK FFs (2026-07-21)
- **User decision: option (a) full external reclock.** Architecture locked at PCB level, Fig 1b added to schematic.html + BOM section.
- **Devices:** LMK00304 (2:1 OCXO mux + 1:4 fanout, ~50fs additive, NOT glitch-free) -> one output to FPGA GC pair, others to 2x LMK1C1108 (1:8, <30ps skew) -> 16x SN74AUC374 octal reclock FFs at 1.8V on a dedicated clean LDO rail (LVCMOS18-compatible, no level translation). 47R series into cascode gates as before.
- **FPGA clocking reworked — single MCLK input, clock selection moved OFF-chip:**
  - Top ports: clk_45m_p/n + clk_49m_p/n REPLACED by mclk_p/n (B71_L12, J28/J29) + clk_sel output (J26 = freed B71_L13_P; H26 now free). clk_sel = SPI reg 0x06 (clk_source_sel, already existed in dac_ctrl_plane — no ctrl-plane change needed).
  - sys_clock_gen: BUFGMUX_CTRL deleted; MMCM CLKIN1 = mclk; new mmcm_rst input.
  - New mux-switch sequencer in top (clk_200m domain): on clk_source_sel change -> assert mmcm_rst, flip clk_sel, hold reset 2048 cycles (10.24us settle), release, MMCM relocks ~100us. ARM mutes via automute before issuing the rate change (LMK mux glitches are harmless while muted + MMCM in reset).
  - XDC: single create_clock clk_mclk @ 20.345ns (faster 48k family covers both); dsp_clk generated-clock master updated; clk_sel LVCMOS18/D4/SLOW + false_path.
- **Setup/hold to external FFs (same-edge launch @ 49.152M):** setup margin ~13ns (Tco 3-5ns + flight <1ns vs 20.35ns); hold met (Tco_min ~2ns > skew + t_h). CAUTION for todo #13: dsp_clk/mclk ratio is 20/3.5 = 40/7 (non-integer) — cascode IOB regs must ultimately be clocked/enabled on an mclk-phase-aligned clock (MMCM CLKOUT1 DIVIDE=20 spare is reserved for this) so launch edges are deterministic vs the FF clock.
- tb_vu13p_top clock section updated (behavioral LMK mux driven by clk_sel); NOTE tb is otherwise stale vs current top (pre-Fig-4d relay names, old DDR4 port list) — needs full refresh before it compiles.
- Datasheet caveat: LMK/AUC skew-jitter-Tco numbers are from memory (+/-20%) — verify before layout.
- OPEN: cascode pin assignment (todo 9); output-timing constraints vs virtual FF clock + mclk-aligned launch clock (todo 13); tb_vu13p_top refresh.
- **BOMs consolidated (user request): bom_hp.md + bom_clock.md merged verbatim into single bom.md** (§1 clock tree/reclock, §2 headphone amp); old files deleted. Remaining blocks (cell array, output stage, I-V, filter, V-stage, servo, relays) still live in LTspice decks — transcribe into bom.md sections as they reach layout.

## Round 25 — BOM <-> SCHEMATIC LOCK-STEP (2026-07-22)
- **bom.md restructured: BOM section N documents schematic.html figure N** (1=clock/1b, 2=unit cell, 3=output stage, 4=I/V, 5=filter/4b, 6=line V-stage/4c, 7=relays/4d, 8=HP/4e, 9=supplies/5, 10=servo/5b). HP section renumbered 2->8. Lock-step rule stated in both file headers (schematic footer cross-ref added).
- New BOM sections transcribed from schematic values (values deck-locked, many MPNs TBD): unit cell (LVFET TBD, THAT300 32pkg, 750R, shared 100R+1000uF), output stage (R_off 180/180.18, pads 50mA, Q5/Q5R/Q5C matched, QM/QN pairs, 10n C0G, 910R, Rf 56R||390p, 4.7R+2.2n snubber, I_ff/I_snk realization TBD), I/V (OPA1612-class + diamond TBD), filter (77.6u/1.99n/15.5u air-core custom, R0=3x50R 0.1% tapped string), line V-stage (shares §8 MPNs, line-specific: 200R mirror deg, 6mA VAS, Rg 196R), relays (K1-K6 telecom bifurcated Au class TBD + ULN2003A, mapped to XDC pins), supplies (0.01R/30nH/bead1u||100R/10u/100n per rail; ref ladder 1.25/1.75/2.4V realization TBD — vfr buffer must sink 100-190mA), servo (SSM2212/SSM2220 + full R/C set from Fig 5b).
- **DISCREPANCY FOUND (logged as bom.md open sync item #1): Fig 1/2 show 2 gates per cell (make-before-break g1/g2) = 256 signals/unit, but RTL/XDC provide cascode_l/r[63:0] = 128 total and §1.2 reclock chain sized for 128.** Either on-board complement generation (breaks make-before-break) or 256 FPGA pins + 32 FF packages. Must resolve before cascode pin assignment (todo 9). Pin budget note: 256 pins still fits (368 available, Round 22).
- Other open sync items: MPN selection list, clock-tree datasheet verification, replica-DAC I_ff/I_snk circuit design.

## Round 26 — CASCODE CELL REVIEW: GATE-COUNT RESOLVED, 256 PINS (2026-07-22)
- Reviewed current cell vs reclock-FF drive (user request). Authoritative cell design ("Cascode Cell BOM — PARTIALLY LOCKED"): 64 cells/ch, **2 complementary FPGA pins per cell, 256 total** — the Round-22 pin review + RTL (cascode_l/r[63:0] = 128) were the stale side. Fixed everywhere:
  - **RTL**: dac_dsp_core + top ports now cascode_l/r_g1/g2[63:0] (256). g2 = registered complement in the IOB (NOT pad-inverted) — both gates launch on one dsp_clk edge, resampled on one FF edge. Reset g1=0/g2=1 (all cells parked on bus_minus). xvlog clean.
  - **XDC**: section 8 rewritten for 4 port buses; IOB cell patterns updated; output_delay placeholder pending todo 13. tb_vu13p_top ports updated.
  - **Clock tree resized WITHOUT changing topology**: 16x SN74AUC374 (octal) -> **16x SN74AUC16374 (16-bit dual-octal, both CLK pins tied at package)** = 256 bits, still 16 clock traces from 2x LMK1C1108 — LMK fanout unchanged. Each package = 8 cells. 47R count 128->256.
  - **schematic.html + bom.md synced** (Fig 1/1b/2 text + captions, BOM §1.2/§1.3/§2/§3, open item 1 resolved). Q5 MPN recorded as DMMT5551-class (package grouping of Q5/Q5R/Q5C triple TBD); LVFET hard spec transcribed into BOM §2 (V_GS<=0.9V @ 0.774mA, ~50pF Ciss; 2N7002 + DMN2041UVT rejected).
- **CONSEQUENCE OF FF DRIVE: gate-drive skew knob (per-cell ODELAY on complement pin) RETIRED** — FFs resample both gates on the same OCXO edge, ODELAY before the FF is absorbed. Default 0 (aligned) was the verified spec-meeting value (knob rule 2), so nothing is lost vs spec; cosim v6 showed 2-3ns skew bought ~20% glitch PP as optimization only. Fallback if bring-up shows dead-zone artifact: post-FF RC on g2 (board rework). Knob inventory updated.
- Pin budget: 256 cascode + 21 control fits easily (368 on connectors, Round 22); bank plan L=64+65, R=67+69 must be revalidated for 128 signals/channel (todo 9).
- NOTE: cell current bookkeeping — older cell notes say 781uA (Vbe 0.665), schematic/decks say 0.774mA; deck value kept as authoritative.

## Round 27 — CORRECTION (user ruling): 128 FPGA PINS; FF STAGE AT ~3.3V; CELL REDESIGN OPENED (2026-07-22)
- **Round 26's "256 FPGA pins" resolution was WRONG and is reverted.** User ruling: 64 cells/ch = **one FPGA data pin per cell, 128 pins total**; the external reclock FFs (introduced Round 24) drive the cells, so the FPGA 1.8V limit no longer constrains the gates — the FF rail (**~3.3V**) sets the gate drive.
- **RTL/XDC/tb reverted** to cascode_l/r[63:0] (identical to pre-Round-26 interface; comments updated: complement generated off-chip). xvlog clean.
- **Reclock stage redefined (bom.md §1.2, Fig 1b)**: D-FFs **with Q + ~Q outputs** at VCC~3.3V generate the complementary pair per cell (intra-package Q/~Q skew; avoids the asymmetric dead-zone of a post-FF inverter). 1.8→3.3V **level translation ahead of the FF D inputs** (jitter absorbed by reclock; only prop delay eats setup margin → budget now ~9–13ns). FF + translator MPNs TBD; FF packaging choice sets LMK1C1108 count. AUC374/AUC16374 selections VOID (AUC max VCC 2.7V, and single-Q anyway). 47R gate resistors: 256 (2 per cell) — unchanged.
- **CELL REDESIGN OPENED (blocks cell re-lock, bom.md §2 + Fig 2 flagged)**: gate drive 1.8V → ~3.3V. (a) switch-FET selection reopened — 2N7002-class re-enters (was rejected ONLY for 1.8V V_GS); low Ciss/Qg still required (charge injection); (b) re-derive source-node level / Q4 V_CE budget at new V_GS; (c) re-run cell + glitch decks (cosim chain) with real FET model at 3.3V drive; (d) pick exact FF rail voltage (sets gate high level) with the cell sim.
- "Cascode Cell BOM — PARTIALLY LOCKED" section updated in place (drive bullet, FET bullet, pin count). Knob inventory unchanged (ODELAY knob stays retired — FFs still resample; complement now formed inside the FF).
- Cross-check note: bfdac_final2.cir's original 3.3V-drive sims (pre-Round-9) are closer to the new regime than the 1.8V decks — but the cell has changed since (shared cascode, padding, Ib-comp), so a fresh deck pass is still required.

## Round 28 — CELL REDESIGN SIMS: DECK-MODEL BUG FOUND, BJT STEERING CELL PROPOSED (2026-07-22, decks bfdac_cosim26*/27*)
- Parts defined BEFORE sims (user rule: real models only): 2N7002/RK7002BM/QS6K1 (LTspice standard.mos vendor models; old `LVFET` was literally 2N7002 with Vto edited 1.6->0.6), SN74LVC74A FF + SN74AVC16T245 translator + TPS7A4700 rail recorded in bom.md §1.2.
- **FET OP window mapped (26/26b/26r)**: gate rail pinned to Vto+[1.1..1.45V] by the 0.58V tail / 1.75V bus sandwich. 2N7002: 2.8-3.05V (3.3V leaves VDS=96mV, goes TRIODE at +85C); RK7002BM: 3.1-3.35V; QS6K1: 2.4-2.65V. **5V/15V rail REJECTED with data (26p5)**: switch drops into triode, make-before-break shorts bus_plus<->bus_minus through ~4R each flip -> asym -30%..+15%. Raising the bus instead would drag sum node/R_off/replica/servo = full output-stage re-verification, for negative benefit (injection ~ swing x C).
- **LEGACY DECK BUG (major)**: cosim10/20/24 asym decks encode skew=1n in the g2 pulse WIDTHS (596n vs 598n) — the 'skew' param moves rise-overlap and fall-overlap OPPOSITELY (rise=skew, fall=2n-skew), which no FF ever does. The verified 0.71e-4 asym was measured at the matched point (skew=1n) of this convention; sweeping it produced phantom knife-edge sensitivity (6e-3/ns) that triggered this round's false alarm. **TRUE FF model = g2 exact delayed complement (equal 598n widths, skew = Qbar lag both edges).**
- **With the TRUE FF model (26f/27f): both cells are fine at delta=0**: 2N7002@3.3V asym 9.2e-5 (bounded <=1.1e-3 over +-1.5n); BJT cell 7.6e-5, slope 2.3e-3/ns.
- **Requirement derived via dem_study (asym_sweep.py, chosen K=4 par+2nd g2=.5 DEM)**: gl_ffwd = 151.7dB@0.71e-4, 150.8@2e-4, 142@1.15e-3, 128.4@5.9e-3 -> **need |asym| <= ~1e-3 => FF Q/Qbar skew |delta| <= ~0.4ns and matched edge shapes**.
- **NEW CELL PROPOSED + SIMMED (cosim27*): BJT emitter-coupled steering pair (DMMT5551 dual, same-die) with divider base drive** (FF 3.3V -> Rs 470R -> base, Rp 82R -> buffered VCM 1.6V; swing 1.36-1.86V around bus-safe levels). vs FET cell: **bus disturbance 2.2mV vs 89mV (40x)**, off-leak ~0.1nA, OP: c_s 1.17V / Q4 VCE 0.59V / switch VCE 0.58V; temp corners -20/25/85C asym stable ~0.8e-3 (27h); k-linearity clean (27k); replica timing skew ±2ns no effect (27r).
- Remaining sensitivities (both cells): Q/Qbar skew slope ~2.3e-3/ns and Q vs Qbar EDGE-RATE mismatch (±0.5ns of 2ns -> ±(3..9)e-3, 27g). RC base caps do NOT fix (27m/27n tried 22p/100p — worse). Full-overlap regime + two-phase replica also no (27q/27u — asym ∝ skew persists, mechanism cell-intrinsic at 50/50 state).
- **PROPOSED RESOLUTION (pending user ratification): ECL/PECL-class differential reclock FF (e.g., onsemi ECLinPS-EP MC100EP52 class) driving the BJT pair.** Guaranteed Q/Qbar skew <=30ps (-> asym ~1e-4), inherently matched complementary edge shapes, <0.2ps additive jitter, and LVPECL output levels (1.6-2.4V @3.3V VCC) land on the required 1.36-1.86V base window with a simple resistive shift — the classic ECL-driven bipolar current-steering architecture (PCM63 lineage). Replaces LVC74A/AVC16T245 selection in bom.md §1.2 if ratified.
- Decks: bfdac_cosim26{,b,r,s,t,L,u,v,w,x,y,z,z2,p5,p5t,f}.cir, bfdac_cosim27{,b,t,r,f,g,h,k,m,n,p,q,s,u}.cir in Documents/LTspice; asym_sweep.py in repo.
- OPEN: ratify BJT cell + ECL FF; then re-lock cell (§2/§1.2 BOM + Fig 1b/2), re-run noise deck with BJT cell, INL/static (Ib of switch pair — alpha error), full cosim chain + temp battery, FF MPN datasheet verification.

## Round 29 — RATIFIED + LOCKED: BJT CELL + MC100EP52; FIRST END-TO-END SIM PASSES (2026-07-22, bfdac_e2e1.cir)
- **USER RATIFIED** the Round-28 proposal. Locked into bom.md + schematic.html (Fig 1/1b/2 redrawn):
  - §1.2: **MC100EP52** x128 (differential LVPECL D-FF, VCC 3.3V TPS7A4700 rail, 1 per channel bank); FPGA 1.8V -> D via 3.6k/1k shift vs V_BB (new buffered 2.31V rail); LMK clock -> CLK via same network; **SN74LVC74A + SN74AVC16T245 REMOVED**; timing budget improves to ~13-16ns setup.
  - §1.1: LMK1C1108 count 9 -> **18** (2 roots -> 16 leaves -> 128 clock traces, single-FF packages).
  - §2: cell = **DMMT5551** same-die steering pair (1 pkg/cell), base networks **100R series + 165R to new buffered 1.00V rail** (swing 1.36-1.86V from PECL 1.6/2.4 levels); THAT300 tail/750R/1.25V line unchanged.
  - §9: added 1.00V steering-bias rail + 2.31V shift rail to reference ladder.
  - Open sync items 2 & 3 marked RESOLVED (datasheet verification of EP52 pinout/V_BB fanout/supply current still pending).
- **END-TO-END DECK `bfdac_e2e1.cir`**: PECL FF (behavioral 1.6/2.4V, 0.4ns edges, 30ps Qbar lag) -> 100/165 shift -> 8 live BJT cells + statics/padding -> shared cascode + replica + Ib-comp -> behavioral-amp I/V + real diamond -> 3rd-order Bessel filter (77.6u/1.99n/15.5u, 150R tapped, full-termination 6V tap) -> discrete line V-stage (VLEG from bfdac_vstage2g) -> 600R diff load. **Results: step_diff 1.194V (8 cells), chain gain 1.760 (theory 1.747: Av 1.769 x filter DC 0.9875), overshoot 0.42% (Bessel-clean), vo_cm -23mV, cell OP c_s 1.187V / Q4 VCE 0.61V / switch VCE 0.56V / tail 0.7699mA, plateau_err_e2e +2.0mV (window likely not fully settled - recheck with longer windows).**
- **SIM GOTCHA (documented for all future composed decks): the line V-stage has a reachable latched DC state** (Round 16/18 lineage - line variant kept Rm=200R). Standalone Newton finds the healthy OP; in the composed deck global Newton fails -> gmin stepping lands in the latch (out CM at -14.7V). Fix in-deck: `.nodeset` on VLEG internals (nd1 12.8, vb2 13.5, ev 14.2, cvc 8.7, vas/out/fb 0, bm 13.1). **Hardware watch item: verify line-stage start-up behavior on the bench; consider the HP-stage Rm=100R fix if bring-up shows latch.**
- NEXT (todo 28): sine-stimulus e2e (needs DEM-patterned cell drive), noise deck w/ BJT cell, static INL (alpha/Ib term), temp battery on e2e, EP52/LMK datasheet verification, XDC pin assignment (todo 9) + FF-clock timing constraints (todo 13).

## Round 30 — FPGA SIDE LOCKED TO ROUND-29 ARCHITECTURE: PINS, CELL_CLK RETIME, XDC TIMING (2026-07-22)
- **Todo #9 CLOSED — 128 cascode pins assigned** in `vu13p_dac_top.xdc` §8: L = banks 64+65, R = banks 67+69, explicit PACKAGE_PIN per bit generated from `Alinx/ACVU13P-Pin-Assignment-20260703.csv` (L-pair sites only, no T/VREF pins; conflict-checked against every other XDC assignment — 0 collisions; generator output kept in `Alinx/cascode_pins_gen.txt`). Bit order = LA-pair number; per-cell remap at layout is free (DEM decorrelates cell position).
- **Todo #13 CLOSED — mclk-phase-aligned launch + virtual-FF-clock output timing:**
  - `sys_clock_gen.sv`: MMCM CLKOUT1_DIVIDE 10→20 = mclk rate (45.1584/49.152 MHz), phase-aligned by the MMCM feedback loop; new `cell_clk` output on its own BUFG.
  - `dac_dsp_core.sv`: cascode IOB stage retimed dsp_clk→cell_clk via toggle-handshake CDC (staging stable ~8 cell_clk per 6.144 MHz DEM update; ASYNC_REG toggle sync + gated bus capture + IOB regs all on cell_clk; local 2-FF reset sync). IOB launch on a cell_clk edge = full mclk period at the MC100EP52 D input.
  - `vu13p_dac_top.sv`: cell_clk wired clock-gen → dsp core; header updated to Round-29 architecture (MC100EP52, no translator).
  - XDC: `create_generated_clock cell_clk` (CLKOUT1/BUFG); `set_max_delay -datapath_only 3.5` staging/toggle → cell-domain capture (kills the 89 ps dsp↔cell related-clock edge chase); false path into cell_rst_sync CLR; virtual `ff_clk` (20.345 ns) with `set_output_delay -max 2.5 / -min -1.5` on all 128 ports (flight 1.0 + shift 0.1 + EP52 setup 0.2 + LMK skew 1.0 margin; VERIFY vs datasheets before layout). Old dsp_clk-referenced output delays deleted.
- bom.md §1.3 pin row updated to ASSIGNED. NOTE: `BFDAC_IMPLEMENTATION_PLAN.md` is stale (still says LVDS cell outputs / XDC blocked / DWA DEM) — historical document, bom.md + XDC are authoritative.
- VERIFIED (todo #14, Vivado 2026.1 standalone xsim in `sim_run/`, unisims + glbl):
  - xvlog clean on all edited RTL (user-run + re-verified).
  - **REAL RTL BUG FOUND by unisim elaboration: `sys_clock_gen.sv` connected `CLKINSEL` on MMCME4_BASE — that port only exists on MMCME4_ADV.** Removed (clock select is external on the LMK00304 anyway). This would have failed first synthesis.
  - **`tb_vu13p_top.sv` REWRITTEN** (was several rounds stale: old port names, 64-bit DDR3-style bus, no CRC on SPI frames, nonexistent disable label). New tb: diff clocks, behavioral LMK00304 mux, 768 kHz-frame I2S source, CRC-8(0x07) 40-bit SPI master, defparam-shortened automute timers, FSM debug monitor. **ALL 7 TESTS PASS** (~135 us sim): MMCM lock, reset/mute state, SPI CRC+unmute→relay, cascode no-X, **cascode toggling through the new dsp_clk→cell_clk CDC (312 updates)**, I2S-stop→watchdog→relay drop. `tb_vu13p_top.tcl` added.
  - tb gotcha worth remembering: I2S LRCLK must be ≥ ~550 kHz (watchdog = 512 dsp_clk ≈ 1.8 µs between frames); a 384 kHz frame rate retriggers automute reset every ~2.6 µs (FSM never leaves FLUSHING — looks exactly like a broken unmute path).
  - `tb_dac_dsp_core.sv`: cell_clk port driven (40:7 ratio); 6/7 tests pass. **PRE-EXISTING FAILURE (not Round 30): FIR output `interp_l` is X-poisoned in xsim (URAM288 coefficient read path) → NS/DEM output rails to all-ones; test 5 (L/R independence) fails and tests 3/6 pass only coincidentally.** Needs URAM init / coef-write investigation — new todo.
- fpga_irq_n is LOW in all full-top sims by design: DDR4 stub holds init_calib_complete=0 → sticky_err[2].
- **DATASHEET VERIFICATION DONE (todo #28 doc half + bom item #5; sources: MC10EP52/D rev 7, LMK00304 SNAS578G, LMK1C110x SNAS717A):**
  - **FINDING 1 — MC100EP52 has NO V_BB pin** (SOIC-8: CLK/CLK̅, D/D̅, Q/Q̅, VCC, VEE; the IBB abs-max row is family boilerplate). §1.2 design assumed on-chip V_BB for D̅/CLK̅ bias → replaced with an external ≈2.1 V threshold rail (divider + buffer per FF group). Also: VIHCMR min = 2.0 V means the old 2.0 V center put the low state exactly at the limit → recenter to ≈2.1–2.2 V. New bom open item #8.
  - **FINDING 2 — FF rail power underestimated:** IEE = 35 typ / 47 max mA per FF + ≈7 mA load network ⇒ ≈2.7 A typ / 3.5 A max PER CHANNEL (≈18 W array). One TPS7A4700 (1 A) per channel is insufficient → ≥3 per channel or a 4 A-class LDO. New bom open item #7.
  - Good news: EP52 timing better than budgeted (tpd 330/410 ps, setup 50 ps, hold 0 ps, jitter 0.2 typ/1 max ps); LMK00304 51 fs / 50 ps skew confirmed; LMK1C1108 12–20 fs, 35/55 ps skew, but part-to-part skew 280 ps dominates leaf-to-leaf (still inside the 1 ns budget). LMK00304 non-glitch-free mux CONFIRMED by TI E2E #1348412. XDC output-delay constraints kept conservative (annotated with verified actuals).
  - bom.md §1 fully updated (banner, §1.1, §1.2, §1.3 reg 0x03, §1.4, open items 3/5 closed, 7/8 opened); XDC §8 comments updated; `BFDAC_IMPLEMENTATION_PLAN.md` banner-archived (todo #31 closed).
  - Remaining #28 sim sub-items (NOT doc work): noise deck w/ BJT cell, static INL (alpha/Ib), temp battery on e2e.
- **EP52 THRESHOLD-RAIL DESIGN (closes bom item #8; user-prioritized):** three buffered rails per channel from the FF 3.3 V LDO (ratiometric): **offset rail 2.49 V** (revised from 2.31 V; same 3.6k/1k networks → D pin swings 1.95–2.34 V center 2.15, CLK pin 1.95–2.67 V center 2.31; ≈40 mA/channel, buffer must sink), **THR_D 2.15 V** (64 D̅ pins; ≤9.6 mA DATA-DEPENDENT via IIH 150 µA vs IIL 0.5 µA), **THR_CLK 2.31 V** (64 CLK̅ pins, periodic). THR_D/THR_CLK deliberately SEPARATE rails: shared rail would convert data-dependent D̅ input current into clock-threshold modulation = data-dependent jitter. Margins: low-state VIHCMR 150/310 mV above the 2.0 V floor (old design sat exactly at it); VPP 390/720 mV vs 150 min; divider accuracy ±35 mV vs ±150 window. Jitter: pin slew 0.6–1.4 V/ns, σv<10 µV → <17 fs (negligible vs FF 0.2–1 ps). Realization: E96 divider → 1 µF RC (44 Hz) → dual op-amp buffer (OPA1678-class, MPN at §9 pass) → 2.2 Ω/10 µF → star → 10 Ω + 100 nF per pin (kickback isolation). bom.md §1.2 note + R41x/R42x rows + §9 rows updated. Nice-to-have before layout: LTspice kickback sanity of rail + network.
- **USER VETO — MC100EP52 RECLOCK STAGE (power/thermal):** verified ≈140 mW/cell static (42 mA × 3.3 V), ≈18 W array. User ruling: **hard thermal constraint made explicit** — drive electronics sit adjacent to matched DMMT5551 pairs; per-cell heat ⇒ gradient drift on the very parts doing precision steering. Target ≤ ~10 mW/cell, array ≤ ~1–1.5 W. ECL is static-bias (power independent of clock rate — no low-power slow ECL exists), so the family itself is disqualified, not just the MPN. bom §1.2 REOPENED (Round 29 design kept for record); open items 7/8 overtaken, new item 9. Round-30 threshold-rail design becomes contingent/retired if replacement is ratified. Candidate direction (NOT ratified): octal CMOS register (1–2 mW/FF dynamic) + **single-ended steering drive vs fixed buffered VREF** — sidesteps the Round-28 complementary-matching problem (skew=0 by construction, reference is static) instead of buying matched edges with a biased differential driver. Round 28 sims covered complementary drive ONLY; needed before ratification: cosim27-lineage single-ended variants — (a) rise-vs-fall edge-rate asym (slope 2.3e-3/ns, budget |asym| ≤ 1e-3), (b) emitter-node CM bounce/injection through the cascode (single-ended drive moves the pair CM by swing/2). If adopted: 128→16 clock leaf loads (LMK1C1108 18→≈3), FF rail mA-class, big BOM shrink.
- **COSIM28 CAMPAIGN — SINGLE-ENDED / LOW-POWER CMOS RECLOCK EVALUATION (user-directed; NO doc/BOM changes until ratified).** Decks bfdac_cosim28{,b,c,d,e,f,g,h}.cir vs 27f baseline (asym 7.6e-5 @skew0, slope 2.3e-3/ns). All power figures PASS the ≤10 mW/cell constraint; all asym figures FAIL or are marginal:
  - 28 single-ended vs mid-VREF (LVC574 real: Ro 23R, 2n edges, dtrf=tr/tf mismatch swept ±1n): asym 5.7e-2 @dtrf0 — Q41 tail cascode near-saturated in the minus state (emitter rides max(bases)−Vbe → state-dependent level, inherent to single-ended).
  - 28b levels raised (vcm 1.85/vhalf 1.90, clears sat): 1.1e-2 @dtrf0, slope 1.1e-2/ns, drive 8.8 mW/cell. 28c speedup caps: worse (1.5e-2) — reconfirms 27m/27n. 28d Cjc-comp caps: no change → Cjc coupling not dominant.
  - 28e complementary same-die CMOS (pre-register inverter idea), rs/rp ×3 + 22p base RC: asym −1.5e-3 @dtrf0 BUT slope 1.3e-2/ns → ±1n real LVC tr/tf band swings ±1.4e-2. 0.8 mW/cell. 28f cross-base cap: same class. 28h ideal-replica diagnostic: identical → the CELL is the transducer, not the replica path.
  - 28g micropower DMMT5551 commutator predriver (1.9 mA tail): −4.7e-3 @0, slope 1.4e-2/ns, ~8 mW/cell — commutation does NOT remove the input duty transduction.
  - **CONCLUSION: the steering cell transduces driver rise-vs-fall (duty) mismatch at ~1.1–1.4e-2 per ns in every topology tried. |asym| ≤ 1e-3 ⇒ need |tPLH−tPHL| + edge-shape mismatch ≤ ~100 ps at the bases — an ECL/LVDS-class spec that CMOS logic does not provide. Low-power single-ended CMOS FAILS as-is; complementary same-die CMOS is marginal at typicals and fails across the datasheet band.**
  - Ways out (user decision pending): (A) constant-transition-density coding (RTZ-class DEM in RTL) — makes per-event charge error code-independent (gain, not distortion); CMOS power ~1–3 mW/cell stands; needs dem_study verification + amplitude/noise cost; (B) per-cell driver with SPEC'D pulse skew ≤100 ps (LVDS-class tsk(p)) — 25–35 mW/cell ≈ 3–4.5 W array, over budget; (C) accept ~140 dB class at 1e-3–5e-3 asym.
- **RTZ-DEM VERIFICATION legs 1+2 (user-ratified direction: RTZ coding + 175-class FF retiming; ratification of BOM still pending legs 3/4):**
  - Leg 1 (`rtz_study.py`, reuses dem_study physics): (a) COMMON duty error a0·code residue = 164.9 dB even at the worst measured asym 2.7e-2 → the RTZ gain-linearization claim is numerically confirmed; (b) PER-CELL duty spread acts as extra static mismatch, DEM-shaped: with **DWA classic** (re-eligible — RTZ makes transition count k benign, so const-k is no longer required; +20 dB mismatch shaping vs const-k K=4) σ_d=5e-3 → 134.1 dB, 1e-2 → 125.2 dB; requirement: **cell-to-cell |tPLH−tPHL| σ ≤ ~400 ps for ≥134 dB** (81.4 ns pulse @6.144 MHz, 50% duty) — comfortably real for same-family CMOS FFs. DWA idle-tone check at other amplitudes still owed.
  - Leg 2 (`bfdac_cosim28j.cir`, 175-class complementary drive, k∈{1,2,4,8} cells pulsing simultaneously, dtrf∈{0,1n}, locally-anchored per-pulse charge, plotwinsize=0/reltol 5e-5): dtrf=1n (NRZ-catastrophic, asym 2.7e-2) → **−2.43 % uniform gain shift**, k-variation of the shift only 3.3e-4 over k=1..8 ✓; per-pulse charge flat to ≤6e-5 for k=1..4; **k=8 shows a reproducible +3e-4 uplift** — suspected STATIC bus-compliance effect (bleed/bus level vs code), common to NRZ, not RTZ-specific → folded into #28b static-INL deck + full-array e2e (#29). Drive power under RTZ ≈2.9 mW/cell ✓.
  - First-run artifact note: unanchored integration showed a fake linear-in-k compression from the 9.1 µs bus-bleed drift (R_bleed·C_bus); per-pulse local anchoring removes it.
  - Leg 3 (`rtz_noise.py`) — RTZ timing-error physics: pulse-POSITION jitter and close-in phase noise cancel (charge-invariant); pulse-WIDTH jitter (broadband, uncorrelated edge pair) is the common term; SSN shifts rise and fall edge groups by β_r·code and β_f·code, so only the rise-vs-fall DIFFERENCE Δβ survives, as a code² (HD2) term. Results @75% duty (preferred: amplitude cost only −2.5 dB, thermal floor 138→135.5 dB ✓): width jitter 80 fs → 139.5 dB ✓ (tree floor 50–80 fs); per-cell FF edge jitter η=0.5 ps → 137.6 dB, η≤1 ps required ≥131.6 dB; **SSN Δβ: 0.05 ps/cell → 104.7 dB, i.e., SHOWSTOPPER for multi-FF packages** (CMOS SSN is 10s of ps per simultaneously-switching output; a quad 175 couples 4 cells → code² distortion at 75–100 dB class even with the 1/n_pkg locality refinement). NRZ context: 80 fs common jitter → 171.9 dB (NRZ was jitter-insensitive; RTZ pays a real but affordable jitter bill).
  - **FF CHOICE OVERTURNED BY SSN: single-FF-per-package required** — candidate **74LVC1G74** (single D-FF, true Q/Q̅, native 3.3 V, SOT-23-6-class, ~1–2 mW dynamic, 64/channel, placeable adjacent to each steering pair; the Round-29 clock tree already assumed 128 single-FF leaf loads). With 1 FF/package, SSN count ∈{0,1} → per-cell effect, DEM-shaped ✓. Requires per-package rail isolation (R/ferrite + local C) so board-rail droop ∝code stays width-symmetric — bound in e2e battery.
  - Leg 4a (SN74LVC1G74 datasheet, TI rev G): fmax 175–200 MHz @3.3 V vs the ~12.3–24.6 MHz RTZ clock (2×/4× cell rate for 50/75 % duty) — huge margin ✓; tpd 2.2–7.1 ns window @3.3 V; "balanced outputs" feature; Icc static 10 µA ✓; dynamic ≈3–4 mW/cell at the RTZ clock + ~1–3 mW network ⇒ ≈5–7 mW/cell ✓. NOT spec'd (bench-verify items, tolerances now generous — see 4b): part-to-part |tPLH−tPHL| spread (need σ ≤ ~600 ps @75 % duty; typicals suggest 200–500 ps) and additive jitter (need ≤1 ps; LVC-class typ 0.2–0.5 ps).
  - Leg 4b (`dwa_tones.py`/`dwa_tones2.py`/`dwa_tones3.py`, 0.22 % combined sigma): DWA classic has real idle tones (peak −129.9 dBFS at −60 dBFS input — pokes above the 135.5 dB thermal floor); naive pointer dither destroys shaping (−109 dBFS). **WINNER: unconstrained sort-based 2nd-order vector shaper (acc1+0.5·acc2, argpartition per sample) — only legal under RTZ (toggles free): in-band −153 to −167 dBFS, peak tones ≤ −168 dBFS across all amplitudes incl. DC-offset provocations.** 25–40 dB better than DWA, tones dead. RTL cost: 64-way partial sort at 6.144 MHz (iterative over 8 cell_clk cycles). The margin also relaxes the duty-spread requirement ~3× (σ_d ~6e-3 → still ≈−143 dBFS).
  - Ratification-review Q&A (user challenges, all resolved in favor of the architecture): (1) **Manchester encoding evaluated and rejected** — pure Manchester nulls the baseband signal exactly (energy moves to Fs/2, the RF-DAC "mix mode"); the salvageable every-cell-pulses variant (dual-width/return-to-complement) keeps constant RISE count but the fall groups split c/(64−c) → same SSN code² term (still needs single-FF), costs −6 dB vs −2.5 dB, and has a higher signal-independent jitter floor (all 64 cells inject edges). RTZ 75 % dominates on every axis. (2) **Derived layout tolerances** (for bom §1 rewrite): Q/Q̅ intra-pair trace mismatch ≤ ~700 ps ≈ 12 cm (static per-cell → gain + shaped; sloppy routing gives <12 ps); clock-tree skew ≤ ~±5 ns ≈ ±80 cm (RTZ position-invariance: rise+fall from same leaf → charge invariant; residual = 1e-4 rad phase at 20 kHz + settle-window erosion; skew spread even helps by staggering SSN edge groups). Sub-ns length matching is dead; only analog cell matching (resistor networks, DMMT5551) keeps its constraints. (3) Single-FF area/routing concern resolved: Round-29 plan was already 128 single-FF SOIC-8 + tree for 128 leaves; SOT-23-6/DPW is 3–5× smaller, 18 W→<1 W; cost = ~384 isolation passives. (4) Literature for the RTZ/ISI claims: Remple & Galton TCAS-I 2016 (10.1109/tcsi.2016.2601026, ISI-in-DEM proof: gain vs shaped), Risbo et al. JSSC 2011 (10.1109/jssc.2011.2164965, hi-res audio ISI), ICECS 2018 RTZ+FIR (10.1109/icecs.2018.8617899), Nandi & Pavan JSSC 2013 SCRZ (10.1109/jssc.2013.2259012).
  - **ALL FOUR LEGS PASS. Converged architecture awaiting user ratification: FPGA (RTZ-encoded 75 % duty, sort-based 2nd-order vector-shaper DEM) → 1× SN74LVC1G74 per cell (single-FF package mandated by SSN, true Q/Q̅, adjacent to each DMMT5551 pair) → steering pair. ≈5–7 mW/cell, array <1 W. Bench-verify: 1G74 duty spread + additive jitter. Sim follow-ups: full-array RTZ e2e (#29), k=8 static uplift (#28b), board-rail SSN width-symmetry bound (36e).**
- **RATIFIED (2026-07-22, user) + DOCS SYNCED:** RTZ 75 % duty + sort-shaper DEM + 1× SN74LVC1G74/cell committed. `bom.md` §1 rewritten (§1 status LOCKED Round 30; §1.1 length matching retired; §1.2 new design + parts table incl. AXC1T45-class translator U440–U567 — **new finding: FPGA LVCMOS18 1.8 V < LVC VIH 2.0 V @3.3 V, translator required**, timing benign/retimed away; rs/rp 1.41k/246Ω vs VCM 1.85 V per cosim28j; EP52 section archived; §1.4 recomputed; open items 8/9 closed, 10 (bench-verify) / 11 (rail isolation) / 12 (translator MPN) opened). `schematic.html` Fig 1/1b + traceability table synced.
- **RTL IMPLEMENTED + ALL SIMS PASS (Round 30 RTZ/sort-shaper):**
  - `dem_sort.sv` NEW: unconstrained sort-based 2nd-order vector shaper. Counting-rank implementation (rank_i = #{j: M_j<M_i or tie j<i}, sel = rank<c), 2 comparison lanes/cycle → 34 dsp_clk latency (56-cycle budget @350 MHz). Metric M=2·A1+A2 (g2=0.5 ×2 integer-scaled); 24-bit signed accumulators (python-verified bounds: |A1|≤63, |A2|≤382 audio; ≤103k at sustained 0 dBFS overload, self-bounding). Integer-exact reference + golden vectors: `dem_sort_gen.py`; SNDR/tone re-check of the exact RTL algorithm (lexsort tie-break): `dem_sort_check.py` → −153.7/−164.6/−168.3 dBFS in-band, tones ≤ −168.3 ✓.
  - `dac_dsp_core.sv`: dem_dwa → dem_sort (valid_out replaces the fixed 3-stage delay pipe); RTZ phase counter in cell_clk domain (resets on CDC capture, gate high phases 1-6 → EXACTLY 6 cell_clk wide pulses regardless of CDC wobble; parks at phase 7/low when streaming stops); IOB regs gate `rtz_gate ? cell_cap : 0`.
  - `tb_dem_sort.sv` NEW (+ golden mem in Testbench/): reset / 2000-sample bit-exact golden match / popcount / latency / extremes / balance — **ALL PASS** (latency max 34, balance 127..129).
  - `tb_dac_dsp_core.sv` tests 3/5 adapted for RTZ (outputs pulse during streaming and park at 0 after drain — single-instant sampling replaced by windowed monitoring on cell_clk with concurrent streaming via fork/join). **ALL 7 PASS** — including TEST 3 signal-flow and TEST 5 L/R independence which previously failed under the "FIR URAM X-poisoning" flag (#32): FIR now demonstrably produces real signal end-to-end → #32 likely stale/environmental, downgrade and re-verify before closing.
  - `tb_vu13p_top.sv` unchanged: **ALL 10 PASS**, cascode CDC toggle count 312→625 updates (RTZ pulsing visible through the full top) ✓. `run_sim.tcl` source list updated.
  - Remaining from ratification: e2e sine/FFT chain (#29, includes full-array RTZ LTspice deck), bench-verify items (bom #10), rail-isolation bound (#11).
- **#29 E2E SINE/FFT CAMPAIGN (in progress — PAUSED 2026-07-22 evening, session budget). The e2e test is earning its keep: FOUR real pre-existing bugs found, three fixed+verified, one open anomaly.**
  - Test rig: `tb_e2e_sine.sv` (coherent 1031.25 Hz, −1 dBFS, 512 input samples → 65536 DEM updates, uniform-boxcar FIR coefs = LTI so spectral purity holds; captures dem_out_l/paced_l/dither_l hex streams) + `e2e_sine_fft.py`/`e2e_bisect.py`/`e2e_align0.py`/`e2e_state_probe.py`. Rate/level probe: `tb_rate_probe.sv`.
  - **BUG 1 (FIXED): halfband_x2 never interpolated** — per-input phase toggle emitted ONE output per input (16 updates/sample end-to-end instead of 128; the DAC would have run at 768 kHz). Fix: emit BOTH phases per input (passthru then filtered, OUT_SPACING=4/2/1 for HB1/2/3), plus **sample pacer** in dac_dsp_core: 256-deep FIFO + cell_clk/8 pop tick (FIR sweep bursts 128 updates into ~1024 clk; NS/DEM/CDC need even 6.144 MHz; overflow warns once — accelerated top-tb overruns legitimately). Verified: 16/32/64/128 per stage ✓, dem_enable spacing ≥45 clk ≥ dem_sort's 36, 0 drops.
  - **BUG 2 (FIXED): NS feed scaling** — old `stable_l[63:16]` (top-48 slice) delivered 2^-17 of the NS input range (−102 dB: converter would have output shaped idle noise with buried signal). Fix: `ns_feed()` = volumed[46:0]<<1 saturating (FIR FS lives at bit 46).
  - **BUG 3 (FIXED): noise_shaper_7th_order coefficients {7,6,5,4,3,2,1} have NTF(DC) = −3 — NO DC zero, in-band noise AMPLIFIED** (−16 dB SNDR standalone). Analysis (`ns_coef_check.py`): FIR-EF is hard-capped at 2nd order with ±28-level signals (headroom ~6 levels vs ||h||₁·1.5 feedback swing); higher order needs NTF poles. **NEW `noise_shaper_ef3.sv`: NTF=(1−z⁻¹)³/(1−z⁻¹/2)³, all-dyadic shift-add, 136 dB** (`ns_ef3_gen.py` integer-exact reference + golden; `tb_ns_ef3` ALL PASS incl. overload recovery). Swapped into core (dem_enable delay pipe unchanged, 6≥4 stages ok).
  - **BUG 4 (FIXED): tpdf_dither_gen advanced its 32-bit LFSRs ONE bit per sample** — consecutive dithers shared 31/32 bits → measured **50 % of dither power in-band** (white = 0.65 %) → unshaped floor at the quantizer. Rewritten: 2× xorshift64 full-state scramble per enable, TPDF ±0.5 level; measured white (0.57 % in-band) ✓. Dither enable moved volumed_valid→pace_valid (1 fresh value per NS sample).
  - **ANOMALY RESOLVED (2026-07-23): it was an FFT MEASUREMENT ARTIFACT, not hardware.** Chain of proof (`ns_identity_probe/ns_ntf_verify/ns_window_check.py`): RTL bit-exact vs model (0/65536); no clips/clamps; exact loop identity y·LSB = u+32·LSB+f−e holds to 0; truncation chain −305 dBc; e white. The bimodal 95.0-vs-136 dB rect-window SNDRs collapse to ~116 dB under Hann (both "modes") — **rectangular-window edge leakage of the out-of-band shaped noise** (noise state is not window-periodic even with a coherent sine); Hann's own sidelobes then floor at 116. Correct methodology: **Kaiser β=38 window (sidelobes <−280 dB), ±12-bin main-lobe exclusion** — `e2e_final_fft.py`.
  - **FINAL E2E RESULT (Kaiser, −1 dBFS 1031.25 Hz, boxcar coefs): in-system DEM popcount SNDR = 138.6 dB** (> 133.5 dB code budget line ✓); NS input (paced_l) = 152.9 dB; python EF3 = 142.2 dB. #29 RTL leg CLOSED.
  - **FULL REGRESSION after all swaps (2026-07-23): tb_dac_dsp_core 7/7 PASS, tb_vu13p_top 10/10 PASS, tb_ns_ef3 ALL PASS, tb_dem_sort unchanged.** Remaining #29 sub-item: full-array RTZ LTspice deck (analog leg); bench-verify (bom #10), rail isolation (#11), translator MPN (#12).
  - **#32 CLOSED (2026-07-23):** the "FIR URAM X-poisoning in xsim" flag is stale — FIR provably passes real signal end-to-end (tb_dac_dsp_core 7/7 incl. signal-flow and L/R tests; e2e sine captured 138.6 dB SNDR through the full chain). Was environmental/fixed by interim RTL changes.
  - **RTL CLEANUP (2026-07-23, user-ratified): DELETED `noise_shaper_5th_order.sv`, `noise_shaper_7th_order.sv`, `tb_noise_shaper.sv`.** Reason: both are FIR error-feedback shapers, and that architecture is **mathematically capped at 2nd order for this converter** — with a 64-level quantizer and the ±28-level signal plan, quantizer headroom is ~6 levels while FIR-EF feedback swing is ||h||₁·1.5 levels (binomial L=3 already overloads; the 7th-order's "stable" de-tuned coefficients destroyed the DC zero = Bug 3). Higher-order shaping requires NTF poles, which `noise_shaper_ef3` provides; it beats the code budget line by ~5 dB and system noise is dominated by thermal/DEM-mismatch anyway, so re-adding a higher-order FIR-EF shaper is pointless. Do NOT restore. Also: `run_sim.tcl` source list pruned; stale comment refs fixed (`dem_64.sv`, `tb_dac_dsp_core.sv`, `tb_e2e_sine.sv` header now documents N_SKIP=0 capture + Kaiser methodology). FULL SUITE RERUN post-cleanup: **PASS — tb_ns_ef3, tb_dem_sort, tb_dac_i2s_ingress (11/11), tb_coef_bank_loader, tb_halfband_x2 (updated for the Round 30 true-x2 contract: 2 out_valids/input, passthru-first ordering, doubled IR capture), tb_dac_dsp_core (7/7), tb_vu13p_top (10/10)**. PRE-EXISTING failures, NOT from this campaign (stale tbs vs evolved RTL, per git history): tb_i2s_rx (data mismatch), tb_spi_ctrl_plane (references removed ports relay_out_status/gain_switch_busy — doesn't elaborate), tb_fir_polyphase_stereo (procedural-driver conflict on cycle_count — doesn't elaborate). Deferred pending user direction. **STALE-TB TRIAGE COMPLETE (2026-07-23, user-directed): all 3 fixed — and two exposed REAL RTL BUGS.** (1) `tb_spi_ctrl_plane` rewritten for the level/outsel scheme (13/13 PASS) → **RTL BUG A: `level_switch_req`/`outsel_switch_req` could NEVER fire** — change detection compared `cmd_*` vs its 1-cycle-old copy, but both only update on the same single-cycle `ctrl_bus_valid`, so they were always equal at pulse time (relay switching dead in hardware). Fixed in `dac_ctrl_plane.sv`: compare incoming `ctrl_bus_data` vs current register. (2) `tb_fir_polyphase_stereo`: fixed tb `cycle_count` + `polyphase_mac_engine` dbg driver conflicts → tb then ran and exposed **RTL BUG B: URAM288 coefficient packing wrong for BWE_MODE=PARITY_INTERLEAVED** — each BWE bit gates data byte [8b+:8] + parity bit [64+b], NOT 9 contiguous bits; the old [17:0]/[35:18]/[53:36]/[71:54] lane layout straddled byte boundaries so odd-MAC coefs lost upper bits IN HARDWARE (DC known-answer = exactly half; even MACs only). The `ifdef SIM` behavioral model hid it (this was the true root of the old #32 'URAM X-poisoning' ghost). Fixed in `fir_polyphase_stereo.sv`: lane k={mac_odd,bank} stores coef[15:0] in data bytes [16k+:16] + coef[17:16] in parity bits [64+2k+:2]; behavioral model now mimics real PARITY_INTERLEAVED gating. tb passes 7/7 with BOTH the real URAM288 primitive (-L unisims_ver, no -d SIM) and the behavioral model. (3) `tb_i2s_rx`: tb defect only — it checked the un-synced priming frame (receiver aligns on first LRCLK edge, first L word legitimately incomplete); checker now skips frame 1, 6 frames sent, ALL PASS + proper verdict line. POST-FIX REGRESSION: tb_dac_dsp_core 7/7, tb_vu13p_top 10/10, tb_spi_ctrl_plane 13/13, tb_fir_polyphase_stereo 7/7 (URAM+behavioral), tb_i2s_rx PASS. NOTE: ad-hoc xsim runs of FIR tbs MUST either pass -d SIM or elaborate with glbl + -L unisims_ver; run_sim.tcl's 4-tb list does neither for URAM designs (its list doesn't include the FIR tb). Re-verified post-delete: tb_dac_dsp_core 7/7, tb_vu13p_top 10/10 PASS.
  - Files touched this leg: `halfband_x2.sv`, `dac_dsp_core.sv` (pacer+ns_feed+ef3+dither enables), `noise_shaper_ef3.sv` (new), `tpdf_dither_gen.sv` (rewrite), `tb_e2e_sine.sv`/`tb_rate_probe.sv`/`tb_ns_ef3.sv` (new), goldens `ns_ef3_golden.mem`, py: `ns_coef_check/ns_ef3_gen/e2e_sine_fft/e2e_bisect/e2e_ns_replay/e2e_dither_replay/e2e_align/e2e_align0/e2e_state_probe`.
- **SINGLE-REGISTER CLOCK CONTROL (user request):** SPI 0x03 (`base_rate_sel`) now drives BOTH the DSP family select and the LMK00304 OCXO mux; 0x06 removed/reserved (`clk_source_sel` is a comb alias in `dac_ctrl_plane.sv` — readback regs 0x12/0x13 keep their bit positions, both bits now always agree). The top-level switch sequencer additionally enforces mute-before-switch IN HARDWARE (was host-firmware convention): register change → automute `rate_changed` drops relay drives + force_zero → `MUTE_DELAY_CYCLES` wait (new top param, 20 ms @ 200 MHz for mechanical relay release; 10 µs in sim) → MMCM held in reset → `clk_sel` flips → 10 µs mux/OCXO settle → release → relock (~100 µs) → `sys_rst_n` flushes every dsp/cell-domain pipeline (FIR, halfbands, NS, DEM, staging, cascode IOBs; the 128 pins reset to 0 so the EP52 FFs clock a static all-off pattern during the switch) → automute auto-re-runs to PLAYING since `cmd_unmute` lives in the always-on clk_200m domain. New tb TEST 5 verifies the full order (mute-before-flip, flip-during-reset, relock, auto-re-unmute): **ALL 10 TESTS PASS**. ARM firmware note: rate change is now ONE write to 0x03; 0x06 writes are ignored.

## Rounds 31-32 - Full-Array RTZ Analog Verification (#29 leg): RATIFIED STACK FAILS; passive-termination study reaches 364ppm plateau (bfdac_cosim29..32 series, 2026-07-23)
- **Replica-DAC option C first (bom #6, cosim29 series, NRZ framework):** transistor-level replica verified. Naive area-scaled single cell FAILS (q_pc 0.004%->0.78%, edge-shape nonlinearity); **64-unit-cell replica array (v29g) = 0.025% flat, 131.3dB** through dem_study (vs 133.5 behavioral); robust to 2ns skew + 0.5% weight mismatch; compact scaled-device variant (v29m) 126.4dB. 5mA mirror bleed required for asym. User flagged footprint (~64 units/channel); decision deferred to the RTZ deck - then superseded by the RTZ finding below.
- **FULL-ARRAY RTZ DECK (cosim30, 64 real cells, RTL-faithful 8-phase timing): the ratified I/V+cascode stack CANNOT process full-scale RTZ.** At N=64 the loop enters a sustained ~7MHz relaxation ring (diffout -4.7..+8.2V, sum nodes +-0.6V, Q5p/Q5m alternately rectifying ~30% of each period, bus caps sloshing ~5nC). Invariant to bus caps 0.5n-10n, 10x amp (400MHz/2700V/us), C_f 390p-10n, C_sum 2.2n-100n. Root: RTZ moved 49.5mA/3ns full-code square steps into EVERY period; all NRZ verification assumed K=4 (3mA) steps. Waveform probe: utils/read_ltraw.py + rtz_wave_probe.py (new).
- **Round 31 (averaging I/V + stagger + behavioral RGC): all fail at 2% INL.** Steady-state exact-period INL metric (utils/rtz_inl.py; boundary-interpolated integration - nearest-sample windows fake mV-level INL). Current audit (rtz_audit.py): virtual ground clean to +-10uV; nonlinearity = +-0.8mA in avg Ie(Q5) - bus-side switch charge interacting with code-dependent bus trajectory. Ideal-cascode falsification: 5x better but amp then saturates - both stages implicated.
- **Round 32 (passive termination, commercial-DAC style, cosim32a-g): 14,000 -> 364 ppm via mechanism kills:**
  - replica-ff casb vs fixed: no difference at this level; bleed-R transduction EXONERATED (910->910k identical); raised bus (vfr 2.5V) no help; 8x4n stagger only ~2x (bus recovery tau > spacing).
  - bus caps: INL tracks bus_pp almost linearly (~1.1%/V transduction constant); 100n -> 59mV slam, 700ppm.
  - **MOSFET cascode kills the Ib-Jensen channel** (avg Ib nonlinear under slam ripple; Ib-comp tracks only the smooth replica current): 8100->927ppm @10n. Also deletes Q5C/QM/QN Ib-comp + snk-replica legs entirely.
  - **stiff gate drive** (47R->10R) cuts dip->Cgd->duty-modulation residual: 501->364ppm @100n.
  - **Plateau ~364ppm (HD2 ~ -70dB class vs -130 target). Root quantity: LVFET gate charge ~230pC/cell x64 = 15nC/period slam vs 94pC/period signal charge.**
- Remaining identified levers (unproven): low-Qg steering device (BJT quad / RF FET, 10-40x less charge), differential injection-cancellation caps, digital predistortion of the smooth static INL(N) bow (~100x on residual, needs cal). Composite could plausibly reach ppm-class = 2 more speculative legs + calibration infrastructure.
- **STATUS: Round 30 RTZ ratification is analog-unverified at target level. Options on table: continue passive-RTZ legs vs revert to NRZ+const-k (fully verified 131dB analog, driver-asym axis ~140dB accepted per Round 29 option C). USER decision pending.**

## Round 33 - Passive-RTZ BREAKTHROUGH: 364ppm -> 8.1ppm settled (bfdac_cosim33a-h, 2026-07-23)
- **Leg 1 (v33, BJT steering):** Q5551-class current-steering pairs replace the LVFET switches (base charge ~3-5pC vs ~230pC gate charge). Bus slam 42mV -> 1.8mV (25x). INL plateaus at ~250ppm - NEW floor, cap-independent.
- **Floor hunt (v33b/c/d):** double cascode: no change (not finite-ro); replica-law calibration 0.72-0.774m: no change; RGC on passive path: no change (295ppm).
- **v33e IDEAL-CASCODE ISOLATION: floor persists (316ppm) => lives in the CELL ARRAY. Smoking gun: 192mV/period slam on the SHARED q4_base 1.25V reference line** (couples through 64 tail Cjc/base paths; R_bias 100R line impedance; code-proportional -> modulates all 64 tails -> N^2 INL). Under NRZ this was K=4-scale and constant/sample (benign) - never seen before.
- **v33f: q4_base HF bypass (10u) with ideal cascode -> 0.54ppm** (measurement floor). Root cause CONFIRMED.
- **v33h COMPOSITE, settled (22n bypass, tau 2.2us, 13us run, serr 2e-5): max|INL| = 8.13ppm** (~-102dB HD class) with: BJT steering cells + MOSFET cascode (replica-ff casb; NO Ib-comp - deleted entirely) + q4_base bypass + 47n bus caps + passive 28R termination.
- **Emerging RTZ architecture is SIMPLER than the ratified one:** no precision loop in the switching path, no Q5C/QM/QN Ib-comp, no snk-replica leg. Still open: reconstruction filter + post-amp design (new sec 2 - passive termination = caps/Ls in audio path, needs user rule check), replica-ff realization (real cells vs B-source), remaining 8ppm decomposition, noise budget of the 28R termination, per-cell base decoupling as the hardware form of the q4_base fix.

## Round 34 - Termination-cap DECISION DATA (bfdac_cosim34a-e, 2026-07-23). User rule context: cap opposition = nonlinear phase (group delay) concern.
- Measurement note: q4_base bypass tau (2.2us) contaminated single-period INL windows; runs extended to 32.5us (13tau) + 10-period exact windows. Residual drift still limits reading to ~+-15ppm.
- **v34c: 12n C0G shunt at termination exposed cascode Vds-lambda modulation** (col node now slow -> code-dependent Vds on M5): 145ppm. **v34d DOUBLE MOSFET cascode fixes it: 32.4ppm = unfiltered baseline (v33h3 29.2ppm) within drift.** v34e BJT cascode instead: 110ppm (Ib channel returns) - MOSFET double cascode is the architecture.
- **Cap decision numbers (28R x 12nF = 473.7kHz pole, the only cap touching raw audio, shunt at 28R):**
  - in-band group-delay variation 0-20kHz: **0.60 ns** (phase 2.42deg @20k); droop 0.0077dB; both min-phase -> EXACTLY pre-invertible in the existing FPGA FIR (fold into polyphase coefs).
  - image @6.144MHz: -22.3dB after this pole alone; post-amp sees 232mVpp ripple, 2.85V/us slew demand (trivial).
  - termination Johnson noise: 136nVrms/20kHz diff vs 0.919Vrms FS -> **136.6dB SNR** before post-amp.
  - INL cost of the cap: **zero** (32.4 vs 29.2ppm, equal within measurement drift).
- **STATUS: passive-RTZ chain at ~30ppm (-90dB HD class); known-remaining smooth mechanisms (predistortion-eligible). Cap ruling awaited; measurement methodology needs an upgrade (drift-limited) before chasing <10ppm.**

## Round 35 - MEASUREMENT METHODOLOGY UPGRADE: floor ~5ppm; the ~30ppm was REAL (bfdac_cosim35/35b, utils/rtz_chop.py, rtz_chop2.py, 2026-07-23)
- New deck style: ONE continuous transient, NO .step (no cold restarts). Cells driven by B-sources gated on a PWL code schedule V(nsch); ref N=32 interleaved between every code segment (drift chopping); DNL pair 31/32/33; reltol 1e-5. Replica-ff law becomes analytic: I_p=krep*N*pw, I_m=krep*(64-N*pw).
- v35 (10-period segments) FAILED usefully: termination tau (336ns~2 periods) + q4_base tau (2.2us~13 periods) >> segment; 5-period discard left 9% of a 1.1V step in-window.
- **v35b (40-period segments, 20 discard): ref drift trace +-12uV pk (chopping removed 66,000uV of raw drift); segment sd 5-17uV -> floor ~5ppm.**
- **RESULT: max|INL| = 73ppm (discard method) / 98ppm (asymptote method), consistent; WORST AT MIDSCALE (N=16-32), 10x above the measurement floor => a REAL mechanism remains, |code-32|-symmetric signature (rail-interaction / replica-copy-asymmetry class).** DNL(31/32/33) = 0.06-0.6% LSB. Asymptote fit taus 350ns/1.2-2.2us confirm circuit time constants.
- Methodology verdict: chopping + 40-period segments + exact-period integration = trusted to ~5ppm. Gold-standard FFT run (real DEM sine vectors) still owed as final gate.
- NEXT (Round 36): midscale mechanism hunt with the trusted tool; then real replica cells, post-amp stage, spectral gate. Cap ruling: user leaning keep (12n C0G termination), not yet committed.

## Round 36 - Midscale mechanism found & killed: CASCODE DEVICE CAPACITANCE. Chain at ~24ppm, instrument-limited (bfdac_cosim36a-g, utils/rtz_chop_eval.py, 2026-07-23)
- v36a per-rail INL: both rails carry the same ~70ppm midscale bow, equal-and-opposite (adds in diff) -> mechanism in the shared cascode-stack physics, function of rail current.
- v36b ideal-cascode chop: cells CLEAN at the new floor (max 21ppm @ floor ~9) - confirms Round 33 cell verdict at 10x better precision.
- v36c/f cbus 220n (80-per segments, floor 1.8ppm): 62ppm - cap-INdependent. v36e fixed-casb (replica deleted): worse/drifty (115ppm, floor 50) - replica-ff stays.
- **v36g cascode devices swapped to 10x-lower-C model (Cgs 5p/Cgd 8p vs 50p/80p, same Kp): 73 -> 23.7ppm, AT the measurement floor (~18ppm).** Mechanism: casb repositioning charge - casb steps by dVgs(N) (sqrt-law bow) into device capacitance every period. CONFIRMED + KILLED. MPN consequence: cascode wants small-capacitance FETs at 100mA, NOT chunky power VDMOS.
- **STATUS: passive-RTZ chain measures <=24ppm (-92dB HD class), reading floor-limited; every identified mechanism killed; next resolution step needs longer-segment runs (floor scales ~1/sqrt) or the FFT gate. Remaining gap to -130dB: ~1.5 orders; predistortion (~100x on static bow) remains in reserve.**
- Architecture as of tonight: BJT steering cells + double MOSFET cascode (LOW-C devices) + replica-ff casb + q4_base bypass + 47n bus caps + 12n C0G termination (cap: user leaning keep, uncommitted) + passive 28R loads.

## Round 37 - GOLD-STANDARD FFT GATE (bfdac_cosim37, utils/gen_cosim37.py, utils/rtz_fft.py, 2026-07-23)
- Stimulus: REAL digital chain, bit-exact python references of RTL (ns_ef3_gen.step EF3 NS + dem_sort integer-exact selection) -> 16384-period vectors, -1dBFS 6.375kHz coherent tone, code range 6..59. Per-cell PWL drives (pwl37/) into the v36g deck (BJT steering, double LOW-C cascode, replica-ff, q4_base bypass, 12n C0G termination). One 2.67ms transient (~1h wall).
- Analysis lesson: windowed-FFT with discard destroyed coherence (fundamental skirt flooded band; kaiser mainlobe 28 bins > 17-bin harmonic spacing). Robust extractor = LS harmonic fit (quadratures h=1..8 + drift terms) on settled segment. Per-harmonic sensing floor (NS noise in 428Hz eq-BW): -115dBc.
- **RESULTS: IDEAL popcount of same vectors: all harmonics at the -115dBc floor (coherent-rect in-band SNDR of code stream = 140.8dB - digital chain holds the target). ANALOG: HD2 = -91.4dBc, HD3 = -93.6dBc in-band (HD4/5 -75dBc out-of-band, reconstruction filter territory).**
- **INTERPRETATION: -91dB HD2 matches the ~24ppm static midscale bow prediction (-92dB). DEM shapes cell mismatch but NOT code-level (array-physics) INL - as expected. NO new dynamic/transition-history mechanism above the -91dB level => the architecture has no hidden dragons; it is gated by the known smooth static bow (predistortion-eligible).**
- GATE VERDICT: architecture PASSES at its static-INL level; path to -130 = kill/predistort the remaining code-level bow. Ratification decision now data-complete.

## Round 38 - REAL-DEVICE MPN PASS on the cascode (bfdac_cosim38a-t, 2026-07-24)
- 3 vendor VDMOS candidates swapped into the v35b chopped deck (all 8 positions incl. replica diodes; self-biasing, no retune): **BSS145 113ppm (Vto 2.8, headroom-marginal); Si1555DL_N 58ppm (best); NDC7002N 66ppm** - vs 24ppm ideal-LVFET baseline. Floors 4-10ppm; errors real.
- **Si1555 signature is HIGHLY REPRODUCIBLE**: INL(N) = (-36, +2, +56, -14, -4, -4) identical across 6 independent perturbation decks (38b/f/h/l/n/q) => static + stable => predistortion-eligible exactly like the baseline bow.
- Mechanism forensics (all on Si1555): headroom vfr2 3.0->3.6V: 54ppm (no). m=4: 48ppm, m=16: 148ppm (paralleling confounded by 16x caps). Cgd linearized: 55ppm (not Cgd). Cjo->0: 137ppm. Cgs->50p only: 134ppm. Cjo->50p only: 58ppm. Cgs+Cjo=50p: 147ppm. External linear caps in D-S/G-S/ground positions: 56-117ppm (never better).
- **DECISIVE discriminator: Si1555 DC params + LVFET cap set = 23ppm (baseline!); LVFET DC + Si1555 caps = 54ppm.** The 24ppm baseline contains a fortuitous dynamic RTZ edge-charge CANCELLATION specific to the LVFET's exact {Cgs=50p, Cjo=50p, Cgdmax=80p/Cgdmin=12p} combination - no single param or external linear cap reproduces it. Vendor VDMOS switch-cap models are crude; a ppm-level cancellation must NOT be design-relied-upon.
- **VERDICT: honest real-device static INL = ~55-60ppm (-83dB HD2 class), stable signature, uncorrelated with device "quality" knobs. Consequence: code-level predistortion (already planned for the 24ppm bow, rd12) is PROMOTED from reserve to REQUIRED for -130dB; it handles 58ppm as easily as 24ppm since the signature is static. MPN pick: Si1555DL_N (dual N-ch SC-89, Vto 1.1V, 20V, low Qg) - headroom-comfortable at vfr/vfr2 = 1.75/3.0V.**

## Round 39 - FFT GATE ON THE REAL Si1555 DECK (bfdac_cosim39, utils/rtz_fft39.py, 2026-07-24)
- Same 16384-period real EF3+dem_sort vectors as Round 37 (pwl37/ reused), cosim37 deck with all 8 cascode positions on the Si1555DL_N vendor model. LS-harmonic-fit extractor (quadratures h=1..8 + drift; kaiser-FFT rejected per Round 37 lesson) rebuilt as rtz_fft39.py.
- **RESULTS: IDEAL popcount all harmonics -111dBc (uniform = noise floor). ANALOG: HD2 = -84.0dBc, HD3 = -80.8dBc in-band (HD4-8 out-of-band -86..-103dBc, reconstruction-filter territory).**
- **INTERPRETATION: -84/-81dBc matches the ~58ppm static signature prediction (-83dB class) - the ~8dB cost vs the Round 37 LVFET baseline (-91.4/-93.6) is fully explained by the static INL. NO new dynamic mechanism from the real device. Gate PASSES at its static level; predistortion carries the rest.**

## Round 40 - FULL 64-CODE INL LUT on Si1555 (bfdac_cosim40/40r, utils/gen_cosim40.py, utils/rtz_inl_full.py, utils/lut_compare.py, 2026-07-24)
- Chopped ref-32 measurement of ALL 64 codes (5080 periods, drift-interpolated): gain -30.978mV/cell, max|INL| 94ppm, floor ~7ppm. SIGN LESSON: LUT must use SIGNED gain (diffout falls with N); first predistortion attempt with |span| convention ADDED distortion (-79.9/-75.8) instead of cancelling - caught by the anti-distortion image test.
- REPRODUCIBILITY: forward vs REVERSED code order agree <1ppm at 55 of 63 codes; N=20-28 zone disagrees by +/-25ppm => HISTORY-DEPENDENT (hysteretic) zone, sets the static-LUT accuracy cap. Averaged fwd/rev LUT performs the same as forward within the gate resolution.

## Round 41 - LEVEL-AWARE PREDISTORTION (utils/dpd_study.py, utils/gen_cosim41.py, bfdac_cosim41, 2026-07-24)
- Concept validated exactly in code domain: EF3 quantizer feedback subtracts ACTUAL level (code + LUT) instead of ideal code; entire static INL is noise-shaped out of band. With self-consistent LUT: in-band SNDR 81.8 -> 141.6dB (Kaiser b38 estimator; rect readings are seed-bimodal, do NOT trust), HD2/HD3 -139dBc. Code stream carries visible anti-distortion image (-88dBc) - good sign-check diagnostic.
- FULL SPICE GATE (Si1555 deck, predistorted vectors): HD2 -84.0 -> -92.6dBc, HD3 -80.8 -> -94.7dBc. Static INL contribution removed; residual -92dB class is DYNAMIC (matches the N=20-28 hysteretic zone / bias-memory scale), invisible to any static LUT.

## Round 42 - DYNAMIC RESIDUAL FORENSICS + extended-DPD attempt (utils/toggle_probe.py, utils/dpd2.py, bfdac_cosim42, 2026-07-24)
- Toggle-count (switching-charge) hypothesis REJECTED: kt ~ 0.07uV/toggle, no harmonic change.
- Bias-memory hypothesis SUPPORTED in-sample: adding ema_tau(code) x poly(code) bilinear terms (taus 4/13.5/40 periods) collapses regression residual HD2 to -128dBc. Physical story: code-dependent bus current moves bias nodes (Q4 base tau 2.2us etc), bias state multiplies cell charge.
- BUT extended DPD FAILED out-of-sample (SPICE cosim42: HD3 back to -82.9): single-tone data cannot separate static poly / EMA products / reconstruction dynamics - the fit is not identifiable and injects wrong anti-distortion. Multitone or broadband ID stimulus required to fit dynamic terms honestly.
- STATUS: shipped result stands at HD2 -92.6 / HD3 -94.7dBc post-static-DPD (10-14dB from predistortion). Gap to -130 target is now entirely dynamic-mechanism territory. NEXT: (a) circuit-level kill of the N=20-28 hysteresis + bias-memory (stiffer q4_base / faster replica), or (b) multitone ID run for the bilinear corrector, or (c) both.

## Round 43 - MECHANISM DISCRIMINATORS (bfdac_cosim43/b/c/d/e, utils/gen_cosim43.py, 2026-07-24)
- Strategy pivot ratified with user: targets restated as noise floor >128dB (achievable via scale/paralleling) + THD as close to -120dBc as possible (verifiability limit: best silicon -120..-124, APx555 residual ~-120). Constant-activity/circuit fix chosen over FIRDAC switch until data says otherwise.
- 43a clamped columns (ideal I/V, uncorrected vectors): -83.7/-80.7 = identical to passive loads => static bow is IN THE CELLS, not the load; column swing (tau=2 periods) also NOT the dynamic mechanism (43b clamped + predistorted: -92.4/-94.1, same as unclamped).
- 43c C_q4 22n->100p: HD3 -75.5 (worse; statics changed, LUT stale - inconclusive but shows q4_base sensitivity).
- **43d C_q4 22n->10u (tau 2.2us->1ms, bias frozen below audio band): HD2 -92.4 -> -101.9 with the STALE LUT. Q4-BASE BIAS MEMORY CONFIRMED as the dominant dynamic HD2 mechanism** (its 2.2us tau = 13.5 periods matched the strongest EMA term in the Round 42 regression).
- 43e adding casb 10u + cbus 470n: statics changed massively (LUT invalid, -69/-76) - those mods need their own LUT and broke chopped-run settling (43.7mV drift); REJECTED for now.

## Round 44 - SLOW-BIAS DECK, FULL HONEST PIPELINE (bfdac_cosim44lut/44, utils/gen_cosim44.py, 2026-07-24)
- Config: C_q4 10u ONLY. LUT re-measured with SHUFFLED chopped schedule (random.Random(44)) so the 1ms bias tau sees a stationary average instead of a code-correlated ramp: max|INL| 89ppm, floor 6.6ppm, drift 12.7uV (ordered schedule was unusable at 34mV drift - lesson: slow bias requires randomized calibration order, true on the bench too).
- **FULL SPICE GATE (predistorted, matched LUT): HD2 -98.8 / HD3 -96.1 dBc; all out-of-band harmonics <= -99.** Progression: -84.0/-80.8 (R39) -> -92.6/-94.7 (R41 DPD) -> -98.8/-96.1 (R44 circuit+DPD). One 8-cent capacitor + calibration procedure = 15dB.
- REMAINING: ~-97dB class residual (hysteretic N=20-28 zone + tau~4-period term candidates: bus 47n/casb nodes - each needs its own LUT-matched round). Sensing floor of the 16384-period gate is getting close; longer runs or averaged gates needed for honest iteration below ~-105.

## Round 45 - EXTENDED GATE 65536 periods (bfdac_cosim45, utils/gen_cosim45.py, 2026-07-24)
- 4x gate on the slow-bias deck (C_q4 10u, cosim44lut LUT, BIN=67, 10.67ms transient, 76min sim). Per-harmonic sensing floor -87.6dBc (3dB better than 16k gates; floor is set by out-of-band NS noise surviving the boxcar, not by run length alone).
- **HD2 -97.9 / HD3 -95.9 dBc - reproduces R44 (-98.8/-96.1) within the floor. The ~-97dB residual is REAL and STABLE, not a sensing artifact or seed fluke.**

## Rounds 46-48 - HYSTERESIS ROOT CAUSE: SELF-OSCILLATION (bfdac_cosim46/47/48a-q, utils/gen_cosim46/48.py, utils/hyst_probe.py, utils/settle_zone.py, utils/probe48.py, 2026-07-24)
- The N=20-28 "hysteretic zone" is a marginal-stability SELF-OSCILLATION: codes 23-28 show an ~18-period quasi-cycle, +/-40-100uV pk on diffout segment std, while all other codes sit dead flat (<1uV). Explains the fwd/rev LUT +/-25ppm disagreement (R40): the "static" level in the zone depends on the oscillation phase at sample time.
- Loop: 47n bus caps against the inductive-looking source impedance of the M5 cascode in a specific current window. Kill matrix (probe48, seg std at c24/c27/c28): 48a control 38/42/52uV; bus-cap snubbers (b=3R3, c=10R) only MOVE the window; **48h mid series 10R: 6.5/6.4/0uV (20dB down); 48j mid 10R + 1n: 0.5/1.0/3.6uV (best kill)**.
- vfr2 stability window probe (48r/s/t/u = 2.5/3.5/4.0/2.0V): oscillating-code window MOVES with cascode bias (vfr2=2.0 quiets 24/28 but wakes c40 at 26uV; 4.0 quiets 27/28 but keeps c24) - no vfr2 value kills it globally. Confirms marginal loop through the cascode; bias tweak is not a fix.

## Rounds 49-50 - MID-NODE DAMPING, LUT-MATCHED GATES (bfdac_cosim49/49lut/50/50lut, utils/gen_cosim49/50.py, 2026-07-24)
- Full honest pipeline on both fixes (shuffled-schedule LUT re-measured on the modified deck, level-aware DPD, 16k gate):
- 49 (mid 10R + 1n): HD2 -88.7 / HD3 -87.8. 50 (mid 10R only): HD2 -89.4 / HD3 -87.1.
- **Both oscillation kills COST ~10dB vs the undamped deck (R44 -98.8/-96.1). The damping element sits in the signal-current path and adds its own code-dependent settling error that the static LUT cannot capture. Oscillation kill is NOT worth the trade at these values - REJECTED as implemented.**

## Round 51 - LUT AVERAGING (bfdac_cosim51, 2026-07-24)
- Base slow-bias deck, LUT = average of seed-44/seed-45 shuffled runs: HD2 -97.8 / HD3 -96.1 - identical to single-LUT R44 within the floor. LUT noise is not the limiter; the residual is the oscillation zone + remaining dynamic terms.
- STATUS after R45-52: converged plateau at HD2 ~-98 / HD3 ~-96 dBc. The residual is dominated by the codes-23-28 marginal oscillation, whose gentle kills (mid damping) cost more than they save. Remaining levers: (a) damping that stays OUT of the signal path (e.g. RC across the M5 cascode gate feed / gate stopper R, loop compensation not series loss), (b) DEM-level avoidance (skip codes 23-28 via NS clamp - zero analog cost, small NS penalty), (c) accept ~-96..-98dBc THD, which already beats the -95dBc class of premium commercial DACs and sits within reach of the APx measurement floor.

## Round 53 - GATE-STOPPER PROBE (bfdac_cosim53a-g, utils/gen_cosim53.py, 2026-07-24)
- Series R at the cascode MOSFET GATES (no drain current through it => no signal-path insertion loss, unlike the mid-series R of R49/50). Kill matrix (seg std at c24/c27/c28/c40 uV; control 38/42/52/0):
- a 22R M5: 9/15/0/1. b 100R M5: 1.0/1.5/1.9/2.3. c 470R M5: 0/6.8/7.7/1.9. **d 100R M5+M6: 1.3/1.0/1.1/0.9 - GLOBAL KILL, all codes <=1.3uV.** e 1k: 29/46/0/3 and f 2k2: 30/35/32/37 - WORSE (classic stopper sweet spot; too much R re-phases the loop). g 470R both: 0.1/9.5/9.9/0.1.
- Sim-speed tell: underdamped variants (22R/100R-single) grind at tiny timesteps (HF ring); damped variants run at full speed.

## Round 54 - GATE-STOPPER FIX, FULL HONEST PIPELINE (bfdac_cosim54lut/54, utils/gen_cosim54.py, 2026-07-24)
- Config: 100R gate stoppers on M5 AND M6 (53d) + slow bias (C_q4 10u). Two real resistors, zero signal-path cost.
- **LUT: max|INL| = 7.10 ppm (was 89 ppm on R44 deck!), floor ~3.4 ppm, drift 17.7uV. The marginal loop was not just noise - it was bending the whole static characteristic 12x.**
- **FULL SPICE GATE (predistorted, matched LUT): HD2 -102.1 / HD3 -109.4 dBc; ALL higher harmonics <= -111 (HD8 -123).** Progression: -84/-81 (R39) -> -92.6/-94.7 (R41) -> -98.8/-96.1 (R44) -> -102.1/-109.4 (R54).
- **ARCHITECTURE VERDICT (answers the "are we at the limit?" question): the -97dB plateau was NOT architectural - it was one device instability, fixed by two 100R resistors. The current-steering cascode architecture is NOT exhausted.** Remaining residual is HD2-dominated at -102; candidates: residual bias memory, LUT floor (7ppm ~ -103dB class - consistent!), even-order coupling. Next levers: LUT averaging on the quiet deck (floor now reachable), extended gate to confirm, HD2-targeted probing.

## Round 55 - LUT AVERAGING ON THE QUIET DECK (bfdac_cosim54lut2/55, 2026-07-24)
- Second LUT with seed-45 shuffled schedule: max|INL| 6.74ppm. Seed-44 vs seed-45 agreement: max|diff| 7.2ppm, rms 1.9ppm - LUTs now agree at the chop-measurement floor (drift ~3.4ppm class); the R40 +/-25ppm hysteretic disagreement is GONE with the oscillation.
- Gate with averaged LUT: HD2 -101.7 / HD3 -110.0 dBc - identical to R54 single-LUT (-102.1/-109.4).
- **CONCLUSION: HD2 ~-102 is NOT LUT-noise limited - it is a SYSTEMATIC even-order mechanism.** Candidates (differential structure should cancel even order, so look for P/N asymmetry): pwa/pwb RTZ pulse skew, krep*N vs krep*(64-N) replica asymmetry, single-ended bleed/bias coupling. Extended 65k gate (R56, avg LUT, gate-stopper deck) launched to confirm before the HD2-asymmetry round.

## Round 56 - EXTENDED GATE CONFIRMATION (bfdac_cosim56, utils/gen_cosim56.py, 2026-07-24)
- 65536 periods, BIN=67 (different tone freq than the 16k BIN=17 gates), avg LUT, gate-stopper deck: **HD2 -102.3 / HD3 -108.4 dBc; HD4-8 all <= -113.** Confirms R54/55 at 4x record length and different tone placement - the numbers are honest.

## Round 57 - HD2 DISCRIMINATOR: RTZ SKEW (bfdac_cosim57lut/57, utils/gen_cosim57.py, 2026-07-24)
- skew=0 (deck's deliberate 1ns pwb delay removed), full honest pipeline (own LUT: 11.5ppm): HD2 -102.6 / HD3 -109.1 - UNCHANGED. **RTZ pulse skew is NOT the HD2 mechanism** (statics from skew were already absorbed by LUT/DPD; also means the bench clock-matching requirement is relaxed at this level).
- **STATUS: HD2 -102 is systematic, reproducible across 4 independent gates (R54/55/56/57), even-order. Remaining candidates: replica-ff krep asymmetry (N vs 64-N), single-ended bleed/bias networks, BJT cell dynamic even-order, vp8/load common-mode conversion. Next discriminator ideas: inverted-signal gate (u -> -u, complex-HD2 phase comparison separates signal-even-order from fixed artifacts), krep trim probe, bleed symmetrization.**

## Round 58 - INVERTED-SIGNAL DISCRIMINATOR (bfdac_cosim58, utils/hd2_phase.py, dpd_study.py "inv" mode, 2026-07-24)
- Same avg LUT, same deck, u -> -u. Complex LS fit (utils/hd2_phase.py, absolute time reference):
- fund -90.8 -> +89.2 deg (exact 180 flip, sanity ok). HD3 +172.7 -> +0.9 deg (flips ~180 = textbook odd-order, tracks x^3). **HD2 -63.1 -> -78.4 deg at -101.7 -> -102.8 dBc = INVARIANT under inversion -> genuine quadratic (x^2) distortion of the differential transfer path**, not a fundamental-polarity-tracking artifact.
- Static residual can't explain it alone: LUT bow scale says 7ppm ~ -106 class, and the measured LUT reproducibility (2-3ppm rms) puts correctable statics below that. Points to DYNAMIC even-order: code-dependent settling in the BJT cells / symmetric CM->diff conversion.
- NEXT: amplitude discriminator (-7dBFS gate: pure x^2 -> HD2 dBc improves ~6dB, 1dB per dB of drive) - separates quadratic-transfer from residual-static, and directly quantifies the drive-level trade available on the bench.

## Round 59 - AMPLITUDE DISCRIMINATOR + GLITCH REGRESSION (bfdac_cosim59, utils/hd2_glitch.py, dpd_study.py dB arg, 2026-07-25)
- -7dB drive gate (code range 18..46, same avg LUT): **HD2 -102.6 dBc - dBc UNCHANGED vs -1dB drive => HD2_abs scales ~A^1, NOT A^2.** HD3 improved -110 -> -117 (odd-order scales as expected). Practical: drive backoff does NOT buy HD2 - it acts like a fixed fraction of signal.
- Combined verdict (R58 inversion-invariant + R59 A^1 scaling): **RECTIFICATION-CLASS mechanism (|x|-type), not quadratic transfer, not static residue.**
- Glitch-energy hypothesis REJECTED: |dN| and dN^2 regressors fitted jointly across gates 55/58/59 give kt = +746/+1383/-1303 u/unit - sign-inconsistent, not physical (utils/hd2_glitch.py; |N-32| regressor is collinear with the HD2 basis - uninterpretable, don't reuse).
- Remaining rectifier candidates: DEM cell-usage/rotation-rate dependence on |s|, EMA'd rail nonlinearity cross-terms, cascode CM disturbance ~ |code excursion|. NEXT discriminator: tone frequency (all gates so far sit at f0 ~ 6.3-6.4kHz(!); a BIN=37 gate at ~13.9kHz separates dynamic rectifier - phase/mag rotates with f - from static rectifier).

## Round 60 - FREQUENCY DISCRIMINATOR (bfdac_cosim60, BIN env var in dpd_study/hd2_phase, 2026-07-25)
- BIN=37 gate (f0=13.875kHz, 2.18x the usual 6.375kHz), same avg LUT: HD2 -96.6 / HD3 -103.8 dBc.
- **Both HD2 and HD3 rose ~5.5-6dB for a 2.18x (6.8dB) frequency step => residual distortion scales ~proportional to f0. The remaining mechanism is DYNAMIC (settling-class), uniform across even and odd order.** Phase rotation modest (HD2 -63 -> -82 deg).
- Full fingerprint of the residual: ~A^1, inversion-invariant (even part), ~f^1 => code-trajectory-dependent settling error (incomplete settling / slew asymmetry within the RTZ window), NOT static, NOT LUT-correctable, NOT glitch-count.
- **BIG PRACTICAL COROLLARY: distortion ~f means the standard 1kHz THD spec point extrapolates to HD2 ~ -119 dBc / HD3 ~ -126 dBc.** Our 6.4kHz gates were a stress test; at the customary audio measurement frequency this design is already in the -120dB class. In-band worst case (f0=10kHz, HD2 at 20kHz band edge): ~-99 dBc.
- Forward options: (a) RTZ timing margin (wider settle window / narrower twid trade), (b) faster cell switching edge, (c) dynamic DPD with memory terms (dN-dependent), (d) accept: report THD vs frequency curve, spec at 1kHz.

## Round 61 - RTZ TIMING + DRIVE-STRENGTH MATRIX (bfdac_cosim61a-e, utils/gen_cosim61.py, 2026-07-25)
- Five variants on the R54 config, full honest pipeline each (own LUT + DPD + 16k gate). NOTE: gates accidentally ran at BIN=37 ($env:BIN persisted in the shell) - turned out useful: 13.9kHz is the more sensitive stress point. Baseline (R60): HD2 -96.6 / HD3 -103.8.
- a tedge 3n->1n (faster edges): -95.5/-101.0 (worse; also 2.4x worse static INL 17ppm - edge feedthrough). b settle margin 1.5tc/5tc: -97.3/-102.5 (wash). c both: -95.7/-100.1 (worse). d overdrive vhi 1.7->2.0: -95.3/-100.9 (worse). e swing 0.9/1.9: -95.6/-100.6 (worse).
- **VERDICT: the settling-class residual is INSENSITIVE to (or degraded by) every RTZ timing/edge/drive-strength knob - the stock 3n/6tc/1.1-1.7V point is already a local optimum. Drive strength does NOT buy linearity. The residual lives in the transition charge dynamics themselves (code-trajectory-dependent switching charge, e.g. collector-node/Cob redistribution), not in incomplete settling.**
- Combined with R60 (~f scaling): remaining realistic levers are dynamic DPD (memory terms) or acceptance with THD-vs-f characterization (1kHz point ~ -119dBc HD2 by ~f extrapolation).

## Round 62 - THD vs FREQUENCY CURVE (bfdac_cosim62b5/62b11 + existing 55/60, 2026-07-25)
- Same deck + avg LUT at four tone frequencies (16k gates). ANALOG HD2/HD3 dBc:
- 1.875kHz: -108.3/-125.5 | 4.125kHz: -104.2/-118.0 | 6.375kHz: -101.7/-110.0 | 13.875kHz: -96.6/-103.8
- **HD2 slope is SUB-linear: ~f^0.65-0.75 (11.7dB rise over a 7.4x frequency span), not the f^1 assumed from the 2-point R60 fit. 1kHz extrapolation: HD2 ~ -112dBc.** HD3 falls faster toward LF and hits the code-domain floor.
- HONESTY FLAG: at 1.875kHz the IDEAL-popcount (NS+DEM+dither) floor is HD2 -114.1 / HD3 -118.4 - the analog LF points are within ~6dB of the code-domain floor of a 16k record; deeper LF readings need longer gates. (4.125k HD3 -118.0 vs floor -116.8: floor-limited, phase-cancellation artifact.)
- In-band worst case at 0dBFS: ~-97..-99dBc (top-of-band tones, harmonics land near/beyond 20kHz). Comparable to the best monolithic flagships (published 1kHz THD+N -120dB; measured 19kHz THD of ES9038/AK4499-class parts is -95..-105dBc).
- Correction lever identified: mechanism = per-period transition charge dependent on the code trajectory (N_prev -> N). Natural digital fix = 2D dynamic LUT E(N_prev,N) in the NS feedback, measured by a pair-transition chop protocol. This is the lever chip vendors DON'T have (we own the digital path).

## Round 63 - PAIR-TRANSITION MEASUREMENT (bfdac_cosim63, utils/gen_cosim63.py, rtz_pair.py, rtz_pair2.py, 2026-07-25)
- Random-walk pair chop: 2048 dwells x 8 periods over 9-code grid {6..58}, thermometer selection (nsch B-sources), R54 config. Deck reuses 54lut structure with PWL file schedule.
- PITFALL FOUND AND FIXED: dwell-differenced analysis (rtz_pair.py) is contaminated by the OUTPUT-FILTER LTI TAIL (rload*cbus ~ 1.3us ~ 8 periods; E1 dominated by 22.2mV/unit * dN linear term, and even the dwell "null" diagonal showed +/-12mV of history leakage).
- rtz_pair2.py does it right: joint fit of one-hot static levels + 16-tap FIR on code history + drift, THEN bin residual by (prev,curr). Null diagonal collapses to <=13uV. **Result: clean dynamic-nonlinearity matrix E_nl(a,b) up to +/-302uV (~150ppm of span, 20x the static INL), SE ~30uV, structure ~ h(a)-dominated (prev-code memory). Depth-2 binning shows same scale.** Saved cosim63_Enl.npy.

## Round 64 - DYNAMIC DPD, FIRST EMBED: NEGATIVE RESULT (bfdac_cosim64, utils/dpd_dyn.py, 2026-07-25)
- EF3 feedback extended to subtract L(prev,code) = code + err_static + E_dyn(prev,code), E_dyn bilinear-interpolated 9x9 -> 64x64 (diag forced 0). Gate at BIN=37: **HD2 -93.8 / HD3 -100.8, HD4 -101, HD5 -99.8 - WORSE than baseline (-96.6/-103.8, HD4/5 < -113). The correction ADDS structured error.**
- Diagnosis: TRANSFER GAP. The pair matrix was measured with THERMOMETER cell selection; the gate runs DEM ROTATION - for the same (N_prev,N) a different (much larger) set of cells toggles. E_nl(a,b) under thermometer != E under DEM. The h(a)-structure that dominates the matrix is not what the gate experiences.
- Next options: (1) toggle-aware correction - digital knows the exact DEM toggle set each period; model error = kt*n_toggle + rail terms, fit kt from a DEM-matched measurement; (2) DEM-matched pair chop (drive sel PWLs with dem_sort exactly as the gate does, measure E vs (N_prev,N) averaged over rotation states); (3) drop DEM in favor of pure LUT correction (statics are LUT-corrected anyway - DEM may be unnecessary and is itself a dynamic-error generator).

## Round 65 - NO-DEM GATES + SIGN DISCRIMINATOR (bfdac_cosim65/65b/65c, NODEM env in gen_cosim41, DYNSIGN in dpd_dyn, 2026-07-25)
- 65 (thermometer, static LUT only, BIN=37): **HD2 -96.6 / HD3 -103.7 - IDENTICAL to DEM baseline. The gate's dynamic distortion is INVARIANT to cell-selection pattern (DEM vs thermometer). DEM neither causes nor cures it; the error is a RAIL-LEVEL function of the code trajectory, not of which cells toggle.** (Also: DEM could be dropped in a LUT-corrected design with no HD penalty - architectural simplification option.)
- 65b (thermometer + E_nl DPD): -93.5/-100.8 + HD4/5 ~-101 - same degradation as R64. DEM transfer gap theory DEAD.
- 65c (E_nl DPD with FLIPPED sign): HD2 -92.5 - ALSO worse. Both signs degrade => injected HD2-band content is in QUADRATURE to the actual gate error. Not a sign bug - the (prev,curr) single-period model itself is wrong.
- E_nl robustness checked: FIR depth 24/32/48 -> offdiag 272-278uV, converged (not an FIR-truncation artifact). Pair error is real in the pair-chop plant.
- Tail analysis (offset-in-dwell binning, D=32): transition error rms by period offset = [85, 114, 82, 47, 28, 26, 30, 35]uV - **nonlinear transition error is SPREAD over ~4 periods with PEAK AT THE SECOND period (delayed response).** Superposition of these tails under per-period NS switching is NOT captured by a settled-state pair measurement -> the (prev,curr) LUT basis is fundamentally inadequate.
- **CONCLUSION: dynamic correction needs a memory-kernel (Volterra-class) model identified under GATE-LIKE excitation, not settled-state chop. We already have 8+ gate pavg records with known code streams - next round: Volterra-2 system ID directly on existing gate data (features: lagged code products, depth ~4), cross-validated across gates, then inverted in the NS loop. Zero new sims needed for the ID step.**

## Rounds 66-67 - VOLTERRA ID + EMBED: INVALIDATED, TWO TRAPS DOCUMENTED (utils/volterra_id.py, dpd_volt.py, bfdac_cosim67, 2026-07-25)
- R66: quadratic memory kernel (20 terms, lags 0..5) fit jointly on 10 gate records; leave-one-out "validated" HD2 within ~1dB/3deg on ALL gates. Looked spectacular. R67 embed: **HD2 -81.0 dBc - 15dB WORSE than baseline.**
- TRAP 1 (fatal): **every honest gate stream uses the same dither seed (rng 5) - leave-one-out cross-validation is NOT independent.** The kernel memorized dither/NS-noise product structure common to all records, not plant physics. BIN=37 gates (60/64/65*) have near-identical streams.
- TRAP 2 (scale/sign): cosim*_pavg.npy for gates is in DIFFERENT units than assumed (pavg-vs-code slope check: -0.0309 - matches rtz_inl gain, OK here) BUT code-domain evaluation of the fitted kernel on the raw NS stream predicts HD2 bins at -50dBc: the kernel MIXES out-of-band shaped noise into harmonic bins (quad products of full-scale NS noise). The real plant does not do this at that magnitude - more proof the fitted Q is noise-fit, not physics. (Also explains R64/65b/65c both-signs-worse: same class of contamination in E_nl embedding.)
- REQUIREMENTS FOR ANY FUTURE DYNAMIC ID (write these into the protocol): (1) independent dither seeds per record; (2) fit/validate only on in-band spectral projections where signal products dominate noise products; (3) before ANY embed, evaluate the kernel's code-domain action on the actual NS stream - its out-of-band-mixing must be below the target floor; (4) suspicously good validation = check excitation independence first.
- Baseline stands: gate 60 (static LUT, BIN=37) HD2 -96.6 / HD3 -103.8; R62 curve is the design signature.

## Rounds 68-71 - DYNAMIC DPD BREAKTHROUGH (utils/volterra_id2.py, dpd_volt.py, bfdac_cosim68a-d/69/70/71, 2026-07-25/26)
- R68 ID protocol (per R66/67 post-mortem): 4 new gates 68a-d with INDEPENDENT dither seeds 101-104 (DSEED env in dpd_study.py), BINs 37/37/17/11. Fit quadratic memory kernel (20 terms, lags 0..5) on IN-BAND complex spectral projections (bins 1..300, fund mainlobe excluded), nuisance (one-hot statics + FIR16 + drift) orthogonalized out. **Honest held-out validation: HD2 predicted within 0.1dB / ~1deg on ALL records including the 68a<->68b independent-seed pair.**
- R69 embed FAILED (-65.2 dBc): fitting on ORTHOGONALIZED features but applying the kernel RAW injects the nuisance-space content (628uV of static). TRAP 3 documented.
- R70 fix: decompose raw kernel action on nuisance basis (68a record), save stat[64]+firw[16]; embed subtracts them so only the true dynamic action (rms ~25uV) enters the EF3 feedback. **Gate 70 (seed 105): HD2 -114.9 (from -96.6, +18dB). HD3 -101.9 unchanged (odd-order needs cubic).**
- R71: cubic terms added (CUBIC=1, 19 terms lags 0..3, total 39). Held-out HD3 within 0.3dB/5deg. **Gate 71 (seed 105, BIN=37 = worst-case 13.875kHz 0dBFS): HD2 -118.7 / HD3 -120.0 / HD4-8 all <= -119. +22dB HD2, +16dB HD3 over static-LUT baseline. ALL harmonics below -118 dBc at the most hostile point in band.**
- Final digital chain: EF3 NS + TPDF dither + static LUT + 39-term Volterra-2/3 memory kernel (integer-friendly, ~78 mults/sample at 6.144MHz or LUT-able) in the quantizer feedback. Kernel files: cosim68c3_Q/pairs/stat/firw.npy.
- PENDING CONFIRMATION: (a) in-band tone gate (BIN=17, fresh seed) with c3 kernel; (b) amplitude robustness (-7dB drive); (c) longer-record floor check.

# NOISE/JITTER CAMPAIGN (opened 2026-07-26) - critical path to >128 dB
Distortion chapter closed at all-harmonics <= -118 dBc (R71). The other half of
the budget is untouched. Signal reference: fund ~0.87 Vpk diff (~0.62 Vrms);
128 dB SNR over 20 kHz requires total in-band noise <= ~245 nVrms.

## Budget lines to quantify (analytic first, then targeted cosim)
1. QUANTIZATION/DITHER FLOOR: EF3 + TPDF at 6.144 MHz, OSR 153. Code-domain,
   exact - compute with long records (no SPICE). NOTE: cosim runs EF3 (3rd
   order); RTL plan says 7th-order NS - reconcile order + stability first.
2. CLOCK JITTER: RTZ edges convert timing noise to charge error; error/sample
   ~ I_cell*n_active*sigma_t/T. Two flavors: (a) white jitter (broadband ->
   in-band 1/OSR share), (b) close-in phase noise of OCXO (folds directly).
   Experiment: perturb PWL edge times with given sigma_t (10ps/1ps/0.1ps rms),
   measure in-band floor vs sigma_t -> spec the OCXO + reclock flops.
3. REFERENCE/RAIL NOISE: cell current is set by rail + Rref; rail noise
   modulates ALL active cells coherently (scales with signal - multiplicative).
   Experiment: inject known noise PSD on the rail B-source, measure in-band.
4. THERMAL: cell resistors + rload + I/V stage. Analytic: 64 cells' noise
   contributions + output network. Verify R and topology from bom.md.
5. 1/f AND EX-NOISE of Si1555 cascodes: LTspice models may not include 1/f -
   check model cards; if absent, budget analytically from datasheet.
## Measurement-floor caveat
16k-period gates read to ~-112 dB; >128 dB verification needs either longer
gates (65k+), noise-free-difference methods (paired runs +/- injection), or
analytic extrapolation. Plan experiments as DIFFERENTIAL (with/without
injection) so the deterministic part cancels.
## Experiment queue
- N1: code-domain floor of the SHIPPING NS config (order, dither, 24-bit in)
- N2: jitter injection sweep (sigma_t = 10/1/0.1 ps white) on gate-71 deck
- N3: rail-noise injection sweep on gate-71 deck
- N4: analytic thermal/1-f budget spreadsheet from bom.md values

## Rounds 72-75 - VOLTERRA GENERALIZATION GAP: ROOT CAUSE + TWO FIXES (2026-07-26)
- Gate 72 (c3 kernel, BIN=17 in-band 6.375k, seed 106): HD2 -101.0 / HD3 -102.4
  dBc - 17dB worse than gate 71's BIN=37 result. Gate 73 (-7dB drive, BIN=37):
  all harmonics <= -105 (floor -75.4), HD3 -127.2 - amplitude robustness OK.
- ROOT CAUSE (TRAP 4): the ideal-popcount of the gate-72 stream shows HD2 -99.0
  dBc = the kernel INJECTS -99dBc of predistortion at BIN=17 where the plant's
  own HD2 is only ~-103 (held-out 68c). The stat/firw nuisance decomposition of
  the raw kernel action was computed ON RECORD 68a (BIN=37) ONLY - it is
  STREAM-DEPENDENT, and subtracting a BIN=37-derived split from a BIN=17 stream
  leaves residual STATIC nonlinearity content -> over-injection at any other
  tone frequency. Gate 71 worked because decomposition matched its own BIN.
- FIX A (R74): NUALL=1 in volterra_id2.py - decompose raw action on ALL FOUR
  records stacked (BINs 37/37/17/11) so the stat/firw split is BIN-independent.
  Kernel saved as cosim68c3j. Code-domain precheck at BIN=17 (seed 106):
  injected HD2 -103.5 (was -99.0, now matches plant), HD3 -115.0 (was -100.9),
  HD4 -120.6, HD5 -110.5. Gate 74 = SPICE confirmation, running.
- FIX B (R75): two new ID records with fresh independent seeds - 75a BIN=5
  (1.875k, seed 107), 75b BIN=27 (10.125k, seed 108), static-LUT streams via
  dpd_study.py. Will refit with EXTREC=1 NUALL=1 (kernel cosim68c3je) and
  gate at BIN=17 if Fix A alone is insufficient.
- TRAP 5 (tooling): first gate-74/75a/75b runs were INVALID - gen_cosim41.py
  still templated from bfdac_cosim39.cir (pre-R54 plant: no 100R gate-stoppers,
  C_q4 22n). Gate 74 read HD2 -83.9/HD3 -80.9 = the codes-23-28 oscillation +
  bias memory, not a DPD result. Generator fixed to template from
  bfdac_cosim72.cir (current plant); all three re-run.
- GATE 74 (Fix A, cosim68c3j kernel, BIN=17, seed 106, CORRECT plant):
  **HD2 -118.0 / HD3 -124.9, HD4-8 all <= -117.9 dBc.** Generalization gap
  CLOSED - matches gate 71's BIN=37 numbers. Root cause was the 68a-only
  nuisance decomposition, exactly as diagnosed.
- Records 75a/75b (static-LUT plants): 75a BIN=5 HD2 -115.1 / HD3 -123.7;
  75b BIN=27 HD2 -99.4 / HD3 -104.4 - plant distortion rises with frequency,
  consistent with the R62 signature.
- Fix B refit (6 records, BINs 5/11/17/27/37/37, EXTREC=1 NUALL=1 CUBIC=1,
  kernel cosim68c3je): held-out validation passes on EVERY record incl. the
  fresh-seed fresh-BIN pair (75a pred/meas -113.2/-113.2, 75b -99.0/-99.0).
  Kernel dyn-action out-of-band mixing -136.1 dBc. Gates 76 (BIN=23 UNSEEN
  frequency, seed 109) + 77 (BIN=37 worst case, seed 110) running as the final
  frequency-generalization cross-check.
- GATE 76 (cosim68c3je, BIN=23 = 8.625k UNSEEN in ID, seed 109): HD2 -117.1 /
  HD3 -120.7, HD4-8 <= -114.9 dBc. GATE 77 (BIN=37 worst case, seed 110):
  HD2 -122.1 / HD3 -116.4, all <= -110.7 (all harmonics OOB above 20k).
- **VERDICT: frequency generalization CONFIRMED. Gates 71/74/76/77 (BINs
  37/17/23/37, four different unseen seeds) all read every harmonic <= -116 dBc
  in-band-relevant, <= -110 dBc everywhere. Distortion campaign CLOSED.**
- SHIPPING KERNEL: cosim68c3je (39-term Volterra-2/3, lags 0-5 quad / 0-3
  cubic) + BIN-independent stat/firw split (NUALL). CALIBRATION IMPLICATION:
  per-board ID protocol MUST use records at >=4 tone frequencies spanning the
  band with independent dither seeds, and the nuisance decomposition MUST be
  computed jointly on all records (stream-dependent otherwise - TRAP 4).

## Noise campaign N1 - CODE-DOMAIN FLOOR (utils/noise_n1.py, 2026-07-26)
- RTL reconciliation: noise_shaper_7th_order was REPLACED in Round 30 by
  noise_shaper_ef3 (placeholder 7th-order FIR had NO DC zero). dac_dsp_core.sv
  ships EF3 + dem_sort = exactly the cosim config. No discrepancy.
- Shipping NS floor (EF3 + TPDF, 6.144MHz, 1M-sample records, Kaiser b38 +
  mainlobe excl, 4 seeds x 2 drives -1/-60dB): **147.5-148.0 dB re -1dBFS
  fund = 25-26 nVrms of the 245 nVrms (128dB) budget - ~1% of noise power.
  Drive-independent. N1 CLOSED: quantization is a negligible budget line.**
- Methodology note: first pass with rect window read one seed at 107dB - the
  R37 edge-leakage artifact of shaped OOB noise, NOT an idle tone (Kaiser
  reading for that seed: 147.3dB). Welch/hann equally unusable (98.5dB
  leakage-limited). Kaiser b38 is mandatory for all noise-floor readings.
- NEXT: N2 jitter injection sweep (sigma_t = 10/1/0.1ps white on RTZ edge
  times, gate-77 deck, differential with/without comparison), N3 rail-noise
  injection, N4 analytic thermal budget from bom.md.

## Noise campaign N2 - JITTER INJECTION (gen_cosim78.py / jitter_n2.py, 2026-07-26)
- Method: gate-77 deck with shared RTZ window sources pwa/pwb replaced by PWL
  trains, per-edge white gaussian jitter common to all 64 cells (reclock-flop
  model). DIFFERENTIAL readout pavg(78x)-pavg(77) cancels all deterministic
  content - not limited by the single-gate -81dBc sensing floor.
- Results (in-band 20Hz-20kHz, re -1dBFS fund 0.62Vrms, budget 245nVrms):
  sigma 10ps: 9.10 uVrms (96.7dB). sigma 1ps: 1.61 uVrms (111.7dB).
  sigma 0 CONTROL: 0.90 uVrms (116.7dB) = PWL-grid/solver reproducibility
  floor, NOT jitter. Floor-corrected slope: **~0.9-1.3 uVrms in-band per ps
  of white edge jitter** (matches analytic estimate ~6uV at 10ps within 4dB;
  in-band spectrum ~+5-8dB above flat-white share - signal-modulated).
- SPEC DERIVED: to hold the jitter line <= 100 nVrms of the 245 nV budget,
  **total white edge jitter (OCXO broadband + reclock flop additive) must be
  <= ~80-110 fs rms**. Achievable: clean reclock FF (NB7V52M/SY89871-class,
  30-100fs additive) + low-noise OCXO; close-in OCXO phase noise folds
  separately (not covered by this white-jitter sweep - N2b if needed).
- N2 CLOSED. Remaining: N3 rail-noise injection sweep, N4 analytic
  thermal/1-f budget from bom.md.

## Noise campaign N3 - RAIL/REFERENCE SENSITIVITY (gen_cosim79.py / rail_n3.py)
- Method: gate-77 deck, DC source replaced by B-source with 997Hz+9973Hz test
  tones; differential pavg(79x)-pavg(77); LS fit at tones + fund+/-tone
  intermod sidebands.
- vcc15 (+15V rail, 10mV tones): sens -121.6 to -134.6 dB V/V (all components
  < 9nV at diffout). **Cascode isolation makes the +15V rail a non-line: any
  ordinary LDO suffices.**
- V_ref (1.25V cell-current reference, 1mV tones): DOMINANT path. At 997Hz:
  direct 0.083 V/V + multiplicative sidebands at fund+/-f 0.113 V/V each
  (RSS 0.18 V/V); rolls -20dB/dec above the R_bias/C_q4 pole (100R+10uF,
  159Hz; tone2 9973Hz reads -41dB, confirming slope).
- Integrated: in-band rms = ~40 x e_n(vref) for flat e_n -> to keep the line
  <= 100nV of 245nV budget, e_n(vref) <= 2.5nV/rtHz - NOT practical for a
  reference+divider. FIX: raise C_q4 10uF -> 220uF (pole 159Hz -> 7.2Hz,
  x22 attenuation) -> spec relaxes to ~55nV/rtHz, trivially met
  (ADR445-class). Verification gate 79c (C_q4=220uF, same injection) running.
- Prior-art check (N4): rtz_noise.py 2026-07-12 already establishes thermal
  floor ~138dB (~78nVrms) - to be re-verified against current deck values
  (750R tails, 28R load) as N4.
- GATE 79c (C_q4 10uF -> 220uF, same V_ref injection): sidebands at 997Hz
  -44.7 dB V/V (was -18.9) = 25.8dB improvement, matching the 22x pole shift
  (159Hz -> 7.2Hz). **N3 CLOSED. Design action: C_q4 = 220uF; V_ref spec
  relaxes to e_n <= ~55nV/rtHz for a <=100nV budget line (ADR445-class +
  divider trivially meets it). CAVEAT: kernel cosim68c3je was identified on
  the 10uF plant - re-run ID records + verification gate after adopting
  220uF before any further distortion work.**

## Noise campaign N4 - ANALYTIC THERMAL BUDGET (utils/thermal_n4.py)
- Structural: p-side conducts k cells, m-side 64-k -> 64 tails ALWAYS active
  -> tail thermal line is code-independent.
- Line items at diffout (duty 6/8): tails 64x750R 0.91 nV/rtHz -> 129 nVrms
  (132.6dB); cascode shot (degeneration-suppressed, gmRt~22) 19 nVrms
  (149dB); 2x28R load proxy 136 nVrms (132.1dB). Core total 188 nVrms =
  129.3dB - passes 128dB but consumes 59% of budget power. NOTE: the 28R
  loads are a cosim proxy; real I/V virtual ground removes that line (I/V
  stage gets its own budget). Core-only (tails+shot): 130nV, 132.5dB.
- The old 'thermal floor ~138dB' note (2026-07-12) was optimistic vs the
  as-built 750R/0.75mA plan. Headroom exists via larger Rt (needs vee
  headroom) if the output-stage budget demands it.
- Open deck-idealized items to spec in hardware: 2x50mA padding sources
  (degenerated mirrors, Rdeg for <=50nV line), replica-FF current sources.
- **NOISE CAMPAIGN N1-N4 COMPLETE.** Budget stack (245nV total): thermal core
  130 + I/V stage TBD + jitter <=100 (80-110fs spec) + V_ref <=100 (220uF fix)
  + quantization 26 + rails ~0. RSS core+jitter+ref+quant = ~193nV -> ~2dB
  margin before the I/V line.

## Round 80 - PLANT FREEZE v80 + FINAL ID CAMPAIGN (utils/patch_v80.py, 2026-07-26)
- v80 plant = cosim72 + C_q4 220uF (N3 fix) + padding as degenerated BJT
  mirrors (Qpad/286R to vee15, ~50mA; replaces ideal I sources). Sanity gate
  80 (75b stream, BIN=27): HD2 -98.7 / HD3 -105.7 vs 75b -99.4/-104.4 -
  no new distortion signature. PLANT FROZEN.
- TRAP 6 (tooling, caught before any fitting): first 80a-f record streams
  were generated with dpd_study.py DEFAULT LUT (cosim40_inl.npy - pre-R54
  plant measurement). Injected ~-83 dBc of static HD3, identical across
  seeds/BINs (the deterministic tell). Verified by exact stream reproduction:
  the R68/75 records used cosim55lut_inl.npy (R55 averaged LUT). All six
  streams regenerated with cosim55lut_inl.npy; wasted batch killed.
  PROTOCOL NOTE: dpd_study.py LUT argument must ALWAYS be explicit; consider
  removing the stale default.
- ID records 80a-f: BINs 37/37/17/11/5/27, seeds 111-116, static-LUT streams
  (cosim55lut), v80 decks. Refit = volterra_id2.py V80=1 NUALL=1 CUBIC=1 ->
  kernel cosim80c3j; then dpd_volt embed + verification gates (unseen seeds,
  incl. unseen BIN).
- ID records 80a-f measured; frequency signature matches R62 (80a/b HD2 -95.7
  ~= 68a/b). Joint fit V80=1 NUALL=1 CUBIC=1: held-out HD2/HD3 within
  0.1-0.7dB on all six records.
- TRAP 7 (fit conditioning): RIDGE=0 fit passed held-out validation but the
  kernel carried 74.6mV of nuisance-space static content (2.2x the 68c3je
  kernel); embed gates 81/82 read a FLAT ~-98 dBc floor at ALL harmonics
  (R69-class signature - null-space directions of the in-band-projected fit
  are unconstrained and blow up). RIDGE sweep 0/1e4/1e6/1e8: held-out
  predictions IDENTICAL to 0.1dB, |static| 74.6mV -> 365uV, dyn rms 33 -> 14.6
  uV at 1e8. PROTOCOL: always fit with RIDGE=1e8-class shrinkage and check
  |static| of the raw-action decomposition BEFORE embedding (sane: <1mV).
  Kernel cosim80c3j re-saved with RIDGE=1e8 (max|q| 4.24 ucode/unit^2, was
  493). Gates 81 (BIN=23 unseen, seed 117) / 82 (BIN=37, seed 118) re-running.
- GATE 81 (cosim80c3j ridge kernel, BIN=23 UNSEEN in ID, seed 117): HD2 -113.0
  / HD3 -112.8, HD4-8 <= -112.4 dBc. GATE 82 (BIN=37 worst case, seed 118):
  HD2 -118.0 / HD3 -115.0, HD4-8 <= -115.4 dBc.
- **V80 CAMPAIGN CLOSED: frozen plant (C_q4 220uF + BJT padding mirrors) +
  kernel cosim80c3j certified - every harmonic <= -112 dBc incl. an unseen
  frequency and unseen seeds, matching the pre-freeze 76/77 numbers. The N3
  reference fix and hardware-realistic padding cost NOTHING in distortion.
  SHIPPING CONFIG: v80 plant + cosim55lut static LUT + cosim80c3j Volterra
  kernel (39 terms, RIDGE=1e8).**

## Round 83-85 - CAL TOLERANCE SIMS (Step 6.5, v80 plant, BIN=37 worst case, 2026-07-26)
- Gate 83 (kernel x1.1, seed 119): HD2 -118.5 / HD3 -119.7, HD4-8 <= -104.6.
- Gate 84 (kernel x0.9, seed 120): HD2 -114.9 / HD3 -118.3, HD4-8 <= -106.2.
- Gate 85 (.temp 45, 27C kernel+LUT, seed 121): HD2 -104.4 / HD3 -105.5,
  HD4-8 <= -111.4.
- **CONCLUSIONS: (1) kernel amplitude accuracy is NOT critical - +/-10%
  mis-scale costs <= 4 dB and every harmonic stays <= -104 (core <= -114);
  cal fit precision is not the limiter. (2) Temperature drift IS the
  limiter: +18C with a cold cal costs ~13-14 dB on HD2/HD3 (to -104/-105).
  Error amplitude ~linear in dT -> +/-5C window around cal temp holds
  ~-115 dBc class. RECAL SPEC (feeds 6.6): either regulate/settle chassis
  to within +/-5C of cal temp before critical listening, or store a
  temperature-indexed kernel (2-3 cal temps, interpolate). Factory cal at
  the enclosure's steady-state operating temp, not bench-cold.**

## Round 86-89 - STEP 6.6 DECISION EXPERIMENT: recal-at-temperature (2026-07-27)
- Q: does a FULL cal performed AT 45C restore 27C-class performance at 45C?
  (If yes -> temperature-indexed cal table is viable; if no -> thermal
  regulation is mandatory.) Staged cheapest-first.
- STAGE 1 (static): 54lut/54lut2 chop decks re-run with .temp 45 (~6 min
  each; utils/patch_temp.py adds .temp to any gen_cosim41 deck). 45C LUT
  (cosim86lut_inl.npy = avg of both runs): max|INL| 6.7ppm - same magnitude
  as 27C, but DECORRELATED from the 27C LUT (corr -0.17; delta 4.0ppm rms
  vs 1.4ppm run-to-run repeatability = real drift). Cell gain -32.71 vs
  -30.98 mV/cell = +5.6%/18C (~0.31%/C, Vbe/mirror tempco).
- STAGE 2 (gate 86, 45C plant, 45C LUT + 27C KERNEL, BIN=37 seed 122):
  HD2 -106.2 / HD3 -104.7 - only ~2dB better than gate 85 (stale
  everything). Static LUT refresh alone does NOT recover the loss ->
  the 13dB temp hit lives in the DYNAMICS (kernel shape, not just the
  5.6% gain scale - gates 83/84 proved +/-10% scale is benign).
- STAGE 3 (full 45C re-ID): records 86a-f (BINs 37/37/17/11/5/27, seeds
  123-128, streams from the 45C LUT, decks at .temp 45). Record signature:
  HD2 -92.7/-93.3 @BIN37 vs -95.7 at 27C (same shape, ~3dB hotter). Fit
  V86=1 NUALL=1 CUBIC=1 RIDGE=1e8 -> kernel cosim86c3j: held-out within
  0.5dB/0.9-16deg on all six, |static| 475uV (<1mV TRAP-7 gate), dyn
  action -138.7 dBc.
- VERIFICATION GATES (45C plant, 45C LUT + 45C kernel):
  Gate 87 (BIN=23 UNSEEN, seed 129): HD2 -112.2 / HD3 -117.1, HD4-8 <= -113.5.
  Gate 88 (BIN=37 worst, seed 130):  HD2 -115.4 / HD3 -119.9, HD4-8 <= -109.1.
  == 27C reference class (gates 81/82: -113.0/-112.8, -118.0/-115.0).
- **STEP 6.6 ANSWER: recal AT temperature FULLY restores performance.
  Temperature-indexed cal table (static LUT + Volterra kernel per temp
  point) is VIABLE; thermal regulation is NOT required. Note the static
  LUT decorrelates across 18C, so the table must index BOTH the LUT and
  the kernel - a kernel-only table would leave the ~4ppm static residue.**
- dT LADDER (BIN=37 worst case, 45C cal = cosim86lut + cosim86c3j):
    dT=0    (gate 88, .temp 45):   HD2 -115.4 / HD3 -119.9
    dT=4.5  (gate 90, .temp 40.5): HD2 -112.8 / HD3 -114.4
    dT=9    (gate 89, .temp 36):   HD2 -105.4 / HD3 -115.3
    dT=18   (gate 85, 27C cal):    HD2 -104.4 / HD3 -105.5
  HD2 loss is NOT linear in dT (R85 conjecture wrong): ~2.6dB at 4.5C,
  ~10dB at 9C, then saturates. +/-4.5C of a cal point holds the -112 dBc
  class; +/-9C does not (-105).
- **STEP 6.6 DECISION (final): temperature-indexed cal table, NO thermal
  regulation. Table = static LUT + Volterra kernel per cal temp, spacing
  <= 9C (worst-case distance 4.5C -> every harmonic <= ~-112 dBc),
  nearest-point selection (interpolation not needed at that spacing and
  untested). Requires a temp sensor AT THE CELL ARRAY (board NTC; FPGA
  die temp is a poor proxy for the discrete cells). Expected cell-temp
  range ~25-50C -> 3 factory cal points (e.g. 27/36/45C) = 3x(64-entry
  LUT + 39-term kernel + stat[64] + FIR[16]) per channel in QSPI -
  trivially small. Recal advisory flag if sensor leaves table range.
  Feeds Step 6.3 (kernel register file gains a temp index) and Step 6.1
  SOP (cal repeated at 3 chamber temps after burn-in).**

## Step 5.1 — FIRST FULL VU13P SYNTHESIS (2026-07-27)
- TOOLING TRAP: two Vivado installs on this machine. 2025.2.1 CANNOT check
  out the license for xcvu13p ("feature Synthesis ... not found") even with
  XILINXD_LICENSE_FILE set and the FlexLM server up. **2026.1
  (C:\AMDDesignTools\2026.1, source Vivado\settings64.bat) is the correct
  version** — license (CORE tier, INCREMENTs versioned 2027.06, expires
  27-jun-2027, served 2100@localhost) checks out fine there. Always:
  cmd /c "call C:\AMDDesignTools\2026.1\Vivado\settings64.bat && vivado ...".
- RUN 1 (synth51.log): SYNTH_OK, 0 errors, 0 critical synth warnings, ~40 min.
  UTILIZATION (NUM_MACS=1024): LUT 148.8k (8.6%), FF 195.4k (5.7%),
  DSP 2062 (16.8%), URAM 512 (40%), BRAM 5.5 (0.2%), IOB 177/702.
  TIMING: all intra-clock setup MET — dsp_clk 280.87 MHz WNS +0.31 ns
  (762k endpoints). FAILURES were all inter-clock CDC paths
  (clk_200m<->dsp_clk, i2s_bclk->dsp_clk, cell_clk->ff_clk hold).
- ROOT CAUSE: create_generated_clock with -master_clock/-divide_by but no
  -add is REJECTED (CRITICAL WARNING 12-672) -> dsp_clk/cell_clk kept their
  auto-derived names (dsp_clk_unbuf/cell_clk_unbuf) and every
  set_false_path referencing dsp_clk/cell_clk silently matched nothing.
  FIX: name-only rename idiom on the MMCM output pins:
  create_generated_clock -name dsp_clk [get_pins u_clk_gen/u_mmcm/CLKOUT0].
  Also fixed BITSTREAM.CONFIG.CONFIGRATE 33 -> 31.9 (not a valid US+ enum).
- RUN 2 (synth51b.log): SYNTH_OK, 0 errors, 0 critical warnings. All CDC
  exceptions now apply. **SETUP TIMING MET: WNS +0.309 ns, TNS 0** (763k
  endpoints, dsp_clk @ 280.87 MHz). Utilization unchanged (LUT 8.57%).
  Remaining hold: (a) intra-dsp_clk THS -24.3k ns over 355k endpoints at
  WHS -0.095 — normal pre-route estimate, the router fixes hold; (b)
  cell_clk->ff_clk WHS -0.785 on the 128 cascode output ports vs the
  virtual ff_clk (output window -max 2.5 / -min -1.5). RTZ tolerates
  +/-5 ns pulse position, so the -min value is reviewable; defer to
  Step 5.2 implementation where clock insertion delays are real.
- STEP 5.1 DONE. Next: Step 5.2 (implementation run: opt/place/route on
  the synth_top.dcp checkpoint), still pending MIG IP for DDR4.
