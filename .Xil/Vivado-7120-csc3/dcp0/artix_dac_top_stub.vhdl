-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity artix_dac_top is
  Port ( 
    clk_45m : in STD_LOGIC;
    clk_49m : in STD_LOGIC;
    clk_ref_ext : in STD_LOGIC;
    ddr4_refclkp : in STD_LOGIC;
    ddr4_refclkn : in STD_LOGIC;
    ext_rst_n : in STD_LOGIC;
    i2s_bclk : in STD_LOGIC;
    i2s_lrclk : in STD_LOGIC;
    i2s_data : in STD_LOGIC;
    spi_sclk : in STD_LOGIC;
    spi_cs_n : in STD_LOGIC;
    spi_mosi : in STD_LOGIC;
    spi_miso : out STD_LOGIC;
    relay_gain_6v : out STD_LOGIC;
    relay_audio_out : out STD_LOGIC;
    lvds_bclk_p : out STD_LOGIC;
    lvds_bclk_n : out STD_LOGIC;
    lvds_sync_p : out STD_LOGIC;
    lvds_sync_n : out STD_LOGIC;
    lvds_data_l_p : out STD_LOGIC;
    lvds_data_l_n : out STD_LOGIC;
    lvds_data_r_p : out STD_LOGIC;
    lvds_data_r_n : out STD_LOGIC;
    frame_sync_p : out STD_LOGIC;
    frame_sync_n : out STD_LOGIC;
    frame_sync_in_p : in STD_LOGIC;
    frame_sync_in_n : in STD_LOGIC;
    ddr4_dq : inout STD_LOGIC_VECTOR ( 15 downto 0 );
    ddr4_dqs_c : inout STD_LOGIC_VECTOR ( 1 downto 0 );
    ddr4_dqs_t : inout STD_LOGIC_VECTOR ( 1 downto 0 );
    ddr4_dm_dbi_n : inout STD_LOGIC_VECTOR ( 1 downto 0 );
    ddr4_addr : out STD_LOGIC_VECTOR ( 16 downto 0 );
    ddr4_ba : out STD_LOGIC_VECTOR ( 1 downto 0 );
    ddr4_bg : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_cs_n : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_cke : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_odt : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_act_n : out STD_LOGIC;
    ddr4_ck_t : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_ck_c : out STD_LOGIC_VECTOR ( 0 to 0 );
    ddr4_reset_n : out STD_LOGIC
  );

end artix_dac_top;

architecture stub of artix_dac_top is
  attribute syn_black_box : boolean;
  attribute black_box_pad_pin : string;
  attribute syn_black_box of stub : architecture is true;
begin
end;
