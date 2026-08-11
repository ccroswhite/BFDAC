# tb_halfband_x2.tcl — Vivado XSim launch script
#
# Usage (quiet):   source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_halfband_x2.tcl}
# Usage (verbose): set sim_debug 1 ; source {C:/...}

set tb_src {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_halfband_x2.sv}

if {[lsearch [get_files] $tb_src] < 0} {
    add_files -fileset sim_1 -norecurse $tb_src
}

set_property top     tb_halfband_x2 [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/sim_defines.tcl}

launch_simulation -simset sim_1 -mode behavioral
run 5ms
