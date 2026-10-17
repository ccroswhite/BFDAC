# f14b (2026-08-25): resume the f14 clean-flow confirmation from the synth
# checkpoint. f14 place completed (post-place phys_opt: estimated WNS +0.199,
# TNS 0.000) but Vivado OOM'd writing impl_f14_placed.dcp (ShapeDB writer
# ballooned to a reported ~1.9 TB peak on this memory-tight box), losing the
# placement. This flow re-places WITHOUT the placed-checkpoint write; routed
# checkpoint writes have succeeded in every f13x run.
#   vivado -mode batch -source scripts/impl_f14b_place_route.tcl -journal impl_f14b.jou -log impl_f14b.log
set_param general.maxThreads 8

set NUM_MACS       1280
set MACS_PER_SLR   [expr {$NUM_MACS / 4}]
set URAMS_PER_SLR  [expr {$NUM_MACS / 2 / 4}]

open_checkpoint impl_f14_synth.dcp

opt_design

# --- SLR pblocks (same as impl_top_f14.tcl) ----------------------------------
set FIR_BASE "u_dsp_core/u_stereo_fir"
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
report_utilization -file impl_f14b_place_utilization.rpt
phys_opt_design
# NO placed-checkpoint write (f14 OOM) — proceed straight to route
route_design

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}
# f13f lesson: FIR addr fanout residue closes with driver replication
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveFanoutOpt
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f14b_route_utilization.rpt
report_timing_summary -file impl_f14b_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f14b_congestion.rpt
write_checkpoint -force impl_f14b_routed.dcp

puts "IMPL_F14B_OK: vu13p_dac_top routed; reports written"
