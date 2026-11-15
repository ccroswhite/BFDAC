set OUT_DIR [expr {[info exists ::env(OUT_DIR)] ? $::env(OUT_DIR) : "build_5m"}]
set_param general.maxThreads 8

open_checkpoint "$OUT_DIR/post_route_signoff.dcp"

set pre_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
puts "INFO: Loaded post_route_signoff.dcp | WNS = ${pre_wns} ns"

if {$pre_wns < 0.000} {
    # Isolate input_frame_done launch into its own path group so dsp_clk stays
    # >= 0 and physopt effort concentrates on cloning the CE LUT5 drivers
    set ifd_ff [get_cells u_dsp_core/u_stereo_fir/u_r_fir/input_frame_done_reg]
    group_path -name ifd_grp -weight 5 -from $ifd_ff
    set_clock_uncertainty -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -setup 0.060

    phys_opt_design -critical_cell_opt -placement_opt -rewire -routing_opt
    route_design -tns_cleanup

    set_clock_uncertainty -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -setup 0
    group_path -default -from $ifd_ff
}

if {[get_property SLACK [get_timing_paths -hold -max_paths 1 -nworst 1]] < 0.000} {
    phys_opt_design -hold_fix
}

set route_str [report_route_status -return_string]
set failed_nets -1
regexp {# of nets with routing errors[^:]*:\s*(\d+)} $route_str -> failed_nets

set final_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set final_whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]

puts "========================================================================="
puts "SIGNOFF2 CLOSURE SCOREBOARD: Failed=$failed_nets | WNS=${final_wns} ns | WHS=${final_whs} ns"
puts "========================================================================="

write_checkpoint -force "$OUT_DIR/post_route_signoff2.dcp"
report_timing_summary -max_paths 25 -warn_on_violation -file "$OUT_DIR/post_route_signoff2_timing.rpt"
report_bus_skew -file "$OUT_DIR/post_route_bus_skew2.rpt"

set WRITE_BIT [expr {[info exists ::env(WRITE_BIT)] ? $::env(WRITE_BIT) : 0}]
if {$WRITE_BIT && $failed_nets == 0 && $final_wns >= 0.000 && $final_whs >= 0.000} {
    puts "INFO: Timing CLOSED with 0 failed nets! Writing $OUT_DIR/acku15s_dac_5m.bit..."
    write_bitstream -force "$OUT_DIR/acku15s_dac_5m.bit"
} else {
    puts "WARNING: Sign-off incomplete (Failed=$failed_nets, WNS=${final_wns} ns, WHS=${final_whs} ns)."
}

exit
