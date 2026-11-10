# =============================================================================
# run_pnr_8m.tcl — Vivado Non-Project Place & Route for BFDAC 8.39M-Tap Build
# =============================================================================

set OUT_DIR   [expr {[info exists ::env(OUT_DIR)]   ? $::env(OUT_DIR)   : "build_8m"}]
set WRITE_BIT [expr {[info exists ::env(WRITE_BIT)] ? $::env(WRITE_BIT) : 1}]

set_param general.maxThreads 8

if {![file exists "$OUT_DIR/post_synth.dcp"]} {
    error "ERROR: $OUT_DIR/post_synth.dcp not found. Run run_synth_8m.tcl first."
}

puts "INFO: Opening post-synthesis checkpoint $OUT_DIR/post_synth.dcp..."
open_checkpoint "$OUT_DIR/post_synth.dcp"

puts "INFO: Running opt_design..."
opt_design -directive Explore
report_utilization -slr -file "$OUT_DIR/post_opt_slr_util.rpt"

puts "INFO: Running place_design..."
place_design -directive Explore
write_checkpoint -force "$OUT_DIR/post_place.dcp"

report_utilization -slr -file "$OUT_DIR/post_place_slr_util.rpt"
report_design_analysis -congestion -timing -logic_level_distribution \
    -max_paths 50 -file "$OUT_DIR/post_place_qor.rpt"

set place_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: Post-Place Setup WNS = ${place_wns} ns"

if {$place_wns < 0.100} {
    puts "INFO: Running post-place phys_opt_design..."
    phys_opt_design -directive AggressiveExplore
    write_checkpoint -force "$OUT_DIR/post_place_physopt.dcp"
}

puts "INFO: Running route_design..."
route_design -directive Explore

set route_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set route_whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "INFO: Initial Post-Route WNS = ${route_wns} ns | WHS = ${route_whs} ns"

if {$route_wns < 0.000} {
    puts "INFO: Running post-route setup phys_opt_design..."
    phys_opt_design -directive AggressiveExplore
}

set route_whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
if {$route_whs < 0.000} {
    puts "INFO: Running post-route hold-fix phys_opt_design..."
    phys_opt_design -hold_fix
}

write_checkpoint -force "$OUT_DIR/post_route.dcp"

report_route_status -file "$OUT_DIR/post_route_status.rpt"
report_timing_summary -max_paths 25 -warn_on_violation -file "$OUT_DIR/post_route_timing_summary.rpt"
report_utilization -file "$OUT_DIR/post_route_utilization.rpt"
report_utilization -slr -file "$OUT_DIR/post_route_slr_util.rpt"
report_clock_interaction -delay_type min_max -file "$OUT_DIR/post_route_clock_interaction.rpt"
report_cdc -details -file "$OUT_DIR/post_route_cdc.rpt"
report_drc -file "$OUT_DIR/post_route_drc.rpt"

set route_str [report_route_status -return_string]
set failed_nets -1
regexp {Number of Failed Nets\s*[:=]\s*(\d+)} $route_str -> failed_nets

set final_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set final_whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

puts "========================================================================="
puts "FINAL 8.39M-TAP PLACE & ROUTE SCOREBOARD"
puts "  Failed / Unrouted Nets : $failed_nets"
puts "  Final Setup WNS        : ${final_wns} ns"
puts "  Final Hold  WHS        : ${final_whs} ns"
puts "  Reports & DCP Dir      : $OUT_DIR/"
puts "========================================================================="

if {$failed_nets != 0} {
    error "ERROR: Routing failed with $failed_nets unrouted/partially routed nets!"
}

if {$WRITE_BIT && $final_wns >= 0.000 && $final_whs >= 0.000} {
    puts "INFO: Timing met with 0 unrouted nets — generating bitstream..."
    write_bitstream -force "$OUT_DIR/vu13p_dac_8m.bit"
} else {
    puts "WARNING: Skipping bitstream generation (WRITE_BIT=$WRITE_BIT, WNS=$final_wns, WHS=$final_whs)."
}

exit