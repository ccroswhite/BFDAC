# f16 — 1M-TAP RELEASE GEOMETRY (2026-09-03 ruling, progress.md TODO-24):
#   NUM_MACS=256, TAPS_PER_PHASE=256 -> 1,048,576 taps, 4 MB/bank, 31 filters on
#   the 128 MiB coefficient flash. Also carries TODO-16 (boot_ok -> bank manager,
#   bank_valid, boot fade after first good load), TODO-23 (32-entry list,
#   FILTER_SELECT_ID 0x17, FILTER_LIST_CTRL[1]), TODO-18 (spi_regs.svh).
#   vivado -mode batch -source scripts/impl_top_f16.tcl -journal impl_f16.jou -log impl_f16.log
#
#   Flow = f15 (synth + place + route in one session; routed DCP written before
#   report_cdc / report_design_analysis). History below retained from f15.
## f15 — FILTER DIRECTORY LOOKUP (2026-09-02): coef_bank_loader directory-walk
#   FSM (load_by_id), coef_bank_manager {by_id,id} request + load_failed,
#   dac_coef_subsys filter_id/filter_load_req path + load_err export,
#   dac_ctrl_plane sticky[6] + CMD_ERR_INFO 0xA/0xB, spi_slave frame_err,
#   qspi_flash_ctrl watchdog. Full RTL synth + IMPLEMENTATION at 5M scale
#   (NUM_MACS=1280, TAPS_PER_PHASE=256 -> 5,242,880 taps, x2 banks in URAM),
#   real DDR4 MIG + AXI width converter included.
#   vivado -mode batch -source scripts/impl_top_f15.tcl -journal impl_f15.jou -log impl_f15.log
#
#   Flow = f14 synth + f14b place/route in ONE session. f14b lesson: no
#   placed-checkpoint write (ShapeDB writer OOM'd on this box); synth and
#   routed checkpoints only.
#   f15b lesson (2026-09-03): write the routed DCP IMMEDIATELY after the
#   timing report. report_cdc + report_design_analysis lifted peak memory
#   to 33.4 GB on a 27.7 GB box and the subsequent PlaceStorage write hung
#   (0 CPU, 1 GB free) for 12 h. All reports had been written; DCP was lost.
#   Result on record: impl_f15b_route_timing.rpt WNS 0.000 / TNS 0.000.
set_param general.maxThreads 8

# ---- Design scale (single point of control, 2026-08-17) ---------------------
# taps = 16 phases * NUM_MACS * TAPS_PER_PHASE (x2 banks resident in URAM).
# NUM_MACS: any multiple of 64 (URAM group tree) AND of 4 (SLR bucketing);
#           power of 2 NOT required (adder tree zero-pads). URAMs = NUM_MACS/2
#           (max 1280 on VU13P -> NUM_MACS <= 2560 hard ceiling).
# TAPS_PER_PHASE: power of 2, max 256 (URAM depth 4096 with dual-bank packing).
# Examples: 1024x256 = 4,194,304 (4M) | 1280x256 = 5,242,880 (5M)
set NUM_MACS       256
set TAPS_PER_PHASE 256
if {$NUM_MACS % 64 != 0} { error "NUM_MACS ($NUM_MACS) must be a multiple of 64" }
if {$NUM_MACS > 2560}    { error "NUM_MACS ($NUM_MACS) needs [expr {$NUM_MACS/2}] URAMs; VU13P has 1280" }

# RTL — exclude the simulation stub dac_ddr4_if.sv (dac_ddr4_if_mig.sv is
# the synthesis implementation of module dac_ddr4_if) and the superseded
# flash_bridge.sv.
set sv_files [glob *.sv]
set sv_files [lsearch -all -inline -not -exact $sv_files "dac_ddr4_if.sv"]
set sv_files [lsearch -all -inline -not -exact $sv_files "flash_bridge.sv"]
read_verilog -sv $sv_files

# Generated IP (OOC checkpoints from scripts/gen_ddr4_mig.tcl)
read_ip ip/ddr4_0/ddr4_0.xci
read_ip ip/axi_dwc_coef/axi_dwc_coef.xci

read_xdc vu13p_dac_top.xdc

synth_design -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i \
    -generic NUM_MACS=$NUM_MACS -generic TAPS_PER_PHASE=$TAPS_PER_PHASE

report_utilization    -file impl_f16_synth_utilization.rpt
# New CDC crossings this round (filter_id/load_req 200m->dsp_clk->ui_clk,
# load_err ui_clk->200m): verify the XDC false-path/max-delay scoping took.
report_cdc            -file impl_f16_synth_cdc.rpt
write_checkpoint -force impl_f16_synth.dcp

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
report_utilization    -file impl_f16_place_utilization.rpt
phys_opt_design
# NO placed-checkpoint write (f14 OOM) — proceed straight to route
route_design

# Post-route phys_opt (added 2026-08-15): the f9wc route left ~4k shallow
# violations (WNS -0.41, avg -0.07 per endpoint). Post-route placement/rewire
# optimization typically recovers this class of miss.
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}
# f13f lesson (2026-08-25): the FIR rd/wr_addr s2->s3 fanout residue closes
# with driver replication, not placement exploration.
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveFanoutOpt
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f16_route_utilization.rpt
report_timing_summary -file impl_f16_route_timing.rpt -max_paths 50
write_checkpoint -force impl_f16_routed.dcp
report_cdc            -file impl_f16_route_cdc.rpt
report_design_analysis -congestion -file impl_f16_congestion.rpt

puts "impl_f16_OK: vu13p_dac_top routed; reports written"
