# ==============================================================================
# ARTIX ULTRASCALE+ MASTER CONSTRAINTS  (xcau25p-ffvb676-2-i)
# ==============================================================================
#
# Migrated from A7-200T 2026-05-12. Key family changes:
#   - LVDS_25 -> LVDS  (US+ HP banks max at 1.8V; 2.5V LVDS removed)
#   - LVCMOS33 -> LVCMOS18 placeholder (US+ HP banks max at 1.8V;
#                                       on-board level shifters required for
#                                       any 3.3V audio inputs/outputs unless
#                                       the dev board exposes HRIO/HD banks
#                                       capable of 3.3V)
#   - All PACKAGE_PIN assignments removed -- to be added from the eventual
#     dev board (Opal Kelly XEM8320 / Alinx ACAU25-HX) reference XDC.
#
# All timing constraints below are family-agnostic and unchanged from
# the A7 baseline.
# ==============================================================================

# 0. FPGA CONFIGURATION
#    CFGBVS / CONFIG_VOLTAGE depend on the dev board's CFGBVS pin tie. Most
#    AU+ dev boards tie CFGBVS to GND with VCCO_0 = 1.8V. Adjust once the
#    target board is selected.
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# 1. SINGLE-ENDED I/O  (CLOCKS, SPI, I2S, RELAYS)
#
#    NOTE: AU+ HP banks do not support 3.3V signaling. The audio interfaces
#    (I2S, SPI) and relay drives are conventionally 3.3V CMOS, so the carrier
#    board MUST include level shifters (e.g., TXS0108E) between the FPGA's
#    1.8V I/O and any 3.3V audio peripherals. The constraints below assume
#    1.8V at the FPGA pin -- update if the target board exposes HRIO banks
#    that natively support 3.3V.
set_property IOSTANDARD LVCMOS18 [get_ports clk_49m]
set_property IOSTANDARD LVCMOS18 [get_ports clk_45m]

# OCXO Clock Input Requirements:
#   - Use MRCC (Multi-Region Clock Capable) pins on Bank 64 or 65
#   - Terminate with 50Ω to ground at FPGA pin (receiver side termination)
#   - Keep traces short (<2 inches) and impedance controlled (50Ω)
#   - Isolate from DDR4 and high-speed digital signals
#   - Use separate clean 3.3V supply for OCXOs (LC filtered)
# Recommended OCXOs:
#   - Crystek CCHD-957-45.1584 (or 49.152)
#   - NDK NZ2520SDA-45.1584MHz (or 49.152MHz)
#   - ECS-2523MVQ-450BN-TR (low profile 2.5mm)

# XEM8320 DDR4 Reference Clock (100 MHz):
#   - On-board fixed oscillator, no user termination needed
#   - Dedicated clock input pin (check XEM8320 schematic for exact pin)
#   - 1.8V LVCMOS signaling
#   - Connects to XCAU25P HMC dedicated clock input

set_property IOSTANDARD LVCMOS18 [get_ports clk_ref_ext]

# External Reference Input (10 MHz or Word Clock):
#   - Accepts 10 MHz (AES11 studio standard) or 44.1k/48k word clock
#   - Terminate with 50Ω to ground at input connector
#   - AC-couple to jitter attenuator (blocks DC offset)
#   - Route through jitter attenuator (LMK61E2, Si5345, AK4137)
#   - Jitter attenuator output feeds FPGA 49.152 MHz input
#
# Jitter Attenuator Options:
#   - TI LMK61E2 (programmable, I2C/SPI, <100 fs jitter)
#   - Silicon Labs Si5345 (multi-output, any-rate synthesis)
#   - AKM AK4137 (audio-specific, SRC + jitter attenuation)

set_property IOSTANDARD LVCMOS18 [get_ports spi_*]
set_property SLEW SLOW [get_ports spi_miso]

set_property IOSTANDARD LVCMOS18 [get_ports i2s_*]
set_property IOSTANDARD LVCMOS18 [get_ports ext_rst_n]

set_property IOSTANDARD LVCMOS18 [get_ports relay_*]
set_property DRIVE 12 [get_ports relay_*]
set_property SLEW SLOW [get_ports relay_*]

# 2. DIFFERENTIAL I/O  (LVDS EGRESS TO MAX10 RECEIVER TUBS)
#    UltraScale+ uses the unified "LVDS" IOSTANDARD on HP banks at 1.8V VCCO.
set_property IOSTANDARD LVDS [get_ports lvds_*]

