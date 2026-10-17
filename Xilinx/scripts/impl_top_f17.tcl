# f17 — MIG-SIM FIXES (2026-09-04, progress.md "Step 4.4 residue"):
#   1) dac_coef_subsys coef write bus ui_clk->dsp_clk is now a 32-deep gray-pointer
#      async FIFO (+ coef_stall into coef_bank_loader, load_done gated on drain);
#      XDC §9 items 3/4 rewritten for cf_*ptr_* / cfifo_mem.
#   2) dac_ddr4_if_mig AxCACHE = 0011 so axi_dwc_coef packs 128b -> 512b beats.
#   Geometry unchanged from f16/f16b (1M-tap release, NUM_MACS=256 x TPP=256,
#   f16b baseline WNS +0.249 / WHS +0.010).
#   vivado -mode batch -source scripts/impl_top_f17.tcl -journal impl_f17.jou -log impl_f17.log
#
#   Flow = f16 (synth + place + route in one session; routed DCP written before
#   report_cdc / report_design_analysis). f16 single-session run vanished in
#   place_design Phase 4.1 once — if that recurs, restart from impl_f17_synth.dcp
#   with the f16b place/route script pattern.
set_param general.maxThreads 8

# ---- Design scale (single point of control, 2026-08-17) ---------------------
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

# ---- New-CDC binding check (f17): the §9 FIFO patterns must match cells and
# the crossings must carry the datapath-only 3.3 ns requirement, not the raw
# ui_clk/dsp_clk edge alignment.
foreach pat {u_coef_subsys/cf_wptr_gray_d1_reg[*] u_coef_subsys/cf_rptr_gray_u1_reg[*] \
             u_coef_subsys/cf_wptr_bin_reg[*] u_coef_subsys/cf_rptr_bin_reg[*] \
             u_coef_subsys/coef_wdata_reg[*]} {
    puts "F17 CDC cells: $pat -> [llength [get_cells -quiet $pat]]"
}
puts "F17 CDC cells: cfifo_mem* -> [llength [get_cells -quiet -hierarchical -filter {NAME =~ u_coef_subsys/cfifo_mem*}]]"
foreach {nm from to} [list \
    wptr  {u_coef_subsys/cf_wptr_gray_reg[*] u_coef_subsys/cf_wptr_bin_reg[*]} {u_coef_subsys/cf_wptr_gray_d1_reg[*]} \
    rptr  {u_coef_subsys/cf_rptr_gray_reg[*] u_coef_subsys/cf_rptr_bin_reg[*]} {u_coef_subsys/cf_rptr_gray_u1_reg[*]} \
    mem   {} {u_coef_subsys/coef_wdata_reg[*]}] {
    if {$from eq ""} {
        set p [get_timing_paths -quiet -to [get_cells -quiet $to] -max_paths 1 -nworst 1]
    } else {
        set p [get_timing_paths -quiet -from [get_cells -quiet $from] -to [get_cells -quiet $to] -max_paths 1 -nworst 1]
    }
    if {[llength $p]} {
        puts "F17 CDC check $nm: requirement = [get_property REQUIREMENT $p] slack = [get_property SLACK $p]"
    } else {
        puts "F17 CDC check $nm: NO PATH FOUND (pattern stale?)"
    }
}

report_utilization    -file impl_f17_synth_utilization.rpt
report_cdc            -file impl_f17_synth_cdc.rpt
write_checkpoint -force impl_f17_synth.dcp

opt_design

# --- SLR pblocks (unchanged since f9/f15) -------------------------------------
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
report_utilization    -file impl_f17_place_utilization.rpt
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

report_utilization    -file impl_f17_route_utilization.rpt
report_timing_summary -file impl_f17_route_timing.rpt -max_paths 50
write_checkpoint -force impl_f17_routed.dcp
report_cdc            -file impl_f17_route_cdc.rpt
report_design_analysis -congestion -file impl_f17_congestion.rpt

puts "impl_f17_OK: vu13p_dac_top routed; reports written"
