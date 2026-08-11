# =============================================================================
# vu13p_dac_top.xdc ? Vivado Timing & Physical Constraints
# Target : XCVU13P-2FHGB2104I on Alinx ACVU13 SOM
#
# Clock, SPI, I2S, relay pins assigned. Cascode outputs (128 pins) need
# baseboard connector assignment before implementation.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Primary Clocks
# -----------------------------------------------------------------------------

# 200 MHz SOM system clock (differential) ? drives SPI control plane (clk_200m domain)
# Uses C1_DDR4_CLKREF on bank 73 GC pins (C1 DDR4 controller unused).
# C0_DDR4_CLKREF (AD33/AE33) remains dedicated to C0 MIG on banks 61/62/63.
create_clock -name clk_200m -period 5.000 [get_ports clk_200m_p]
set_property IOSTANDARD LVDS     [get_ports {clk_200m_p clk_200m_n}]
set_property PACKAGE_PIN G20     [get_ports clk_200m_p]
set_property PACKAGE_PIN G19     [get_ports clk_200m_n]

# Master audio clock (differential) ? externally-muxed OCXO from LMK00304.
# Carries EITHER 45.1584 MHz (22.151 ns) or 49.152 MHz (20.345 ns); constrain
# at the faster 49.152 MHz rate so both families are timing-covered.
# Bank 71 TRUE GC pair B71_L12 (J1-A17/A16).
create_clock -name clk_mclk -period 20.345 [get_ports mclk_p]
set_property IOSTANDARD LVDS     [get_ports {mclk_p mclk_n}]
set_property PACKAGE_PIN J28     [get_ports mclk_p]
set_property PACKAGE_PIN J29     [get_ports mclk_n]

# Clock source select ? drives LMK00304 CLKin_SEL (0 = 45.1584 M, 1 = 49.152 M).
# Quasi-static control output; placed on the freed B71_L13_P pin (J1-B5).
# (B71_L13_N / H26, J1-B4, is now free for future use.)
set_property IOSTANDARD LVCMOS18 [get_ports clk_sel]
set_property DRIVE       4       [get_ports clk_sel]
set_property SLEW        SLOW    [get_ports clk_sel]
set_property PACKAGE_PIN J26     [get_ports clk_sel]
set_false_path -to [get_ports clk_sel]

# I2S bit clock ? asynchronous to all internal clocks; treated as input-only.
# Vivado does not need to time paths through it because i2s_rx is its own
# clock domain and all outputs cross into dsp_clk via a toggle synchronizer.
# Placed on bank 71 GC pin B71_L11_P (J1-B17) so it gets dedicated clock
# routing ? the previous CLOCK_DEDICATED_ROUTE=FALSE waiver on R27 is gone.
create_clock -name i2s_bclk -period 20.345 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS18 [get_ports i2s_bclk]

# -----------------------------------------------------------------------------
# 2. Generated Clocks (MMCM outputs ? Vivado auto-derives these;
#    explicit declarations improve reporting clarity)
# -----------------------------------------------------------------------------

# dsp_clk derived from the single mclk input via the MMCM (no internal BUFGMUX;
# clock selection is external on the LMK00304). At CLKOUT0_DIVIDE_F=3.500:
#   44.1k family: 903.168/3.5 = 258.05 MHz  (3.875 ns)
#   48k   family: 983.04 /3.5 = 280.87 MHz  (3.560 ns)
# clk_mclk is constrained at the faster (48k) rate, so dsp_clk timing covers both.
# NOTE (Step 5.1 synth fix): the previous form used -master_clock/-divide_by
# without -add, which Vivado rejects (CRITICAL WARNING 12-672) -- the clock
# kept its auto-derived name (dsp_clk_unbuf) and every exception referencing
# dsp_clk matched nothing. Name-only create_generated_clock on the MMCM output
# pin RENAMES the auto-derived clock; all other properties are inherited.
create_generated_clock -name dsp_clk [get_pins u_clk_gen/u_mmcm/CLKOUT0]