# 3. BASE CLOCKS
# Ultra-low jitter OCXO inputs for audiophile-grade clocking:
#   45.1584 MHz = 1024 × 44.1 kHz (44.1k family: 44.1k, 88.2k, 176.4k, 352.8k)
#   49.152 MHz  = 1024 × 48 kHz   (48k family: 48k, 96k, 192k, 384k, 768k)
#
# Generated clocks:
#   DSP Clock: 357.46 MHz (983.04 MHz VCO / 2.75)
#   LVDS Clock: 196.608 MHz = 768 kHz × 256 (exact frame sync)
#
# Jitter budget: OCXO <1 ps RMS → MMCM adds ~100-200 ps → Total <250 ps RMS
# This preserves the ultra-low jitter for high-end audio performance.
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m]

# DDR4 Reference Clock (XEM8320 on-board 100 MHz differential LVDS)
# create_clock is owned by the MIG IP XDC (names it ddr4_refclkp).
# Do not duplicate it here — Vivado warns and the second overrides the first.
set_property IOSTANDARD LVDS [get_ports ddr4_refclkp]
set_property IOSTANDARD LVDS [get_ports ddr4_refclkn]
set_property DIFF_TERM FALSE [get_ports ddr4_refclkp]
create_clock -period 100.000 -name clk_ref_ext [get_ports clk_ref_ext]
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# Clock Domain Exclusivity (BUFGMUX isolation)
# 45.1584 and 49.152 MHz are physically mutually exclusive
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]

# External reference is asynchronous to internal OCXOs
# The jitter attenuator provides isolation; FPGA sees cleaned 49.152 MHz
set_clock_groups -asynchronous -group [get_clocks clk_ref_ext] -group [get_clocks clk_49m] -group [get_clocks clk_45m]

# DDR4 100 MHz reference is asynchronous to all audio clocks
# The MIG handles CDC internally; only AXI4 interface crosses domains
set_clock_groups -asynchronous -group [get_clocks ddr4_refclkp] -group [get_clocks clk_49m] -group [get_clocks clk_45m] -group [get_clocks clk_ref_ext]

# MIG-generated clocks (ui_clk = mmcm_clkout0, plus phy clocks) are asynchronous
# to all DSP/audio clocks. The load_start_r -> load_start_sync_ui CDC path is a
# properly designed 2FF synchronizer and must not be timed across domains.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks ddr4_refclkp] \
    -group [get_clocks -include_generated_clocks clk_49m] \
    -group [get_clocks -include_generated_clocks clk_45m] \
    -group [get_clocks clk_ref_ext] \
    -group [get_clocks i2s_bclk] \
    -group [get_clocks spi_sclk]

# Explicitly sever the orphaned MMCM generated clocks
set_clock_groups -physically_exclusive -group [get_clocks dsp_clk_unbuf] -group [get_clocks dsp_clk_unbuf_1]

# Explicitly sever the SPI Control Plane from ALL generated DSP clocks (both directions)
set_false_path -from [get_clocks clk_49m] -to [get_clocks *dsp_clk*]
set_false_path -from [get_clocks clk_45m] -to [get_clocks *dsp_clk*]
set_false_path -from [get_clocks *dsp_clk*] -to [get_clocks clk_49m]
set_false_path -from [get_clocks *dsp_clk*] -to [get_clocks clk_45m]

# Sledgehammer: Kill the BUFGMUX Ghost Paths using wildcards
set_false_path -from [get_clocks *dsp_clk_unbuf*] -to [get_clocks *dsp_clk_unbuf_1*]
set_false_path -from [get_clocks *dsp_clk_unbuf_1*] -to [get_clocks *dsp_clk_unbuf*]
set_false_path -from [get_clocks *lvds_clk_unbuf*] -to [get_clocks *lvds_clk_unbuf_1*]
set_false_path -from [get_clocks *lvds_clk_unbuf_1*] -to [get_clocks *lvds_clk_unbuf*]

# Asynchronous Boundary between 357 MHz DSP and 196.6 MHz LVDS Egress
set_clock_groups -asynchronous -group [get_clocks *dsp_clk*] -group [get_clocks *lvds_clk*]

