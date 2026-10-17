# f17b (2026-09-05): re-run place/route from the f17 synth checkpoint with the
# corrected coef-FIFO memory-read CDC constraint.
# f17 result: WNS -5.152 on 38 cfifo_mem -> coef_waddr0_reg paths — the XDC §9
# "-to coef_w*_reg" pattern matched nothing (synth merged the three FIFO output
# registers into coef_waddr0_reg[*]), so those paths were timed at the raw
# 0.002 ns ui_clk/dsp_clk edge alignment, and every post-route phys_opt pass
# burned its effort on them. Residue elsewhere: adder tree level7->8 -0.698
# (2033 endpoints, SLR-hop routes) which f16b closed at +0.249 with the same
# geometry — expected to close once phys_opt is not distracted.
# The XDC in vu13p_dac_top.xdc is already fixed (no -to); the synth DCP carries
# the stale one (matched nothing, harmless), so apply the fix here explicitly.
#   vivado -mode batch -source scripts/impl_f17b_place_route.tcl -journal impl_f17b.jou -log impl_f17b.log
set_param general.maxThreads 8

set NUM_MACS       256
set MACS_PER_SLR   [expr {$NUM_MACS / 4}]
set URAMS_PER_SLR  [expr {$NUM_MACS / 2 / 4}]

open_checkpoint impl_f17_synth.dcp

# --- Corrected §9 item 3+4 memory-read constraint ------------------------------
set cfifo [get_cells -hierarchical -filter {NAME =~ u_coef_subsys/cfifo_mem*}]
puts "F17b: cfifo_mem cells = [llength $cfifo]"
set_max_delay -datapath_only 3.3 -from $cfifo

# CDC sanity: every crossing out of the coef FIFO must now carry 3.3 ns
set p [get_timing_paths -from $cfifo -max_paths 1 -nworst 1]
puts "F17b CDC check mem: requirement = [get_property REQUIREMENT $p] slack = [get_property SLACK $p]"
foreach {nm from to} [list \
    wptr {u_coef_subsys/cf_wptr_gray_reg[*] u_coef_subsys/cf_wptr_bin_reg[*]} {u_coef_subsys/cf_wptr_gray_d1_reg[*]} \
    rptr {u_coef_subsys/cf_rptr_gray_reg[*] u_coef_subsys/cf_rptr_bin_reg[*]} {u_coef_subsys/cf_rptr_gray_u1_reg[*]}] {
    set p [get_timing_paths -from [get_cells $from] -to [get_cells $to] -max_paths 1 -nworst 1]
    puts "F17b CDC check $nm: requirement = [get_property REQUIREMENT $p] slack = [get_property SLACK $p]"
}
# Any remaining ui_clk <-> dsp_clk path still at the raw edge alignment?
set raw [get_timing_paths -from [get_clocks mmcm_clkout0] -to [get_clocks dsp_clk] -max_paths 1 -nworst 1]
puts "F17b worst mmcm_clkout0->dsp_clk: requirement = [get_property REQUIREMENT $raw] endpoint = [get_property ENDPOINT_PIN $raw]"

opt_design

# --- SLR pblocks (same as impl_top_f17.tcl) -----------------------------------
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
report_utilization -file impl_f17b_place_utilization.rpt
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

report_utilization    -file impl_f17b_route_utilization.rpt
report_timing_summary -file impl_f17b_route_timing.rpt -max_paths 50
# DCP before the analysis reports (f15b memory lesson)
write_checkpoint -force impl_f17b_routed.dcp
report_cdc            -file impl_f17b_route_cdc.rpt
report_design_analysis -congestion -file impl_f17b_congestion.rpt

puts "impl_f17b_OK: vu13p_dac_top routed; reports written"
