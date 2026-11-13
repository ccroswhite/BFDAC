open_checkpoint build_8m/post_route.dcp

set paths [get_timing_paths -quiet -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -max_paths 2000 -nworst 1 -slack_lesser_than 0.0]
puts "total failing dsp_clk paths sampled: [llength $paths]"
set rst_cnt 0
set other 0
array unset seen
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    if {[string match "dsp_rst_tree_n_reg*" $sp]} { incr rst_cnt; continue }
    incr other
    set ep  [get_property ENDPOINT_PIN $p]
    set slk [get_property SLACK $p]
    set lvl [get_property LOGIC_LEVELS $p]
    regsub -all {\[[0-9]+\]} $sp {[*]} sp_b
    regsub -all {\[[0-9]+\]} $ep {[*]} ep_b
    set key "$sp_b -> $ep_b (levels=$lvl)"
    if {![info exists seen($key)]} {
        set seen($key) [list 1 $slk]
    } else {
        lassign $seen($key) cnt worst
        if {$slk < $worst} { set worst $slk }
        set seen($key) [list [expr {$cnt + 1}] $worst]
    }
}
puts "paths from dsp_rst_tree_n_reg : $rst_cnt"
puts "paths from OTHER sources      : $other"
foreach k [lsort [array names seen]] {
    lassign $seen($k) cnt worst
    puts [format "  %4d eps | WNS %7.3f ns | %s" $cnt $worst $k]
}
exit
