# ==============================================================================
# ARTIX-7 MASTER CONSTRAINTS - CLEAN SLATE
# ==============================================================================

# 0. FPGA CONFIGURATION
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# 1. 3.3V I/O (CLOCKS, SPI, I2S, RELAYS)
set_property IOSTANDARD LVCMOS33 [get_ports clk_49m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_45m]

set_property IOSTANDARD LVCMOS33 [get_ports spi_*]
set_property SLEW SLOW [get_ports spi_miso]

set_property IOSTANDARD LVCMOS33 [get_ports i2s_*]
set_property IOSTANDARD LVCMOS33 [get_ports ext_rst_n]

set_property IOSTANDARD LVCMOS33 [get_ports relay_*]
set_property DRIVE 12 [get_ports relay_*]
set_property SLEW SLOW [get_ports relay_*]

# 2. 2.5V I/O (LVDS EGRESS)
set_property IOSTANDARD LVDS_25 [get_ports lvds_*]

# 3. BASE CLOCKS
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m]
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# Clock Domain Exclusivity
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]
set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]
set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]

# Explicitly sever the orphaned MMCM generated clocks
set_clock_groups -physically_exclusive \
    -group [get_clocks dsp_clk_unbuf] \
    -group [get_clocks dsp_clk_unbuf_1]

# Explicitly sever the SPI Control Plane from ALL generated DSP clocks
set_false_path -from [get_clocks clk_49m] -to [get_clocks *dsp_clk*]
set_false_path -from [get_clocks clk_45m] -to [get_clocks *dsp_clk*]

# Sledgehammer: Kill the BUFGMUX Ghost Paths using wildcards
set_false_path -from [get_clocks *dsp_clk_unbuf*] -to [get_clocks *dsp_clk_unbuf_1*]
set_false_path -from [get_clocks *dsp_clk_unbuf_1*] -to [get_clocks *dsp_clk_unbuf*]
set_false_path -from [get_clocks *lvds_clk_unbuf*] -to [get_clocks *lvds_clk_unbuf_1*]
set_false_path -from [get_clocks *lvds_clk_unbuf_1*] -to [get_clocks *lvds_clk_unbuf*]

# Asynchronous Boundary between 357MHz DSP and 196.6MHz LVDS Egress
set_clock_groups -asynchronous -group [get_clocks *dsp_clk*] -group [get_clocks *lvds_clk*]

# 4. ASYNC FIFO CDC SEVERING (Bulletproof Cell-Based Targeting)
# This safely severs the pointers without relying on Vivado's auto-generated clock names.
set_false_path -from [get_cells -hierarchical *w_ptr_gray_reg*] -to [get_cells -hierarchical *w_ptr_gray_sync1_reg*]
set_false_path -from [get_cells -hierarchical *r_ptr_gray_reg*] -to [get_cells -hierarchical *r_ptr_gray_sync1_reg*]

# 5. LVDS TIMING BOUNDARIES
# Generate the forwarded clock directly from the MMCM to ensure perfect phase tracking
create_generated_clock -name fwd_lvds_clk -source [get_pins u_clk_gen/u_mmcm/CLKOUT1] -multiply_by 1 [get_ports lvds_bclk_p]

set_output_delay -clock fwd_lvds_clk -max 1.500 [get_ports lvds_data_*_p]
set_output_delay -clock fwd_lvds_clk -min -0.500 [get_ports lvds_data_*_p]
set_output_delay -clock fwd_lvds_clk -max 1.500 [get_ports lvds_sync_p]
set_output_delay -clock fwd_lvds_clk -min -0.500 [get_ports lvds_sync_p]

# 6. IOB PACKING & PACKAGE PINS
set_property IOB TRUE [get_ports lvds_data_*_p]
set_property IOB TRUE [get_ports lvds_sync_p]

# Force LVDS transmission flip-flops into the physical pad IOBs
set_property IOB TRUE [get_ports lvds_data_l_p]
set_property IOB TRUE [get_ports lvds_data_r_p]
set_property IOB TRUE [get_ports lvds_sync_p]

# ==============================================================================
# 7. MULTICYCLE PATHS (The 128-Cycle Oversampled DSP Domain)
# ==============================================================================
# Filter for ONLY sequential elements (flip-flops) inside the slow logic blocks
set slow_dsp_cells [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*(u_noise_shaper|u_dem_mapper|u_dither).*.*}]

# Relax the internal feedback loops to 128 clock cycles (358ns)
set_multicycle_path -setup 128 -from $slow_dsp_cells -to $slow_dsp_cells
set_multicycle_path -hold 127 -from $slow_dsp_cells -to $slow_dsp_cells

# Relax the path from the Holding Register into the Noise Shaper math tree
set_multicycle_path -setup 128 -from [get_cells *stable_audio_64b_reg*] -to $slow_dsp_cells
set_multicycle_path -hold 127 -from [get_cells *stable_audio_64b_reg*] -to $slow_dsp_cells

# Relax timing for the FIFOs for the DEM mapper
# Relax the massive 512-bit bus routing from the DEM mapper into the Async FIFO
set_multicycle_path -setup 128 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]
set_multicycle_path -hold 127 -from [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_dem_mapper.*}] -to [get_cells -hierarchical -filter {IS_SEQUENTIAL == 1} -regexp {.*u_output_fifo.*}]

# ==============================================================================
# 8. EXCLUSIVE CLOCK DOMAINS (BUFGMUX Isolation)
# ==============================================================================
# The 45.158MHz and 49.152MHz families are physically mutually exclusive.
# This prevents Vivado from analyzing impossible inter-clock paths.
set_clock_groups -physically_exclusive \
    -group [get_clocks -include_generated_clocks clk_45m] \
    -group [get_clocks -include_generated_clocks clk_49m]

# set pins
set_property PACKAGE_PIN L3 [get_ports lvds_bclk_p]
set_property PACKAGE_PIN K3 [get_ports lvds_bclk_n]
set_property PACKAGE_PIN B1 [get_ports lvds_data_l_p]
set_property PACKAGE_PIN A1 [get_ports lvds_data_l_n]
set_property PACKAGE_PIN C2 [get_ports lvds_data_r_p]
set_property PACKAGE_PIN B2 [get_ports lvds_data_r_n]
set_property PACKAGE_PIN E1 [get_ports lvds_sync_p]
set_property PACKAGE_PIN D1 [get_ports lvds_sync_n]
set_property PACKAGE_PIN D17 [get_ports clk_45m]
set_property PACKAGE_PIN C18 [get_ports clk_49m]
set_property PACKAGE_PIN K19 [get_ports i2s_data]
set_property PACKAGE_PIN L20 [get_ports ext_rst_n]
set_property PACKAGE_PIN J19 [get_ports i2s_lrclk]
set_property PACKAGE_PIN K18 [get_ports i2s_bclk]
set_property PACKAGE_PIN J16 [get_ports spi_cs_n]
set_property PACKAGE_PIN G16 [get_ports spi_sclk]
set_property PACKAGE_PIN G13 [get_ports spi_miso]
set_property PACKAGE_PIN H13 [get_ports spi_mosi]
set_property PACKAGE_PIN R6 [get_ports relay_gain_6v]
set_property PACKAGE_PIN AA6 [get_ports relay_audio_out]