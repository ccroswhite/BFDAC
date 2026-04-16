# ==============================================================================
# ARTIX-7 (XC7A200T-FBG484) - SYNTHESIS ONLY CONSTRAINTS
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

# ------------------------------------------------------------------------------
# 1. I/O STANDARDS (3.3V DOMAIN)
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
set_property IOSTANDARD LVCMOS33 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_lrclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_data]
set_property IOSTANDARD LVCMOS33 [get_ports ext_rst_n]

# Relays & Sensors
set_property IOSTANDARD LVCMOS33 [get_ports relay_iv_filter]
set_property IOSTANDARD LVCMOS33 [get_ports relay_gain_6v]
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
# 3. TIMING ASSERTIONS
# ------------------------------------------------------------------------------
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m]
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# Clock Domain Exclusivity
set_clock_groups -physically_exclusive -group [get_clocks clk_49m] -group [get_clocks clk_45m]
set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]
set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks {clk_49m clk_45m}]

# Slow paths
set_false_path -from [get_ports {blade_detect_pins[*]}]
set_false_path -to [get_ports relay_iv_filter]
set_false_path -to [get_ports relay_gain_6v]

set_property PACKAGE_PIN B1 [get_ports {lvds_clk_p[0]}]
set_property PACKAGE_PIN A1 [get_ports {lvds_clk_n[0]}]
set_property PACKAGE_PIN C2 [get_ports {lvds_clk_p[3]}]
set_property PACKAGE_PIN B2 [get_ports {lvds_clk_n[3]}]
set_property PACKAGE_PIN E1 [get_ports {lvds_clk_p[2]}]
set_property PACKAGE_PIN D1 [get_ports {lvds_clk_n[2]}]
set_property PACKAGE_PIN E2 [get_ports {lvds_clk_p[1]}]
set_property PACKAGE_PIN D2 [get_ports {lvds_clk_n[1]}]
set_property PACKAGE_PIN L3 [get_ports {lvds_frame_p[0]}]
set_property PACKAGE_PIN K3 [get_ports {lvds_frame_n[0]}]
set_property PACKAGE_PIN G1 [get_ports {lvds_frame_p[3]}]
set_property PACKAGE_PIN F1 [get_ports {lvds_frame_n[3]}]
set_property PACKAGE_PIN F3 [get_ports {lvds_frame_p[2]}]
set_property PACKAGE_PIN E3 [get_ports {lvds_frame_n[2]}]
set_property PACKAGE_PIN K1 [get_ports {lvds_frame_p[1]}]
set_property PACKAGE_PIN J1 [get_ports {lvds_frame_n[1]}]
set_property PACKAGE_PIN H2 [get_ports {lvds_data_p[0]}]
set_property PACKAGE_PIN G2 [get_ports {lvds_data_n[0]}]
set_property PACKAGE_PIN J5 [get_ports {lvds_data_p[2]}]
set_property PACKAGE_PIN H5 [get_ports {lvds_data_n[2]}]
set_property PACKAGE_PIN K2 [get_ports {lvds_data_p[3]}]
set_property PACKAGE_PIN J2 [get_ports {lvds_data_n[3]}]
set_property PACKAGE_PIN H3 [get_ports {lvds_data_p[1]}]
set_property PACKAGE_PIN G3 [get_ports {lvds_data_n[1]}]
set_property PACKAGE_PIN R3 [get_ports {lvds_data_p[5]}]
set_property PACKAGE_PIN R2 [get_ports {lvds_data_n[5]}]
set_property PACKAGE_PIN T1 [get_ports {lvds_data_p[7]}]
set_property PACKAGE_PIN U1 [get_ports {lvds_data_n[7]}]
set_property PACKAGE_PIN U2 [get_ports {lvds_data_p[6]}]
set_property PACKAGE_PIN V2 [get_ports {lvds_data_n[6]}]
set_property PACKAGE_PIN W2 [get_ports {lvds_data_p[4]}]
set_property PACKAGE_PIN Y2 [get_ports {lvds_data_n[4]}]
set_property PACKAGE_PIN W1 [get_ports {lvds_clk_p[7]}]
set_property PACKAGE_PIN Y1 [get_ports {lvds_clk_n[7]}]
set_property PACKAGE_PIN Y4 [get_ports {lvds_clk_p[4]}]
set_property PACKAGE_PIN AA4 [get_ports {lvds_clk_n[4]}]
set_property PACKAGE_PIN AA1 [get_ports {lvds_clk_p[5]}]
set_property PACKAGE_PIN AB1 [get_ports {lvds_clk_n[5]}]
set_property PACKAGE_PIN U3 [get_ports {lvds_clk_p[6]}]
set_property PACKAGE_PIN V3 [get_ports {lvds_clk_n[6]}]
set_property PACKAGE_PIN Y6 [get_ports {lvds_frame_p[4]}]
set_property PACKAGE_PIN AA6 [get_ports {lvds_frame_n[4]}]
set_property PACKAGE_PIN AB3 [get_ports {lvds_frame_p[7]}]
set_property PACKAGE_PIN AB2 [get_ports {lvds_frame_n[7]}]
set_property PACKAGE_PIN Y3 [get_ports {lvds_frame_p[6]}]
set_property PACKAGE_PIN AA3 [get_ports {lvds_frame_n[6]}]
set_property PACKAGE_PIN AA5 [get_ports {lvds_frame_p[5]}]
set_property PACKAGE_PIN AB5 [get_ports {lvds_frame_n[5]}]

