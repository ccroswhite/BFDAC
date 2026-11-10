#!/usr/bin/env bash
set -euo pipefail

export NUM_MACS="${NUM_MACS:-128}"
export TAPS_PER_PHASE="${TAPS_PER_PHASE:-256}"
export OUT_DIR="${OUT_DIR:-build_8m}"
export SRC_ROOT="${SRC_ROOT:-.}"

mkdir -p "$OUT_DIR"

echo "=== [1/2] Running 8.39M-Tap Synthesis (NUM_MACS=$NUM_MACS, TAPS_PER_PHASE=$TAPS_PER_PHASE) ==="
vivado -mode batch -nojournal -log "$OUT_DIR/vivado_synth.log" -source run_synth_8m.tcl

echo "=== [2/2] Running 8.39M-Tap Place & Route ==="
vivado -mode batch -nojournal -log "$OUT_DIR/vivado_pnr.log" -source run_pnr_8m.tcl