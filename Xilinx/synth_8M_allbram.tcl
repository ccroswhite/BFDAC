# All-BRAM windows at 8.4M taps: win + win_rev both group-packed SDP BRAM
set_param general.maxThreads 16
read_verilog -sv [glob polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_polyphase_stereo.sv]
synth_design -mode out_of_context -top fir_polyphase_stereo -part xcvu13p-fhgb2104-2-i \
    -generic NUM_MACS=1024 -generic TAPS_PER_PHASE=256 \
    -generic SYM_FOLD_EN=1 -generic QUAD_URAM_EN=1 \
    -generic WIN_BRAM_EN=1 -generic WIN_REV_BRAM_EN=1
report_utilization -file synth_8M_ab_util.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file synth_8M_ab_util_hier.rpt
write_checkpoint -force synth_8M_ab.dcp
