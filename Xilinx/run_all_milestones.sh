#!/usr/bin/env bash
set -euo pipefail

echo "=== [1/6] Milestone 1: Standalone 1,280-Input Time-Multiplexed Adder Tree ==="
xvlog -sv polyphase_adder_tree.sv tb_fir_milestone1.sv
xelab tb_fir_milestone1 -s sim_m1
xsim sim_m1 -R

echo "=== [2/6] Milestone 1: Full Interpolator + MAC + Adder Tree (SYM_FOLD_EN=0, rate_shift 0..3) ==="
xvlog -sv polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv tb_fir_interp_m1.sv
xelab tb_fir_interp_m1 -s sim_interp_m1
xsim sim_interp_m1 -R

echo "=== [3/6] Milestone 2: Bit-Exact Option B Half-Curve Fold (SYM_FOLD_EN=1, rate_shift 0..3) ==="
xvlog -sv polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv tb_fir_interp_m2.sv
xelab tb_fir_interp_m2 -s sim_interp_m2
xsim sim_interp_m2 -R

echo "=== [4/6] Milestone 3: Stereo Wrapper + Quad-MAC URAM288 + Half-Curve Fold ==="
xvlog -sv -d SIM polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_polyphase_stereo.sv tb_fir_stereo_m3.sv
xelab tb_fir_stereo_m3 -s sim_stereo_m3
xsim sim_stereo_m3 -R

echo "=== [5/6] Milestone 4: 8-Band Stereo Double-Precision PEQ Engine ==="
xvlog -sv dac_peq_engine.sv tb_dac_peq_m4.sv
xelab tb_dac_peq_m4 -s sim_peq_m4
xsim sim_peq_m4 -R

echo "=== [6/6] Full DSP Core Compilation Check (Milestones 1..4 Integrated) ==="
xvlog -sv -d SIM polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_polyphase_stereo.sv dac_peq_engine.sv halfband_x2.sv noise_shaper_ef3.sv dpd_engine.sv dem_sort.sv dac_dsp_core.sv

echo "=== ALL MILESTONES (1..4) VERIFIED BIT-EXACT ==="
