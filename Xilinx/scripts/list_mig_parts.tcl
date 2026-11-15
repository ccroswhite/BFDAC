create_project -in_memory -part xcku15p-ffve1517-2-i
create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_q -dir ./ip_tmp
set_property CONFIG.C0.DDR4_MemoryPart {MT40A512M16LY-075} [get_ips ddr4_q]
set_property CONFIG.C0.DDR4_DataWidth  {64}                [get_ips ddr4_q]
if {[catch {set_property CONFIG.C0.DDR4_Ecc {true} [get_ips ddr4_q]} e]} { puts "ECC_FAIL: $e" }
puts "ECC=[get_property CONFIG.C0.DDR4_Ecc [get_ips ddr4_q]] DW=[get_property CONFIG.C0.DDR4_DataWidth [get_ips ddr4_q]]"
puts "DONE_LIST"
