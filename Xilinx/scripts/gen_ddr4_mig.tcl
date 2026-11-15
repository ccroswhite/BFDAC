# ACKU15S-3 — Generate DDR4 MIG (ddr4_0) + AXI width converter for ACKU15S SOM
#   Topology: C0 controller, 4x Nanya NT5AD512M16C4-HR x16 = 64-bit non-ECC
#   (4 GB addressable; SoM 5th chip unconnected — Xilinx MIG caps DataWidth
#   at 72 = 64+ECC, 80-bit non-ECC unsupported; user ruled option (a) 2026-11-14),
#   2666 Mbps, on-module 200 MHz ref clk (AR32/AT32), banks 66-68,
#   xcku15p-ffve1517-2-i.
#   MemoryPart: Nanya NT5AD512M16C4-HR is not MIG-listed; using the
#   config-compatible Micron 8Gb x16 DDR4-2666 entry (MT40A512M16LY-075
#   accepted by the tool 2026-11-14). VERIFY timing params or move to a
#   C0.DDR4_CustomParts CSV with Nanya timings.
#   AXI: slave runs full 512-bit (valid for DW=64: {32..512}); axi_dwc_coef
#   bridges the 128-bit
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
# Ordering matters (verified 2026-11-14): TimePeriod/InputClockPeriod FIRST,
# then MemoryPart, then the AXI dict, then DataWidth LAST — the AXI dict
# cascade-resets DataWidth back to the part minimum (observed 80 -> 8).
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod            {750} \
    CONFIG.C0.DDR4_InputClockPeriod      {5000} \
] [get_ips ddr4_0]
set_property CONFIG.C0.DDR4_MemoryPart {MT40A512M16LY-075} [get_ips ddr4_0]
set_property -dict [list \
    CONFIG.C0.DDR4_AxiSelection          {true} \
    CONFIG.C0.DDR4_AxiIDWidth            {1} \
    CONFIG.C0.DDR4_AxiArbitrationScheme  {RD_PRI_REG} \
] [get_ips ddr4_0]
# DataWidth LAST: the AXI dict resets it to the part minimum; applying it last
# leaves AxiDataWidth at the DW=64 default of 512 (valid range 32..512).
set_property CONFIG.C0.DDR4_DataWidth  {64}                [get_ips ddr4_0]
puts "CHECK part=[get_property CONFIG.C0.DDR4_MemoryPart [get_ips ddr4_0]] dw=[get_property CONFIG.C0.DDR4_DataWidth [get_ips ddr4_0]] tp=[get_property CONFIG.C0.DDR4_TimePeriod [get_ips ddr4_0]] axi=[get_property CONFIG.C0.DDR4_AxiDataWidth [get_ips ddr4_0]]"

puts "ddr4_0 AxiAddressWidth = [get_property CONFIG.C0.DDR4_AxiAddressWidth [get_ips ddr4_0]]"

# ------------------------------------------- axi_dwidth_converter 128<->64
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
    -module_name axi_dwc_coef -dir $ip_dir
set_property -dict [list \
    CONFIG.ADDR_WIDTH          {32} \
    CONFIG.SI_DATA_WIDTH       {128} \
    CONFIG.MI_DATA_WIDTH       {512} \
    CONFIG.SI_ID_WIDTH         {1} \
    CONFIG.FIFO_MODE           {0} \
] [get_ips axi_dwc_coef]

generate_target all [get_ips ddr4_0 axi_dwc_coef]
synth_ip [get_ips ddr4_0 axi_dwc_coef]

puts "MIG_OK: ddr4_0 + axi_dwc_coef generated and synthesized OOC"
