# tb_coef_bank_loader.tcl — Vivado XSim launch script
#
# Usage (quiet):   source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_coef_bank_loader.tcl}
# Usage (verbose): set sim_debug 1 ; source {C:/...}

set tb_src {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_coef_bank_loader.sv}

if {[lsearch [get_files] $tb_src] < 0} {
    add_files -fileset sim_1 -norecurse $tb_src
}

set_property top     tb_coef_bank_loader [get_filesets sim_1]
set_property top_lib xil_defaultlib      [get_filesets sim_1]

source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/sim_defines.tcl}

launch_simulation -simset sim_1 -mode behavioral
run 5ms
