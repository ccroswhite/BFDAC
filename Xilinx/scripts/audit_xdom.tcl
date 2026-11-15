open_checkpoint build/5m/post_synth.dcp

foreach c1 [get_clocks] {
    foreach c2 [get_clocks] {
        if {$c1 eq $c2} continue
        set paths [get_timing_paths -quiet -from $c1 -to $c2 -max_paths 500 -nworst 1 -slack_lesser_than 0.0]
        if {[llength $paths] == 0} continue
        puts "\n=== INTER-CLOCK: $c1 -> $c2 ([llength $paths] failing endpoints) ==="
        array unset seen
        foreach p $paths {
            set sp  [get_property STARTPOINT_PIN $p]
            set ep  [get_property ENDPOINT_PIN $p]
            set req [get_property REQUIREMENT $p]
            set slk [get_property SLACK $p]
            regsub -all {\[[0-9]+\]} $sp {[*]} sp_b
            regsub -all {\[[0-9]+\]} $ep {[*]} ep_b
            set key "$sp_b -> $ep_b (req=$req ns)"
            if {![info exists seen($key)]} {
                set seen($key) [list 1 $slk]
            } else {
                lassign $seen($key) cnt worst
                set seen($key) [list [expr {$cnt + 1}] $worst]
            }
        }
        foreach k [lsort [array names seen]] {
            lassign $seen($k) cnt worst
            puts [format "  %3d eps | WNS %7.3f ns | %s" $cnt $worst $k]
        }
    }
}

set dsp_paths [get_timing_paths -quiet -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -max_paths 50 -nworst 1 -slack_lesser_than 0.0]
puts "\n=== INTRA-CLOCK: dsp_clk -> dsp_clk (top [llength $dsp_paths] failing) ==="
array unset dseen
foreach p $dsp_paths {
    set sp  [get_property STARTPOINT_PIN $p]
    set ep  [get_property ENDPOINT_PIN $p]
    set slk [get_property SLACK $p]
    set lvl [get_property LOGIC_LEVELS $p]
    regsub -all {\[[0-9]+\]} $sp {[*]} sp_b
    regsub -all {\[[0-9]+\]} $ep {[*]} ep_b
    set key "$sp_b -> $ep_b (levels=$lvl)"
    if {![info exists dseen($key)]} {
        set dseen($key) [list 1 $slk]
    } else {
        lassign $dseen($key) cnt worst
        set dseen($key) [list [expr {$cnt + 1}] $worst]
    }
}
foreach k [lsort [array names dseen]] {
    lassign $dseen($k) cnt worst
    puts [format "  %3d eps | WNS %7.3f ns | %s" $cnt $worst $k]
}
exit