# 4. ASYNC FIFO CDC SEVERING
# Cell names match async_fifo.sv: w_gray/r_gray are the source Gray-code pointer regs;
# wq1_r_gray/rq1_w_gray are the first synchronizer stage flip-flops.
set_false_path -from [get_cells -hierarchical *w_gray_reg*] -to [get_cells -hierarchical *rq1_w_gray_reg*]
set_false_path -from [get_cells -hierarchical *r_gray_reg*] -to [get_cells -hierarchical *wq1_r_gray_reg*]

# 5. LVDS TIMING BOUNDARIES
#
#   Source-synchronous output with CENTER-ALIGNED forwarded clock.
#   The bclk ODDR in lvds_serial_tx.sv is wired with D1=0, D2=1 so the
#   forwarded clock's rising edge falls at the CENTER of each data bit
#   window (half a bit_clk period after data transitions). The MAX10
#   receiver samples in the middle of the eye with ~2 ns of margin on
#   both sides at 196 MHz bit rate.
#
#   The -invert flag tells Vivado the generated clock is inverted
#   relative to its source so static-timing analysis correctly accounts
#   for the half-period phase relationship.
create_generated_clock -name fwd_lvds_clk -source [get_pins u_clk_gen/u_mmcm/CLKOUT1] -multiply_by 1 -invert [get_ports lvds_bclk_p]

# Output delays model the MAX10 LVDS receiver Tsu/Th plus assumed
# board-matched routing (data and clock traces equal length on PCB).
# Conservative MAX10 LVDS SDR receiver: Tsu ~ 0.3 ns, Th ~ 0.2 ns.
# These values are easily met by the center-aligned eye.
set_output_delay -clock fwd_lvds_clk -max  0.300 [get_ports lvds_data_*_p]
set_output_delay -clock fwd_lvds_clk -min -0.200 [get_ports lvds_data_*_p]
set_output_delay -clock fwd_lvds_clk -max  0.300 [get_ports lvds_sync_p]
set_output_delay -clock fwd_lvds_clk -min -0.200 [get_ports lvds_sync_p]

# Mask the spurious DDR falling-edge launch arc on data/sync ODDRs.
#
#   The data/sync ODDRs in lvds_serial_tx.sv are wired with D1 = D2 =
#   <same fabric signal>, so the Q output cannot change on the falling
#   edge of bit_clk -- it only transitions when the upstream fabric
#   register changes, which happens at the rising edge. Vivado's STA
#   doesn't know D1 == D2 (they are independent input pins) and
#   therefore reports a phantom hold path from lvds_clk_unbuf's
#   falling edge to these output ports. This false_path tells the
#   tool to ignore that physically impossible arc. The bclk port is
#   intentionally excluded: u_oddr_bclk has D1 != D2 (it is a real
#   half-rate clock forwarder) and its falling-edge arc IS real.
set_false_path -fall_from [get_clocks lvds_clk_unbuf] -to [get_ports {lvds_data_l_p lvds_data_r_p lvds_sync_p}]

# 6. IOB PACKING & PACKAGE PINS
#
#   With explicit ODDR primitives driving the LVDS outputs (see
#   lvds_serial_tx.sv), the output flops are already inside the OLOGIC /
#   IOB by construction. The IOB TRUE constraints below are redundant
#   and were observed to send opt_design into a multi-hour loop when
#   combined with the explicit ODDRs (Vivado iterating on whether to
#   also pull the upstream fabric flops into the IOB). Disabled here.
#
# set_property IOB TRUE [get_ports lvds_data_*_p]
# set_property IOB TRUE [get_ports lvds_sync_p]
# set_property IOB TRUE [get_ports lvds_data_l_p]
# set_property IOB TRUE [get_ports lvds_data_r_p]
# set_property IOB TRUE [get_ports lvds_sync_p]

# ==============================================================================
# 7. MULTICYCLE PATHS (The 128-Cycle Oversampled DSP Domain)
# ==============================================================================
# Filter for ONLY sequential elements (flip-flops) inside the slow logic blocks

# Multicycle paths for noise shaper / DEM / dither — reserved for when those
# modules are implemented. Commented out until cells exist in the netlist.
#set_multicycle_path -setup 128 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
#set_multicycle_path -hold 127 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
#set_multicycle_path -setup 128 -from [get_cells *stable_audio_64b_reg*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
#set_multicycle_path -hold 127 -from [get_cells *stable_audio_64b_reg*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
#set_multicycle_path -setup 128 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]
#set_multicycle_path -hold 127 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]


