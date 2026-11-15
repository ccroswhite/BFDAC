# 10.48M-tap hybrid-BRAM synthesis check: NUM_MACS=1280, TAPS_PER_PHASE=256
set_param general.maxThreads 8
read_verilog -sv [glob polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_polyphase_stereo.sv]
synth_design -mode out_of_context -top fir_polyphase_stereo -part xcku15p-ffve1517-2-i \
    -generic NUM_MACS=1280 -generic TAPS_PER_PHASE=256 \
    -generic SYM_FOLD_EN=1 -generic QUAD_URAM_EN=1 -generic WIN_BRAM_EN=1
report_utilization -file synth_10M_util.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file synth_10M_util_hier.rpt
report_timing_summary -file synth_10M_timing.rpt -max_paths 10
write_checkpoint -force synth_10M.dcp
