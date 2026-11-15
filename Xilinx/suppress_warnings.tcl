# =============================================================================
# suppress_warnings.tcl — Scoped Vivado message pruning for the 5.24M build
#
# Sourced by run_synth_5m.tcl before synth_design.  Entries are string-scoped
# wherever possible so a suppression only silences the KNOWN-benign instance —
# new/unexpected instances of the same message ID still fire.  Broad classes
# are demoted to INFO, not suppressed, so they remain greppable in the log.
# =============================================================================

# --- URAM288 port-map noise -------------------------------------------------
# CAS_OUT_* (cascade), DBITERR/SBITERR/RDACCESS (ECC status) are output-only
# pins intentionally left open: our URAMs are standalone, ECC disabled.
set_msg_config -id {Synth 8-7071} -string {URAM288} -suppress

# --- Intentional constant-driven outputs -------------------------------------
# cf_dq[3:2]/qspi1_dq[3:2] static-high in x1 flash mode; relay_level default.
set_msg_config -id {Synth 8-3917} -suppress

# --- Known unconnected/no-load ports ----------------------------------------
# cal_data_a[23:18]: shared 24-bit cal word, a_coef explicitly truncates to 18.
# led_status/mclk_n: board-level spares with no internal load.
set_msg_config -id {Synth 8-7129} -string {cal_data_a} -suppress
set_msg_config -id {Synth 8-7129} -string {led_status} -suppress
set_msg_config -id {Synth 8-7129} -string {mclk_n}     -suppress

# --- Verified dead registers (reviewed 2026-11-12) ---------------------------
# act_r: written but never read in dpd_engine (latched activation, debug-only).
# boundary_rev_reg_reg[0]: tail of reverse systolic chain, no consumer.
# cf_div_reg/hdr_cnt_reg/rec_dest_reg/fifo_count_reg/bank_id_reg/new_index_reg:
#   residue from earlier control-plane iterations, verified unreferenced.
# tag_pipe_reg[78:95]: dead MSBs of the I2S tag pipeline.
set_msg_config -id {Synth 8-6014} -string {act_r_reg}            -suppress
set_msg_config -id {Synth 8-6014} -string {boundary_rev_reg}     -suppress
set_msg_config -id {Synth 8-6014} -string {cf_div_reg}           -suppress
set_msg_config -id {Synth 8-6014} -string {hdr_cnt_reg}          -suppress
set_msg_config -id {Synth 8-6014} -string {rec_dest_reg}         -suppress
set_msg_config -id {Synth 8-6014} -string {fifo_count_reg}       -suppress
set_msg_config -id {Synth 8-6014} -string {bank_id_reg}          -suppress
set_msg_config -id {Synth 8-6014} -string {new_index_reg}        -suppress
set_msg_config -id {Synth 8-6014} -string {tag_pipe_reg}         -suppress

# --- Parameterization trimming -----------------------------------------------
# products_reg/shreg/pre_add dead MSBs in halfband_x2: datapath is narrower
# than the declared vector by construction.
set_msg_config -id {Synth 8-3332} -string {products_reg} -suppress
set_msg_config -id {Synth 8-3332} -string {shreg_reg}    -suppress
set_msg_config -id {Synth 8-3332} -string {pre_add_reg}  -suppress

# --- Broad classes: demote, don't hide ----------------------------------------
# Remaining pruning/dead-element reports stay in the log at INFO severity so
# new dead logic is still visible when grepping, without WARNING noise.
set_msg_config -id {Synth 8-6014} -new_severity INFO
set_msg_config -id {Synth 8-3332} -new_severity INFO
set_msg_config -id {Synth 8-7129} -new_severity INFO
