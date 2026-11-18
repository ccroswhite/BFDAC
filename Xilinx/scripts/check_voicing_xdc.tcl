# Verify every cell/pin pattern in the new voicing CDC constraints resolves.
# Run from Xilinx/: vivado -mode batch -source scripts/check_voicing_xdc.tcl
set_param general.maxThreads 8
set srcs [glob *.sv]
set srcs [lsearch -all -inline -not -glob $srcs *dac_ddr4_if_mig.sv]
read_verilog -sv $srcs
synth_design -rtl -top acku15s_dac_top -part xcku15p-ffve1517-2-i

proc check {name expr} {
    set n [llength [uplevel 1 $expr]]
    puts "XDC_CHECK $name : $n match(es)"
    if {$n == 0} { puts "XDC_MISS  $name : NO MATCHES -> $expr" }
}

check commit_from {get_cells {u_ctrl_plane/voicing_commit_toggle_reg}}
check commit_to   {get_cells {u_coef_subsys/u_voicing_commit/commit_sync_reg[0]}}
check sh_from     {get_cells {u_ctrl_plane/voicing_sh_en_reg u_ctrl_plane/voicing_sh_k2_reg[*] u_ctrl_plane/voicing_sh_k3_reg[*] u_ctrl_plane/voicing_sh_fid_reg[*]}}
check pend_to     {get_cells {u_coef_subsys/u_voicing_commit/pend_en_reg u_coef_subsys/u_voicing_commit/pend_k2_reg[*] u_coef_subsys/u_voicing_commit/pend_k3_reg[*] u_coef_subsys/u_voicing_commit/pend_filter_id_reg[*]}}
check ack_from    {get_cells {u_coef_subsys/u_voicing_commit/ack_toggle_reg}}
check ack_to      {get_cells {u_ctrl_plane/vo_ack_sync_reg[0]}}
check err_from    {get_cells {u_coef_subsys/u_voicing_commit/vo_err_toggle_reg}}
check err_to      {get_cells {u_ctrl_plane/vo_err_sync_reg[0]}}
check busy_pin    {get_pins {u_ctrl_plane/vo_busy_sync_reg[0]/D}}
check eseen_pin   {get_pins {u_coef_subsys/u_voicing_commit/err_seen_sync_reg[0]/D}}
check appl_from   {get_cells {u_coef_subsys/u_coef_mgr/current_bank_r_reg[*] u_coef_subsys/u_voicing_commit/voicing_en_reg}}
check appl_to     {get_cells {u_ctrl_plane/vo_afid_r_reg[*] u_ctrl_plane/vo_aen_r_reg}}
check bchg_from   {get_cells {u_coef_subsys/voicing_bank_chg_reg}}
check bchg_to     {get_cells {u_ctrl_plane/vo_bchg_sync_reg[0]}}
puts "XDC_CHECK done"
quit
