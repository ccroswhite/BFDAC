open_checkpoint build/5m/post_route.dcp

set paths [get_timing_paths -quiet -from [get_clocks dsp_clk] -to [get_clocks dsp_clk] -max_paths 2000 -nworst 1 -slack_lesser_than 0.0]
puts "failing dsp_clk paths sampled: [llength $paths]"

array unset pair
set unknown 0
foreach p $paths {
    set sc [get_cells -quiet -of_objects [get_property STARTPOINT_PIN $p]]
    set dc [get_cells -quiet -of_objects [get_property ENDPOINT_PIN $p]]
    if {$sc eq "" || $dc eq ""} { incr unknown; continue }
    set sslr "?"
    set dslr "?"
    set sobj [get_slrs -quiet -of_objects $sc]
    set dobj [get_slrs -quiet -of_objects $dc]
    if {$sobj ne ""} { set sslr [get_property NAME $sobj] }
    if {$dobj ne ""} { set dslr [get_property NAME $dobj] }
    incr pair("$sslr->$dslr")
}
puts "unresolved cells: $unknown"
puts "\n=== SLR pairs (source->dest) ==="
foreach k [lsort [array names pair]] { puts [format "  %5d paths | %s" $pair($k) $k] }
exit
