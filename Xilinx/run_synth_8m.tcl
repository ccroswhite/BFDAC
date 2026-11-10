# =============================================================================
# run_synth_8m.tcl — Vivado Non-Project Synthesis for BFDAC 8.39M-Tap (x2 -> x8)
# Target: XCVU13P-2FHGB2104I (xcvu13p-fhgb2104-2-i)
# Effective Taps: 2 (fold) * 2 (S1A) * 128 (MACs) * 2048 (TPP) * 8 (S1B) = 8,388,608
# =============================================================================

set PART           "xcvu13p-fhgb2104-2-i"
set TOP            "vu13p_dac_top"
set NUM_MACS       [expr {[info exists ::env(NUM_MACS)]       ? $::env(NUM_MACS)       : 128}]
set TAPS_PER_PHASE [expr {[info exists ::env(TAPS_PER_PHASE)] ? $::env(TAPS_PER_PHASE) : 256}]
set OUT_DIR        [expr {[info exists ::env(OUT_DIR)]        ? $::env(OUT_DIR)        : "build_8m"}]
set SRC_ROOT       [expr {[info exists ::env(SRC_ROOT)]       ? $::env(SRC_ROOT)       : "."}]

file mkdir $OUT_DIR
set_param general.maxThreads 8
create_project -in_memory -part $PART

# -----------------------------------------------------------------------------
# 1. Discover & Read SystemVerilog / Verilog RTL (excluding testbenches & build dirs)
# -----------------------------------------------------------------------------
proc find_files {basedir pattern} {
    set result {}
    foreach f [glob -nocomplain -directory $basedir -types f $pattern] {
        lappend result $f
    }
    foreach d [glob -nocomplain -directory $basedir -types d *] {
        set tail [file tail $d]
        if {[string match "build*" $tail] || [string match "*.gen" $tail] ||
            [string match "*.srcs" $tail] || [string match "xsim*" $tail] ||
            [string match ".git*" $tail]  || [string match "*.ip_user_files" $tail]} {
            continue
        }
        set result [concat $result [find_files $d $pattern]]
    }
    return $result
}

set sv_files {}
foreach f [find_files $SRC_ROOT "*.sv"] {
    set base [file tail $f]
    if {[string match "tb_*" $base] || [string match "*_tb.sv" $base] ||
        [string match "uram_quad_coef_bank.sv" $base]} {
        continue
    }
    lappend sv_files $f
}

if {[lsearch -glob $sv_files "*fir_stage1b_interp8.sv"] < 0} {
    error "ERROR: fir_stage1b_interp8.sv not found under $SRC_ROOT!"
}

puts "INFO: Reading [llength $sv_files] SystemVerilog RTL files..."
read_verilog -sv $sv_files

set v_files [find_files $SRC_ROOT "*.v"]
if {[llength $v_files] > 0} {
    puts "INFO: Reading [llength $v_files] Verilog files..."
    read_verilog $v_files
}

# -----------------------------------------------------------------------------
# 2. Read IP Cores (.xci, e.g., DDR4 MIG C0) & Constraints (.xdc)
# -----------------------------------------------------------------------------
set xci_files [find_files $SRC_ROOT "*.xci"]
if {[llength $xci_files] > 0} {
    puts "INFO: Reading [llength $xci_files] IP (.xci) cores..."
    read_ip $xci_files
    upgrade_ip -quiet [get_ips]
    generate_target {synthesis implementation} [get_ips]
    # Synthesize any IP lacking an out-of-context DCP
    foreach ip [get_ips] {
        set dcp_list [get_files -quiet -of_objects $ip *.dcp]
        if {[llength $dcp_list] == 0} {
            synth_ip $ip
        }
    }
}

set xdc_files [find_files $SRC_ROOT "*.xdc"]
if {[llength $xdc_files] > 0} {
    puts "INFO: Reading [llength $xdc_files] constraint (.xdc) files..."
    read_xdc $xdc_files
} else {
    puts "WARNING: No .xdc constraint files found under $SRC_ROOT!"
}

# -----------------------------------------------------------------------------
# 3. Synthesize Design (DO NOT define SIM — keeps hardware URAM288 primitives)
# -----------------------------------------------------------------------------
puts "INFO: Launching synth_design with NUM_MACS=$NUM_MACS, TAPS_PER_PHASE=$TAPS_PER_PHASE..."
synth_design \
    -top $TOP \
    -part $PART \
    -generic NUM_MACS=$NUM_MACS \
    -generic TAPS_PER_PHASE=$TAPS_PER_PHASE \
    -directive PerformanceOptimized \
    -flatten_hierarchy rebuilt

# -----------------------------------------------------------------------------
# 4. Verify Primitive Inference & Save Checkpoint / Reports
# -----------------------------------------------------------------------------
set bram_all [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]
set bram_dob [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.* && DOB_REG == 1}]
set uram_all [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]
set dsp_all  [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ ARITHMETIC.DSP.*}]
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

puts "INFO: Synthesis complete. Checkpoint written to $OUT_DIR/post_synth.dcp"
exit