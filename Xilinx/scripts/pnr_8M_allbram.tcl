set_param general.maxThreads 16
open_checkpoint synth_8M_ab.dcp
create_clock -period 3.306 -name clk [get_ports clk]
opt_design
place_design
report_utilization -file pnr_8M_ab_place_util.rpt
route_design
report_timing_summary -file pnr_8M_ab_route_timing.rpt -max_paths 20
report_route_status -file pnr_8M_ab_route_status.rpt
write_checkpoint -force pnr_8M_ab.dcp
