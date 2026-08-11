# Step 4C.3 - Phase 1 elaboration of vu13p_dac_top + utilization estimate
# Run from Xilinx/ so $readmemh coefficient files resolve:
#   vivado -mode batch -source scripts/elab_top.tcl -journal elab_top.jou -log elab_top.log
set_param general.maxThreads 8

# RTL sources only (testbenches live in Testbench/, not globbed)
read_verilog -sv [glob *.sv]

# Elaborate (RTL analysis) - validates top-level wiring, port widths,
# parameter propagation. XDC is NOT applied in -rtl mode; full XDC object
# validation happens at Phase 5.1 first synthesis.
synth_design -rtl -top vu13p_dac_top -part xcvu13p-fhgb2104-2-i

report_utilization -file elab_utilization.rpt
puts "ELAB_OK: vu13p_dac_top elaborated, report in elab_utilization.rpt"
