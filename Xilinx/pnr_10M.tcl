# OOC place+route of the 10.48M-tap hybrid stereo FIR at 302.47 MHz
set_param general.maxThreads 8
open_checkpoint synth_10M.dcp
create_clock -period 3.306 -name clk [get_ports clk]
opt_design
place_design
report_utilization -file pnr_10M_place_util.rpt
route_design
report_timing_summary -file pnr_10M_route_timing.rpt -max_paths 20
report_route_status -file pnr_10M_route_status.rpt
report_drc -file pnr_10M_drc.rpt
write_checkpoint -force pnr_10M.dcp
