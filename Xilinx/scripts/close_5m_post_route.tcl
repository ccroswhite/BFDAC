set_param general.maxThreads 8
open_checkpoint "build/5m/post_route.dcp"

# 1. SPI Mode 0 hold multicycle: MOSI/CS toggle on cf_sck falling edge (clk_200m +5 ns),
#    never on cf_sck rising edge. Shifts hold req from 0.0 ns to -5.0 ns (+3.529 ns slack).
set_multicycle_path 1 -hold -start \
    -from [get_clocks clk_200m] \
    -to   [get_ports {cf_cs_n[*] cf_dq[0]}]

# 2. Static rate_shift_q_reg inside u_stereo_fir (only changes while MMCM is in reset).
set rs_cells [get_cells -quiet -hierarchical -filter {NAME =~ u_dsp_core/u_stereo_fir/u_*_fir/rate_shift_q_reg[*]}]
if {[llength $rs_cells] > 0} {
    set_max_delay 6.6 -from $rs_cells
}

puts "INFO: Pre-opt WNS = [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]] ns"
puts "INFO: Pre-opt WHS = [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]] ns"

if {[get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]] < 0.000} {
    phys_opt_design -directive AggressiveExplore
}
if {[get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]] < 0.000} {
    route_design -tns_cleanup
}
if {[get_property SLACK [get_timing_paths -hold -max_paths 1 -nworst 1]] < 0.000} {
    phys_opt_design -hold_fix
}

set final_wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
set final_whs [get_property SLACK [get_timing_paths -hold  -max_paths 1 -nworst 1]]
puts "========================================================================="
puts "INCREMENTAL CLOSURE SCOREBOARD: WNS = ${final_wns} ns | WHS = ${final_whs} ns"
puts "========================================================================="

write_checkpoint -force "build/5m/post_route_closed.dcp"
report_timing_summary -max_paths 20 -file "build/5m/post_route_closed_timing.rpt"

set WRITE_BIT [expr {[info exists ::env(WRITE_BIT)] ? $::env(WRITE_BIT) : 0}]
if {$WRITE_BIT && $final_wns >= 0.000 && $final_whs >= 0.000} {
    puts "INFO: Timing CLOSED! Writing build/5m/acku15s_dac_5m.bit..."
    write_bitstream -force "build/5m/acku15s_dac_5m.bit"
}
exit
