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

# Master audio clock: carrier oscillator/fanout copy, single-ended LVCMOS18.
# Carries EITHER 45.1584 MHz (22.151 ns) or 49.152 MHz (20.345 ns); constrain
# at the faster 49.152 MHz rate so both families are timing-covered.
# Bank 65 TRUE GC pair B65_L12 (J6-C30/C29) - moved from B71_L12 (J1-A17/A16,
# J28/J29) on 2026-10-08: the clock block sits on the analog/right edge next to
# J6, J1 is the noisy/left edge.  Carrier drives mclk_p single-ended LVCMOS18
# and leaves mclk_n reserved/no-connect. RTL uses IBUF on mclk_p.
create_clock -name clk_mclk -period 20.345 [get_ports mclk_p]
set_property IOSTANDARD LVCMOS18 [get_ports {mclk_p mclk_n}]
set_property PACKAGE_PIN AW28    [get_ports mclk_p]
set_property PACKAGE_PIN AY28    [get_ports mclk_n]

# Physical oscillator enable: 0 = 49.152 MHz, 1 = 45.1584 MHz.
# This is the inverse of the stream-rate code's family48 bit.
# Quasi-static control output; B65_L16_P (J6-A19) since 2026-10-08 (was
# B71_L13_P / J26, J1-B5) - same move as mclk, drives the XO enables in the
# clock block on the analog edge.
set_property IOSTANDARD LVCMOS18 [get_ports clk_sel]
set_property DRIVE       4       [get_ports clk_sel]
set_property SLEW        SLOW    [get_ports clk_sel]
set_property PACKAGE_PIN AR25    [get_ports clk_sel]
set_false_path -to [get_ports clk_sel]

# I2S BCLK is an output generated from cell_clk; DATA returns through isolation.
# BCLK is an FPGA output. Worst-case native rate is 384k: MCLK/2.
# Slower stream modes divide by 4/8/16. Physical return timing must be
# qualified against the programmed capture phase and isolator/AP delays.
set_property IOSTANDARD LVCMOS18 [get_ports i2s_bclk]

# -----------------------------------------------------------------------------
# 2. Generated Clocks (MMCM outputs ? Vivado auto-derives these;
#    explicit declarations improve reporting clarity)
# -----------------------------------------------------------------------------

# dsp_clk derived from the buffered XOCLK copy on mclk via the MMCM (no internal
# BUFGMUX; clk_sel controls the dual oscillator-enable network). At divide 3.25:
#   44.1k family: 903.168/3.25 = 277.898 MHz  (3.599 ns)
#   48k   family: 983.04 /3.25 = 302.474 MHz  (3.306 ns)
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

# clk_200m (SPI control plane) -> dsp_clk single-bit synchronizer first stages.
# Do not blanket-false-path this clock pair: held multi-bit buses use explicit
# datapath-only max delays below and must remain constrained.
set_false_path -to [get_pins {
    unmute_sync_chain_reg[0]/D rate_sel_sync_chain_reg[0]/D
    level_req_sync_chain_reg[0]/D
    outsel_req_sync_chain_reg[0]/D outsel_target_sync_chain_reg[0]/D
    vol_tog_sync_reg[0]/D
}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/level_target_reg[*]}] \
    -to   [get_cells {level_target_sync_chain_reg[0] level_target_sync_chain_reg[1] level_target_sync_chain_reg[2]}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {sys_volume_q_reg[*]}] \
    -to   [get_cells {sys_volume_dsp_reg[*]}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/i2s_rx_trim_reg[*]}] \
    -to   [get_cells {u_i2s_ingress/trim_meta_reg[*]}]

# The applied interpolation/rate-shift bus changes only while the MMCM path
# reset is asserted, and remains static until the DSP and cell domains relock.
set_false_path \
    -from [get_cells {u_stream_rate/applied_rate_reg[1] u_stream_rate/applied_rate_reg[2]}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_dsp_core/* && IS_SEQUENTIAL}]
set_false_path \
    -from [get_cells {u_stream_rate/applied_rate_reg[1] u_stream_rate/applied_rate_reg[2]}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_i2s_ingress/* && IS_SEQUENTIAL}]

# dsp_clk -> clk_200m single-bit status synchronizer first stages.
set_false_path -to [get_pins {
    u_ctrl_plane/i2s_err_sync[0]/D
    u_ctrl_plane/switch_busy_sync[0]/D
    u_ctrl_plane/line_mute_sync[0]/D
    u_ctrl_plane/hp_mute_sync[0]/D
}]

# Serial DATA synchronizer and tagged launch-event crossing.
set_false_path -from [get_ports i2s_data] -to [get_pins {u_i2s_ingress/data_sync_reg[0]/D}]
set_false_path -to [get_pins {u_i2s_ingress/enable_cell_reg[0]/D u_i2s_ingress/enable_sync_reg[0]/D u_i2s_ingress/valid_sync_reg[0]/D}]
set_max_delay -datapath_only 3.5 \
    -from [get_cells {u_i2s_ingress/launch_toggle_reg u_i2s_ingress/launch_bit_reg[*]}] \
    -to [get_cells {u_i2s_ingress/launch_sync_reg[0] u_i2s_ingress/tag_pipe_reg[0][*]}]

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

# Async reset assertion; release is synchronized in DSP and serial cell domains.
set_false_path -to [get_pins -hierarchical -filter {NAME =~ *dsp_reset_sync_reg*/CLR || NAME =~ *cell_reset_reg*/CLR}]

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

