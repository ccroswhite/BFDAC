open_checkpoint build_5m/post_synth.dcp
set p [get_timing_paths -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -max_paths 1 -nworst 1 -setup]
puts "\n=== 1. WORST dsp_clk PATH CELLS & PBLOCKS ==="
foreach c [get_cells -of_objects $p] {
    puts [format "  PBLOCK=%-14s | REF=%-10s | %s" [get_property PBLOCK $c] [get_property REF_NAME $c] $c]
}

puts "\n=== 2. ALL FAILING dsp_clk GROUPS (641 eps) ==="
set paths [get_timing_paths -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -max_paths 1000 -nworst 1 -slack_lesser_than 0.0]
array unset seen
foreach pt $paths {
    regsub -all {\[[0-9]+\]} [get_property STARTPOINT_PIN $pt] {[*]} sp
    regsub -all {\[[0-9]+\]} [get_property ENDPOINT_PIN $pt]   {[*]} ep
    set k "$sp -> $ep (lvls=[get_property LOGIC_LEVELS $pt])"
    if {![info exists seen($k)]} {
        set seen($k) [list 1 [get_property SLACK $pt]]
    } else {
        lassign $seen($k) n w
        set seen($k) [list [expr {$n + 1}] $w]
    }
}
foreach k [lsort [array names seen]] {
    lassign $seen($k) n w
    puts [format "  %3d eps | WNS %7.3f ns | %s" $n $w $k]
}

puts "\n=== 3. URAM PBLOCK MEMBERSHIP ==="
set urams [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]
set u_unassigned [get_cells -quiet -hierarchical -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.* && PBLOCK == ""}]
puts "  Total URAMs: [llength $urams] | Un-pblocked URAMs: [llength $u_unassigned]"
exit
