# ==============================================================================
# ARTIX-7 REFERENCE DAC MASTER CONSTRAINTS (.XDC)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. PHYSICAL I/O CONSTRAINTS (VOLTAGE & LOCATION)
# ------------------------------------------------------------------------------

# --- Master Clocks (Bank 34/35 - Requires High Range 2.5V/3.3V for LVDS_25) ---
# Note: DIFF_TERM is handled internally by the IBUFGDS in the SystemVerilog
set_property PACKAGE_PIN A1 [get_ports clk_49m_p]
set_property IOSTANDARD LVDS_25 [get_ports clk_49m_p]

set_property PACKAGE_PIN B1 [get_ports clk_45m_p]
set_property IOSTANDARD LVDS_25 [get_ports clk_45m_p]

# --- Administrative Control Plane (Bank 14/15 - 3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports ext_rst_n]
set_property PACKAGE_PIN C1 [get_ports ext_rst_n]

set_property IOSTANDARD LVCMOS33 [get_ports spi_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]
# Add SPI PACKAGE_PIN locations here...

# --- Hardware Relays & Sensors (3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports {blade_detect_pins[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports relay_iv_filter]
set_property IOSTANDARD LVCMOS33 [get_ports relay_gain_6v]
# Add Relay/Sensor PACKAGE_PIN locations here...

# --- I2S Audio Ingress (3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_lrclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_data]
# Add I2S PACKAGE_PIN locations here...

# --- High-Speed LVDS Egress to Blades (Bank 13/14 - 2.5V Domain) ---
# 8 Data Lanes + 1 Strobe Clock
set_property IOSTANDARD LVDS_25 [get_ports {lvds_tx_p[*]}]
set_property SLEW FAST [get_ports {lvds_tx_p[*]}]
# Add LVDS PACKAGE_PIN locations here... (Only need to define the _p pin, Vivado infers the _n)

# ------------------------------------------------------------------------------
# 2. TIMING ASSERTIONS & CLOCK CREATION
# ------------------------------------------------------------------------------

# Create the physical base clocks entering the FPGA. 
# Vivado will automatically track these through the MMCM and derive the 
# 98MHz DSP clock and the 393MHz LVDS Bit Clock.
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m_p]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m_p]

# Create the asynchronous I2S Boundary Clock
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]

# Create the slow administrative SPI Clock
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# ------------------------------------------------------------------------------
# 3. CLOCK EXCEPTIONS & CROSS-DOMAIN RULES (THE CRITICAL PATH)
# ------------------------------------------------------------------------------

# RULE 1: The Glitch-Free Mux Exception
# By default, Vivado tries to analyze what happens if clk_49m and clk_45m 
# interact. Because they feed into a BUFGMUX, they are physically mutually exclusive.
# We MUST tell Vivado they never exist on the chip at the same time.
set_clock_groups -physically_exclusive -group [get_clocks clk_49m] -group [get_clocks clk_45m]

# RULE 2: The Async FIFO Moat
# The I2S clock domain and the DSP clock domain are safely isolated by our async_fifo. 
# We tell Vivado to ignore timing paths that cross this boundary to save routing time.
set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks clk_49m clk_45m]

# RULE 3: The SPI Control Domain
# The SPI registers change at human speeds. We treat the entire SPI domain 
# as asynchronous to the high-speed DSP domain.
set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks clk_49m clk_45m]

# RULE 4: Hardware Control Pins
# Relays and blade detection pins do not need picosecond timing analysis.
set_false_path -from [get_ports {blade_detect_pins[*]}]
set_false_path -to [get_ports relay_iv_filter]
set_false_path -to [get_ports relay_gain_6v]