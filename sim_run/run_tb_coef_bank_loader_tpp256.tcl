# Batch-mode wrapper: tb_coef_bank_loader with COEF_DEPTH=4096 (TB_TPP256)
# Exercises the multi-burst (4 bursts/MAC) loader path for the KU15P TPP=256 config
open_project {C:/Users/ccros/BFDAC-XCVU13P/BFDAC-XCVU13P.xpr}

set tb_src {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_coef_bank_loader.sv}
if {[lsearch [get_files] $tb_src] < 0} {
    add_files -fileset sim_1 -norecurse $tb_src
}
set_property top     tb_coef_bank_loader [get_filesets sim_1]
set_property top_lib xil_defaultlib      [get_filesets sim_1]
set_property verilog_define "SIM TB_TPP256" [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
run 80ms

# Restore default defines so subsequent runs are unaffected
set_property verilog_define "SIM" [get_filesets sim_1]
close_sim -force
close_project
exit
