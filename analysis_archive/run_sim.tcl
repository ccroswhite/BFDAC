# =============================================================================
# run_sim.tcl  —  Vivado xsim batch simulation script
#
# Usage (from Vivado Tcl Console or batch):
#   vivado -mode batch -source run_sim.tcl
#
# Or interactively in the Tcl console:
#   source {C:/Users/ccros/src/BFDAC/Xilinx/run_sim.tcl}
#
# Debug output: set SIM_DEBUG 1 before sourcing (or edit below) to enable
# `ifdef SIM_DEBUG blocks in all testbenches:
#   set SIM_DEBUG 1 ; source run_sim.tcl
#
# Each testbench is compiled, elaborated, and run to $stop.
# Pass/Fail lines are written to the transcript.
# =============================================================================

set RTL_DIR   [file normalize [file dirname [info script]]]
set TB_DIR    "$RTL_DIR/Testbench"
set WORK_DIR  "$RTL_DIR/xsim_work"

# Set to 1 to enable [DEBUG] output in testbenches (ifdef SIM_DEBUG)
if {![info exists SIM_DEBUG]} { set SIM_DEBUG 0 }

file mkdir $WORK_DIR

# -----------------------------------------------------------------------------
# RTL source list (order matters — dependencies first)
# -----------------------------------------------------------------------------
set rtl_sources [list \
    $RTL_DIR/async_fifo.sv           \
    $RTL_DIR/async_fifo_wide.sv      \
    $RTL_DIR/spi_slave.sv            \
    $RTL_DIR/i2s_rx.sv               \
    $RTL_DIR/dac_i2s_ingress.sv      \
    $RTL_DIR/dac_ctrl_plane.sv       \
    $RTL_DIR/coef_bram.sv            \
    $RTL_DIR/coef_bank_loader.sv     \
    $RTL_DIR/coef_bank_manager.sv    \
    $RTL_DIR/dac_coef_subsys.sv      \
    $RTL_DIR/automute_controller.sv  \
    $RTL_DIR/volume_multiplier.sv    \
    $RTL_DIR/tpdf_dither_gen.sv      \
    $RTL_DIR/noise_shaper_ef3.sv     \
    $RTL_DIR/halfband_x2.sv          \
    $RTL_DIR/dem_64.sv               \
    $RTL_DIR/dem_dwa.sv              \
    $RTL_DIR/dem_sort.sv             \
    $RTL_DIR/dem_mapper.sv           \
    $RTL_DIR/dac_dsp_core.sv         \
]

# -----------------------------------------------------------------------------
# Testbench list: {top_module  tb_file}
# -----------------------------------------------------------------------------
set testbenches [list \
    {tb_i2s_rx            $TB_DIR/tb_i2s_rx.sv}           \
    {tb_dac_i2s_ingress   $TB_DIR/tb_dac_i2s_ingress.sv}  \
    {tb_spi_ctrl_plane    $TB_DIR/tb_spi_ctrl_plane.sv}    \
    {tb_coef_bank_loader  $TB_DIR/tb_coef_bank_loader.sv}  \
    {tb_halfband_x2       $TB_DIR/tb_halfband_x2.sv}       \
]

# -----------------------------------------------------------------------------
# Helper: compile, elaborate, simulate one testbench
# -----------------------------------------------------------------------------
proc run_tb {top tb_file rtl_sources work_dir} {
    set snap "${top}_snap"
    puts "\n============================================================"
    puts " Running: $top"
    puts "============================================================"

    # Compile RTL + TB
    set all_sources [concat $rtl_sources [list $tb_file]]
    set debug_flag  [expr {$::SIM_DEBUG ? "-d SIM_DEBUG" : ""}]
    set xvlog_args  [concat xvlog -sv --work xsim_work {*}[split $debug_flag] {*}$all_sources]
    if {[catch {exec {*}$xvlog_args} msg]} {
        puts "COMPILE ERROR: $msg"
        return
    }

    # Elaborate
    if {[catch {exec xelab -top $top -snapshot $snap \
                    --work xsim_work --debug typical} msg]} {
        puts "ELAB ERROR: $msg"
        return
    }

    # Simulate
    if {[catch {exec xsim $snap --runall --log "${work_dir}/${top}.log"} msg]} {
        puts "SIM OUTPUT:\n$msg"
    } else {
        puts "SIM OUTPUT:\n$msg"
    }

    # Print PASS/FAIL/ERROR summary lines from log (and DEBUG lines if SIM_DEBUG)
    set log_file "${work_dir}/${top}.log"
    if {[file exists $log_file]} {
        set fp [open $log_file r]
        while {[gets $fp line] >= 0} {
            if {[string match -nocase "*PASS*"     $line] ||
                [string match -nocase "*FAIL*"     $line] ||
                [string match -nocase "*ERROR*"    $line] ||
                [string match -nocase "*complete*" $line] ||
                ($::SIM_DEBUG && [string match "*\[DEBUG\]*" $line])} {
                puts "  >> $line"
            }
        }
        close $fp
    }
}

# -----------------------------------------------------------------------------
# Run all testbenches
# -----------------------------------------------------------------------------
foreach tb_entry $testbenches {
    set top     [lindex $tb_entry 0]
    set tb_file [subst [lindex $tb_entry 1]]
    run_tb $top $tb_file $rtl_sources $WORK_DIR
}

puts "\n=== All testbenches complete ==="
