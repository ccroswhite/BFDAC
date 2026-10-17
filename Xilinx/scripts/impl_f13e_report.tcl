# f13e (2026-08-24): apply the halfband product->accumulator 2-cycle MCP
# (true multicycle: products load on valid_pipe[0], acc captures on
# valid_pipe[2], input spacing >> 2 clks) on the f13d routed checkpoint and
# re-report. No routing changes — the exception corrects the requirement on
# the 25 residual -0.031 endpoints.
#   vivado -mode batch -source scripts/impl_f13e_report.tcl -journal impl_f13e.jou -log impl_f13e.log
set_param general.maxThreads 8

open_checkpoint impl_f13d_routed.dcp

set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/products_reg* || NAME =~ u_dsp_core/u_hb*/center_product_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/acc_filtered_reg*}]
set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/products_reg* || NAME =~ u_dsp_core/u_hb*/center_product_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ u_dsp_core/u_hb*/acc_filtered_reg*}]

report_timing_summary -file impl_f13e_route_timing.rpt -max_paths 50
write_checkpoint -force impl_f13e_routed.dcp

puts "IMPL_F13E_OK: timing re-reported with halfband MCP"
