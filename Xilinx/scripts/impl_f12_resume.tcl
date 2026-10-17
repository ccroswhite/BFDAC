# f12 resume (2026-08-22): the first f12 route_design was killed by a terminal
# interrupt during rip-up iteration 1 (NOT a router failure — overlaps had
# converged, intermediate WNS -2.57 pre-timing-iteration). Resume from the
# synth checkpoint; this time write a checkpoint after place so any further
# interruption resumes without redoing placement.
#   vivado -mode batch -source scripts/impl_f12_resume.tcl -journal impl_f12r.jou -log impl_f12r.log
set_param general.maxThreads 8

set NUM_MACS       1280
set TAPS_PER_PHASE 256

if {[file exists impl_f12_placed.dcp]} {
    puts "F12R: resuming from PLACED checkpoint"
    open_checkpoint impl_f12_placed.dcp
} else {
    puts "F12R: resuming from SYNTH checkpoint"
    open_checkpoint impl_f12_synth.dcp

    opt_design

    # --- SLR pblocks (same as impl_top_f9.tcl / f12) --------------------------
    set FIR_BASE "u_dsp_core/u_stereo_fir"
    set MACS_PER_SLR  [expr {$NUM_MACS / 4}]
    set URAMS_PER_SLR [expr {$NUM_MACS / 2 / 4}]

    for {set s 0} {$s < 4} {incr s} {
        create_pblock pb_fir_slr$s
        resize_pblock pb_fir_slr$s -add SLR$s
        set bucket($s) {}
    }

    puts "PBLOCK: collecting FIR cells"
    set fir_cells [get_cells -quiet [list \
        "$FIR_BASE/u_l_fir/gen_win*" \
        "$FIR_BASE/u_l_fir/gen_poly_mac*" \
        "$FIR_BASE/u_r_fir/gen_win*" \
        "$FIR_BASE/u_r_fir/gen_poly_mac*" \
        "$FIR_BASE/gen_uram_coef*"]]
    puts "PBLOCK: [llength $fir_cells] candidate cells"

    foreach c $fir_cells {
        if {[regexp {gen_(?:win|poly_mac)\[(\d+)\]} $c -> idx]} {
            lappend bucket([expr {$idx / $MACS_PER_SLR}]) $c
        } elseif {[regexp {gen_uram_coef\[(\d+)\]} $c -> idx]} {
            lappend bucket([expr {$idx / $URAMS_PER_SLR}]) $c
        }
    }

    set pb_fail 0
    for {set s 0} {$s < 4} {incr s} {
        if {[llength $bucket($s)] == 0} {
            puts "CRITICAL: pb_fir_slr$s matched 0 cells - pblock patterns are stale"
            set pb_fail 1
        } else {
            add_cells_to_pblock [get_pblocks pb_fir_slr$s] $bucket($s)
            puts "pb_fir_slr$s: [llength $bucket($s)] cells"
        }
    }
    if {$pb_fail} { error "PBLOCK assignment failed - aborting before place_design" }
    puts "PBLOCK: assignment complete"

    place_design
    report_utilization -file impl_f12_place_utilization.rpt
    phys_opt_design
    write_checkpoint -force impl_f12_placed.dcp
}

route_design
write_checkpoint -force impl_f12_routed_raw.dcp

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f12_route_utilization.rpt
report_timing_summary -file impl_f12_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f12_congestion.rpt
write_checkpoint -force impl_f12_routed.dcp

puts "IMPL_F12_OK: vu13p_dac_top routed; reports written"
