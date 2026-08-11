# Batch-mode wrapper: open project, run tb_coef_bank_loader via launch_simulation
open_project {C:/Users/ccros/BFDAC-XCVU13P/BFDAC-XCVU13P.xpr}
source {C:/Users/ccros/src/BFDAC/Xilinx/Testbench/tb_coef_bank_loader.tcl}
run 10ms
close_sim -force
close_project
exit
