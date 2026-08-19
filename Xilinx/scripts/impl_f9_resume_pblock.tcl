# f9 iteration 3 — resume from impl_f9_synth.dcp (RTL unchanged since the
# 2026-08-13 broadcast-tree run) and re-place/route with SLR pblocks.
# Pblock logic mirrors impl_top_f9.tcl; keep the two in sync.
#   vivado -mode batch -source scripts/impl_f9_resume_pblock.tcl -journal impl_f9pb.jou -log impl_f9pb.log
set_param general.maxThreads 8

open_checkpoint impl_f9_synth.dcp

opt_design

# Pblock assignment: ONE bracket-free glob per cell array, then Tcl-side
# index bucketing. (The previous version passed ~1280 per-index glob patterns
# to a single get_cells, which killed Vivado silently on the 3M-cell netlist.)
set FIR_BASE "u_dsp_core/u_stereo_fir"
set MACS_PER_SLR  [expr {1024 / 4}]
set URAMS_PER_SLR [expr {512 / 4}]

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
report_utilization    -file impl_f9pb_place_utilization.rpt
phys_opt_design
route_design

report_utilization    -file impl_f9pb_route_utilization.rpt
report_timing_summary -file impl_f9pb_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f9pb_congestion.rpt
write_checkpoint -force impl_f9pb_routed.dcp

puts "IMPL_F9PB_OK: vu13p_dac_top routed with SLR pblocks; reports written"
