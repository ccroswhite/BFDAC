# sim_defines.tcl — Common simulation define macros
#
# Sourced by every TB launch script before launch_simulation.
#
# Defines:
#   SIM        — always set; gates sim-only RTL blocks (URAM behavioral model,
#                MAC debug counters, etc.)  Excluded from synthesis automatically.
#   SIM_DEBUG  — optional; enables verbose $display output in RTL and testbenches.
#                Pass -debug on the command line or uncomment below to enable.
#
# Usage in RTL:
#   `ifdef SIM
#       // simulation-only code
#       `ifdef SIM_DEBUG
#           $display("...");
#       `endif
#   `endif
#
# Usage from Vivado Tcl console (enable verbose debug):
#   set sim_debug 1
#   source sim_defines.tcl
#   source tb_dac_dsp_core.tcl
#
# -------------------------------------------------------------------------

# Always define SIM for behavioral simulation
set_property verilog_define "SIM" [get_filesets sim_1]

# Optionally add SIM_DEBUG if sim_debug flag is set
if {[info exists sim_debug] && $sim_debug} {
    set_property verilog_define "SIM SIM_DEBUG" [get_filesets sim_1]
    puts "  \[sim_defines\] SIM + SIM_DEBUG enabled (verbose logging ON)"
} else {
    puts "  \[sim_defines\] SIM enabled, SIM_DEBUG disabled (set sim_debug 1 to enable verbose logs)"
}
