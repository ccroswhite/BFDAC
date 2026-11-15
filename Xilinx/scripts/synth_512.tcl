# Synthesis test for 512 MAC design
set_param general.maxThreads 8
read_verilog -sv [glob *.sv]
synth_design -top dac_dsp_core -part xc7k70tfbv676-1 -generic NUM_MACS=1024
report_utilization -file utilization_512.rpt
report_timing_summary -file timing_512.rpt -max_paths 10
write_checkpoint -force synth_512.dcp