# ==============================================================================
# 8. EXCLUSIVE CLOCK DOMAINS (BUFGMUX Isolation)
# ==============================================================================
# The 45.1584 MHz and 49.152 MHz families are physically mutually exclusive.
# This prevents Vivado from analyzing impossible inter-clock paths.
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_45m] -group [get_clocks -include_generated_clocks clk_49m]

# ==============================================================================
# 8b. PBLOCK — Co-locate Coefficient Logic with FIR
# ==============================================================================
# The coef_waddr path from u_coef_subsys (X26Y35) to u_stereo_fir (X84Y149)
# has 3.35ns of pure routing delay — crossing the entire chip height.
# Constraining both modules to the same clock region eliminates this route.
# Expected improvement: ~2ns slack gain (0.397ns -> ~2.4ns)
create_pblock pblock_coef_fir
add_cells_to_pblock [get_pblocks pblock_coef_fir] [get_cells -hierarchical u_coef_subsys]
add_cells_to_pblock [get_pblocks pblock_coef_fir] [get_cells -hierarchical u_dsp_core/u_stereo_fir]
resize_pblock [get_pblocks pblock_coef_fir] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y2}

# 9. PACKAGE PIN ASSIGNMENTS
#
#    TODO: Populate once the target dev board is finalized.
#    Pin assignments depend on which board hosts the AU25P:
#      - Opal Kelly XEM8320 -- SYZYGY connector pin map per OK reference XDC
#      - Alinx ACAU25-HX    -- carrier-specific pin map per Alinx ref design
#
#    Required ports needing PACKAGE_PIN:
#      lvds_bclk_p / lvds_bclk_n          (differential pair, MRCC pins ideal)
#      lvds_data_l_p / lvds_data_l_n      (differential pair, same bank as bclk)
#      lvds_data_r_p / lvds_data_r_n      (differential pair, same bank as bclk)
#      lvds_sync_p / lvds_sync_n          (differential pair, same bank as bclk)
#      clk_45m, clk_49m                   (single-ended, MRCC inputs - audio-locked)
#      i2s_bclk, i2s_lrclk, i2s_data      (single-ended, async clock domain)
#      spi_sclk, spi_cs_n, spi_mosi, spi_miso
#      ext_rst_n
#      relay_gain_6v, relay_audio_out


# ==============================================================================
# 8. DDR4 MEMORY INTERFACE (XEM8320 - XCAU25P HMC - Bank 64)
# ==============================================================================
# Official pin assignments from Opal Kelly xem8320.xdc (pins.opalkelly.com)
# IOSTANDARDs per UltraScale+ DDR4 requirements (PG150)

# DDR4 Reference Clock - LVDS pair (100 MHz, pins AD20/AE20)
set_property PACKAGE_PIN AD20 [get_ports {ddr4_refclkp}]
set_property PACKAGE_PIN AE20 [get_ports {ddr4_refclkn}]

# Control/Command - SSTL12_DCI
set_property PACKAGE_PIN AF22 [get_ports "ddr4_cs_n[0]"]
set_property PACKAGE_PIN AA20 [get_ports "ddr4_cke[0]"]
set_property PACKAGE_PIN AB20 [get_ports "ddr4_odt[0]"]
set_property PACKAGE_PIN AE26 [get_ports "ddr4_reset_n"]
set_property PACKAGE_PIN Y18  [get_ports "ddr4_act_n"]
set_property PACKAGE_PIN AB19 [get_ports "ddr4_bg[0]"]
set_property PACKAGE_PIN AC18 [get_ports "ddr4_ba[0]"]
set_property PACKAGE_PIN AF18 [get_ports "ddr4_ba[1]"]

