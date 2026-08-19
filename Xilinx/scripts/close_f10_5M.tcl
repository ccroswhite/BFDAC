# Incremental timing closure on the routed 5M checkpoint (2026-08-17).
# f10 route ended at WNS -0.025 / TNS -1.853 / 174 endpoints - shallow,
# heterogeneous, placement-noise level. Iterate post-route phys_opt.
#   vivado -mode batch -source scripts/close_f10_5M.tcl -journal close_f10.jou -log close_f10.log
set_param general.maxThreads 8

open_checkpoint impl_f9_routed.dcp

for {set i 0} {$i < 3} {incr i} {
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    puts "CLOSE_F10: iteration $i entry WNS = $wns"
    if {$wns >= 0} { break }
    phys_opt_design -directive AggressiveExplore
    route_design -preserve
}

report_timing_summary -file impl_f10_close_timing.rpt
report_utilization    -file impl_f10_close_utilization.rpt
write_checkpoint -force impl_f10_5M_routed.dcp

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "CLOSE_F10_DONE: final WNS = $wns"
