# ACKU15S-3 — Generate DDR4 MIG (ddr4_0) + AXI width converter for ACKU15S SOM
#   Topology: C0 controller, 5x Nanya NT5AD512M16C4-HR x16 = 80-bit non-ECC
#   (5 GB addressable), 2666 Mbps, on-module 200 MHz ref clk (AR32/AT32),
#   banks 66-68, xcku15p-ffve1517-2-i.
#   MemoryPart: Nanya NT5AD512M16C4-HR is not a MIG-listed part; using the
#   config-compatible Micron 8Gb x16 DDR4-2666 entry. VERIFY: if Vivado
#   rejects the part name, the error prints the valid list — pick the 8Gb x16
#   -075 (2666) part or move to a C0.DDR4_CustomParts CSV with Nanya timings.
#   AXI: for an 80-bit memory the slave caps at 64-bit (valid: 32, 64);
#   axi_dwc_coef bridges the 128-bit
#   read/write masters (coef_bank_loader, qspi_boot_loader).
#   Pins are NOT set here: PACKAGE_PINs live in acku15s_dac_top.xdc.
#   vivado -mode batch -source scripts/gen_ddr4_mig.tcl -journal gen_mig.jou -log gen_mig.log
set_param general.maxThreads 8

set ip_dir [file normalize "./ip"]
file mkdir $ip_dir

create_project -in_memory -part xcku15p-ffve1517-2-i
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------- ddr4_0
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_0 -dir $ip_dir
# Ordering matters: TimePeriod/InputClockPeriod FIRST (changing them later
# cascade-resets DataWidth back to the part default — observed dw=80 -> 8),
# then MemoryPart (sets x16 granularity so 80 is a valid DataWidth), then
# DataWidth, then AXI params (AxiDataWidth valid range depends on DataWidth:
# for 80-bit memory the slave caps at 64).
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod            {750} \
    CONFIG.C0.DDR4_InputClockPeriod      {5000} \
] [get_ips ddr4_0]
set_property CONFIG.C0.DDR4_MemoryPart {MT40A512M16LY-075} [get_ips ddr4_0]
set_property CONFIG.C0.DDR4_DataWidth  {80}                [get_ips ddr4_0]
set_property -dict [list \
    CONFIG.C0.DDR4_AxiSelection          {true} \
    CONFIG.C0.DDR4_AxiDataWidth          {64} \
    CONFIG.C0.DDR4_AxiIDWidth            {1} \
    CONFIG.C0.DDR4_AxiArbitrationScheme  {RD_PRI_REG} \
] [get_ips ddr4_0]
puts "CHECK part=[get_property CONFIG.C0.DDR4_MemoryPart [get_ips ddr4_0]] dw=[get_property CONFIG.C0.DDR4_DataWidth [get_ips ddr4_0]] tp=[get_property CONFIG.C0.DDR4_TimePeriod [get_ips ddr4_0]] axi=[get_property CONFIG.C0.DDR4_AxiDataWidth [get_ips ddr4_0]]"

puts "ddr4_0 AxiAddressWidth = [get_property CONFIG.C0.DDR4_AxiAddressWidth [get_ips ddr4_0]]"

# ------------------------------------------- axi_dwidth_converter 128<->64
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
    -module_name axi_dwc_coef -dir $ip_dir
set_property -dict [list \
    CONFIG.ADDR_WIDTH          {33} \
    CONFIG.SI_DATA_WIDTH       {128} \
    CONFIG.MI_DATA_WIDTH       {64} \
    CONFIG.SI_ID_WIDTH         {1} \
    CONFIG.FIFO_MODE           {0} \
] [get_ips axi_dwc_coef]

generate_target all [get_ips ddr4_0 axi_dwc_coef]
synth_ip [get_ips ddr4_0 axi_dwc_coef]

puts "MIG_OK: ddr4_0 + axi_dwc_coef generated and synthesized OOC"
