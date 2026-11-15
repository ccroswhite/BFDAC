open_checkpoint build/5m/post_route.dcp
set rst_cells [get_cells -hierarchical -filter {NAME =~ *dsp_rst_tree_n_reg*}]
puts "RST cells: [llength $rst_cells] -> $rst_cells"
foreach c $rst_cells {
    set pins [get_pins -of_objects $c -filter {REF_PIN_NAME == C}]
    foreach p $pins {
        set n [get_nets -of_objects $p]
        puts "NET $n fanout=[get_property FLAT_PIN_COUNT $n]"
    }
}
# failing endpoints by start clock on dsp_clk group
set tp_rst [get_timing_paths -from $rst_cells -slack_less_than 0 -max_paths 20000 -nworst 1]
puts "FAILING from rst_tree: [llength $tp_rst]"
set tp_all [get_timing_paths -to [get_clocks dsp_clk] -slack_less_than 0 -max_paths 20000 -nworst 1]
puts "FAILING to dsp_clk total: [llength $tp_all]"
