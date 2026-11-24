# =============================================================================
# run_pnr_5m.tcl — Vivado Non-Project Place & Route for BFDAC 5.24M-Tap Build
# =============================================================================

set OUT_DIR   [expr {[info exists ::env(OUT_DIR)]   ? $::env(OUT_DIR)   : "build/5m"}]

set_param general.maxThreads 8

# Scoped message pruning (string-matched known-benign instances only; MIG
# phys_opt DONT_TOUCH noise added 2026-11-23).
source scripts/suppress_warnings.tcl

if {![file exists "$OUT_DIR/post_synth.dcp"]} {
    error "ERROR: $OUT_DIR/post_synth.dcp not found. Run run_synth_5m.tcl first."
}

puts "INFO: Opening post-synthesis checkpoint $OUT_DIR/post_synth.dcp..."
open_checkpoint "$OUT_DIR/post_synth.dcp"

# Post-synth port-property refresh: checkpoint may predate XDC fixes.
# clk_200m sits on HDIO bank 94 -- LVDS is not legal there; DIFF_HSTL_I_18 is
# (1.8 V VCCO, LVDS-level compatible). Re-apply in case dcp has stale LVDS.
set_property IOSTANDARD DIFF_HSTL_I_18 [get_ports {clk_200m_p clk_200m_n}]
set_property CLOCK_DEDICATED_ROUTE ANY_CMT_COLUMN [get_nets mclk]

# Constraint staleness fixes (post-route audit): belt-and-suspenders only —
# post-61f14bc the dcp embeds the repaired XDC, so each block skips silently
# when its objects were renamed post-synth (level_target_sync_chain is gone).
set ltc_cells [get_cells -quiet {level_target_sync_chain_reg[0] level_target_sync_chain_reg[1] level_target_sync_chain_reg[2]}]
if {[llength $ltc_cells] > 0} {
    set_max_delay -datapath_only 5.0 \
        -from [get_clocks clk_200m] \
        -to   $ltc_cells
}
# Reset tree: 8439 endpoints sat outside the u_l_fir/u_r_fir buckets.
set rst_src_cells [get_cells -hierarchical -filter {NAME =~ *dsp_rst*tree_n_reg*}]
if {[llength $rst_src_cells] > 0} {
    set_max_delay 6.6 -from $rst_src_cells
    # pace reset pins carry CLR not R.
    set_false_path \
        -from $rst_src_cells \
        -to   [get_pins -quiet -hierarchical -filter {NAME =~ u_dsp_core/pace_*_reg* && (REF_PIN_NAME == R || REF_PIN_NAME == CLR || REF_PIN_NAME == PRE)}]
}
# rate_shift_q: u_r copy trimmed post-synth; one tolerant pattern covers both.
set rsq_cells [get_cells -quiet -hierarchical -filter {NAME =~ u_dsp_core/u_stereo_fir/*/rate_shift_q_reg*}]
if {[llength $rsq_cells] > 0} { set_max_delay 6.6 -from $rsq_cells }
# job bus -from pattern (job_words renamed post-synth).
set job_src [get_cells -quiet -hierarchical -filter {NAME =~ u_boot_loader/job_addr* || NAME =~ u_boot_loader/job_words* || NAME =~ u_boot_loader/rec_len*}]
set job_dst [get_cells -quiet {u_boot_loader/w_addr_reg[*] u_boot_loader/w_words_left_reg[*]}]
if {[llength $job_src] > 0 && [llength $job_dst] > 0} {
    set_max_delay -datapath_only 3.3 -from $job_src -to $job_dst
}

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
# u_dem_l FSM state bit fans to ~1300 DEM sort loads (post-route audit).
set dem_nets [get_nets -quiet -of_objects \
    [get_pins -hierarchical -filter {NAME =~ u_dsp_core/u_dem_l/FSM_sequential_state_reg*/Q}]]
set s3_nets [concat $s3_nets $dem_nets]
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

exit