# 5b. External reset from the application processor (through the ISO7710 on the
#     carrier control sheet, 2026-10-07): bank 71 B71_L2_N = J1 pin A1.
set_property IOSTANDARD LVCMOS18 [get_ports ext_rst_n]
set_property PACKAGE_PIN R27     [get_ports ext_rst_n]

# -----------------------------------------------------------------------------
# 6. FPGA-master I2S with asynchronously returning serial DATA
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {i2s_bclk i2s_lrclk i2s_data}]
# J1 bank 71. BCLK/LRCLK are outputs; DATA is sampled with a qualified delay.
# R27 (B71_L2_N, J1-A1) = ext_rst_n (5b).
set_property PACKAGE_PIN H27     [get_ports i2s_bclk]
set_property PACKAGE_PIN T27     [get_ports i2s_lrclk]
set_property PACKAGE_PIN N28     [get_ports i2s_data]
set_property DRIVE 4 [get_ports {i2s_bclk i2s_lrclk}]
set_property SLEW SLOW [get_ports {i2s_bclk i2s_lrclk}]
set_property IOB TRUE [get_cells {u_i2s_ingress/i2s_bclk_reg u_i2s_ingress/i2s_lrclk_reg}]
create_generated_clock -name i2s_bclk -source [get_pins u_clk_gen/u_mmcm/CLKOUT1] -divide_by 2 [get_ports i2s_bclk]
set_max_delay -datapath_only 5.0 -to [get_ports {i2s_bclk i2s_lrclk}]
set_false_path -to [get_pins {u_stream_rate/lock_sync_reg[0]/D stream_fault_sync_reg[0]/D}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_stream_rate/applied_rate_reg[*]}] \
    -to [get_cells {u_coef_subsys/u_coef_loader/rate_r_reg[*]}]

# Review capture delay against the complete clock/AP/DATA round-trip budget.

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
set_property PACKAGE_PIN K28     [get_ports {relay_level[1]}]
set_property PACKAGE_PIN N29     [get_ports pg_all]
set_property PACKAGE_PIN M29     [get_ports test_select_n]
set_property PACKAGE_PIN L29     [get_ports test_step_n]
set_property PACKAGE_PIN L28     [get_ports test_led]
set_property IOSTANDARD LVCMOS18 [get_ports {pg_all test_select_n test_step_n test_led}]
set_property DRIVE 4 [get_ports test_led]
set_property SLEW SLOW [get_ports test_led]
set_false_path -from [get_ports {pg_all test_select_n test_step_n}]
set_false_path -to [get_ports test_led]
set_false_path -to [get_ports {relay_line_mute relay_hp_mute relay_hp_rails relay_level[*]}]

# -----------------------------------------------------------------------------
# 8. Cascode Cell Outputs (1 pin per cell, 64 per channel, 128 total)
#
# Round 29 architecture (bom.md 1.2, Fig. 1b): these 128 LVCMOS18 outputs are
# DATA into the external MC100EP52 differential LVPECL reclock FFs (resistive
# 3.6k/1k shift into each FF D input vs external ~2.1 V threshold rail;
# the EP52 has no V_BB pin - Round 30 finding, bom.md 1.2). The FF resamples on the
# OCXO-derived XOCLK fanout clock and its Q/~Q pair drives the DMMT5551 steering
# cell bases through 100R/165R networks. No CMOS translator.
#
# Timing (todo #13, closed Round 29; hold fix 2026-08-14):
#   - IOB FFs are clocked by cell_clk (MMCM CLKOUT1 = mclk rate, CLKOUT1_PHASE
#     = 90 deg -> launch edge 5.09 ns after the mclk/ff_clk edge; same selected
#     XOCLK through the LMK1C1108 fanout). The 90 deg shift exists because at 0 deg the MMCM-compensated
#     launch was coincident with the ff_clk edge and violated the budgeted
#     hold pad by -1.74 ns (f9wb route). See sys_clock_gen.sv.
#   - ff_clk below is a VIRTUAL clock representing the MC100EP52 clock pin.
#     Launch on cell_clk edge N (t = 5.09 ns), capture on ff_clk edge N+1
#     (t = 20.345 ns): 15.26 ns setup budget, 5.09 ns of real hold margin
#     against edge N.
#   - Output delay numbers DATASHEET-VERIFIED (Round 30, bom.md 1.4):
#     MC10EP52/D rev 7: setup 50 ps min, hold 0 ps min. Exact oscillator/
#     fanout/board skew still needs physical verification. Constraints below
#     retain a conservative 1.0 ns skew budget; do not relax without routed evidence:
#       max = board flight 1.0 + shift network 0.1 + EP52 setup 0.2
#             + fanout skew margin 1.0                      = 2.3  -> 2.5 pad
#       min = -(EP52 hold 0.2 + fanout skew margin 1.0)     = -1.2 -> -1.5 pad
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
# XOCLK fanout/board skew between the FPGA copy and FF CLK pins is budgeted in
# the +-1.0 ns output-delay values above).
create_clock -name ff_clk -period 20.345

