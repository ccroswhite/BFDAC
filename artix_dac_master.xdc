# ==============================================================================
# ARTIX-7 REFERENCE DAC MASTER CONSTRAINTS (.XDC)
# ARCHITECTURE: 1-Million Tap Polyphase Interpolator + 2nd Order DEM
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. PHYSICAL I/O CONSTRAINTS (VOLTAGE & LOCATION)
# ------------------------------------------------------------------------------
# Note: Replace "PACKAGE_PIN XX" with your actual schematic netlist pins.

# --- Master Clocks (Requires 2.5V or 3.3V High Range Bank for LVDS_25 / LVCMOS) ---
set_property PACKAGE_PIN A1 [get_ports clk_49m_p]
set_property IOSTANDARD LVDS_25 [get_ports clk_49m_p]

set_property PACKAGE_PIN B1 [get_ports clk_45m_p]
set_property IOSTANDARD LVDS_25 [get_ports clk_45m_p]

# --- Administrative Control Plane (3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports ext_rst_n]
set_property PACKAGE_PIN C1 [get_ports ext_rst_n]

set_property IOSTANDARD LVCMOS33 [get_ports spi_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]

# --- Hardware Relays & Sensors (3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports {blade_detect_pins[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports relay_iv_filter]
set_property IOSTANDARD LVCMOS33 [get_ports relay_gain_6v]

# --- I2S Audio Ingress (3.3V Domain) ---
set_property IOSTANDARD LVCMOS33 [get_ports i2s_bclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_lrclk]
set_property IOSTANDARD LVCMOS33 [get_ports i2s_data]

# --- High-Speed LVDS Egress to Blades (Requires 2.5V Bank) ---
# 8 Data Lanes + 1 Strobe Clock
# SLEW FAST is mandatory to preserve the eye diagram at ~400 MHz
set_property IOSTANDARD LVDS_25 [get_ports {lvds_tx_p[*]}]
set_property SLEW FAST [get_ports {lvds_tx_p[*]}]

# ------------------------------------------------------------------------------
# 2. TIMING ASSERTIONS & CLOCK CREATION
# ------------------------------------------------------------------------------

# Define the physical base clocks entering the FPGA pins.
# Vivado's MMCM primitive will automatically derive the 90.3MHz / 98.3MHz DSP 
# clocks and the 361MHz / 393MHz LVDS Bit Clocks from these definitions.
create_clock -period 20.345 -name clk_49m -waveform {0.000 10.172} [get_ports clk_49m_p]
create_clock -period 22.144 -name clk_45m -waveform {0.000 11.072} [get_ports clk_45m_p]

# Define the asynchronous I2S Boundary Clock (Example: 24.576 MHz / 64 bits = ~384 kHz max)
create_clock -period 40.690 -name i2s_bclk [get_ports i2s_bclk]

# Define the slow administrative SPI Clock (e.g., 10 MHz)
create_clock -period 100.000 -name spi_sclk [get_ports spi_sclk]

# ------------------------------------------------------------------------------
# 3. CLOCK EXCEPTIONS & CROSS-DOMAIN RULES (THE CRITICAL PATH)
# ------------------------------------------------------------------------------

# RULE 1: The Glitch-Free Mux Exception (CRITICAL)
# Instructs Vivado that the 45MHz and 49MHz families never physically interact.
# This forces the timing analyzer to verify the 1-Million tap FIR engine at 
# both 90.3MHz and 98.3MHz independently without throwing setup/hold errors.
set_clock_groups -physically_exclusive -group [get_clocks clk_49m] -group [get_clocks clk_45m]

# RULE 2: The Async FIFO Moat
# The I2S clock domain and the DSP clock domain are safely isolated by our async_fifo.
# We instruct Vivado to ignore paths crossing this boundary.
set_clock_groups -asynchronous -group [get_clocks i2s_bclk] -group [get_clocks -include_generated_clocks clk_49m clk_45m]

# RULE 3: The SPI Control Domain
# The SPI registers change at human/ARM speeds and cross into the DSP domain via 
# multi-cycle paths or stable registers.
set_clock_groups -asynchronous -group [get_clocks spi_sclk] -group [get_clocks -include_generated_clocks clk_49m clk_45m]

# RULE 4: Hardware Control Pins
# Relays and blade detection pins do not require high-speed timing analysis.
set_false_path -from [get_ports {blade_detect_pins[*]}]
set_false_path -to [get_ports relay_iv_filter]
set_false_path -to [get_ports relay_gain_6v]