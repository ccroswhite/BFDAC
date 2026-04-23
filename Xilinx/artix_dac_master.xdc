# ==============================================================================
# ARTIX-7 (XC7A200T-FBG484) - MASTER CONSTRAINTS
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. FPGA CONFIGURATION & AUTONOMOUS BOOT (MultiBoot Enabled)
# ------------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 66 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]

set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
set_property BITSTREAM.CONFIG.NEXT_CONFIG_ADDR 0x00400000 [current_design]

set_property IOSTANDARD LVCMOS33 [get_ports qspi_*_n]
set_property IOSTANDARD LVCMOS33 [get_ports qspi_mosi*]
set_property IOSTANDARD LVCMOS33 [get_ports qspi_miso]

# ------------------------------------------------------------------------------
# 1. I/O STANDARDS & SLEW RATES (3.3V DOMAIN)
# ------------------------------------------------------------------------------
# Clocks
set_property IOSTANDARD LVCMOS33 [get_ports clk_49m]
set_property IOSTANDARD LVCMOS33 [get_ports clk_45m]

# HyperRAM
set_property IOSTANDARD LVCMOS33 [get_ports hyper_ck]
set_property IOSTANDARD LVCMOS33 [get_ports hyper_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports hyper_rwds]
set_property IOSTANDARD LVCMOS33 [get_ports {hyper_dq[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports hyper_reset_n]

# SPI & I2S & Reset
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]
set_property SLEW SLOW [get_ports spi_miso]

set_property IOSTANDARD LVCMOS33 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_lrclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_data]
set_property IOSTANDARD LVCMOS33 [get_ports ext_rst_n]

# Relays & Sensors (Slow Slew Rate to prevent EMI injection into analog domain)
set_property IOSTANDARD LVCMOS33 [get_ports relay_iv_filter]
set_property SLEW SLOW [get_ports relay_iv_filter]

set_property IOSTANDARD LVCMOS33 [get_ports relay_gain_6v]
set_property DRIVE 12 [get_ports relay_gain_6v]
set_property SLEW SLOW [get_ports relay_gain_6v]

set_property IOSTANDARD LVCMOS33 [get_ports relay_audio_out]
set_property DRIVE 12 [get_ports relay_audio_out]
set_property SLEW SLOW [get_ports relay_audio_out]

set_property IOSTANDARD LVCMOS33 [get_ports {blade_detect_pins[*]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[7]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[6]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[5]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[4]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[3]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[2]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[1]}]
set_property PULLTYPE PULLDOWN [get_ports {blade_detect_pins[0]}]

# ------------------------------------------------------------------------------
# 2. I/O STANDARDS (2.5V DOMAIN)
# ------------------------------------------------------------------------------
# LVDS Egress
set_property IOSTANDARD LVDS_25 [get_ports {lvds_data_p[*]}]
set_property IOSTANDARD LVDS_25 [get_ports {lvds_clk_p[*]}]
set_property IOSTANDARD LVDS_25 [get_ports {lvds_frame_p[*]}]

# ------------------------------------------------------------------------------
# 3. BASE TIMING ASSERTIONS
# ------------------------------------------------------------------------------
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m]
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# Clock Domain Exclusivity
# set_clock_groups -physically_exclusive -group [get_clocks clk_49m] -group [get_clocks clk_45m]
# set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]
# set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]

# Tell Vivado the two baseband families (and all downstream MMCM clocks) NEVER exist at the same time
set_clock_groups -physically_exclusive -group [get_clocks -include_generated_clocks clk_49m] -group [get_clocks -include_generated_clocks clk_45m]

# Tell Vivado that I2S and SPI are totally asynchronous to the DSP domains (ignore cross-domain timing)
set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]
set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]

# Slow paths
set_false_path -from [get_ports {blade_detect_pins[*]}]
set_false_path -to [get_ports relay_iv_filter]
set_false_path -to [get_ports relay_gain_6v]
set_false_path -to [get_ports relay_audio_out]

# ------------------------------------------------------------------------------
# 4. ADVANCED I/O TIMING BOUNDARIES (NEW)
# ------------------------------------------------------------------------------

# --- A. LVDS Forwarded Clocks & Output Delays ---
# Define the forwarded clock at the output pins so Vivado can phase-align the data.
# IMPORTANT: Update "-source" to the actual internal primitive pin driving the LVDS clock out.
# create_generated_clock -name fwd_lvds_clk -source [get_pins u_clk_gen/inst/clk_out_lvds] -divide_by 1 [get_ports {lvds_clk_p[*]}]
create_generated_clock -name fwd_lvds_clk -source [get_pins u_clk_gen/u_mmcm/CLKOUT0] -divide_by 1 [get_ports {lvds_clk_p[*]}]

# Define the Setup/Hold requirements of the MAX 10 receivers on the analog blades.
# (Adjust the 2.0ns and -1.0ns margins based on the MAX 10 datasheet and your target frequency)
set_output_delay -clock fwd_lvds_clk -max 2.0 [get_ports {lvds_data_p[*]}]
set_output_delay -clock fwd_lvds_clk -min -1.0 [get_ports {lvds_data_p[*]}]
set_output_delay -clock fwd_lvds_clk -max 2.0 [get_ports {lvds_frame_p[*]}]
set_output_delay -clock fwd_lvds_clk -min -1.0 [get_ports {lvds_frame_p[*]}]

# --- B. HyperRAM DDR Interface Framework ---
# HyperRAM requires strict source-synchronous constraints. You must populate these 
# values based on the specific IP core documentation you are using.
#