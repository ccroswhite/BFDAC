# Step 4C.3 / 5.1 - First full synthesis of acku15s_dac_top with master XDC
#   vivado -mode batch -source scripts/synth_top.tcl -journal synth_top.jou -log synth_top.log
set_param general.maxThreads 8

# RTL — exclude the simulation stub dac_ddr4_if.sv (dac_ddr4_if_mig.sv is
# the synthesis implementation of module dac_ddr4_if). Same guard as
# impl_top_f*/run_synth_5m: without it the stub's ui_clk=0 constant-folds
# the entire boot/coef AXI path out of the netlist.
set sv_files [glob *.sv]
set sv_files [lsearch -all -inline -not -exact $sv_files "dac_ddr4_if.sv"]
read_verilog -sv $sv_files
read_xdc acku15s_dac_top.xdc

synth_design -top acku15s_dac_top -part xcku15p-ffve1517-2-i -generic NUM_MACS=1024

report_utilization    -file synth_top_utilization.rpt
report_timing_summary -file synth_top_timing.rpt -max_paths 20
report_exceptions     -file synth_top_exceptions.rpt
write_checkpoint -force synth_top.dcp
puts "SYNTH_OK: acku15s_dac_top synthesized; reports written"