set_property PACKAGE_PIN G20 [get_ports {hyper_dq[2]}]
set_property PACKAGE_PIN M21 [get_ports {hyper_dq[7]}]
set_property PACKAGE_PIN H22 [get_ports {hyper_dq[0]}]
set_property PACKAGE_PIN L21 [get_ports {hyper_dq[6]}]
set_property PACKAGE_PIN H20 [get_ports {hyper_dq[3]}]
set_property PACKAGE_PIN K21 [get_ports {hyper_dq[5]}]
set_property PACKAGE_PIN J22 [get_ports {hyper_dq[1]}]
set_property PACKAGE_PIN K22 [get_ports {hyper_dq[4]}]
set_property PACKAGE_PIN L15 [get_ports hyper_reset_n]
set_property PACKAGE_PIN K16 [get_ports hyper_ck]
set_property PACKAGE_PIN L14 [get_ports hyper_cs_n]
set_property PACKAGE_PIN J16 [get_ports hyper_rwds]
set_property PACKAGE_PIN B22 [get_ports spi_mosi]
set_property PACKAGE_PIN C22 [get_ports spi_miso]
set_property PACKAGE_PIN A21 [get_ports spi_cs_n]
set_property PACKAGE_PIN B21 [get_ports spi_sclk]
set_property PACKAGE_PIN F15 [get_ports i2s_lrclk]
set_property PACKAGE_PIN F14 [get_ports i2s_data]
set_property PACKAGE_PIN E21 [get_ports ext_rst_n]
set_property PACKAGE_PIN Y18 [get_ports clk_45m]
set_property PACKAGE_PIN U20 [get_ports clk_49m]
set_property PACKAGE_PIN Y14 [get_ports {blade_detect_pins[7]}]
set_property PACKAGE_PIN AA14 [get_ports {blade_detect_pins[5]}]
set_property PACKAGE_PIN Y13 [get_ports {blade_detect_pins[6]}]
set_property PACKAGE_PIN AA15 [get_ports {blade_detect_pins[4]}]
set_property PACKAGE_PIN AB15 [get_ports {blade_detect_pins[3]}]
set_property PACKAGE_PIN AA13 [get_ports {blade_detect_pins[2]}]
set_property PACKAGE_PIN AB13 [get_ports {blade_detect_pins[1]}]
set_property PACKAGE_PIN AB16 [get_ports {blade_detect_pins[0]}]
set_property PACKAGE_PIN Y17 [get_ports relay_iv_filter]
set_property PACKAGE_PIN Y16 [get_ports relay_gain_6v]
set_property DRIVE 12 [get_ports relay_gain_6v]

set_property PACKAGE_PIN E19 [get_ports i2s_bclk]