# Step 4C.3 - Phase 1 elaboration of acku15s_dac_top + utilization estimate
# Run from Xilinx/ so $readmemh coefficient files resolve:
#   vivado -mode batch -source scripts/elab_top.tcl -journal elab_top.jou -log elab_top.log
set_param general.maxThreads 8

# RTL sources only (testbenches live in Testbench/, not globbed)
# Exclude dac_ddr4_if_mig.sv: it wraps the Vivado ddr4_0 IP (+ axi_dwc_coef)
# which is out-of-fileset until ACKU15S-3 regenerates the MIG. The dac_ddr4_if.sv
# stub provides the module for elaboration/sim.
set srcs [glob *.sv]
set srcs [lsearch -all -inline -not -glob $srcs *dac_ddr4_if_mig.sv]
read_verilog -sv $srcs

# Elaborate (RTL analysis) - validates top-level wiring, port widths,
# parameter propagation. XDC is NOT applied in -rtl mode; full XDC object
# validation happens at Phase 5.1 first synthesis.
# Scoped suppressions for verified-benign warnings (same set as 5m synth flow)
source [file join [file dirname [info script]] suppress_warnings.tcl]

synth_design -rtl -top acku15s_dac_top -part xcku15p-ffve1517-2-i

puts "ELAB_OK: acku15s_dac_top elaborated (rtl mode - no utilization report)"
catch {report_utilization -file elab_utilization.rpt}
