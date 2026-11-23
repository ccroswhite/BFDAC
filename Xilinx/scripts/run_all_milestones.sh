#!/usr/bin/env bash
set -euo pipefail

# xsim exits 0 even on $fatal, so each run tees to a per-sim log and greps for
# real failures.  A TB-declared FAIL/Fatal aborts the script with a nonzero
# status instead of silently reporting green.
run_sim() {
    local name="$1"
    xsim "$name" -R | tee "sim_${name}.log"
    if grep -qE "Fatal:|FAIL:|Error:" "sim_${name}.log"; then
        echo "*** ${name}: simulation FAILED (see sim_${name}.log) ***" >&2
        exit 1
    fi
}

echo "=== [1/6] Milestone 1: Standalone 1,280-Input Time-Multiplexed Adder Tree ==="
xvlog -sv polyphase_adder_tree.sv Testbench/legacy_fir_milestones/tb_fir_milestone1.sv
xelab tb_fir_milestone1 -s sim_m1
run_sim sim_m1

echo "=== [2/6] Milestone 1: Full Interpolator + MAC + Adder Tree (SYM_FOLD_EN=0, rate_shift 0..3) ==="
xvlog -sv polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv Testbench/legacy_fir_milestones/tb_fir_interp_m1.sv
xelab tb_fir_interp_m1 -s sim_interp_m1
run_sim sim_interp_m1

echo "=== [3/6] Milestone 2: Bit-Exact Option B Half-Curve Fold (SYM_FOLD_EN=1, rate_shift 0..3) ==="
xvlog -sv polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv Testbench/legacy_fir_milestones/tb_fir_interp_m2.sv
xelab tb_fir_interp_m2 -s sim_interp_m2
run_sim sim_interp_m2

echo "=== [4/6] Milestone 3: Stereo Wrapper + Quad-MAC URAM288 + Half-Curve Fold ==="
xvlog -sv -d SIM polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_stage1b_interp8.sv fir_polyphase_stereo.sv Testbench/legacy_fir_milestones/tb_fir_stereo_m3.sv
xelab tb_fir_stereo_m3 -s sim_stereo_m3
run_sim sim_stereo_m3

echo "=== [5/6] Full DSP Core Compilation Check (Milestones 1..3 Integrated) ==="
xvlog -sv -d SIM polyphase_mac_engine.sv polyphase_adder_tree.sv fir_polyphase_interpolator.sv fir_stage1b_interp8.sv fir_polyphase_stereo.sv halfband_x2.sv noise_shaper_ef3.sv dpd_engine.sv dem_sort.sv dac_dsp_core.sv

echo "=== ALL MILESTONES (1..3) VERIFIED BIT-EXACT ==="
