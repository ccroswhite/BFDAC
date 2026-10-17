# f16b (2026-09-03): re-run place/route from the f16 synth checkpoint
# (1M-tap release geometry, NUM_MACS=256 x TAPS_PER_PHASE=256).
# The single-session impl_top_f16.tcl run VANISHED silently at 19:24 in
# place_design Phase 4.1 (Post Commit Optimization) after Post-Placement
# WNS +0.486 — no ERROR, no hs_err dump, no Event Log entry, peak 15.3 GB.
# Synth DCP (written 18:45) is intact, so restart from it (f14b/f15b pattern).
#   vivado -mode batch -source scripts/impl_f16b_place_route.tcl -journal impl_f16b.jou -log impl_f16b.log
set_param general.maxThreads 8

set NUM_MACS       256
set MACS_PER_SLR   [expr {$NUM_MACS / 4}]
set URAMS_PER_SLR  [expr {$NUM_MACS / 2 / 4}]

open_checkpoint impl_f16_synth.dcp

# CDC sanity (the corrected constraints live in vu13p_dac_top.xdc since f15b)
set ld_seq  [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/u_coef_loader/* && IS_SEQUENTIAL}]
set chk [get_timing_paths -from [get_cells {u_coef_subsys/u_coef_mgr/target_bank_reg[*]}] -to $ld_seq -max_paths 1 -nworst 1]
puts "CDC check mgr->loader: requirement = [get_property REQUIREMENT $chk]"
opt_design

# --- SLR pblocks (same as impl_top_f15.tcl) ----------------------------------
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
report_utilization -file impl_f16b_place_utilization.rpt
phys_opt_design
# NO placed-checkpoint write (f14 OOM) — proceed straight to route
route_design

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveFanoutOpt
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f16b_route_utilization.rpt
report_timing_summary -file impl_f16b_route_timing.rpt -max_paths 50
# DCP before the analysis reports: the 2026-09-02 run hung in the
# PlaceStorage write after report_cdc/report_design_analysis pushed peak
# memory past physical RAM (see impl_top_f15.tcl header).
write_checkpoint -force impl_f16b_routed.dcp
report_cdc            -file impl_f16b_route_cdc.rpt
report_design_analysis -congestion -file impl_f16b_congestion.rpt

puts "impl_f16b_OK: vu13p_dac_top routed; reports written"