# Address - SSTL12_DCI
set_property PACKAGE_PIN AD18 [get_ports "ddr4_addr[0]"]
set_property PACKAGE_PIN AE17 [get_ports "ddr4_addr[1]"]
set_property PACKAGE_PIN AB17 [get_ports "ddr4_addr[2]"]
set_property PACKAGE_PIN AE18 [get_ports "ddr4_addr[3]"]
set_property PACKAGE_PIN AD19 [get_ports "ddr4_addr[4]"]
set_property PACKAGE_PIN AF17 [get_ports "ddr4_addr[5]"]
set_property PACKAGE_PIN Y17  [get_ports "ddr4_addr[6]"]
set_property PACKAGE_PIN AE16 [get_ports "ddr4_addr[7]"]
set_property PACKAGE_PIN AA17 [get_ports "ddr4_addr[8]"]
set_property PACKAGE_PIN AC17 [get_ports "ddr4_addr[9]"]
set_property PACKAGE_PIN AC19 [get_ports "ddr4_addr[10]"]
set_property PACKAGE_PIN AC16 [get_ports "ddr4_addr[11]"]
set_property PACKAGE_PIN AF20 [get_ports "ddr4_addr[12]"]
set_property PACKAGE_PIN AD16 [get_ports "ddr4_addr[13]"]
set_property PACKAGE_PIN AA19 [get_ports "ddr4_addr[14]"]
set_property PACKAGE_PIN AF19 [get_ports "ddr4_addr[15]"]
set_property PACKAGE_PIN AA18 [get_ports "ddr4_addr[16]"]

# Clock differential pair - DIFF_SSTL12_DCI
set_property PACKAGE_PIN Y20  [get_ports "ddr4_ck_t[0]"]
set_property PACKAGE_PIN Y21  [get_ports "ddr4_ck_c[0]"]

# Data strobes - POD12_DCI differential
set_property PACKAGE_PIN AC26 [get_ports "ddr4_dqs_t[0]"]
set_property PACKAGE_PIN AA22 [get_ports "ddr4_dqs_t[1]"]
set_property PACKAGE_PIN AD26 [get_ports "ddr4_dqs_c[0]"]
set_property PACKAGE_PIN AB22 [get_ports "ddr4_dqs_c[1]"]

# Data mask - POD12_DCI
set_property PACKAGE_PIN AE25 [get_ports "ddr4_dm_dbi_n[0]"]
set_property PACKAGE_PIN AE22 [get_ports "ddr4_dm_dbi_n[1]"]

# Data - POD12_DCI
set_property PACKAGE_PIN AF24 [get_ports "ddr4_dq[0]"]
set_property PACKAGE_PIN AB25 [get_ports "ddr4_dq[1]"]
set_property PACKAGE_PIN AB26 [get_ports "ddr4_dq[2]"]
set_property PACKAGE_PIN AC24 [get_ports "ddr4_dq[3]"]
set_property PACKAGE_PIN AF25 [get_ports "ddr4_dq[4]"]
set_property PACKAGE_PIN AB24 [get_ports "ddr4_dq[5]"]
set_property PACKAGE_PIN AD24 [get_ports "ddr4_dq[6]"]
set_property PACKAGE_PIN AD25 [get_ports "ddr4_dq[7]"]
set_property PACKAGE_PIN AB21 [get_ports "ddr4_dq[8]"]
set_property PACKAGE_PIN AE21 [get_ports "ddr4_dq[9]"]
set_property PACKAGE_PIN AE23 [get_ports "ddr4_dq[10]"]
set_property PACKAGE_PIN AD23 [get_ports "ddr4_dq[11]"]
set_property PACKAGE_PIN AC23 [get_ports "ddr4_dq[12]"]
set_property PACKAGE_PIN AD21 [get_ports "ddr4_dq[13]"]
set_property PACKAGE_PIN AC22 [get_ports "ddr4_dq[14]"]
set_property PACKAGE_PIN AC21 [get_ports "ddr4_dq[15]"]

# IOSTANDARDs
set_property IOSTANDARD LVDS        [get_ports "ddr4_refclkp"]
set_property IOSTANDARD LVDS        [get_ports "ddr4_refclkn"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_cs_n[*]"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_cke[*]"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_odt[*]"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_act_n"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_bg[*]"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_ba[*]"]
set_property IOSTANDARD SSTL12_DCI  [get_ports "ddr4_addr[*]"]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports "ddr4_ck_t[*]"]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports "ddr4_ck_c[*]"]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports "ddr4_dqs_t[*]"]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports "ddr4_dqs_c[*]"]
set_property IOSTANDARD POD12_DCI   [get_ports "ddr4_dm_dbi_n[*]"]
set_property IOSTANDARD POD12_DCI   [get_ports "ddr4_dq[*]"]
set_property IOSTANDARD LVCMOS12    [get_ports "ddr4_reset_n"]

