# =============================================================================
# run_synth_8m.tcl — Vivado Non-Project Synthesis for BFDAC 8.39M-Tap (x2 -> x8)
# Aligned with scripts/synth_f18_5M_cf.tcl (no legacy/sub-IP XDC pollution)
# =============================================================================

set PART           "xcku15p-ffve1517-2-i"
set TOP            "acku15s_dac_top"
set NUM_MACS       [expr {[info exists ::env(NUM_MACS)]       ? $::env(NUM_MACS)       : 80}]
set TAPS_PER_PHASE [expr {[info exists ::env(TAPS_PER_PHASE)] ? $::env(TAPS_PER_PHASE) : 256}]
set OUT_DIR        [expr {[info exists ::env(OUT_DIR)]        ? $::env(OUT_DIR)        : "build_8m"}]

file mkdir $OUT_DIR
set_param general.maxThreads 8
create_project -in_memory -part $PART

# Scoped message pruning (string-filtered; known-benign instances only)
source suppress_warnings.tcl

set sv_files {}
foreach f [glob *.sv] {
    if {[string match "tb_*" $f] || [string match "*_tb.sv" $f] ||
        $f eq "dac_ddr4_if.sv"   || $f eq "flash_bridge.sv"     ||
        $f eq "uram_quad_coef_bank.sv"} {
        continue
    }
    lappend sv_files $f
}

if {[lsearch -exact $sv_files "fir_stage1b_interp8.sv"] < 0} {
    error "ERROR: fir_stage1b_interp8.sv not found in working directory!"
}

puts "INFO: Reading [llength $sv_files] SystemVerilog RTL files..."
read_verilog -sv $sv_files

read_ip ip/ddr4_0/ddr4_0.xci
read_ip ip/axi_dwc_coef/axi_dwc_coef.xci
read_xdc acku15s_dac_top.xdc

puts "INFO: Launching synth_design with NUM_MACS=$NUM_MACS, TAPS_PER_PHASE=$TAPS_PER_PHASE..."
synth_design \
    -top $TOP \
    -part $PART \
    -generic NUM_MACS=$NUM_MACS \
    -generic TAPS_PER_PHASE=$TAPS_PER_PHASE

set bram_all [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]
set bram_dob [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.* && DOB_REG == 1}]
set uram_all [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]
set dsp_all  [get_cells -quiet -hierarchical -filter {REF_NAME =~ DSP48E*}]
set lram_all [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ DMEM.DRAM.*}]

puts "========================================================================="
puts "POST-SYNTHESIS PRIMITIVE AUDIT (8.39M-Tap Two-Stage Build)"
puts "  DSP48E2 slices        : [llength $dsp_all]"
puts "  URAM288 tiles         : [llength $uram_all]"
puts "  RAMB18/RAMB36 tiles   : [llength $bram_all] (with DOB_REG=1: [llength $bram_dob])"
puts "  Distributed LUTRAMs   : [llength $lram_all]"
puts "========================================================================="

write_checkpoint -force "$OUT_DIR/post_synth.dcp"
report_utilization -file "$OUT_DIR/synth_utilization.rpt"
report_utilization -hierarchical -hierarchical_depth 4 -file "$OUT_DIR/synth_utilization_hier.rpt"
report_timing_summary -max_paths 20 -file "$OUT_DIR/synth_timing_summary.rpt"
report_cdc -file "$OUT_DIR/synth_cdc.rpt"

puts "INFO: Synthesis complete. Checkpoint written to $OUT_DIR/post_synth.dcp"
exit
