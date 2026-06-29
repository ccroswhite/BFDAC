set_property SRC_FILE_INFO {cfile:C:/Users/ccros/BFDAC-Xilinx/BFDAC-Xilinx.srcs/constrs_1/imports/Xilinx/artix_dac_master.xdc rfile:../../BFDAC-Xilinx.srcs/constrs_1/imports/Xilinx/artix_dac_master.xdc id:1 rxprname:$PSRCDIR/constrs_1/imports/Xilinx/artix_dac_master.xdc} [current_design]
set_property src_info {type:XDC file:1 line:1 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:2 export:INPUT save:INPUT read:READ} [current_design]
# ARTIX ULTRASCALE+ MASTER CONSTRAINTS  (xcau25p-ffvb676-2-i)
set_property src_info {type:XDC file:1 line:3 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:4 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:5 export:INPUT save:INPUT read:READ} [current_design]
# Migrated from A7-200T 2026-05-12. Key family changes:
set_property src_info {type:XDC file:1 line:6 export:INPUT save:INPUT read:READ} [current_design]
#   - LVDS_25 -> LVDS  (US+ HP banks max at 1.8V; 2.5V LVDS removed)
set_property src_info {type:XDC file:1 line:7 export:INPUT save:INPUT read:READ} [current_design]
#   - LVCMOS33 -> LVCMOS18 placeholder (US+ HP banks max at 1.8V;
set_property src_info {type:XDC file:1 line:8 export:INPUT save:INPUT read:READ} [current_design]
#                                       on-board level shifters required for
set_property src_info {type:XDC file:1 line:9 export:INPUT save:INPUT read:READ} [current_design]
#                                       any 3.3V audio inputs/outputs unless
set_property src_info {type:XDC file:1 line:10 export:INPUT save:INPUT read:READ} [current_design]
#                                       the dev board exposes HRIO/HD banks
set_property src_info {type:XDC file:1 line:11 export:INPUT save:INPUT read:READ} [current_design]
#                                       capable of 3.3V)
set_property src_info {type:XDC file:1 line:12 export:INPUT save:INPUT read:READ} [current_design]
#   - All PACKAGE_PIN assignments removed -- to be added from the eventual
set_property src_info {type:XDC file:1 line:13 export:INPUT save:INPUT read:READ} [current_design]
#     dev board (Opal Kelly XEM8320 / Alinx ACAU25-HX) reference XDC.
set_property src_info {type:XDC file:1 line:14 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:15 export:INPUT save:INPUT read:READ} [current_design]
# All timing constraints below are family-agnostic and unchanged from
set_property src_info {type:XDC file:1 line:16 export:INPUT save:INPUT read:READ} [current_design]
# the A7 baseline.
set_property src_info {type:XDC file:1 line:17 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:18 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:19 export:INPUT save:INPUT read:READ} [current_design]
# 0. FPGA CONFIGURATION
set_property src_info {type:XDC file:1 line:20 export:INPUT save:INPUT read:READ} [current_design]
#    CFGBVS / CONFIG_VOLTAGE depend on the dev board's CFGBVS pin tie. Most
set_property src_info {type:XDC file:1 line:21 export:INPUT save:INPUT read:READ} [current_design]
#    AU+ dev boards tie CFGBVS to GND with VCCO_0 = 1.8V. Adjust once the
set_property src_info {type:XDC file:1 line:22 export:INPUT save:INPUT read:READ} [current_design]
#    target board is selected.
set_property src_info {type:XDC file:1 line:23 export:INPUT save:INPUT read:READ} [current_design]
set_property CFGBVS GND [current_design]
set_property src_info {type:XDC file:1 line:24 export:INPUT save:INPUT read:READ} [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property src_info {type:XDC file:1 line:25 export:INPUT save:INPUT read:READ} [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property src_info {type:XDC file:1 line:26 export:INPUT save:INPUT read:READ} [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property src_info {type:XDC file:1 line:27 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:28 export:INPUT save:INPUT read:READ} [current_design]
# 1. SINGLE-ENDED I/O  (CLOCKS, SPI, I2S, RELAYS)
set_property src_info {type:XDC file:1 line:29 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:30 export:INPUT save:INPUT read:READ} [current_design]
#    NOTE: AU+ HP banks do not support 3.3V signaling. The audio interfaces
set_property src_info {type:XDC file:1 line:31 export:INPUT save:INPUT read:READ} [current_design]
#    (I2S, SPI) and relay drives are conventionally 3.3V CMOS, so the carrier
set_property src_info {type:XDC file:1 line:32 export:INPUT save:INPUT read:READ} [current_design]
#    board MUST include level shifters (e.g., TXS0108E) between the FPGA's
set_property src_info {type:XDC file:1 line:33 export:INPUT save:INPUT read:READ} [current_design]
#    1.8V I/O and any 3.3V audio peripherals. The constraints below assume
set_property src_info {type:XDC file:1 line:34 export:INPUT save:INPUT read:READ} [current_design]
#    1.8V at the FPGA pin -- update if the target board exposes HRIO banks
set_property src_info {type:XDC file:1 line:35 export:INPUT save:INPUT read:READ} [current_design]
#    that natively support 3.3V.
set_property src_info {type:XDC file:1 line:36 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports clk_49m]
set_property src_info {type:XDC file:1 line:37 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports clk_45m]
set_property src_info {type:XDC file:1 line:38 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:39 export:INPUT save:INPUT read:READ} [current_design]
# OCXO Clock Input Requirements:
set_property src_info {type:XDC file:1 line:40 export:INPUT save:INPUT read:READ} [current_design]
#   - Use MRCC (Multi-Region Clock Capable) pins on Bank 64 or 65
set_property src_info {type:XDC file:1 line:41 export:INPUT save:INPUT read:READ} [current_design]
#   - Terminate with 50Ω to ground at FPGA pin (receiver side termination)
set_property src_info {type:XDC file:1 line:42 export:INPUT save:INPUT read:READ} [current_design]
#   - Keep traces short (<2 inches) and impedance controlled (50Ω)
set_property src_info {type:XDC file:1 line:43 export:INPUT save:INPUT read:READ} [current_design]
#   - Isolate from DDR4 and high-speed digital signals
set_property src_info {type:XDC file:1 line:44 export:INPUT save:INPUT read:READ} [current_design]
#   - Use separate clean 3.3V supply for OCXOs (LC filtered)
set_property src_info {type:XDC file:1 line:45 export:INPUT save:INPUT read:READ} [current_design]
# Recommended OCXOs:
set_property src_info {type:XDC file:1 line:46 export:INPUT save:INPUT read:READ} [current_design]
#   - Crystek CCHD-957-45.1584 (or 49.152)
set_property src_info {type:XDC file:1 line:47 export:INPUT save:INPUT read:READ} [current_design]
#   - NDK NZ2520SDA-45.1584MHz (or 49.152MHz)
set_property src_info {type:XDC file:1 line:48 export:INPUT save:INPUT read:READ} [current_design]
#   - ECS-2523MVQ-450BN-TR (low profile 2.5mm)
set_property src_info {type:XDC file:1 line:49 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:50 export:INPUT save:INPUT read:READ} [current_design]
# XEM8320 DDR4 Reference Clock (100 MHz):
set_property src_info {type:XDC file:1 line:51 export:INPUT save:INPUT read:READ} [current_design]
#   - On-board fixed oscillator, no user termination needed
set_property src_info {type:XDC file:1 line:52 export:INPUT save:INPUT read:READ} [current_design]
#   - Dedicated clock input pin (check XEM8320 schematic for exact pin)
set_property src_info {type:XDC file:1 line:53 export:INPUT save:INPUT read:READ} [current_design]
#   - 1.8V LVCMOS signaling
set_property src_info {type:XDC file:1 line:54 export:INPUT save:INPUT read:READ} [current_design]
#   - Connects to XCAU25P HMC dedicated clock input
set_property src_info {type:XDC file:1 line:55 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:56 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports clk_ref_ext]
set_property src_info {type:XDC file:1 line:57 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:58 export:INPUT save:INPUT read:READ} [current_design]
# External Reference Input (10 MHz or Word Clock):
set_property src_info {type:XDC file:1 line:59 export:INPUT save:INPUT read:READ} [current_design]
#   - Accepts 10 MHz (AES11 studio standard) or 44.1k/48k word clock
set_property src_info {type:XDC file:1 line:60 export:INPUT save:INPUT read:READ} [current_design]
#   - Terminate with 50Ω to ground at input connector
set_property src_info {type:XDC file:1 line:61 export:INPUT save:INPUT read:READ} [current_design]
#   - AC-couple to jitter attenuator (blocks DC offset)
set_property src_info {type:XDC file:1 line:62 export:INPUT save:INPUT read:READ} [current_design]
#   - Route through jitter attenuator (LMK61E2, Si5345, AK4137)
set_property src_info {type:XDC file:1 line:63 export:INPUT save:INPUT read:READ} [current_design]
#   - Jitter attenuator output feeds FPGA 49.152 MHz input
set_property src_info {type:XDC file:1 line:64 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:65 export:INPUT save:INPUT read:READ} [current_design]
# Jitter Attenuator Options:
set_property src_info {type:XDC file:1 line:66 export:INPUT save:INPUT read:READ} [current_design]
#   - TI LMK61E2 (programmable, I2C/SPI, <100 fs jitter)
set_property src_info {type:XDC file:1 line:67 export:INPUT save:INPUT read:READ} [current_design]
#   - Silicon Labs Si5345 (multi-output, any-rate synthesis)
set_property src_info {type:XDC file:1 line:68 export:INPUT save:INPUT read:READ} [current_design]
#   - AKM AK4137 (audio-specific, SRC + jitter attenuation)
set_property src_info {type:XDC file:1 line:69 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:70 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports spi_*]
set_property src_info {type:XDC file:1 line:71 export:INPUT save:INPUT read:READ} [current_design]
set_property SLEW SLOW [get_ports spi_miso]
set_property src_info {type:XDC file:1 line:72 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:73 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports i2s_*]
set_property src_info {type:XDC file:1 line:74 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports ext_rst_n]
set_property src_info {type:XDC file:1 line:75 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:76 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS18 [get_ports relay_*]
set_property src_info {type:XDC file:1 line:77 export:INPUT save:INPUT read:READ} [current_design]
set_property DRIVE 12 [get_ports relay_*]
set_property src_info {type:XDC file:1 line:78 export:INPUT save:INPUT read:READ} [current_design]
set_property SLEW SLOW [get_ports relay_*]
set_property src_info {type:XDC file:1 line:79 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:80 export:INPUT save:INPUT read:READ} [current_design]
# 2. DIFFERENTIAL I/O  (LVDS EGRESS TO MAX10 RECEIVER TUBS)
set_property src_info {type:XDC file:1 line:81 export:INPUT save:INPUT read:READ} [current_design]
#    UltraScale+ uses the unified "LVDS" IOSTANDARD on HP banks at 1.8V VCCO.
set_property src_info {type:XDC file:1 line:82 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVDS [get_ports lvds_*]
set_property src_info {type:XDC file:1 line:83 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:84 export:INPUT save:INPUT read:READ} [current_design]
# 3. BASE CLOCKS
set_property src_info {type:XDC file:1 line:85 export:INPUT save:INPUT read:READ} [current_design]
# Ultra-low jitter OCXO inputs for audiophile-grade clocking:
set_property src_info {type:XDC file:1 line:86 export:INPUT save:INPUT read:READ} [current_design]
#   45.1584 MHz = 1024 × 44.1 kHz (44.1k family: 44.1k, 88.2k, 176.4k, 352.8k)
set_property src_info {type:XDC file:1 line:87 export:INPUT save:INPUT read:READ} [current_design]
#   49.152 MHz  = 1024 × 48 kHz   (48k family: 48k, 96k, 192k, 384k, 768k)
set_property src_info {type:XDC file:1 line:88 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:89 export:INPUT save:INPUT read:READ} [current_design]
# Generated clocks:
set_property src_info {type:XDC file:1 line:90 export:INPUT save:INPUT read:READ} [current_design]
#   DSP Clock: 357.46 MHz (983.04 MHz VCO / 2.75)
set_property src_info {type:XDC file:1 line:91 export:INPUT save:INPUT read:READ} [current_design]
#   LVDS Clock: 196.608 MHz = 768 kHz × 256 (exact frame sync)
set_property src_info {type:XDC file:1 line:92 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:93 export:INPUT save:INPUT read:READ} [current_design]
# Jitter budget: OCXO <1 ps RMS → MMCM adds ~100-200 ps → Total <250 ps RMS
set_property src_info {type:XDC file:1 line:94 export:INPUT save:INPUT read:READ} [current_design]
# This preserves the ultra-low jitter for high-end audio performance.
set_property src_info {type:XDC file:1 line:95 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m]
set_property src_info {type:XDC file:1 line:96 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m]
set_property src_info {type:XDC file:1 line:97 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:98 export:INPUT save:INPUT read:READ} [current_design]
# DDR4 Reference Clock (XEM8320 on-board 100 MHz differential LVDS)
set_property src_info {type:XDC file:1 line:99 export:INPUT save:INPUT read:READ} [current_design]
# create_clock is owned by the MIG IP XDC (names it ddr4_refclkp).
set_property src_info {type:XDC file:1 line:100 export:INPUT save:INPUT read:READ} [current_design]
# Do not duplicate it here — Vivado warns and the second overrides the first.
set_property src_info {type:XDC file:1 line:103 export:INPUT save:INPUT read:READ} [current_design]
set_property DIFF_TERM_ADV TERM_NONE [get_ports ddr4_refclkp]
set_property src_info {type:XDC file:1 line:104 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 100.000 -name clk_ref_ext [get_ports clk_ref_ext]
set_property src_info {type:XDC file:1 line:105 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]
set_property src_info {type:XDC file:1 line:106 export:INPUT save:INPUT read:READ} [current_design]
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]
set_property src_info {type:XDC file:1 line:107 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:108 export:INPUT save:INPUT read:READ} [current_design]
# Clock Domain Exclusivity (BUFGMUX isolation)
set_property src_info {type:XDC file:1 line:109 export:INPUT save:INPUT read:READ} [current_design]
# 45.1584 and 49.152 MHz are physically mutually exclusive
set_property src_info {type:XDC file:1 line:110 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]
set_property src_info {type:XDC file:1 line:111 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:112 export:INPUT save:INPUT read:READ} [current_design]
# External reference is asynchronous to internal OCXOs
set_property src_info {type:XDC file:1 line:113 export:INPUT save:INPUT read:READ} [current_design]
# The jitter attenuator provides isolation; FPGA sees cleaned 49.152 MHz
set_property src_info {type:XDC file:1 line:114 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -asynchronous -group [get_clocks clk_ref_ext] -group [get_clocks clk_49m] -group [get_clocks clk_45m]
set_property src_info {type:XDC file:1 line:115 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:116 export:INPUT save:INPUT read:READ} [current_design]
# DDR4 100 MHz reference is asynchronous to all audio clocks
set_property src_info {type:XDC file:1 line:117 export:INPUT save:INPUT read:READ} [current_design]
# The MIG handles CDC internally; only AXI4 interface crosses domains
set_property src_info {type:XDC file:1 line:118 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -asynchronous -group [get_clocks ddr4_refclkp] -group [get_clocks clk_49m] -group [get_clocks clk_45m] -group [get_clocks clk_ref_ext]
set_property src_info {type:XDC file:1 line:119 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:120 export:INPUT save:INPUT read:READ} [current_design]
# MIG-generated clocks (ui_clk = mmcm_clkout0, plus phy clocks) are asynchronous
set_property src_info {type:XDC file:1 line:121 export:INPUT save:INPUT read:READ} [current_design]
# to all DSP/audio clocks. The load_start_r -> load_start_sync_ui CDC path is a
set_property src_info {type:XDC file:1 line:122 export:INPUT save:INPUT read:READ} [current_design]
# properly designed 2FF synchronizer and must not be timed across domains.
set_property src_info {type:XDC file:1 line:123 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks ddr4_refclkp] -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m] -group [get_clocks clk_ref_ext] -group [get_clocks i2s_bclk] -group [get_clocks spi_sclk]
set_property src_info {type:XDC file:1 line:130 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:131 export:INPUT save:INPUT read:READ} [current_design]
# Explicitly sever the orphaned MMCM generated clocks
set_property src_info {type:XDC file:1 line:132 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -physically_exclusive -group [get_clocks dsp_clk_unbuf] -group [get_clocks dsp_clk_unbuf_1]
set_property src_info {type:XDC file:1 line:133 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:134 export:INPUT save:INPUT read:READ} [current_design]
# Explicitly sever the SPI Control Plane from ALL generated DSP clocks (both directions)
set_property src_info {type:XDC file:1 line:135 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks clk_49m] -to [get_clocks *dsp_clk*]
set_property src_info {type:XDC file:1 line:136 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks clk_45m] -to [get_clocks *dsp_clk*]
set_property src_info {type:XDC file:1 line:137 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *dsp_clk*] -to [get_clocks clk_49m]
set_property src_info {type:XDC file:1 line:138 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *dsp_clk*] -to [get_clocks clk_45m]
set_property src_info {type:XDC file:1 line:139 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:140 export:INPUT save:INPUT read:READ} [current_design]
# Sledgehammer: Kill the BUFGMUX Ghost Paths using wildcards
set_property src_info {type:XDC file:1 line:141 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *dsp_clk_unbuf*] -to [get_clocks *dsp_clk_unbuf_1*]
set_property src_info {type:XDC file:1 line:142 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *dsp_clk_unbuf_1*] -to [get_clocks *dsp_clk_unbuf*]
set_property src_info {type:XDC file:1 line:143 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *lvds_clk_unbuf*] -to [get_clocks *lvds_clk_unbuf_1*]
set_property src_info {type:XDC file:1 line:144 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_clocks *lvds_clk_unbuf_1*] -to [get_clocks *lvds_clk_unbuf*]
set_property src_info {type:XDC file:1 line:145 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:146 export:INPUT save:INPUT read:READ} [current_design]
# Asynchronous Boundary between 357 MHz DSP and 196.6 MHz LVDS Egress
set_property src_info {type:XDC file:1 line:147 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -asynchronous -group [get_clocks *dsp_clk*] -group [get_clocks *lvds_clk*]
set_property src_info {type:XDC file:1 line:148 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:149 export:INPUT save:INPUT read:READ} [current_design]
# 4. ASYNC FIFO CDC SEVERING
set_property src_info {type:XDC file:1 line:150 export:INPUT save:INPUT read:READ} [current_design]
# Cell names match async_fifo.sv: w_gray/r_gray are the source Gray-code pointer regs;
set_property src_info {type:XDC file:1 line:151 export:INPUT save:INPUT read:READ} [current_design]
# wq1_r_gray/rq1_w_gray are the first synchronizer stage flip-flops.
set_property src_info {type:XDC file:1 line:152 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_cells -hierarchical *w_gray_reg*] -to [get_cells -hierarchical *rq1_w_gray_reg*]
set_property src_info {type:XDC file:1 line:153 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -from [get_cells -hierarchical *r_gray_reg*] -to [get_cells -hierarchical *wq1_r_gray_reg*]
set_property src_info {type:XDC file:1 line:154 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:155 export:INPUT save:INPUT read:READ} [current_design]
# 5. LVDS TIMING BOUNDARIES
set_property src_info {type:XDC file:1 line:156 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:157 export:INPUT save:INPUT read:READ} [current_design]
#   Source-synchronous output with CENTER-ALIGNED forwarded clock.
set_property src_info {type:XDC file:1 line:158 export:INPUT save:INPUT read:READ} [current_design]
#   The bclk ODDR in lvds_serial_tx.sv is wired with D1=0, D2=1 so the
set_property src_info {type:XDC file:1 line:159 export:INPUT save:INPUT read:READ} [current_design]
#   forwarded clock's rising edge falls at the CENTER of each data bit
set_property src_info {type:XDC file:1 line:160 export:INPUT save:INPUT read:READ} [current_design]
#   window (half a bit_clk period after data transitions). The MAX10
set_property src_info {type:XDC file:1 line:161 export:INPUT save:INPUT read:READ} [current_design]
#   receiver samples in the middle of the eye with ~2 ns of margin on
set_property src_info {type:XDC file:1 line:162 export:INPUT save:INPUT read:READ} [current_design]
#   both sides at 196 MHz bit rate.
set_property src_info {type:XDC file:1 line:163 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:164 export:INPUT save:INPUT read:READ} [current_design]
#   The -invert flag tells Vivado the generated clock is inverted
set_property src_info {type:XDC file:1 line:165 export:INPUT save:INPUT read:READ} [current_design]
#   relative to its source so static-timing analysis correctly accounts
set_property src_info {type:XDC file:1 line:166 export:INPUT save:INPUT read:READ} [current_design]
#   for the half-period phase relationship.
set_property src_info {type:XDC file:1 line:167 export:INPUT save:INPUT read:READ} [current_design]
create_generated_clock -name fwd_lvds_clk -source [get_pins u_clk_gen/u_mmcm/CLKOUT1] -multiply_by 1 -invert [get_ports lvds_bclk_p]
set_property src_info {type:XDC file:1 line:168 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:169 export:INPUT save:INPUT read:READ} [current_design]
# Output delays model the MAX10 LVDS receiver Tsu/Th plus assumed
set_property src_info {type:XDC file:1 line:170 export:INPUT save:INPUT read:READ} [current_design]
# board-matched routing (data and clock traces equal length on PCB).
set_property src_info {type:XDC file:1 line:171 export:INPUT save:INPUT read:READ} [current_design]
# Conservative MAX10 LVDS SDR receiver: Tsu ~ 0.3 ns, Th ~ 0.2 ns.
set_property src_info {type:XDC file:1 line:172 export:INPUT save:INPUT read:READ} [current_design]
# These values are easily met by the center-aligned eye.
set_property src_info {type:XDC file:1 line:173 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock fwd_lvds_clk -max 0.300 [get_ports lvds_data_*_p]
set_property src_info {type:XDC file:1 line:174 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock fwd_lvds_clk -min -0.200 [get_ports lvds_data_*_p]
set_property src_info {type:XDC file:1 line:175 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock fwd_lvds_clk -max 0.300 [get_ports lvds_sync_p]
set_property src_info {type:XDC file:1 line:176 export:INPUT save:INPUT read:READ} [current_design]
set_output_delay -clock fwd_lvds_clk -min -0.200 [get_ports lvds_sync_p]
set_property src_info {type:XDC file:1 line:177 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:178 export:INPUT save:INPUT read:READ} [current_design]
# Mask the spurious DDR falling-edge launch arc on data/sync ODDRs.
set_property src_info {type:XDC file:1 line:179 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:180 export:INPUT save:INPUT read:READ} [current_design]
#   The data/sync ODDRs in lvds_serial_tx.sv are wired with D1 = D2 =
set_property src_info {type:XDC file:1 line:181 export:INPUT save:INPUT read:READ} [current_design]
#   <same fabric signal>, so the Q output cannot change on the falling
set_property src_info {type:XDC file:1 line:182 export:INPUT save:INPUT read:READ} [current_design]
#   edge of bit_clk -- it only transitions when the upstream fabric
set_property src_info {type:XDC file:1 line:183 export:INPUT save:INPUT read:READ} [current_design]
#   register changes, which happens at the rising edge. Vivado's STA
set_property src_info {type:XDC file:1 line:184 export:INPUT save:INPUT read:READ} [current_design]
#   doesn't know D1 == D2 (they are independent input pins) and
set_property src_info {type:XDC file:1 line:185 export:INPUT save:INPUT read:READ} [current_design]
#   therefore reports a phantom hold path from lvds_clk_unbuf's
set_property src_info {type:XDC file:1 line:186 export:INPUT save:INPUT read:READ} [current_design]
#   falling edge to these output ports. This false_path tells the
set_property src_info {type:XDC file:1 line:187 export:INPUT save:INPUT read:READ} [current_design]
#   tool to ignore that physically impossible arc. The bclk port is
set_property src_info {type:XDC file:1 line:188 export:INPUT save:INPUT read:READ} [current_design]
#   intentionally excluded: u_oddr_bclk has D1 != D2 (it is a real
set_property src_info {type:XDC file:1 line:189 export:INPUT save:INPUT read:READ} [current_design]
#   half-rate clock forwarder) and its falling-edge arc IS real.
set_property src_info {type:XDC file:1 line:190 export:INPUT save:INPUT read:READ} [current_design]
set_false_path -fall_from [get_clocks lvds_clk_unbuf] -to [get_ports {lvds_data_l_p lvds_data_r_p lvds_sync_p}]
set_property src_info {type:XDC file:1 line:191 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:192 export:INPUT save:INPUT read:READ} [current_design]
# 6. IOB PACKING & PACKAGE PINS
set_property src_info {type:XDC file:1 line:193 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:194 export:INPUT save:INPUT read:READ} [current_design]
#   With explicit ODDR primitives driving the LVDS outputs (see
set_property src_info {type:XDC file:1 line:195 export:INPUT save:INPUT read:READ} [current_design]
#   lvds_serial_tx.sv), the output flops are already inside the OLOGIC /
set_property src_info {type:XDC file:1 line:196 export:INPUT save:INPUT read:READ} [current_design]
#   IOB by construction. The IOB TRUE constraints below are redundant
set_property src_info {type:XDC file:1 line:197 export:INPUT save:INPUT read:READ} [current_design]
#   and were observed to send opt_design into a multi-hour loop when
set_property src_info {type:XDC file:1 line:198 export:INPUT save:INPUT read:READ} [current_design]
#   combined with the explicit ODDRs (Vivado iterating on whether to
set_property src_info {type:XDC file:1 line:199 export:INPUT save:INPUT read:READ} [current_design]
#   also pull the upstream fabric flops into the IOB). Disabled here.
set_property src_info {type:XDC file:1 line:200 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:201 export:INPUT save:INPUT read:READ} [current_design]
# set_property IOB TRUE [get_ports lvds_data_*_p]
set_property src_info {type:XDC file:1 line:202 export:INPUT save:INPUT read:READ} [current_design]
# set_property IOB TRUE [get_ports lvds_sync_p]
set_property src_info {type:XDC file:1 line:203 export:INPUT save:INPUT read:READ} [current_design]
# set_property IOB TRUE [get_ports lvds_data_l_p]
set_property src_info {type:XDC file:1 line:204 export:INPUT save:INPUT read:READ} [current_design]
# set_property IOB TRUE [get_ports lvds_data_r_p]
set_property src_info {type:XDC file:1 line:205 export:INPUT save:INPUT read:READ} [current_design]
# set_property IOB TRUE [get_ports lvds_sync_p]
set_property src_info {type:XDC file:1 line:206 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:207 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:208 export:INPUT save:INPUT read:READ} [current_design]
# 7. MULTICYCLE PATHS (The 128-Cycle Oversampled DSP Domain)
set_property src_info {type:XDC file:1 line:209 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:210 export:INPUT save:INPUT read:READ} [current_design]
# Filter for ONLY sequential elements (flip-flops) inside the slow logic blocks
set_property src_info {type:XDC file:1 line:211 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:212 export:INPUT save:INPUT read:READ} [current_design]
# Multicycle paths for noise shaper / DEM / dither — reserved for when those
set_property src_info {type:XDC file:1 line:213 export:INPUT save:INPUT read:READ} [current_design]
# modules are implemented. Commented out until cells exist in the netlist.
set_property src_info {type:XDC file:1 line:214 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -setup 128 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
set_property src_info {type:XDC file:1 line:215 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -hold 127 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
set_property src_info {type:XDC file:1 line:216 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -setup 128 -from [get_cells *stable_audio_64b_reg*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
set_property src_info {type:XDC file:1 line:217 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -hold 127 -from [get_cells *stable_audio_64b_reg*] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp .*(u_noise_shaper|u_dem_mapper|u_dither).*.*]
set_property src_info {type:XDC file:1 line:218 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -setup 128 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]
set_property src_info {type:XDC file:1 line:219 export:INPUT save:INPUT read:READ} [current_design]
#set_multicycle_path -hold 127 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]
set_property src_info {type:XDC file:1 line:220 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:221 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:222 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:223 export:INPUT save:INPUT read:READ} [current_design]
# 8. EXCLUSIVE CLOCK DOMAINS (BUFGMUX Isolation)
set_property src_info {type:XDC file:1 line:224 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:225 export:INPUT save:INPUT read:READ} [current_design]
# The 45.1584 MHz and 49.152 MHz families are physically mutually exclusive.
set_property src_info {type:XDC file:1 line:226 export:INPUT save:INPUT read:READ} [current_design]
# This prevents Vivado from analyzing impossible inter-clock paths.
set_property src_info {type:XDC file:1 line:227 export:INPUT save:INPUT read:READ} [current_design]
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_45m] -group [get_clocks -include_generated_clocks clk_49m]
set_property src_info {type:XDC file:1 line:228 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:229 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:230 export:INPUT save:INPUT read:READ} [current_design]
# 8b. PBLOCK — Co-locate Coefficient Logic with FIR
set_property src_info {type:XDC file:1 line:231 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:232 export:INPUT save:INPUT read:READ} [current_design]
# The coef_waddr path from u_coef_subsys (X26Y35) to u_stereo_fir (X84Y149)
set_property src_info {type:XDC file:1 line:233 export:INPUT save:INPUT read:READ} [current_design]
# has 3.35ns of pure routing delay — crossing the entire chip height.
set_property src_info {type:XDC file:1 line:234 export:INPUT save:INPUT read:READ} [current_design]
# Constraining both modules to the same clock region eliminates this route.
set_property src_info {type:XDC file:1 line:235 export:INPUT save:INPUT read:READ} [current_design]
# Expected improvement: ~2ns slack gain (0.397ns -> ~2.4ns)
set_property src_info {type:XDC file:1 line:236 export:INPUT save:INPUT read:READ} [current_design]
create_pblock pblock_coef_fir
add_cells_to_pblock [get_pblocks pblock_coef_fir] [get_cells -quiet [list u_coef_subsys u_dsp_core/u_stereo_fir]]
resize_pblock [get_pblocks pblock_coef_fir] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y2}
set_property src_info {type:XDC file:1 line:240 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:241 export:INPUT save:INPUT read:READ} [current_design]
# 9. PACKAGE PIN ASSIGNMENTS
set_property src_info {type:XDC file:1 line:242 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:243 export:INPUT save:INPUT read:READ} [current_design]
#    TODO: Populate once the target dev board is finalized.
set_property src_info {type:XDC file:1 line:244 export:INPUT save:INPUT read:READ} [current_design]
#    Pin assignments depend on which board hosts the AU25P:
set_property src_info {type:XDC file:1 line:245 export:INPUT save:INPUT read:READ} [current_design]
#      - Opal Kelly XEM8320 -- SYZYGY connector pin map per OK reference XDC
set_property src_info {type:XDC file:1 line:246 export:INPUT save:INPUT read:READ} [current_design]
#      - Alinx ACAU25-HX    -- carrier-specific pin map per Alinx ref design
set_property src_info {type:XDC file:1 line:247 export:INPUT save:INPUT read:READ} [current_design]
#
set_property src_info {type:XDC file:1 line:248 export:INPUT save:INPUT read:READ} [current_design]
#    Required ports needing PACKAGE_PIN:
set_property src_info {type:XDC file:1 line:249 export:INPUT save:INPUT read:READ} [current_design]
#      lvds_bclk_p / lvds_bclk_n          (differential pair, MRCC pins ideal)
set_property src_info {type:XDC file:1 line:250 export:INPUT save:INPUT read:READ} [current_design]
#      lvds_data_l_p / lvds_data_l_n      (differential pair, same bank as bclk)
set_property src_info {type:XDC file:1 line:251 export:INPUT save:INPUT read:READ} [current_design]
#      lvds_data_r_p / lvds_data_r_n      (differential pair, same bank as bclk)
set_property src_info {type:XDC file:1 line:252 export:INPUT save:INPUT read:READ} [current_design]
#      lvds_sync_p / lvds_sync_n          (differential pair, same bank as bclk)
set_property src_info {type:XDC file:1 line:253 export:INPUT save:INPUT read:READ} [current_design]
#      clk_45m, clk_49m                   (single-ended, MRCC inputs - audio-locked)
set_property src_info {type:XDC file:1 line:254 export:INPUT save:INPUT read:READ} [current_design]
#      i2s_bclk, i2s_lrclk, i2s_data      (single-ended, async clock domain)
set_property src_info {type:XDC file:1 line:255 export:INPUT save:INPUT read:READ} [current_design]
#      spi_sclk, spi_cs_n, spi_mosi, spi_miso
set_property src_info {type:XDC file:1 line:256 export:INPUT save:INPUT read:READ} [current_design]
#      ext_rst_n
set_property src_info {type:XDC file:1 line:257 export:INPUT save:INPUT read:READ} [current_design]
#      relay_gain_6v, relay_audio_out
set_property src_info {type:XDC file:1 line:258 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:259 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:260 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:261 export:INPUT save:INPUT read:READ} [current_design]
# 8. DDR4 MEMORY INTERFACE (XEM8320 - XCAU25P HMC - Bank 64)
set_property src_info {type:XDC file:1 line:262 export:INPUT save:INPUT read:READ} [current_design]
# ==============================================================================
set_property src_info {type:XDC file:1 line:263 export:INPUT save:INPUT read:READ} [current_design]
# Official pin assignments from Opal Kelly xem8320.xdc (pins.opalkelly.com)
set_property src_info {type:XDC file:1 line:264 export:INPUT save:INPUT read:READ} [current_design]
# IOSTANDARDs per UltraScale+ DDR4 requirements (PG150)
set_property src_info {type:XDC file:1 line:265 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:266 export:INPUT save:INPUT read:READ} [current_design]
# DDR4 Reference Clock - LVDS pair (100 MHz, pins AD20/AE20)
set_property src_info {type:XDC file:1 line:268 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD20 [get_ports ddr4_refclkp]
set_property src_info {type:XDC file:1 line:268 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE20 [get_ports ddr4_refclkn]
set_property src_info {type:XDC file:1 line:269 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:270 export:INPUT save:INPUT read:READ} [current_design]
# Control/Command - SSTL12_DCI
set_property src_info {type:XDC file:1 line:271 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF22 [get_ports {ddr4_cs_n[0]}]
set_property src_info {type:XDC file:1 line:272 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AA20 [get_ports {ddr4_cke[0]}]
set_property src_info {type:XDC file:1 line:273 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB20 [get_ports {ddr4_odt[0]}]
set_property src_info {type:XDC file:1 line:274 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE26 [get_ports ddr4_reset_n]
set_property src_info {type:XDC file:1 line:275 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN Y18 [get_ports ddr4_act_n]
set_property src_info {type:XDC file:1 line:276 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB19 [get_ports {ddr4_bg[0]}]
set_property src_info {type:XDC file:1 line:277 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC18 [get_ports {ddr4_ba[0]}]
set_property src_info {type:XDC file:1 line:278 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF18 [get_ports {ddr4_ba[1]}]
set_property src_info {type:XDC file:1 line:279 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:280 export:INPUT save:INPUT read:READ} [current_design]
# Address - SSTL12_DCI
set_property src_info {type:XDC file:1 line:281 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD18 [get_ports {ddr4_addr[0]}]
set_property src_info {type:XDC file:1 line:282 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE17 [get_ports {ddr4_addr[1]}]
set_property src_info {type:XDC file:1 line:283 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB17 [get_ports {ddr4_addr[2]}]
set_property src_info {type:XDC file:1 line:284 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE18 [get_ports {ddr4_addr[3]}]
set_property src_info {type:XDC file:1 line:285 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD19 [get_ports {ddr4_addr[4]}]
set_property src_info {type:XDC file:1 line:286 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF17 [get_ports {ddr4_addr[5]}]
set_property src_info {type:XDC file:1 line:287 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN Y17 [get_ports {ddr4_addr[6]}]
set_property src_info {type:XDC file:1 line:288 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE16 [get_ports {ddr4_addr[7]}]
set_property src_info {type:XDC file:1 line:289 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AA17 [get_ports {ddr4_addr[8]}]
set_property src_info {type:XDC file:1 line:290 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC17 [get_ports {ddr4_addr[9]}]
set_property src_info {type:XDC file:1 line:291 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC19 [get_ports {ddr4_addr[10]}]
set_property src_info {type:XDC file:1 line:292 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC16 [get_ports {ddr4_addr[11]}]
set_property src_info {type:XDC file:1 line:293 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF20 [get_ports {ddr4_addr[12]}]
set_property src_info {type:XDC file:1 line:294 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD16 [get_ports {ddr4_addr[13]}]
set_property src_info {type:XDC file:1 line:295 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AA19 [get_ports {ddr4_addr[14]}]
set_property src_info {type:XDC file:1 line:296 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF19 [get_ports {ddr4_addr[15]}]
set_property src_info {type:XDC file:1 line:297 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AA18 [get_ports {ddr4_addr[16]}]
set_property src_info {type:XDC file:1 line:298 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:299 export:INPUT save:INPUT read:READ} [current_design]
# Clock differential pair - DIFF_SSTL12_DCI
set_property src_info {type:XDC file:1 line:301 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN Y20 [get_ports {ddr4_ck_t[0]}]
set_property src_info {type:XDC file:1 line:301 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN Y21 [get_ports {ddr4_ck_c[0]}]
set_property src_info {type:XDC file:1 line:302 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:303 export:INPUT save:INPUT read:READ} [current_design]
# Data strobes - POD12_DCI differential
set_property src_info {type:XDC file:1 line:306 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC26 [get_ports {ddr4_dqs_t[0]}]
set_property src_info {type:XDC file:1 line:306 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD26 [get_ports {ddr4_dqs_c[0]}]
set_property src_info {type:XDC file:1 line:307 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AA22 [get_ports {ddr4_dqs_t[1]}]
set_property src_info {type:XDC file:1 line:307 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB22 [get_ports {ddr4_dqs_c[1]}]
set_property src_info {type:XDC file:1 line:308 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:309 export:INPUT save:INPUT read:READ} [current_design]
# Data mask - POD12_DCI
set_property src_info {type:XDC file:1 line:310 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE25 [get_ports {ddr4_dm_dbi_n[0]}]
set_property src_info {type:XDC file:1 line:311 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE22 [get_ports {ddr4_dm_dbi_n[1]}]
set_property src_info {type:XDC file:1 line:312 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:313 export:INPUT save:INPUT read:READ} [current_design]
# Data - POD12_DCI
set_property src_info {type:XDC file:1 line:314 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF24 [get_ports {ddr4_dq[0]}]
set_property src_info {type:XDC file:1 line:315 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB25 [get_ports {ddr4_dq[1]}]
set_property src_info {type:XDC file:1 line:316 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB26 [get_ports {ddr4_dq[2]}]
set_property src_info {type:XDC file:1 line:317 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC24 [get_ports {ddr4_dq[3]}]
set_property src_info {type:XDC file:1 line:318 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AF25 [get_ports {ddr4_dq[4]}]
set_property src_info {type:XDC file:1 line:319 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB24 [get_ports {ddr4_dq[5]}]
set_property src_info {type:XDC file:1 line:320 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD24 [get_ports {ddr4_dq[6]}]
set_property src_info {type:XDC file:1 line:321 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD25 [get_ports {ddr4_dq[7]}]
set_property src_info {type:XDC file:1 line:322 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AB21 [get_ports {ddr4_dq[8]}]
set_property src_info {type:XDC file:1 line:323 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE21 [get_ports {ddr4_dq[9]}]
set_property src_info {type:XDC file:1 line:324 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AE23 [get_ports {ddr4_dq[10]}]
set_property src_info {type:XDC file:1 line:325 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD23 [get_ports {ddr4_dq[11]}]
set_property src_info {type:XDC file:1 line:326 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC23 [get_ports {ddr4_dq[12]}]
set_property src_info {type:XDC file:1 line:327 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AD21 [get_ports {ddr4_dq[13]}]
set_property src_info {type:XDC file:1 line:328 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC22 [get_ports {ddr4_dq[14]}]
set_property src_info {type:XDC file:1 line:329 export:INPUT save:INPUT read:READ} [current_design]
set_property PACKAGE_PIN AC21 [get_ports {ddr4_dq[15]}]
set_property src_info {type:XDC file:1 line:330 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:331 export:INPUT save:INPUT read:READ} [current_design]
# IOSTANDARDs
set_property src_info {type:XDC file:1 line:332 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVDS [get_ports ddr4_refclkp]
set_property src_info {type:XDC file:1 line:333 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVDS [get_ports ddr4_refclkn]
set_property src_info {type:XDC file:1 line:334 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_cs_n[*]}]
set_property src_info {type:XDC file:1 line:335 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_cke[*]}]
set_property src_info {type:XDC file:1 line:336 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_odt[*]}]
set_property src_info {type:XDC file:1 line:337 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports ddr4_act_n]
set_property src_info {type:XDC file:1 line:338 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_bg[*]}]
set_property src_info {type:XDC file:1 line:339 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_ba[*]}]
set_property src_info {type:XDC file:1 line:340 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD SSTL12_DCI [get_ports {ddr4_addr[*]}]
set_property src_info {type:XDC file:1 line:341 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports {ddr4_ck_t[*]}]
set_property src_info {type:XDC file:1 line:342 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD DIFF_SSTL12_DCI [get_ports {ddr4_ck_c[*]}]
set_property src_info {type:XDC file:1 line:343 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {ddr4_dqs_t[*]}]
set_property src_info {type:XDC file:1 line:344 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {ddr4_dqs_c[*]}]
set_property src_info {type:XDC file:1 line:345 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD POD12_DCI [get_ports {ddr4_dm_dbi_n[*]}]
set_property src_info {type:XDC file:1 line:346 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD POD12_DCI [get_ports {ddr4_dq[*]}]
set_property src_info {type:XDC file:1 line:347 export:INPUT save:INPUT read:READ} [current_design]
set_property IOSTANDARD LVCMOS12 [get_ports ddr4_reset_n]
set_property src_info {type:XDC file:1 line:348 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:XDC file:1 line:349 export:INPUT save:INPUT read:READ} [current_design]

