# tb_vu13p_top.tcl - launch full-top integration testbench in Vivado XSim
#
# Usage (Vivado Tcl console):
#   source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_vu13p_top.tcl}
#
# Requires unisims (IBUFDS/MMCME4_BASE/BUFG/OBUFDS) - Vivado's
# launch_simulation compiles them automatically.

set tb_src  {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_vu13p_top.sv}

if {[lsearch [get_files] $tb_src] < 0} {
    add_files -fileset sim_1 -norecurse $tb_src
}

set_property top     tb_vu13p_top   [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/sim_defines.tcl}

launch_simulation -simset sim_1 -mode behavioral
# MMCM lock (~ tens of us) + automute sequences + 80 us toggle window
run 500us
