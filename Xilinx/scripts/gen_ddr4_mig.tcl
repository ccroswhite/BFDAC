# f9 — Generate DDR4 MIG (ddr4_0) + AXI width converter for ACVU13 SOM
#   Topology: C0 controller. SOM carries 5x 1Gx16 (80 DQ) but the DDR4 MIG
#   controller maxes at 72-bit -> configured 64-bit data (4 devices, 8 GB
#   addressable; 5th device unused by this controller). Part: MIG list has
#   MT40A1G16RC-062E as the 1Gx16 -062E device (KD not listed; RC config-
#   compatible). 2400 MT/s, on-module 200 MHz ref clk, xcvu13p-fhgb2104-2-i.
#   AXI: MIG native 512-bit slave; axi_dwidth_converter bridges the 128-bit
#   read-only master in coef_bank_loader.
#   vivado -mode batch -source scripts/gen_ddr4_mig.tcl -journal gen_mig.jou -log gen_mig.log
set_param general.maxThreads 8

set ip_dir [file normalize "./ip"]
file mkdir $ip_dir

create_project -in_memory -part xcvu13p-fhgb2104-2-i
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------- ddr4_0
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_0 -dir $ip_dir
set_property -dict [list \
    CONFIG.C0.DDR4_TimePeriod            {833} \
    CONFIG.C0.DDR4_InputClockPeriod      {4998} \
    CONFIG.C0.DDR4_MemoryPart            {MT40A1G16RC-062E} \
    CONFIG.C0.DDR4_DataWidth             {64} \
    CONFIG.C0.DDR4_AxiSelection          {true} \
    CONFIG.C0.DDR4_AxiDataWidth          {512} \
    CONFIG.C0.DDR4_AxiIDWidth            {1} \
    CONFIG.C0.DDR4_AxiArbitrationScheme  {RD_PRI_REG} \
] [get_ips ddr4_0]

puts "ddr4_0 AxiAddressWidth = [get_property CONFIG.C0.DDR4_AxiAddressWidth [get_ips ddr4_0]]"

# ------------------------------------------- axi_dwidth_converter 128<->512
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
    -module_name axi_dwc_coef -dir $ip_dir
set_property -dict [list \
    CONFIG.ADDR_WIDTH          {33} \
    CONFIG.SI_DATA_WIDTH       {128} \
    CONFIG.MI_DATA_WIDTH       {512} \
    CONFIG.SI_ID_WIDTH         {1} \
    CONFIG.FIFO_MODE           {0} \
] [get_ips axi_dwc_coef]

generate_target all [get_ips ddr4_0 axi_dwc_coef]
synth_ip [get_ips ddr4_0 axi_dwc_coef]

puts "MIG_OK: ddr4_0 + axi_dwc_coef generated and synthesized OOC"
