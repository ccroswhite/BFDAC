# Step 4C.3 / 5.1 - First full synthesis of vu13p_dac_top with master XDC
#   vivado -mode batch -source scripts/synth_top.tcl -journal synth_top.jou -log synth_top.log
set_param general.maxThreads 8

read_verilog -sv [glob *.sv]
read_xdc vu13p_dac_top.xdc

synth_design -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i -generic NUM_MACS=1024

report_utilization    -file synth_top_utilization.rpt
report_timing_summary -file synth_top_timing.rpt -max_paths 20
report_exceptions     -file synth_top_exceptions.rpt
write_checkpoint -force synth_top.dcp
puts "SYNTH_OK: vu13p_dac_top synthesized; reports written"
