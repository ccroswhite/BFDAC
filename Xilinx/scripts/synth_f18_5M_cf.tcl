# f18 synth-only (2026-10-05): first synthesis of the carrier-coefficient-flash
# RTL (bom 18a: qspi_flash_ctrl 2-bit target, qspi_boot_loader carrier-first
# boot, vu13p_dac_top cf_sck/cf_cs_n/cf_dq + IOB-registered outputs, XDC s11b)
# at the PROVEN 5M geometry (1280 x 256, f15b closed WNS 0.000). Purpose:
#   1) prove the new RTL + s11b constraints synthesize cleanly (IOB packing,
#      pin/IOSTANDARD legality, multicycle pattern binds to u_flash_ctrl cells);
#   2) refresh the 5M utilization baseline (LUT-as-memory in particular) that
#      the 10M folded-FIR estimate is built on (item 18 (b)).
# No place/route: the 10M fold needs its RTL first.
#   vivado -mode batch -source scripts/synth_f18_5M_cf.tcl -journal synth_f18.jou -log synth_f18.log
set_param general.maxThreads 8

set NUM_MACS       1280
set TAPS_PER_PHASE 256

set sv_files [glob *.sv]
set sv_files [lsearch -all -inline -not -exact $sv_files "dac_ddr4_if.sv"]
set sv_files [lsearch -all -inline -not -exact $sv_files "flash_bridge.sv"]
read_verilog -sv $sv_files
read_ip ip/ddr4_0/ddr4_0.xci
read_ip ip/axi_dwc_coef/axi_dwc_coef.xci
read_xdc vu13p_dac_top.xdc

synth_design -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i \
    -generic NUM_MACS=$NUM_MACS -generic TAPS_PER_PHASE=$TAPS_PER_PHASE

# s11b binding checks
puts "F18 cf ports: [llength [get_ports {cf_sck cf_cs_n[*] cf_dq[*]}]] (expect 9)"
puts "F18 rx_sr cells for the MISO multicycle: [llength [get_cells -quiet -hierarchical -filter {NAME =~ u_flash_ctrl/rx_sr_reg[*]}]]"
foreach p {cf_sck cf_cs_n[0] cf_dq[0]} {
    set c [get_cells -quiet -of_objects [get_nets -quiet -of_objects [get_ports $p]] -filter {IS_PRIMITIVE && REF_NAME =~ FD*}]
    puts "F18 IOB candidate for $p: [llength $c] driver FF(s)"
}
set mc [get_timing_paths -quiet -from [get_ports {cf_dq[1]}] -max_paths 1 -nworst 1]
if {[llength $mc]} { puts "F18 MISO path requirement = [get_property REQUIREMENT $mc]" } else { puts "F18 MISO path: NONE" }

report_utilization    -file synth_f18_utilization.rpt
report_utilization    -hierarchical -hierarchical_depth 2 -file synth_f18_util_hier.rpt
report_timing_summary -file synth_f18_timing.rpt -max_paths 20
report_cdc            -file synth_f18_cdc.rpt
write_checkpoint -force synth_f18_5M.dcp
puts "F18_OK: vu13p_dac_top (1280x256, carrier flash) synthesized; reports written"
