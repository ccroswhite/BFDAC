# f15b (2026-09-02): re-place/route the f15 synth checkpoint with the two
# mgr<->loader CDC constraints that failed to bind in f15:
#   xdc:525  -to u_coef_loader/*_reg*   missed the retimed burst_addr__N regs
#            (and picked up LUTs -> "not a valid endpoint" warnings)
#   xdc:532  -to u_coef_mgr/state_reg[*] matched nothing (FSM_sequential_state_reg)
# Both crossings were therefore timed at the 0.002 ns dsp_clk/ui_clk
# coincidence: WNS -5.238, and the placer/phys_opt spent the whole flow on
# those unfixable paths instead of the FIR write-control fanout (dsp_clk
# residue -0.735 / 9.8k endpoints; f14b closed the same RTL at +0.024).
# The checkpoint carries the f15 XDC, so only the corrected constraints are
# re-applied here (they supersede the partially-bound line-525 constraint on
# the same from/to pairs; the line-532 one bound nothing).
#   vivado -mode batch -source scripts/impl_f15b_place_route.tcl -journal impl_f15b.jou -log impl_f15b.log
set_param general.maxThreads 8

set NUM_MACS       1280
set MACS_PER_SLR   [expr {$NUM_MACS / 4}]
set URAMS_PER_SLR  [expr {$NUM_MACS / 2 / 4}]

open_checkpoint impl_f15_synth.dcp

# --- Corrected CDC constraints (mirror of vu13p_dac_top.xdc 5 / 5b) ----------
set ld_seq  [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/u_coef_loader/* && IS_SEQUENTIAL}]
set mgr_seq [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/u_coef_mgr/* && IS_SEQUENTIAL}]
puts "CDC: loader sequential cells = [llength $ld_seq], mgr sequential cells = [llength $mgr_seq]"
if {[llength $ld_seq] == 0 || [llength $mgr_seq] == 0} { error "CDC cell match failed" }
set_max_delay -datapath_only 5.0 \
    -from [get_cells {u_coef_subsys/u_coef_mgr/target_bank_reg[*]}] -to $ld_seq
set_max_delay -datapath_only 3.5 \
    -from [get_cells {u_coef_subsys/u_coef_loader/load_err_reg}] -to $mgr_seq

# Sanity: the two f15 offenders must now be datapath-only constrained
set chk [get_timing_paths -from [get_cells {u_coef_subsys/u_coef_mgr/target_bank_reg[*]}] \
                          -to $ld_seq -max_paths 1 -nworst 1]
puts "CDC check mgr->loader: requirement = [get_property REQUIREMENT $chk]"
set chk [get_timing_paths -from [get_cells {u_coef_subsys/u_coef_loader/load_err_reg}] \
                          -to $mgr_seq -max_paths 1 -nworst 1]
puts "CDC check loader->mgr: requirement = [get_property REQUIREMENT $chk]"

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
report_utilization -file impl_f15b_place_utilization.rpt
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

report_utilization    -file impl_f15b_route_utilization.rpt
report_timing_summary -file impl_f15b_route_timing.rpt -max_paths 50
# DCP before the analysis reports: the 2026-09-02 run hung in the
# PlaceStorage write after report_cdc/report_design_analysis pushed peak
# memory past physical RAM (see impl_top_f15.tcl header).
write_checkpoint -force impl_f15b_routed.dcp
report_cdc            -file impl_f15b_route_cdc.rpt
report_design_analysis -congestion -file impl_f15b_congestion.rpt

puts "impl_f15b_OK: vu13p_dac_top routed; reports written"
