# =============================================================================
# run_pnr_5m.tcl — Vivado Non-Project Place & Route for BFDAC 5.24M-Tap Build
# =============================================================================

set OUT_DIR   [expr {[info exists ::env(OUT_DIR)]   ? $::env(OUT_DIR)   : "build/5m"}]
set WRITE_BIT [expr {[info exists ::env(WRITE_BIT)] ? $::env(WRITE_BIT) : 0}]

set_param general.maxThreads 8

if {![file exists "$OUT_DIR/post_synth.dcp"]} {
    error "ERROR: $OUT_DIR/post_synth.dcp not found. Run run_synth_5m.tcl first."
}

puts "INFO: Opening post-synthesis checkpoint $OUT_DIR/post_synth.dcp..."
open_checkpoint "$OUT_DIR/post_synth.dcp"

# Pre-place cross-clock sanity audit (verifies zero sub-ns un-excepted beat paths)
foreach {src dst} {
    dsp_clk      clk_200m
    clk_200m     dsp_clk
    dsp_clk      cell_clk
    cell_clk     dsp_clk
    clk_200m     mmcm_clkout0
    mmcm_clkout0 clk_200m
    mmcm_clkout0 dsp_clk
    dsp_clk      mmcm_clkout0
} {
    set p [get_timing_paths -quiet -from [get_clocks -quiet $src] -to [get_clocks -quiet $dst] -max_paths 1 -nworst 1]
    if {[llength $p] > 0} {
        puts "CDC_CHECK $src -> $dst : req=[get_property REQUIREMENT $p] ns | ep=[get_property ENDPOINT_PIN $p]"
    }
}

puts "INFO: Running opt_design..."
opt_design
report_utilization -file "$OUT_DIR/post_opt_utilization.rpt"

puts "INFO: Running place_design..."
place_design -directive Explore
report_utilization -slr -file "$OUT_DIR/post_place_slr_util.rpt"

set place_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "INFO: Post-Place Setup WNS = ${place_wns} ns"

# Placement-aware fanout replication: the s3 broadcast leaves (cap/clr/we/addr
# + snap_en + I2S new_sample) each span multiple horizontal BRAM columns even
# inside one SLR. Replicating them post-place clusters each replica against
# the physical BRAM columns it feeds -- zero latency change.
phys_opt_design -directive AggressiveFanoutOpt
set s3_nets [get_nets -quiet -hierarchical -filter {
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*cap_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*clr_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*we_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*rd_addr_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*rd_rev_addr_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*wr_addr_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*coef_addr_s3* ||
    NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/*snap_en* ||
    NAME =~ u_i2s_ingress/new_sample
}]
if {[llength $s3_nets] > 0} {
    puts "INFO: Forcing replication on [llength $s3_nets] broadcast nets"
    phys_opt_design -force_replication_on_nets $s3_nets
}
phys_opt_design -directive AggressiveExplore

puts "INFO: Running route_design..."
route_design -directive Explore

set route_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set route_whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "INFO: Initial Post-Route WNS = ${route_wns} ns | WHS = ${route_whs} ns"

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0.000} {
    puts "INFO: Running post-route phys_opt_design (AggressiveExplore)..."
    phys_opt_design -directive AggressiveExplore
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0.000} {
    puts "INFO: Running post-route phys_opt_design (AggressiveFanoutOpt)..."
    phys_opt_design -directive AggressiveFanoutOpt
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
regexp {# of nets with routing errors[^:]*:\s*(\d+)} $route_str -> failed_nets

set final_wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set final_whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

puts "========================================================================="
puts "FINAL 5.24M-TAP PLACE & ROUTE SCOREBOARD"
puts "  Failed / Unrouted Nets : $failed_nets"
puts "  Final Setup WNS        : ${final_wns} ns"
puts "  Final Hold  WHS        : ${final_whs} ns"
puts "  Reports & DCP Dir      : $OUT_DIR/"
puts "========================================================================="

if {$failed_nets != 0} {
    error "ERROR: Routing failed with $failed_nets routing errors!"
}

if {$WRITE_BIT && $final_wns >= 0.000 && $final_whs >= 0.000} {
    puts "INFO: Timing met with 0 routing errors — generating bitstream..."
    write_bitstream -force "$OUT_DIR/acku15s_dac_5m.bit"
} else {
    puts "WARNING: Skipping bitstream generation (WRITE_BIT=$WRITE_BIT, WNS=$final_wns, WHS=$final_whs)."
}

exit
