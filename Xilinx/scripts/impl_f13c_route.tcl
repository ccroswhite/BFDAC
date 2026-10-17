# f13c (2026-08-24): incremental re-route of f13b with the gray-MSB alias
# exception. f13b left exactly ONE failing endpoint: wptr_bin_reg[4] ->
# wptr_gray_ui1_reg[4] — synthesis merged the gray MSB register into the
# binary pointer (gray[4]==bin[4]), so the "-from *gray_reg" CDC exception
# missed that bit. XDC updated; this run applies the same exception on the
# routed checkpoint and lets the router clean the single path.
#   vivado -mode batch -source scripts/impl_f13c_route.tcl -journal impl_f13c.jou -log impl_f13c.log
set_param general.maxThreads 8

open_checkpoint impl_f13b_routed.dcp

set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/wptr_bin_reg[*]}] \
    -to   [get_cells {u_boot_loader/wptr_gray_ui1_reg[*]}]
set_max_delay -datapath_only 3.3 \
    -from [get_cells {u_boot_loader/rptr_bin_reg[*]}] \
    -to   [get_cells {u_boot_loader/rptr_gray_c1_reg[*]}]

route_design

report_utilization    -file impl_f13c_route_utilization.rpt
report_timing_summary -file impl_f13c_route_timing.rpt -max_paths 50
report_design_analysis -congestion -file impl_f13c_congestion.rpt
write_checkpoint -force impl_f13c_routed.dcp

puts "IMPL_F13C_OK: vu13p_dac_top routed; reports written"
