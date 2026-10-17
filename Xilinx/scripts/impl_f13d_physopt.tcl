# f13d (2026-08-24): post-route phys_opt recovery pass on f13c. The f13c
# incremental route cleared the CDC alias path but perturbed 25 hb1
# accumulator endpoints to -0.031 (the f13c script omitted the post-route
# phys_opt that closed this group in f13b).
#   vivado -mode batch -source scripts/impl_f13d_physopt.tcl -journal impl_f13d.jou -log impl_f13d.log
set_param general.maxThreads 8

open_checkpoint impl_f13c_routed.dcp

phys_opt_design -directive AggressiveExplore
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f13d_route_utilization.rpt
report_timing_summary -file impl_f13d_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f13d_congestion.rpt
write_checkpoint -force impl_f13d_routed.dcp

puts "IMPL_F13D_OK: vu13p_dac_top routed; reports written"