set_output_delay -clock ff_clk -max  2.500 [get_ports {cascode_l[*] cascode_r[*]}]
set_output_delay -clock ff_clk -min -1.500 [get_ports {cascode_l[*] cascode_r[*]}]

# Package pins: banks 64+65 = LEFT channel (J6), banks 67+66 = RIGHT channel
# (J5 + J6).  cascode_r[48..63] moved from bank 69 (J1, the carrier's noisy
# left edge) to bank 66 L15-L21/L24 (J6, analog edge) on 2026-10-08.
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
set_property PACKAGE_PIN AT18 [get_ports {cascode_r[48]}] ;# B66_L15_P
set_property PACKAGE_PIN AU17 [get_ports {cascode_r[49]}] ;# B66_L15_N
set_property PACKAGE_PIN AR17 [get_ports {cascode_r[50]}] ;# B66_L16_P
set_property PACKAGE_PIN AT17 [get_ports {cascode_r[51]}] ;# B66_L16_N
set_property PACKAGE_PIN AP18 [get_ports {cascode_r[52]}] ;# B66_L17_P
set_property PACKAGE_PIN AR18 [get_ports {cascode_r[53]}] ;# B66_L17_N
set_property PACKAGE_PIN AP20 [get_ports {cascode_r[54]}] ;# B66_L18_P
set_property PACKAGE_PIN AR20 [get_ports {cascode_r[55]}] ;# B66_L18_N
set_property PACKAGE_PIN AN18 [get_ports {cascode_r[56]}] ;# B66_L19_P
set_property PACKAGE_PIN AN17 [get_ports {cascode_r[57]}] ;# B66_L19_N
set_property PACKAGE_PIN AN19 [get_ports {cascode_r[58]}] ;# B66_L20_P
set_property PACKAGE_PIN AP19 [get_ports {cascode_r[59]}] ;# B66_L20_N
set_property PACKAGE_PIN AM16 [get_ports {cascode_r[60]}] ;# B66_L21_P
set_property PACKAGE_PIN AN16 [get_ports {cascode_r[61]}] ;# B66_L21_N
set_property PACKAGE_PIN AL20 [get_ports {cascode_r[62]}] ;# B66_L24_P
set_property PACKAGE_PIN AM20 [get_ports {cascode_r[63]}] ;# B66_L24_N

# -----------------------------------------------------------------------------
# 9. DDR4 Interface
# C0 controller pin LOCs from "ACVU13P FPGA Onboard Part Pin Assignment -
# DDR4 Modules.csv" (Alinx SOM). 64-bit config: bytes 0-7 (D0-D63).
# Bytes 8/9 (D64-D79, DQS8/9, DM8/9 — the SOM's 5th x16 device) are
# UNCONNECTED: DDR4 MIG maxes at 72-bit, we run 64-bit (2026-08-11 note).
# IOSTANDARD / DCI / output impedance are set by the ddr4_0 IP (PG150);
# only PACKAGE_PIN is constrained here.
# addr[16:14] carry RAS/CAS/WE per DDR4 command encoding: A14=WE_B,
# A15=CAS_B, A16=RAS_B.
set_property PACKAGE_PIN AD33 [get_ports ddr4_clkref_p]
set_property PACKAGE_PIN AE33 [get_ports ddr4_clkref_n]

set_property PACKAGE_PIN AK27 [get_ports {ddr4_addr[0]}]
set_property PACKAGE_PIN AK32 [get_ports {ddr4_addr[1]}]
set_property PACKAGE_PIN AF30 [get_ports {ddr4_addr[2]}]
set_property PACKAGE_PIN Y33  [get_ports {ddr4_addr[3]}]
set_property PACKAGE_PIN AB34 [get_ports {ddr4_addr[4]}]
set_property PACKAGE_PIN AD34 [get_ports {ddr4_addr[5]}]
set_property PACKAGE_PIN AC32 [get_ports {ddr4_addr[6]}]
set_property PACKAGE_PIN AC33 [get_ports {ddr4_addr[7]}]
set_property PACKAGE_PIN AC31 [get_ports {ddr4_addr[8]}]
set_property PACKAGE_PIN AE30 [get_ports {ddr4_addr[9]}]
set_property PACKAGE_PIN W31  [get_ports {ddr4_addr[10]}]
set_property PACKAGE_PIN AD30 [get_ports {ddr4_addr[11]}]
set_property PACKAGE_PIN AA32 [get_ports {ddr4_addr[12]}]
set_property PACKAGE_PIN AD31 [get_ports {ddr4_addr[13]}]
set_property PACKAGE_PIN AJ34 [get_ports {ddr4_addr[14]}]
set_property PACKAGE_PIN W34  [get_ports {ddr4_addr[15]}]
set_property PACKAGE_PIN W33  [get_ports {ddr4_addr[16]}]

