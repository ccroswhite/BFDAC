set OUT_DIR [expr {[info exists ::env(OUT_DIR)] ? $::env(OUT_DIR) : "build_8m"}]
set_param general.maxThreads 8

open_checkpoint "$OUT_DIR/post_route.dcp"

set pre_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set pre_whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "INFO: Loaded post_route.dcp | WNS = ${pre_wns} ns | WHS = ${pre_whs} ns"

# Pass 1: Over-constrain dsp_clk setup by +30 ps (additive to 74 ps MMCM jitter)
if {$pre_wns < 0.000} {
    set dclk [get_clocks dsp_clk]
    set_clock_uncertainty -from $dclk -to $dclk -setup 0.030

    phys_opt_design -directive AggressiveExplore
    route_design -tns_cleanup

    # Reset user uncertainty to 0 so nominal MMCM jitter (0.074 ns) governs STA
    set_clock_uncertainty -from $dclk -to $dclk -setup 0
}

# Pass 2: Surgical min-delay reroute on general fabric nets if any <0 ps path remains
set mid_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
puts "INFO: Post-Pass-1 WNS = ${mid_wns} ns"

if {$mid_wns < 0.000} {
    set bad_paths [get_timing_paths -setup -slack_lesser_than 0.000 -max_paths 25]
    set crit_pins [get_pins -quiet -of_objects $bad_paths -filter {
        DIRECTION == OUT &&
        (REF_NAME =~ FD* || REF_NAME =~ LUT* || REF_NAME == DSP_OUTPUT) &&
        (REF_PIN_NAME == Q || REF_PIN_NAME == O || REF_PIN_NAME =~ P[*])
    }]
    set crit_nets [get_nets -top_net_of_hierarchical_group -quiet -of_objects $crit_pins -filter {TYPE == SIGNAL}]

    if {[llength $crit_nets] > 0} {
        puts "INFO: Min-delay rerouting [llength $crit_nets] fabric nets..."
        route_design -unroute -nets $crit_nets
        route_design -nets $crit_nets -delay
        route_design -preserve
    }
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
puts "SIGNOFF CLOSURE SCOREBOARD: Failed=$failed_nets | WNS=${final_wns} ns | WHS=${final_whs} ns"
puts "========================================================================="

write_checkpoint -force "$OUT_DIR/post_route_signoff.dcp"
report_timing_summary -max_paths 25 -warn_on_violation -file "$OUT_DIR/post_route_signoff_timing.rpt"
report_bus_skew -file "$OUT_DIR/post_route_bus_skew.rpt"

if {$failed_nets == 0 && $final_wns >= 0.000 && $final_whs >= 0.000} {
    puts "INFO: Timing CLOSED with 0 failed nets! Writing $OUT_DIR/vu13p_dac_8m.bit..."
    write_bitstream -force "$OUT_DIR/vu13p_dac_8m.bit"
} else {
    puts "WARNING: Sign-off incomplete (Failed=$failed_nets, WNS=${final_wns} ns, WHS=${final_whs} ns)."
}

exit