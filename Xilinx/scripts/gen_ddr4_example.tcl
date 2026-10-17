# Generate the ddr4_0 example design to harvest the DDR4 SDRAM simulation
# model (Micron ddr4_model + arch/proj packages + Xilinx wrapper) that ships
# ONLY with the example project. Output tree is scratch (gitignored).
#   vivado -mode batch -source scripts/gen_ddr4_example.tcl -journal gen_ddr4_ex.jou -log gen_ddr4_ex.log
set_param general.maxThreads 8

set ex_dir [file normalize "./sim_mig/ddr4_example"]
file mkdir $ex_dir

create_project -force ddr4_ex_proj ./sim_mig/ddr4_ex_proj -part xcvu13p-fhgb2104-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

read_ip ip/ddr4_0/ddr4_0.xci
open_example_project -force -dir $ex_dir [get_ips ddr4_0]

set ep [current_project]
puts "EXAMPLE_PROJECT: [get_property DIRECTORY $ep]"
foreach f [get_files -of_objects [get_filesets sim_1]] {
    puts "SIMFILE: $f"
}
puts "DDR4_EXAMPLE_OK"
