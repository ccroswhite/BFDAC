# f13b (2026-08-23): re-route the f13 placement with the corrected boot-FIFO
# CDC exception. f12/f13 "WNS -2.05" was 513 clk_200m -> mmcm_clkout0 (ui_clk)
# endpoints: m_axi_wdata = fifo_rdata leaves qspi_boot_loader combinationally,
# so the async-FIFO read lands in the AXI upsizer's WDATA registers — the old
# XDC exception (-to u_boot_loader/*wdata*) matched nothing and the group was
# timed at the 0.336 ns unrelated-edge requirement. RTL is unchanged from f13
# (registered rd_stall included), so the placed checkpoint is reusable.
#   vivado -mode batch -source scripts/impl_f13b_route.tcl -journal impl_f13b.jou -log impl_f13b.log
set_param general.maxThreads 8

open_checkpoint impl_f13_placed.dcp

# Corrected exception (mirrors vu13p_dac_top.xdc; the old mis-scoped one
# matched nothing so it left no stale constraint in the checkpoint)
set_max_delay -datapath_only 3.3 \
    -from [get_cells -hierarchical -filter {NAME =~ u_boot_loader/fifo_mem*}]

route_design
write_checkpoint -force impl_f13b_routed_raw.dcp

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_utilization    -file impl_f13b_route_utilization.rpt
report_timing_summary -file impl_f13b_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f13b_congestion.rpt
write_checkpoint -force impl_f13b_routed.dcp

puts "IMPL_F13B_OK: vu13p_dac_top routed; reports written"