# cell_clk ? MMCM CLKOUT1 = VCO/20 = mclk frequency (45.1584/49.152 MHz),
# phase-aligned to mclk by the MMCM feedback loop. Launches ONLY the 128
# cascode IOB registers (Round 29, todo #13).
create_generated_clock -name cell_clk [get_pins u_clk_gen/u_mmcm/CLKOUT1]

# -----------------------------------------------------------------------------
# 3. Clock Domain Crossing ? False Paths
#
# All CDC signals use 2-stage (* ASYNC_REG = "TRUE" *) synchronizer chains.
# Vivado must not attempt multi-cycle or single-cycle timing across these.
# -----------------------------------------------------------------------------

# clk_200m (SPI control plane) -> dsp_clk
# Signals: spi_unmute, base_rate_sel, level_switch_req, level_target, outsel_switch_req, outsel_target
set_false_path -from [get_clocks clk_200m] -to [get_clocks dsp_clk]

# dsp_clk -> clk_200m
# Signals: i2s_err, switch_busy, line_mute_status, hp_mute_status (synchronised in dac_ctrl_plane)
set_false_path -from [get_clocks dsp_clk] -to [get_clocks clk_200m]

# i2s_bclk -> dsp_clk
# toggle synchronizer in dac_i2s_ingress for data_valid crossing
set_false_path -from [get_clocks i2s_bclk] -to [get_clocks dsp_clk]

# cell_clk -> dsp_clk (CDC audit, Step 4C.2)
# pace_tgl (cell_clk /8 tick toggle in dac_dsp_core section 6) crosses to the
# 3-FF pace_sync chain in dsp_clk. cell_clk and dsp_clk are related MMCM
# clocks (89 ps worst-case edge alignment) so without this constraint Vivado
# times the raw edge-to-edge path. Toggle protocol tolerates 1 cycle of
# skew/metastability by construction -> datapath-only, one dsp_clk period.
set_max_delay -datapath_only 3.5 \
    -from [get_cells u_dsp_core/pace_tgl_reg] \
    -to   [get_cells {u_dsp_core/pace_sync_reg[0]}]

# Asynchronous external reset ? reset synchronizers handle the CDC
set_false_path -from [get_ports ext_rst_n]

# Async assert into the i2s_bclk-domain reset synchronizer in dac_i2s_ingress
# (sys_rst_n = ext_rst_n & clk_locked; deassert is synchronized by the 2-FF
# chain itself). Mirrors the cell_rst_sync exception in section 8.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *bclk_rst_sync_reg*/CLR}]

# -----------------------------------------------------------------------------
# 4. SPI Control Bus (ARM SPI master -> FPGA slave, clk_200m domain)
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {spi_sclk spi_cs_n spi_mosi spi_miso}]
set_property SLEW       SLOW     [get_ports spi_miso]
# J1 connector, bank 71 single-ended pins
set_property PACKAGE_PIN T26     [get_ports spi_sclk]
set_property PACKAGE_PIN R26     [get_ports spi_cs_n]
set_property PACKAGE_PIN H29     [get_ports spi_mosi]
set_property PACKAGE_PIN G29     [get_ports spi_miso]

# SPI signals are asynchronous to clk_200m; captured by 3-stage synchronizer
set_false_path -from [get_ports {spi_sclk spi_cs_n spi_mosi}]
set_false_path -to   [get_ports spi_miso]

# -----------------------------------------------------------------------------
# 5. FPGA IRQ (active-low, slow control signal to ARM)
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports fpga_irq_n]
set_property DRIVE       4       [get_ports fpga_irq_n]
set_property SLEW        SLOW    [get_ports fpga_irq_n]
set_property PACKAGE_PIN P28     [get_ports fpga_irq_n]
set_false_path -to [get_ports fpga_irq_n]

# -----------------------------------------------------------------------------
# 6. I2S Ingress (asynchronous to all FPGA clocks)
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {i2s_bclk i2s_lrclk i2s_data}]
# J1 connector, bank 71. bclk on GC pin B71_L11_P (J1-B17) for dedicated
# clock routing; lrclk/data on ordinary I/O (they are data, sampled by bclk).
# R27 (B71_L2_N, J1-A1) is now free.
set_property PACKAGE_PIN H27     [get_ports i2s_bclk]
set_property PACKAGE_PIN T27     [get_ports i2s_lrclk]
set_property PACKAGE_PIN N28     [get_ports i2s_data]