set_property PACKAGE_PIN AB32 [get_ports {ddr4_ba[0]}]
set_property PACKAGE_PIN AA34 [get_ports {ddr4_ba[1]}]
set_property PACKAGE_PIN AA33 [get_ports {ddr4_bg[0]}]
set_property PACKAGE_PIN Y31  [get_ports ddr4_act_n]
set_property PACKAGE_PIN Y32  [get_ports {ddr4_cs_n[0]}]
set_property PACKAGE_PIN W30  [get_ports {ddr4_cke[0]}]
set_property PACKAGE_PIN Y30  [get_ports {ddr4_odt[0]}]
set_property PACKAGE_PIN AU34 [get_ports ddr4_reset_n]
set_property PACKAGE_PIN AE31 [get_ports {ddr4_ck_t[0]}]
set_property PACKAGE_PIN AE32 [get_ports {ddr4_ck_c[0]}]

# Byte 0 (bank 61)
set_property PACKAGE_PIN AT29 [get_ports {ddr4_dq[0]}]
set_property PACKAGE_PIN AU31 [get_ports {ddr4_dq[1]}]
set_property PACKAGE_PIN AU30 [get_ports {ddr4_dq[2]}]
set_property PACKAGE_PIN AU32 [get_ports {ddr4_dq[3]}]
set_property PACKAGE_PIN AT30 [get_ports {ddr4_dq[4]}]
set_property PACKAGE_PIN AW31 [get_ports {ddr4_dq[5]}]
set_property PACKAGE_PIN AV31 [get_ports {ddr4_dq[6]}]
set_property PACKAGE_PIN AV32 [get_ports {ddr4_dq[7]}]
set_property PACKAGE_PIN AU29 [get_ports {ddr4_dqs_t[0]}]
set_property PACKAGE_PIN AV29 [get_ports {ddr4_dqs_c[0]}]
set_property PACKAGE_PIN AW29 [get_ports {ddr4_dm_dbi_n[0]}]
# Byte 1 (bank 61)
set_property PACKAGE_PIN AM31 [get_ports {ddr4_dq[8]}]
set_property PACKAGE_PIN AR30 [get_ports {ddr4_dq[9]}]
set_property PACKAGE_PIN AL29 [get_ports {ddr4_dq[10]}]
set_property PACKAGE_PIN AP29 [get_ports {ddr4_dq[11]}]
set_property PACKAGE_PIN AL30 [get_ports {ddr4_dq[12]}]
set_property PACKAGE_PIN AN31 [get_ports {ddr4_dq[13]}]
set_property PACKAGE_PIN AN29 [get_ports {ddr4_dq[14]}]
set_property PACKAGE_PIN AP30 [get_ports {ddr4_dq[15]}]
set_property PACKAGE_PIN AM29 [get_ports {ddr4_dqs_t[1]}]
set_property PACKAGE_PIN AM30 [get_ports {ddr4_dqs_c[1]}]
set_property PACKAGE_PIN AP31 [get_ports {ddr4_dm_dbi_n[1]}]
# Byte 2 (bank 61)
set_property PACKAGE_PIN BE30 [get_ports {ddr4_dq[16]}]
set_property PACKAGE_PIN BE32 [get_ports {ddr4_dq[17]}]
set_property PACKAGE_PIN BC29 [get_ports {ddr4_dq[18]}]
set_property PACKAGE_PIN BE33 [get_ports {ddr4_dq[19]}]
set_property PACKAGE_PIN BD29 [get_ports {ddr4_dq[20]}]
set_property PACKAGE_PIN BD33 [get_ports {ddr4_dq[21]}]
set_property PACKAGE_PIN BF30 [get_ports {ddr4_dq[22]}]
set_property PACKAGE_PIN BE31 [get_ports {ddr4_dq[23]}]
set_property PACKAGE_PIN BD30 [get_ports {ddr4_dqs_t[2]}]
set_property PACKAGE_PIN BD31 [get_ports {ddr4_dqs_c[2]}]
set_property PACKAGE_PIN BF32 [get_ports {ddr4_dm_dbi_n[2]}]
# Byte 3 (bank 61)
set_property PACKAGE_PIN BB29 [get_ports {ddr4_dq[24]}]
set_property PACKAGE_PIN BB31 [get_ports {ddr4_dq[25]}]
set_property PACKAGE_PIN BA29 [get_ports {ddr4_dq[26]}]
set_property PACKAGE_PIN BB30 [get_ports {ddr4_dq[27]}]
set_property PACKAGE_PIN AY30 [get_ports {ddr4_dq[28]}]
set_property PACKAGE_PIN AY32 [get_ports {ddr4_dq[29]}]
set_property PACKAGE_PIN AY31 [get_ports {ddr4_dq[30]}]
set_property PACKAGE_PIN BA30 [get_ports {ddr4_dq[31]}]
set_property PACKAGE_PIN BA32 [get_ports {ddr4_dqs_t[3]}]
set_property PACKAGE_PIN BB32 [get_ports {ddr4_dqs_c[3]}]
set_property PACKAGE_PIN BC31 [get_ports {ddr4_dm_dbi_n[3]}]
# Byte 4 (bank 62)
set_property PACKAGE_PIN AY36 [get_ports {ddr4_dq[32]}]
set_property PACKAGE_PIN AV34 [get_ports {ddr4_dq[33]}]
set_property PACKAGE_PIN AY35 [get_ports {ddr4_dq[34]}]
set_property PACKAGE_PIN AV33 [get_ports {ddr4_dq[35]}]
set_property PACKAGE_PIN BA33 [get_ports {ddr4_dq[36]}]
set_property PACKAGE_PIN AW33 [get_ports {ddr4_dq[37]}]
set_property PACKAGE_PIN AY33 [get_ports {ddr4_dq[38]}]
set_property PACKAGE_PIN AW34 [get_ports {ddr4_dq[39]}]
set_property PACKAGE_PIN AW35 [get_ports {ddr4_dqs_t[4]}]
set_property PACKAGE_PIN AW36 [get_ports {ddr4_dqs_c[4]}]
set_property PACKAGE_PIN BA34 [get_ports {ddr4_dm_dbi_n[4]}]
# Byte 5 (bank 62)
set_property PACKAGE_PIN AP34 [get_ports {ddr4_dq[40]}]
set_property PACKAGE_PIN AL34 [get_ports {ddr4_dq[41]}]
set_property PACKAGE_PIN AP33 [get_ports {ddr4_dq[42]}]
set_property PACKAGE_PIN AM34 [get_ports {ddr4_dq[43]}]
set_property PACKAGE_PIN AR33 [get_ports {ddr4_dq[44]}]
set_property PACKAGE_PIN AL32 [get_ports {ddr4_dq[45]}]
set_property PACKAGE_PIN AN34 [get_ports {ddr4_dq[46]}]
set_property PACKAGE_PIN AM32 [get_ports {ddr4_dq[47]}]
set_property PACKAGE_PIN AN32 [get_ports {ddr4_dqs_t[5]}]
set_property PACKAGE_PIN AN33 [get_ports {ddr4_dqs_c[5]}]
set_property PACKAGE_PIN AT33 [get_ports {ddr4_dm_dbi_n[5]}]
# Byte 6 (bank 63)
set_property PACKAGE_PIN AG31 [get_ports {ddr4_dq[48]}]
set_property PACKAGE_PIN AJ33 [get_ports {ddr4_dq[49]}]
set_property PACKAGE_PIN AF33 [get_ports {ddr4_dq[50]}]
set_property PACKAGE_PIN AH33 [get_ports {ddr4_dq[51]}]
set_property PACKAGE_PIN AG32 [get_ports {ddr4_dq[52]}]
set_property PACKAGE_PIN AG34 [get_ports {ddr4_dq[53]}]
set_property PACKAGE_PIN AF32 [get_ports {ddr4_dq[54]}]
set_property PACKAGE_PIN AF34 [get_ports {ddr4_dq[55]}]
set_property PACKAGE_PIN AH31 [get_ports {ddr4_dqs_t[6]}]
set_property PACKAGE_PIN AH32 [get_ports {ddr4_dqs_c[6]}]
set_property PACKAGE_PIN AH34 [get_ports {ddr4_dm_dbi_n[6]}]
# Byte 7 (bank 63)
set_property PACKAGE_PIN AJ28 [get_ports {ddr4_dq[56]}]
set_property PACKAGE_PIN AK31 [get_ports {ddr4_dq[57]}]
set_property PACKAGE_PIN AG29 [get_ports {ddr4_dq[58]}]
set_property PACKAGE_PIN AJ29 [get_ports {ddr4_dq[59]}]
set_property PACKAGE_PIN AG30 [get_ports {ddr4_dq[60]}]
set_property PACKAGE_PIN AJ31 [get_ports {ddr4_dq[61]}]
set_property PACKAGE_PIN AK28 [get_ports {ddr4_dq[62]}]
set_property PACKAGE_PIN AJ30 [get_ports {ddr4_dq[63]}]
set_property PACKAGE_PIN AH28 [get_ports {ddr4_dqs_t[7]}]
set_property PACKAGE_PIN AH29 [get_ports {ddr4_dqs_c[7]}]
set_property PACKAGE_PIN AJ27 [get_ports {ddr4_dm_dbi_n[7]}]

