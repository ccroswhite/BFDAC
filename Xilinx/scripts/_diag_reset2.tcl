open_checkpoint build/5m/post_route.dcp
set rst_cells [get_cells -hierarchical -filter {NAME =~ *dsp_rst_tree_n_reg*}]
set tp_rst [get_timing_paths -from $rst_cells -slack_less_than 0 -max_paths 20000 -nworst 1]
array set buckets {}
foreach p $tp_rst {
    set ep [get_property ENDPOINT_PIN $p]
    regsub {/[^/]*$} $ep "" cellname
    regsub {^(u_dsp_core/u_stereo_fir|u_dsp_core|u_coef_subsys|u_ctrl_plane|u_i2s_ingress|u_cal_store|u_stream_rate|u_bench_controller|u_bench_stimulus).*} $cellname {\1} mod
    incr buckets($mod)
}
puts "=== rst_tree failing endpoints by module ==="
foreach m [lsort [array names buckets]] { puts "  $m : $buckets($m)" }
# non-reset failures: sample worst
set tp_all [get_timing_paths -to [get_clocks dsp_clk] -slack_less_than 0 -max_paths 20000 -nworst 1]
puts "=== non-rst failing endpoints (by startpoint cell, top 15) ==="
array set sp {}
foreach p $tp_all {
    set s [get_property STARTPOINT_PIN $p]
    regsub {/[^/]*$} $s "" sc
    if {[lsearch -exact $rst_cells $sc] >= 0} continue
    incr sp($sc)
}
set sorted [lsort -stride 2 -index 1 -integer -decreasing [array get sp]]
foreach {k v} [lrange $sorted 0 29] { puts "  $k : $v" }