# i2s_rx is clocked by i2s_bclk; its outputs cross to dsp_clk via toggle sync.
# No timing constraint needed on the raw I2S input ports beyond the clock above.

# -----------------------------------------------------------------------------
# 7. Hardware Relay Outputs (slow, relay coil drive)
# -----------------------------------------------------------------------------
# Fig. 4d relay set: 2x mute, HP rails, 2x level tap (all coil drives via ULN buffer)
set_property IOSTANDARD LVCMOS18 [get_ports {relay_line_mute relay_hp_mute relay_hp_rails relay_level[*]}]
set_property DRIVE       12      [get_ports {relay_line_mute relay_hp_mute relay_hp_rails relay_level[*]}]
set_property SLEW        SLOW    [get_ports {relay_line_mute relay_hp_mute relay_hp_rails relay_level[*]}]
set_property PACKAGE_PIN R28     [get_ports relay_line_mute]
set_property PACKAGE_PIN T28     [get_ports relay_hp_mute]
# Verified against ACVU13P-Pin-Assignment-20260703.csv: B71_L6/L4 on J1 (B1/B2/B7)
set_property PACKAGE_PIN N26     [get_ports relay_hp_rails]
set_property PACKAGE_PIN P26     [get_ports {relay_level[0]}]
set_property PACKAGE_PIN N29     [get_ports {relay_level[1]}]
set_false_path -to [get_ports {relay_line_mute relay_hp_mute relay_hp_rails relay_level[*]}]

# -----------------------------------------------------------------------------
# 8. Cascode Cell Outputs (1 pin per cell, 64 per channel, 128 total)
#
# Round 29 architecture (bom.md 1.2, Fig. 1b): these 128 LVCMOS18 outputs are
# DATA into the external MC100EP52 differential LVPECL reclock FFs (resistive
# 3.6k/1k shift into each FF D input vs external ~2.1 V threshold rail;
# the EP52 has no V_BB pin - Round 30 finding, bom.md 1.2). The FF resamples on the
# OCXO-derived LMK tree clock and its Q/~Q pair drives the DMMT5551 steering
# cell bases through 100R/165R networks. No CMOS translator.
#
# Timing (todo #13, closed Round 29):
#   - IOB FFs are clocked by cell_clk (MMCM CLKOUT1 = mclk rate, phase-aligned
#     to mclk and therefore to the external FF clock, same LMK00304 source).
#   - ff_clk below is a VIRTUAL clock representing the MC100EP52 clock pin.
#     Launch on cell_clk edge N, capture on ff_clk edge N+1 (single cycle,
#     20.345 ns budget at 49.152 MHz).
#   - Output delay numbers DATASHEET-VERIFIED (Round 30, bom.md 1.4):
#     MC10EP52/D rev 7: setup 50 ps min, hold 0 ps min; LMK tree skew actual
#     ~0.35 ns (LMK00304 50 ps + LMK1C1108 part-to-part 280 ps + trace 10 ps).
#     Constraints below kept CONSERVATIVE (budgeted setup 0.2 / hold 0.2 /
#     skew 1.0) - real margin is only better; do not relax without need:
#       max = board flight 1.0 + shift network 0.1 + EP52 setup 0.2
#             + LMK tree skew margin 1.0                    = 2.3  -> 2.5 pad
#       min = -(EP52 hold 0.2 + LMK tree skew margin 1.0)   = -1.2 -> -1.5 pad
#   - dsp_clk -> cell_clk crossing uses a toggle-handshake CDC in
#     dac_dsp_core (staging bus stable ~8 cell_clk per 6.144 MHz DEM update);
#     constrain datapath-only so Vivado does not chase the 89 ps related-clock
#     edge alignment.
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {cascode_l[*] cascode_r[*]}]
set_property DRIVE       8       [get_ports {cascode_l[*] cascode_r[*]}]
set_property SLEW        FAST    [get_ports {cascode_l[*] cascode_r[*]}]
set_property IOB         TRUE    [get_cells {u_dsp_core/cascode_iob_l_reg[*] u_dsp_core/cascode_iob_r_reg[*]}]

