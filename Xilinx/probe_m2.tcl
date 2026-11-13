add_condition {/tb_fir_interp_m2/dut/new_sample_valid == 1} {puts "NSV t=[current_time] st=[get_value /tb_fir_interp_m2/dut/state] hc=[get_value /tb_fir_interp_m2/dut/history_clear] rf=[get_value /tb_fir_interp_m2/dut/rate_flush] sa=[get_value /tb_fir_interp_m2/dut/sample_accept]"}
add_condition {/tb_fir_interp_m2/dut/sample_accept == 1} {puts "SA at [current_time]"}
run 5 us
exit