# --- ui_clk <-> dsp_clk CDC (dac_coef_subsys) ---------------------------------
# ENABLED 2026-08-14 (f9wb route review): these were staged before the MIG
# merge and never uncommented — the f9wb route timed the crossings against the
# raw 2 ps ui_clk/dsp_clk edge alignment (WNS -4.31). CDC audit (Step 4C.2):
# dac_coef_subsys has two toggle synchronizers (load_start, load_done) and one
# async FIFO (coef write bus) crossing between ui_clk (MIG user clock
# mmcm_clkout0, 3.332 ns = 300 MHz) and dsp_clk (3.875 ns).

# 1) load_start  dsp_clk -> ui_clk  (toggle sync)
set_max_delay -datapath_only 5.0 \
    -from [get_cells u_coef_subsys/load_start_toggle_dsp_reg] \
    -to   [get_cells {u_coef_subsys/load_start_sync_ui_reg[0]}]

# 2) load_done   ui_clk -> dsp_clk  (toggle sync, one dsp_clk period budget)
set_max_delay -datapath_only 3.5 \
    -from [get_cells u_coef_subsys/load_done_toggle_ui_reg] \
    -to   [get_cells {u_coef_subsys/load_done_sync_dsp_reg[0]}]

# 3+4) coef write bus ui_clk -> dsp_clk: ASYNC FIFO (2026-09-04, replaces the
#    per-write toggle sync + qualified bus, which lost writes at ui_clk 300 MHz
#    > dsp_clk 258 MHz — found by tb_vu13p_mig on the real MIG). Gray pointers
#    2-FF ASYNC_REG each way; LUTRAM written in ui_clk, read in dsp_clk after
#    the synced pointer guarantees stability. Same pattern/aliases as the
#    qspi_boot_loader FIFO below (gray MSB merges into the binary pointer).
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_coef_subsys/cf_wptr_gray_reg[*] u_coef_subsys/cf_wptr_bin_reg[*]}] \
    -to   [get_cells {u_coef_subsys/cf_wptr_gray_d1_reg[*]}]
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_coef_subsys/cf_rptr_gray_reg[*] u_coef_subsys/cf_rptr_bin_reg[*]}] \
    -to   [get_cells {u_coef_subsys/cf_rptr_gray_u1_reg[*]}]