# CDC: dsp_clk staging/toggle -> cell_clk sync/capture (toggle handshake)
set_max_delay -datapath_only 3.5 \
    -from [get_cells {u_dsp_core/staging_l_reg[*] u_dsp_core/staging_r_reg[*] u_dsp_core/dem_update_tgl_reg}] \
    -to   [get_cells {u_dsp_core/cell_cap_l_reg[*] u_dsp_core/cell_cap_r_reg[*] u_dsp_core/tgl_sync_reg[0]}]

# Async reset into the cell_clk reset synchronizer (recovery/removal handled
# by the 2-FF synchronizer itself)
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *cell_rst_sync_reg*/CLR}]

# Virtual clock: external MC100EP52 clock pin (same rate/phase as mclk; the
# LMK tree skew between the FPGA mclk input and the FF CLK pins is inside the
# +-1.0 ns margin folded into the output delay values above).
create_clock -name ff_clk -period 20.345

set_output_delay -clock ff_clk -max  2.500 [get_ports {cascode_l[*] cascode_r[*]}]
set_output_delay -clock ff_clk -min -1.500 [get_ports {cascode_l[*] cascode_r[*]}]

# Package pins: banks 64+65 = LEFT channel, banks 67+69 = RIGHT channel.
# Generated from Alinx ACVU13P-Pin-Assignment-20260703.csv (L-pair pins only,
# no T/VREF sites; conflict-checked against all other XDC assignments).
# Bit ordering within a bank follows the LA-pair number; final per-cell
# ordering is free to be remapped at layout (DEM decorrelates cell position).
set_property PACKAGE_PIN BF24 [get_ports {cascode_l[0]}] ;# B64_L1_P
set_property PACKAGE_PIN BF23 [get_ports {cascode_l[1]}] ;# B64_L1_N
set_property PACKAGE_PIN BD23 [get_ports {cascode_l[2]}] ;# B64_L2_P
set_property PACKAGE_PIN BE23 [get_ports {cascode_l[3]}] ;# B64_L2_N
set_property PACKAGE_PIN BC24 [get_ports {cascode_l[4]}] ;# B64_L3_P
set_property PACKAGE_PIN BD24 [get_ports {cascode_l[5]}] ;# B64_L3_N
set_property PACKAGE_PIN BE22 [get_ports {cascode_l[6]}] ;# B64_L4_P
set_property PACKAGE_PIN BF22 [get_ports {cascode_l[7]}] ;# B64_L4_N
set_property PACKAGE_PIN BD21 [get_ports {cascode_l[8]}] ;# B64_L5_P
set_property PACKAGE_PIN BE21 [get_ports {cascode_l[9]}] ;# B64_L5_N
set_property PACKAGE_PIN BD20 [get_ports {cascode_l[10]}] ;# B64_L6_P
set_property PACKAGE_PIN BE20 [get_ports {cascode_l[11]}] ;# B64_L6_N
set_property PACKAGE_PIN BA20 [get_ports {cascode_l[12]}] ;# B64_L7_P
set_property PACKAGE_PIN BB20 [get_ports {cascode_l[13]}] ;# B64_L7_N
set_property PACKAGE_PIN BB21 [get_ports {cascode_l[14]}] ;# B64_L8_P
set_property PACKAGE_PIN BC21 [get_ports {cascode_l[15]}] ;# B64_L8_N
set_property PACKAGE_PIN BB22 [get_ports {cascode_l[16]}] ;# B64_L9_P
set_property PACKAGE_PIN BC22 [get_ports {cascode_l[17]}] ;# B64_L9_N
set_property PACKAGE_PIN BA24 [get_ports {cascode_l[18]}] ;# B64_L10_P
set_property PACKAGE_PIN BB24 [get_ports {cascode_l[19]}] ;# B64_L10_N
set_property PACKAGE_PIN AY22 [get_ports {cascode_l[20]}] ;# B64_L11_P
set_property PACKAGE_PIN BA22 [get_ports {cascode_l[21]}] ;# B64_L11_N
set_property PACKAGE_PIN AY23 [get_ports {cascode_l[22]}] ;# B64_L12_P
set_property PACKAGE_PIN BA23 [get_ports {cascode_l[23]}] ;# B64_L12_N
set_property PACKAGE_PIN AV23 [get_ports {cascode_l[24]}] ;# B64_L13_P
set_property PACKAGE_PIN AW23 [get_ports {cascode_l[25]}] ;# B64_L13_N
set_property PACKAGE_PIN AV24 [get_ports {cascode_l[26]}] ;# B64_L14_P
set_property PACKAGE_PIN AW24 [get_ports {cascode_l[27]}] ;# B64_L14_N
set_property PACKAGE_PIN AU22 [get_ports {cascode_l[28]}] ;# B64_L15_P
set_property PACKAGE_PIN AV22 [get_ports {cascode_l[29]}] ;# B64_L15_N
set_property PACKAGE_PIN AR22 [get_ports {cascode_l[30]}] ;# B64_L16_P
set_property PACKAGE_PIN AT22 [get_ports {cascode_l[31]}] ;# B64_L16_N
set_property PACKAGE_PIN AR23 [get_ports {cascode_l[32]}] ;# B64_L17_P
set_property PACKAGE_PIN AT23 [get_ports {cascode_l[33]}] ;# B64_L17_N
set_property PACKAGE_PIN AT24 [get_ports {cascode_l[34]}] ;# B64_L18_P
set_property PACKAGE_PIN AU24 [get_ports {cascode_l[35]}] ;# B64_L18_N
set_property PACKAGE_PIN AN22 [get_ports {cascode_l[36]}] ;# B64_L19_P
set_property PACKAGE_PIN AN21 [get_ports {cascode_l[37]}] ;# B64_L19_N
set_property PACKAGE_PIN AN23 [get_ports {cascode_l[38]}] ;# B64_L20_P
set_property PACKAGE_PIN AP23 [get_ports {cascode_l[39]}] ;# B64_L20_N
set_property PACKAGE_PIN AN24 [get_ports {cascode_l[40]}] ;# B64_L21_P
set_property PACKAGE_PIN AP24 [get_ports {cascode_l[41]}] ;# B64_L21_N
set_property PACKAGE_PIN AL24 [get_ports {cascode_l[42]}] ;# B64_L22_P
set_property PACKAGE_PIN AM24 [get_ports {cascode_l[43]}] ;# B64_L22_N
set_property PACKAGE_PIN AL22 [get_ports {cascode_l[44]}] ;# B64_L23_P
set_property PACKAGE_PIN AM22 [get_ports {cascode_l[45]}] ;# B64_L23_N
set_property PACKAGE_PIN AL21 [get_ports {cascode_l[46]}] ;# B64_L24_P
set_property PACKAGE_PIN AM21 [get_ports {cascode_l[47]}] ;# B64_L24_N
set_property PACKAGE_PIN BF28 [get_ports {cascode_l[48]}] ;# B65_L1_P
set_property PACKAGE_PIN BF29 [get_ports {cascode_l[49]}] ;# B65_L1_N
set_property PACKAGE_PIN BE27 [get_ports {cascode_l[50]}] ;# B65_L2_P
set_property PACKAGE_PIN BD28 [get_ports {cascode_l[51]}] ;# B65_L3_P
set_property PACKAGE_PIN BE28 [get_ports {cascode_l[52]}] ;# B65_L3_N
set_property PACKAGE_PIN BD26 [get_ports {cascode_l[53]}] ;# B65_L4_P
set_property PACKAGE_PIN BE26 [get_ports {cascode_l[54]}] ;# B65_L4_N
set_property PACKAGE_PIN BE25 [get_ports {cascode_l[55]}] ;# B65_L5_P
set_property PACKAGE_PIN BF25 [get_ports {cascode_l[56]}] ;# B65_L5_N
set_property PACKAGE_PIN BC26 [get_ports {cascode_l[57]}] ;# B65_L6_P
set_property PACKAGE_PIN BC27 [get_ports {cascode_l[58]}] ;# B65_L6_N
set_property PACKAGE_PIN BA25 [get_ports {cascode_l[59]}] ;# B65_L7_P
set_property PACKAGE_PIN BB25 [get_ports {cascode_l[60]}] ;# B65_L7_N
set_property PACKAGE_PIN BB26 [get_ports {cascode_l[61]}] ;# B65_L8_P
set_property PACKAGE_PIN BB27 [get_ports {cascode_l[62]}] ;# B65_L8_N
set_property PACKAGE_PIN BA27 [get_ports {cascode_l[63]}] ;# B65_L9_P
set_property PACKAGE_PIN BF14 [get_ports {cascode_r[0]}] ;# B67_L1_P
set_property PACKAGE_PIN BF13 [get_ports {cascode_r[1]}] ;# B67_L1_N
set_property PACKAGE_PIN BE15 [get_ports {cascode_r[2]}] ;# B67_L2_P
set_property PACKAGE_PIN BF15 [get_ports {cascode_r[3]}] ;# B67_L2_N
set_property PACKAGE_PIN BD16 [get_ports {cascode_r[4]}] ;# B67_L3_P
set_property PACKAGE_PIN BE16 [get_ports {cascode_r[5]}] ;# B67_L3_N
set_property PACKAGE_PIN BD13 [get_ports {cascode_r[6]}] ;# B67_L4_P
set_property PACKAGE_PIN BE13 [get_ports {cascode_r[7]}] ;# B67_L4_N
set_property PACKAGE_PIN BD15 [get_ports {cascode_r[8]}] ;# B67_L5_P
set_property PACKAGE_PIN BD14 [get_ports {cascode_r[9]}] ;# B67_L5_N
set_property PACKAGE_PIN BC14 [get_ports {cascode_r[10]}] ;# B67_L6_P
set_property PACKAGE_PIN BC13 [get_ports {cascode_r[11]}] ;# B67_L6_N
set_property PACKAGE_PIN BA12 [get_ports {cascode_r[12]}] ;# B67_L7_P
set_property PACKAGE_PIN BB12 [get_ports {cascode_r[13]}] ;# B67_L7_N
set_property PACKAGE_PIN AY12 [get_ports {cascode_r[14]}] ;# B67_L8_P
set_property PACKAGE_PIN AY11 [get_ports {cascode_r[15]}] ;# B67_L8_N
set_property PACKAGE_PIN AY16 [get_ports {cascode_r[16]}] ;# B67_L9_P
set_property PACKAGE_PIN AY15 [get_ports {cascode_r[17]}] ;# B67_L9_N
set_property PACKAGE_PIN BB15 [get_ports {cascode_r[18]}] ;# B67_L10_P
set_property PACKAGE_PIN BB14 [get_ports {cascode_r[19]}] ;# B67_L10_N
set_property PACKAGE_PIN BA15 [get_ports {cascode_r[20]}] ;# B67_L11_P
set_property PACKAGE_PIN BA14 [get_ports {cascode_r[21]}] ;# B67_L11_N
set_property PACKAGE_PIN AY13 [get_ports {cascode_r[22]}] ;# B67_L12_P
set_property PACKAGE_PIN BA13 [get_ports {cascode_r[23]}] ;# B67_L12_N
set_property PACKAGE_PIN AW14 [get_ports {cascode_r[24]}] ;# B67_L13_P
set_property PACKAGE_PIN AW13 [get_ports {cascode_r[25]}] ;# B67_L13_N
set_property PACKAGE_PIN AW16 [get_ports {cascode_r[26]}] ;# B67_L14_P
set_property PACKAGE_PIN AW15 [get_ports {cascode_r[27]}] ;# B67_L14_N
set_property PACKAGE_PIN AU13 [get_ports {cascode_r[28]}] ;# B67_L15_P
set_property PACKAGE_PIN AV13 [get_ports {cascode_r[29]}] ;# B67_L15_N
set_property PACKAGE_PIN AU14 [get_ports {cascode_r[30]}] ;# B67_L16_P
set_property PACKAGE_PIN AV14 [get_ports {cascode_r[31]}] ;# B67_L16_N
set_property PACKAGE_PIN AT15 [get_ports {cascode_r[32]}] ;# B67_L17_P
set_property PACKAGE_PIN AU15 [get_ports {cascode_r[33]}] ;# B67_L17_N
set_property PACKAGE_PIN AU16 [get_ports {cascode_r[34]}] ;# B67_L18_P
set_property PACKAGE_PIN AV16 [get_ports {cascode_r[35]}] ;# B67_L18_N
set_property PACKAGE_PIN AR16 [get_ports {cascode_r[36]}] ;# B67_L19_P
set_property PACKAGE_PIN AR15 [get_ports {cascode_r[37]}] ;# B67_L19_N
set_property PACKAGE_PIN AP15 [get_ports {cascode_r[38]}] ;# B67_L20_P
set_property PACKAGE_PIN AP14 [get_ports {cascode_r[39]}] ;# B67_L20_N
set_property PACKAGE_PIN AN14 [get_ports {cascode_r[40]}] ;# B67_L21_P
set_property PACKAGE_PIN AN13 [get_ports {cascode_r[41]}] ;# B67_L21_N
set_property PACKAGE_PIN AP13 [get_ports {cascode_r[42]}] ;# B67_L22_P
set_property PACKAGE_PIN AR13 [get_ports {cascode_r[43]}] ;# B67_L22_N
set_property PACKAGE_PIN AL15 [get_ports {cascode_r[44]}] ;# B67_L23_P
set_property PACKAGE_PIN AM15 [get_ports {cascode_r[45]}] ;# B67_L23_N
set_property PACKAGE_PIN AL14 [get_ports {cascode_r[46]}] ;# B67_L24_P
set_property PACKAGE_PIN AM14 [get_ports {cascode_r[47]}] ;# B67_L24_N
set_property PACKAGE_PIN U34  [get_ports {cascode_r[48]}] ;# B69_L1_P
set_property PACKAGE_PIN T34  [get_ports {cascode_r[49]}] ;# B69_L1_N
set_property PACKAGE_PIN T33  [get_ports {cascode_r[50]}] ;# B69_L2_P
set_property PACKAGE_PIN R33  [get_ports {cascode_r[51]}] ;# B69_L2_N
set_property PACKAGE_PIN U32  [get_ports {cascode_r[52]}] ;# B69_L3_P
set_property PACKAGE_PIN T32  [get_ports {cascode_r[53]}] ;# B69_L3_N
set_property PACKAGE_PIN V32  [get_ports {cascode_r[54]}] ;# B69_L4_P
set_property PACKAGE_PIN V33  [get_ports {cascode_r[55]}] ;# B69_L4_N
set_property PACKAGE_PIN V31  [get_ports {cascode_r[56]}] ;# B69_L5_P
set_property PACKAGE_PIN U31  [get_ports {cascode_r[57]}] ;# B69_L5_N
set_property PACKAGE_PIN U30  [get_ports {cascode_r[58]}] ;# B69_L6_P
set_property PACKAGE_PIN T30  [get_ports {cascode_r[59]}] ;# B69_L6_N
set_property PACKAGE_PIN R30  [get_ports {cascode_r[60]}] ;# B69_L7_P
set_property PACKAGE_PIN P30  [get_ports {cascode_r[61]}] ;# B69_L7_N
set_property PACKAGE_PIN R31  [get_ports {cascode_r[62]}] ;# B69_L8_P
set_property PACKAGE_PIN R32  [get_ports {cascode_r[63]}] ;# B69_L8_N

