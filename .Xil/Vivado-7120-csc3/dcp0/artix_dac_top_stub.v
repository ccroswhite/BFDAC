// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module artix_dac_top(clk_45m, clk_49m, clk_ref_ext, ddr4_refclkp, 
  ddr4_refclkn, ext_rst_n, i2s_bclk, i2s_lrclk, i2s_data, spi_sclk, spi_cs_n, spi_mosi, spi_miso, 
  relay_gain_6v, relay_audio_out, lvds_bclk_p, lvds_bclk_n, lvds_sync_p, lvds_sync_n, 
  lvds_data_l_p, lvds_data_l_n, lvds_data_r_p, lvds_data_r_n, frame_sync_p, frame_sync_n, 
  frame_sync_in_p, frame_sync_in_n, ddr4_dq, ddr4_dqs_c, ddr4_dqs_t, ddr4_dm_dbi_n, ddr4_addr, 
  ddr4_ba, ddr4_bg, ddr4_cs_n, ddr4_cke, ddr4_odt, ddr4_act_n, ddr4_ck_t, ddr4_ck_c, ddr4_reset_n);
  input clk_45m;
  input clk_49m;
  input clk_ref_ext;
  input ddr4_refclkp;
  input ddr4_refclkn;
  input ext_rst_n;
  input i2s_bclk;
  input i2s_lrclk;
  input i2s_data;
  input spi_sclk;
  input spi_cs_n;
  input spi_mosi;
  output spi_miso;
  output relay_gain_6v;
  output relay_audio_out;
  output lvds_bclk_p;
  output lvds_bclk_n;
  output lvds_sync_p;
  output lvds_sync_n;
  output lvds_data_l_p;
  output lvds_data_l_n;
  output lvds_data_r_p;
  output lvds_data_r_n;
  output frame_sync_p;
  output frame_sync_n;
  input frame_sync_in_p;
  input frame_sync_in_n;
  inout [15:0]ddr4_dq;
  inout [1:0]ddr4_dqs_c;
  inout [1:0]ddr4_dqs_t;
  inout [1:0]ddr4_dm_dbi_n;
  output [16:0]ddr4_addr;
  output [1:0]ddr4_ba;
  output [0:0]ddr4_bg;
  output [0:0]ddr4_cs_n;
  output [0:0]ddr4_cke;
  output [0:0]ddr4_odt;
  output ddr4_act_n;
  output [0:0]ddr4_ck_t;
  output [0:0]ddr4_ck_c;
  output ddr4_reset_n;
endmodule
