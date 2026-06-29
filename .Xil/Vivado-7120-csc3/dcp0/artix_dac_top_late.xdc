set_property SRC_FILE_INFO {cfile:c:/Users/ccros/BFDAC-Xilinx/BFDAC-Xilinx.gen/sources_1/ip/ddr4_0/ddr4_0_board.xdc rfile:../../BFDAC-Xilinx.gen/sources_1/ip/ddr4_0/ddr4_0_board.xdc id:1 order:LATE used_in_board:yes scoped_inst:u_ddr4_if/u_ddr4/inst prop_thru_buffer:yes rxprname:$PGENDIR/sources_1/ip/ddr4_0/ddr4_0_board.xdc} [current_design]
set_property SRC_FILE_INFO {cfile:C:/AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl rfile:../../../../../AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl id:2 order:LATE scoped_inst:u_ddr4_if/u_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/rst_0/U0/EXT_LPF/ACTIVE_LOW_AUX.ACT_LO_AUX unmanaged:yes rxprname:$PPRDIR/../../../AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl} [current_design]
set_property SRC_FILE_INFO {cfile:C:/AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl rfile:../../../../../AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl id:3 order:LATE scoped_inst:u_ddr4_if/u_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/rst_0/U0/EXT_LPF/ACTIVE_HIGH_EXT.ACT_HI_EXT unmanaged:yes rxprname:$PPRDIR/../../../AMDDesignTools/2025.2.1/Vivado/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_single.tcl} [current_design]
set_property src_info {type:SCOPED_XDC file:1 line:1 export:INPUT save:INPUT read:READ} [current_design]
#--------------------Physical Constraints-----------------
set_property src_info {type:SCOPED_XDC file:1 line:2 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:SCOPED_XDC file:1 line:3 export:INPUT save:INPUT read:READ} [current_design]

set_property src_info {type:SCOPED_XDC file:2 line:1 export:INPUT save:NONE read:READ} [current_design]
# Scoped constraints for xpm_cdc_single
set_property src_info {type:SCOPED_XDC file:2 line:4 export:INPUT save:NONE read:READ} [current_design]

current_instance u_ddr4_if/u_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/rst_0/U0/EXT_LPF/ACTIVE_LOW_AUX.ACT_LO_AUX
set_property src_info {type:SCOPED_XDC file:2 line:5 export:INPUT save:NONE read:READ} [current_design]
set_false_path -to [get_cells {syncstages_ff_reg[0]}]
set_property src_info {type:SCOPED_XDC file:2 line:10 export:INPUT save:NONE read:READ} [current_design]

set_property src_info {type:SCOPED_XDC file:2 line:11 export:INPUT save:NONE read:READ} [current_design]

set_property src_info {type:SCOPED_XDC file:3 line:1 export:INPUT save:NONE read:READ} [current_design]
# Scoped constraints for xpm_cdc_single
set_property src_info {type:SCOPED_XDC file:3 line:4 export:INPUT save:NONE read:READ} [current_design]

current_instance -quiet
current_instance u_ddr4_if/u_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/rst_0/U0/EXT_LPF/ACTIVE_HIGH_EXT.ACT_HI_EXT
set_property src_info {type:SCOPED_XDC file:3 line:5 export:INPUT save:NONE read:READ} [current_design]
set_false_path -to [get_cells {syncstages_ff_reg[0]}]
set_property src_info {type:SCOPED_XDC file:3 line:10 export:INPUT save:NONE read:READ} [current_design]

set_property src_info {type:SCOPED_XDC file:3 line:11 export:INPUT save:NONE read:READ} [current_design]