# -----------------------------------------------------------------------------
# 9. DDR4 Interface
# Pin assignments and timing constraints are generated by the MIG IP wizard
# and will be merged here once SYNTH-2 (dac_ddr4_if MIG) is complete.
# Placeholder: do not remove this section header.
# -----------------------------------------------------------------------------
# <MIG-generated constraints will be inserted here>

# --- ui_clk <-> dsp_clk CDC (dac_coef_subsys) - ENABLE WITH THE MIG -----------
# CDC audit (Step 4C.2): dac_coef_subsys has three toggle synchronizers and
# one qualified data bus crossing between ui_clk (MIG user clock, 5 ns) and
# dsp_clk. ui_clk does not exist until the MIG is instantiated, so these
# constraints are staged here commented out. Uncomment on MIG merge; the
# cell names are already final in dac_coef_subsys.sv.
#
# 1) load_start  dsp_clk -> ui_clk  (toggle sync, one ui_clk period budget)
# set_max_delay -datapath_only 5.0 \
#     -from [get_cells u_coef_subsys/load_start_toggle_dsp_reg] \
#     -to   [get_cells {u_coef_subsys/load_start_sync_ui_reg[0]}]
#
# 2) load_done   ui_clk -> dsp_clk  (toggle sync, one dsp_clk period budget)
# set_max_delay -datapath_only 3.5 \
#     -from [get_cells u_coef_subsys/load_done_toggle_ui_reg] \
#     -to   [get_cells {u_coef_subsys/load_done_sync_dsp_reg[0]}]
#
# 3) coef_we     ui_clk -> dsp_clk  (toggle sync)
# set_max_delay -datapath_only 3.5 \
#     -from [get_cells u_coef_subsys/coef_we_toggle_ui_reg] \
#     -to   [get_cells {u_coef_subsys/coef_we_sync_dsp_reg[0]}]
#
# 4) coef write bus ui_clk -> dsp_clk (coef_waddr/wdata/wmac): held stable a
#    full ui_clk cycle and sampled only on the synced coef_we edge (2-3
#    dsp_clk later), so a datapath-only bound of one ui_clk period suffices.
# set_max_delay -datapath_only 5.0 \
#     -from [get_cells -hierarchical -filter {NAME =~ *u_coef_loader/coef_w*_reg*}] \
#     -to   [get_cells {u_coef_subsys/coef_waddr_reg[*] u_coef_subsys/coef_wdata_reg[*] u_coef_subsys/coef_wmac_reg[*]}]

