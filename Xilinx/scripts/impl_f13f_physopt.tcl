# f13f (2026-08-24): phys_opt on the f13e checkpoint (halfband MCP applied).
# Remaining 15 endpoints at -0.029 are real single-cycle FIR paths:
# rd_addr_s2[7] -> rd_addr_s3[144..159] fanout, wr_addr s2->s3, cap_s3 ->
# boundary CE, one adder-tree hop. With the MCP paths out of the pool,
# phys_opt can replicate the fanout drivers instead of chasing the
# unfixable halfband adder.
#   vivado -mode batch -source scripts/impl_f13f_physopt.tcl -journal impl_f13f.jou -log impl_f13f.log
set_param general.maxThreads 8

open_checkpoint impl_f13e_routed.dcp

phys_opt_design -directive AggressiveExplore
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveFanoutOpt
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1]] < 0} {
    phys_opt_design -directive AggressiveExplore
}

report_timing_summary -file impl_f13f_route_timing.rpt -max_paths 50
report_utilization    -file impl_f13f_route_utilization.rpt
write_checkpoint -force impl_f13f_routed.dcp

puts "IMPL_F13F_OK: vu13p_dac_top routed; reports written"