#    f17 lesson (2026-09-05): synth merged the {wmac,waddr,wdata} FIFO output
#    registers into ONE vector named coef_waddr0_reg[*]; a -to on the RTL names
#    matched nothing and the 38 LUTRAM->register paths were timed at the raw
#    0.002 ns ui_clk/dsp_clk edge alignment (WNS -5.15). The LUTRAM's only
#    readers are those registers, so constrain -from the memory with no -to.
set_max_delay -datapath_only 3.3 \
    -from [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/cfifo_mem*}]

# 5) load request dsp_clk -> ui_clk (2026-09-02, directory lookup): the bank
#    manager latches {by_id, id[15:0]} in target_bank_reg at load_start and
#    holds it until load_done; the loader samples it only on its synced
#    load_start pulse (>= 3 ui_clk later). The SPI-side registers now enter
#    dsp_clk first (3-FF request sync in dac_coef_subsys, covered by the
#    blanket clk_200m -> dsp_clk false path above).
#    f15 lesson (2026-09-02): synth retimes the bank_base add into registers
#    named burst_addr__N (no _reg suffix) and the FSM extractor renames
#    state_reg -> FSM_sequential_state_reg; match on IS_SEQUENTIAL, not names.
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_coef_subsys/u_coef_mgr/target_bank_reg[*]}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/u_coef_loader/* && IS_SEQUENTIAL}]

# 5b) failed-load flag ui_clk -> dsp_clk: load_err is a level set >= 1 ui_clk
#     before the load_done toggle and sampled by the manager only on the
#     synced toggle edge.
set_max_delay -datapath_only 3.5 \
    -from [get_cells {u_coef_subsys/u_coef_loader/load_err_reg}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/u_coef_mgr/* && IS_SEQUENTIAL}]

# 5c) failed-load flag + code ui_clk -> clk_200m: level into a 2-FF sync in
#     dac_ctrl_plane; the 2-bit code is stable one ui_clk before the level
#     rises and is sampled on the synced rising edge.
set_false_path -to [get_pins {u_ctrl_plane/load_err_sync_reg[0]/D}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_coef_subsys/u_coef_loader/load_err_code_reg[*]}] \
    -to   [get_cells {u_ctrl_plane/err_info_reason_reg[*]}]

# 6) MIG calibration-complete ui_clk -> clk_200m: monotonic level into the
#    2-FF synchronizer in dac_ctrl_plane (added f9wc route review 2026-08-15).
set_false_path -to [get_pins {u_ctrl_plane/ddr4_calib_sync_reg[0]/D}]

set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/cell_test_req_reg[*] u_ctrl_plane/cell_test_cfg_reg[*]}] \
    -to [get_cells {u_dsp_core/cell_test_req_meta_reg[*] u_dsp_core/cell_test_applied_reg[*]}]
set_false_path -to [get_pins {u_ctrl_plane/cell_test_ack_meta_reg[*]/D}]
set_false_path -to [get_pins {u_bench_ctrl/ack_meta_reg/D bench_ctrl_meta_reg[*]/D}]
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_bench_ctrl/cmd_reg[*]}] \
    -to [get_cells {u_dsp_core/u_bench_stimulus/applied_reg[*]}]
set_false_path -to [get_pins {u_dsp_core/u_bench_stimulus/req_meta_reg/D}]

# --- clk_200m <-> dsp_clk CDC (cal_coef_store, Step 6.3/6.7 Aug 2026) ---------
# ARM-computed temperature-corrected cal coefficients: toggle-synchronized
# write/commit into dsp_clk, quasi-static readback and status coming back.

# 7) cal write + commit toggles clk_200m -> dsp_clk (3-FF chains in the store)
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/cal_wr_toggle_reg u_ctrl_plane/cal_commit_toggle_reg}] \
    -to   [get_cells {u_cal_store/wr_tg_sync_dsp_reg[0] u_cal_store/commit_tg_sync_dsp_reg[0]}]

# 8) cal write bus clk_200m -> dsp_clk: cal_wr_addr/wr_data are stable when the
#    toggle flips (one word per SPI frame, microseconds apart) and sampled only
#    on the synced wr_pulse 2-3 dsp_clk later — same pattern as the coef bus.
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/cal_wr_addr_reg[*] u_ctrl_plane/cal_wr_data_reg[*]}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_cal_store/mem*_reg*}]
set_false_path -to [get_pins {u_ctrl_plane/cal_write_reject_sync_reg[0]/D}]

# 9) cal readback address clk_200m -> dsp_clk: quasi-static SPI register
#    (written frames before the readback frame), resampled through 2 FFs.
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_ctrl_plane/cal_rd_addr_reg[*]}] \
    -to   [get_cells {u_cal_store/rd_addr_meta_reg[*]}]

# 10) cal readback data + status dsp_clk -> clk_200m: rd_data_dsp is
#     quasi-static after commit; active/pending are single-bit into 2-FF syncs.
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_cal_store/rd_data_dsp_reg[*]}] \
    -to   [get_cells {u_cal_store/rd_data_reg[*]}]
set_false_path -to [get_pins {u_cal_store/active_sync_ctrl_reg[0]/D u_cal_store/pending_sync_ctrl_reg[0]/D u_cal_store/cal_valid_sync_ctrl_reg[0]/D}]

# --- clk_200m <-> ui_clk CDC (qspi_boot_loader, 2026-08-22) -------------------
# Async FIFO gray pointers (2-FF ASYNC_REG chains each way)
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/wptr_gray_reg[*]}] \
    -to   [get_cells {u_boot_loader/wptr_gray_ui1_reg[*]}]
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/rptr_gray_reg[*]}] \
    -to   [get_cells {u_boot_loader/rptr_gray_c1_reg[*]}]
# gray[4] == bin[4] (bin2gray MSB), so synthesis merges the gray MSB register
# into the binary pointer register — the -from *gray_reg patterns miss that
# bit (f13b: last failing endpoint wptr_bin_reg[4] -> wptr_gray_ui1_reg[4]).
# Cover the alias with the sync FFs as tight -to scope (2026-08-24).
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/wptr_bin_reg[*]}] \
    -to   [get_cells {u_boot_loader/wptr_gray_ui1_reg[*]}]
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/rptr_bin_reg[*]}] \
    -to   [get_cells {u_boot_loader/rptr_gray_c1_reg[*]}]
# FIFO memory read: LUTRAM written in clk_200m, read in ui_clk after the gray
# pointer guarantees stability (datapath-only). SCOPE FIX (2026-08-23, f13):
# m_axi_wdata = fifo_rdata is combinational out of the module, so the real
# CDC endpoints are the AXI upsizer's ui_clk WDATA registers — the old
# "-to u_boot_loader/*wdata*" matched nothing and 513 endpoints were timed
# against the 0.336 ns unrelated-edge requirement (f12/f13 WNS -2.05 group).
set_max_delay -datapath_only 3.3 \
    -from [get_cells -hierarchical -filter {NAME =~ u_boot_loader/fifo_mem*}]
# Job toggle + stable job bus (addr/words set before the toggle flips)
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/job_toggle_reg}] \
    -to   [get_cells {u_boot_loader/job_sync_ui_reg[0]}]
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/job_addr_reg[*] u_boot_loader/job_words_reg[*]}] \
    -to   [get_cells {u_boot_loader/w_addr_reg[*] u_boot_loader/w_words_left_reg[*]}]
# Done toggle + quasi-static job_err back to clk_200m
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_boot_loader/done_toggle_ui_reg}] \
    -to   [get_cells {u_boot_loader/done_sync_c_reg[0]}]
set_false_path -to [get_pins {u_boot_loader/job_err_sync_reg[0]/D}]
# Boot gate levels into clk_200m (monotonic): MIG calib + STARTUPE3 EOS
set_false_path -to [get_pins {calib_sync_boot_reg[0]/D eos_sync_boot_reg[0]/D}]

# DPD enable level clk_200m -> dsp_clk (2-FF sync, Step 4D.1)
set_false_path -to [get_pins {dpd_en_sync_ff_reg[0]/D}]

# Halfband product -> accumulator is a true 2-cycle path (2026-08-24, f13d):
# products/center_product load on valid_pipe[0], acc_filtered captures on
# valid_pipe[2] — exactly 2 clocks later — and halfband input spacing is
# hundreds of dsp_clk cycles (audio-rate in_valid), so no intermediate
# capture exists. f13b-d left 25 of these endpoints at -0.031 (11 levels:
# DSP_OUTPUT + 7xCARRY8 48-bit adder tree).
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/products_reg* || NAME =~ u_dsp_core/u_hb*/center_product_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/acc_filtered_reg*}]
set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/products_reg* || NAME =~ u_dsp_core/u_hb*/center_product_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/acc_filtered_reg*}]