# -----------------------------------------------------------------------------
# 10. User LED (debug / status indicator)
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports led_status]
set_property DRIVE       4       [get_ports led_status]
set_property SLEW        SLOW    [get_ports led_status]
set_property PACKAGE_PIN BC33    [get_ports led_status]
set_false_path -to [get_ports led_status]

# Board-level debug LEDs on J1 (B71_L18/L10, verified free in connector CSV)
# [3]=clk_locked [2]=ddr4_calib_done [1]=i2s_err [0]=force_zero
set_property IOSTANDARD LVCMOS18 [get_ports {led_debug[*]}]
set_property DRIVE       4       [get_ports {led_debug[*]}]
set_property SLEW        SLOW    [get_ports {led_debug[*]}]
set_property PACKAGE_PIN D28     [get_ports {led_debug[0]}]
set_property PACKAGE_PIN E28     [get_ports {led_debug[1]}]
set_property PACKAGE_PIN K27     [get_ports {led_debug[2]}]
set_property PACKAGE_PIN K26     [get_ports {led_debug[3]}]
set_false_path -to [get_ports {led_debug[*]}]

# -----------------------------------------------------------------------------
# 11. QSPI Flash 1 (coefficient storage, bank 65)
#     Flash 0 uses dedicated config pins (CCLK/FCS_B/D00-D03) via STARTUPE3.
#     Flash 1 directly accessible as user I/O on bank 65.
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {qspi1_cs_n qspi1_dq[*]}]
set_property DRIVE       8       [get_ports {qspi1_cs_n qspi1_dq[*]}]
set_property SLEW        FAST    [get_ports {qspi1_dq[*]}]
set_property PACKAGE_PIN BF27    [get_ports qspi1_cs_n]
set_property PACKAGE_PIN AM26    [get_ports {qspi1_dq[0]}]
set_property PACKAGE_PIN AN26    [get_ports {qspi1_dq[1]}]
set_property PACKAGE_PIN AL25    [get_ports {qspi1_dq[2]}]
set_property PACKAGE_PIN AM25    [get_ports {qspi1_dq[3]}]
# QSPI1 clock is shared CCLK via STARTUPE3 (no dedicated pin assignment needed)

# -----------------------------------------------------------------------------
# 12. Bitstream / Configuration
# -----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4       [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE   31.9     [current_design]
set_property BITSTREAM.GENERAL.COMPRESS    TRUE     [current_design]
set_property CONFIG_VOLTAGE                1.8      [current_design]
set_property CFGBVS                        GND      [current_design]

