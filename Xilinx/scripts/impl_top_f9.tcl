# f9 — VU13P datum fitment: full RTL synth + IMPLEMENTATION at production
#   scale (NUM_MACS=1024, TAPS_PER_PHASE=256 -> 16 phases x 1024 MACs x 256 =
#   4,194,304 taps, x2 banks resident in URAM for gapless switching),
#   real DDR4 MIG + AXI width converter included.
#   vivado -mode batch -source scripts/impl_top_f9.tcl -journal impl_f9.jou -log impl_f9.log
set_param general.maxThreads 8

# ---- Design scale (single point of control, 2026-08-17) ---------------------
# taps = 16 phases * NUM_MACS * TAPS_PER_PHASE (x2 banks resident in URAM).
# NUM_MACS: any multiple of 64 (URAM group tree) AND of 4 (SLR bucketing);
#           power of 2 NOT required (adder tree zero-pads). URAMs = NUM_MACS/2
#           (max 1280 on VU13P -> NUM_MACS <= 2560 hard ceiling).
# TAPS_PER_PHASE: power of 2, max 256 (URAM depth 4096 with dual-bank packing).
# Examples: 1024x256 = 4,194,304 (4M) | 1280x256 = 5,242,880 (5M)
set NUM_MACS       1280
set TAPS_PER_PHASE 256
if {$NUM_MACS % 64 != 0} { error "NUM_MACS ($NUM_MACS) must be a multiple of 64" }
if {$NUM_MACS > 2560}    { error "NUM_MACS ($NUM_MACS) needs [expr {$NUM_MACS/2}] URAMs; VU13P has 1280" }

# RTL — exclude the simulation stub dac_ddr4_if.sv (dac_ddr4_if_mig.sv is
# the synthesis implementation of module dac_ddr4_if)
set sv_files [glob *.sv]
set sv_files [lsearch -all -inline -not -exact $sv_files "dac_ddr4_if.sv"]
read_verilog -sv $sv_files

# Generated IP (OOC checkpoints from scripts/gen_ddr4_mig.tcl)
read_ip ip/ddr4_0/ddr4_0.xci
read_ip ip/axi_dwc_coef/axi_dwc_coef.xci

read_xdc vu13p_dac_top.xdc

synth_design -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i \
    -generic NUM_MACS=$NUM_MACS -generic TAPS_PER_PHASE=$TAPS_PER_PHASE

report_utilization    -file impl_f9_synth_utilization.rpt
write_checkpoint -force impl_f9_synth.dcp

opt_design

# --- SLR pblocks (2026-08-13, second f9 iteration) ---------------------------
# The broadcast-tree fix registered all window/URAM-facing controls per
# 64-window group, but the routed result showed the placer scattering each
# group's windows across the die (s3 group reg -> own-group window: 6.1 ns
# route). The tree is built as 4 super-groups of 4 groups, one per SLR;
# these pblocks enforce that geography. MAC windows + DSPs + their URAM
# coefficient stores land together; the adder tree and broadcast registers
# are left floating (their pipeline absorbs SLR hops, and the placer pulls
# them to their loads).
# Pblock assignment: ONE bracket-free glob per cell array, then Tcl-side
# index bucketing. (Passing ~1280 per-index glob patterns to a single
# get_cells killed Vivado silently on the 3M-cell netlist.)
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
report_utilization    -file impl_f9_place_utilization.rpt
phys_opt_design
route_design

# Post-route phys_opt (added 2026-08-15): the f9wc route left ~4k shallow
# violations (WNS -0.41, avg -0.07 per endpoint). Post-route placement/rewire
# optimization typically recovers this class of miss.
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f9_route_utilization.rpt
report_timing_summary -file impl_f9_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f9_congestion.rpt
write_checkpoint -force impl_f9_routed.dcp

puts "IMPL_F9_OK: vu13p_dac_top routed; reports written"
