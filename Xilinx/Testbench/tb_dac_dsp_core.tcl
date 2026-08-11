# tb_dac_dsp_core.tcl — launch integration testbench in Vivado XSim
#
# Usage (Vivado Tcl console, quiet):
#   source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_dac_dsp_core.tcl}
#
# Usage with verbose RTL debug output:
#   set sim_debug 1
#   source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_dac_dsp_core.tcl}

set tb_src  {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_dac_dsp_core.sv}

if {[lsearch [get_files] $tb_src] < 0} {
    add_files -fileset sim_1 -norecurse $tb_src
}

set_property top     tb_dac_dsp_core [get_filesets sim_1]
set_property top_lib xil_defaultlib  [get_filesets sim_1]

source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/sim_defines.tcl}

launch_simulation -simset sim_1 -mode behavioral
run 50ms
