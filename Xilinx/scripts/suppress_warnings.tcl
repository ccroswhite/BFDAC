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
set_msg_config -id {Synth 8-7129} -string {mclk_n}     -suppress

# --- Verified dead registers (reviewed 2026-11-12) ---------------------------
# boundary_rev_reg_reg[0]: tail of reverse systolic chain, no consumer.
# cf_div_reg/hdr_cnt_reg/rec_dest_reg/fifo_count_reg/new_index_reg:
#   residue from earlier control-plane iterations, verified unreferenced.
# tag_pipe_reg[78:95]: dead MSBs of the I2S tag pipeline.
# audio_frame_ready_reg: driven inside i2s_master_ingress, port explicitly
#   left unconnected at top (.audio_frame_ready()).
set_msg_config -id {Synth 8-6014} -string {boundary_rev_reg}     -suppress
set_msg_config -id {Synth 8-6014} -string {cf_div_reg}           -suppress
set_msg_config -id {Synth 8-6014} -string {hdr_cnt_reg}          -suppress
set_msg_config -id {Synth 8-6014} -string {rec_dest_reg}         -suppress
set_msg_config -id {Synth 8-6014} -string {fifo_count_reg}       -suppress
set_msg_config -id {Synth 8-6014} -string {new_index_reg}        -suppress
set_msg_config -id {Synth 8-6014} -string {tag_pipe_reg}         -suppress
set_msg_config -id {Synth 8-6014} -string {audio_frame_ready}    -suppress

# --- Parameterization trimming -----------------------------------------------
# products_reg/shreg/pre_add dead MSBs in halfband_x2: datapath is narrower
# than the declared vector by construction.
set_msg_config -id {Synth 8-3332} -string {products_reg} -suppress
set_msg_config -id {Synth 8-3332} -string {shreg_reg}    -suppress
set_msg_config -id {Synth 8-3332} -string {pre_add_reg}  -suppress

# --- Vivado netlist artifact --------------------------------------------------
# <const1> multi-term driver: internal tool net, no real netlist conflict.
set_msg_config -id {Netlist 29-1115} -string {const1} -suppress

# --- MIG phys_opt noise (P&R stage) -------------------------------------------
# u_mig_ddr4_phy carries Xilinx's DONT_TOUCH (hand-tuned PHY — must NOT be
# removed). phys_opt correctly refuses netlist edits/replication across that
# boundary; the warnings are the tool reporting it did the right thing.
# String-scoped to the MIG hierarchy so dont-touch violations in OUR RTL
# still fire.  Sources: run_pnr_5m.tcl (sourced 2026-11-23).
set_msg_config -id {Netlist 29-47}   -string {u_mig_ddr4_phy} -suppress
set_msg_config -id {Physopt 32-780}  -string {u_mig_ddr4_phy} -suppress
set_msg_config -id {Physopt 32-1483} -string {u_mig_ddr4_phy} -suppress
# "Net ... was not replicated" for the mcal_*_dly calibration-reg fanins.
set_msg_config -id {Physopt 32-782}  -string {mcal_}          -suppress

# --- Broad classes: demote, don't hide ----------------------------------------
# Remaining pruning/dead-element reports stay in the log at INFO severity so
# new dead logic is still visible when grepping, without WARNING noise.
set_msg_config -id {Synth 8-6014} -new_severity INFO
set_msg_config -id {Synth 8-3332} -new_severity INFO
set_msg_config -id {Synth 8-7129} -new_severity INFO