# -----------------------------------------------------------------------------
# 10. User LED (debug / status indicator)
# -----------------------------------------------------------------------------
# BC33 is in bank 61, which the SOM powers at VCCO=1.2 V for DDR4 (C0).
# The user LED must therefore be LVCMOS12 (BIVC-1 DRC otherwise).
set_property IOSTANDARD LVCMOS12 [get_ports led_status]
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
# 11b. Carrier coefficient flash (bom item 18/18a, 2026-10-05)
#      1..4 x Micron MT25QU02G on one x1 bus, bank 70 (J1, VCCIO_70 = V18;
#      bank was 51/51 free, no cascode or clock neighbours). All four CS
#      populated (4 x 2 Gb = 8 Gb = 90 filters at 10M taps; need 60+ = 30
#      designs x {44.1k, 48k}; ruled 2026-10-05). SCK is a
#      user-IO forwarded copy of the engine clock, driven from an IOB
#      register together with CS/MOSI (vu13p_dac_top cf_*_q).
#      Engine rate for this target: clk_200m/8 = 25 MHz (qspi_flash_ctrl
#      CF_CKDIV_LOG2 = 3). Series 33 R on CF_CLK, 10k pull-ups on CS_n/DQ2/DQ3.
# -----------------------------------------------------------------------------
set_property IOSTANDARD LVCMOS18 [get_ports {cf_sck cf_cs_n[*] cf_dq[*]}]
set_property DRIVE       8       [get_ports {cf_sck cf_cs_n[*] cf_dq[*]}]
set_property SLEW        FAST    [get_ports {cf_sck cf_dq[*]}]
set_property SLEW        SLOW    [get_ports {cf_cs_n[*]}]
set_property PACKAGE_PIN J35     [get_ports cf_sck]         ;# B70_L3_P  J1-A20
set_property PACKAGE_PIN J36     [get_ports {cf_cs_n[0]}]   ;# B70_L3_N  J1-A19
set_property PACKAGE_PIN H37     [get_ports {cf_cs_n[1]}]   ;# B70_L1_P  J1-A26
set_property PACKAGE_PIN H38     [get_ports {cf_cs_n[2]}]   ;# B70_L1_N  J1-A25
set_property PACKAGE_PIN G37     [get_ports {cf_cs_n[3]}]   ;# B70_L2_P  J1-B29
set_property PACKAGE_PIN H36     [get_ports {cf_dq[0]}]     ;# B70_L4_P  J1-A23  MOSI
set_property PACKAGE_PIN G36     [get_ports {cf_dq[1]}]     ;# B70_L4_N  J1-A22  MISO
set_property PACKAGE_PIN H34     [get_ports {cf_dq[2]}]     ;# B70_L5_P  J1-B20  WP#
set_property PACKAGE_PIN G34     [get_ports {cf_dq[3]}]     ;# B70_L5_N  J1-B19  HOLD#/RESET#

