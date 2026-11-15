create_project -in_memory -part xcku15p-ffve1517-2-i
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_q -dir ./ip_tmp
set vals [list_property_value CONFIG.C0.DDR4_MemoryPart [get_ips ddr4_q]]
puts "NUM_VALS: [llength $vals]"
puts "ALL: $vals"
puts "DONE_LIST"