# Timing: the forwarded SCK is an ordinary registered output (not a clock
# in the STA sense). Outputs leave the same IOB register set on clk_200m, so
# the SCK/MOSI/CS relationship is fixed by the engine (MOSI changes on the
# SCK-low half, 20 ns before the rising edge). MISO is sampled by the engine
# 20 ns after the SCK falling edge it launched; budget = 20 ns - t_CLQV(7 ns)
# - clk-to-out(~4 ns) - 2x connector/trace(~2 ns) - IBUF+route(~4 ns) ≈ 3 ns
# slack at 25 MHz. Constrain the MISO input as a system-synchronous path to
# clk_200m with the external delay accounted for (max = tco + tCLQV + trace).
set_input_delay  -clock [get_clocks clk_200m] \
    -max 13.0 [get_ports {cf_dq[1]}]
set_input_delay  -clock [get_clocks clk_200m] \
    -min  1.0 [get_ports {cf_dq[1]}]
# The engine samples MISO on a 25 MHz tick: 4 clk_200m cycles after the
# launching register edge -> multicycle 4 (setup) / 3 (hold) on this path.
set_multicycle_path 4 -setup -from [get_ports {cf_dq[1]}] \
    -to [get_cells -hierarchical -filter {NAME =~ u_flash_ctrl/rx_sr_reg[*]}]
set_multicycle_path 3 -hold  -from [get_ports {cf_dq[1]}] \
    -to [get_cells -hierarchical -filter {NAME =~ u_flash_ctrl/rx_sr_reg[*]}]
# Outputs: quasi-static relationship to the flash is set by the engine's
# 20 ns half-period, not by clk_200m; only require they stay in the IOB.
set_output_delay -clock [get_clocks clk_200m] \
    -max 2.0 [get_ports {cf_sck cf_cs_n[*] cf_dq[0]}]
set_output_delay -clock [get_clocks clk_200m] \
    -min 0.0 [get_ports {cf_sck cf_cs_n[*] cf_dq[0]}]
set_false_path -to [get_ports {cf_dq[2] cf_dq[3]}]

# -----------------------------------------------------------------------------
# 12. Bitstream / Configuration
# -----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4       [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE   31.9     [current_design]
set_property BITSTREAM.GENERAL.COMPRESS    TRUE     [current_design]
set_property CONFIG_VOLTAGE                1.8      [current_design]
set_property CFGBVS                        GND      [current_design]

# Multiboot / golden fallback (2026-08-22 — field bin updates over ARM SPI):
# Flash 0 layout: golden image at 0x0000_0000 (write-protected by ARM policy,
# never field-updated), update image at 0x0400_0000. The GOLDEN build sets
# NEXT_CONFIG_ADDR to the update image; a corrupted/incomplete update image
# falls back to the golden image automatically (CONFIGFALLBACK). The UPDATE
# image (this build class) enables fallback only.
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
# Golden-build only (leave commented for update builds):
# set_property BITSTREAM.CONFIG.NEXT_CONFIG_ADDR 0x04000000 [current_design]
