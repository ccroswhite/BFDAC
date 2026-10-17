`ifndef SPI_REGS_SVH
`define SPI_REGS_SVH
// =============================================================================
//  SPI control-plane register map (dac_ctrl_plane.sv) — single source of truth
//
//  Frame: 40 bits {R/W[1], addr[7], data[24], crc8[8]}, CRC-8 poly 0x07 over
//  bits [39:8]. Write and read address spaces are INDEPENDENT (the same 7-bit
//  address can mean different things per R/W bit). Unknown read -> 0xDEADBEEF;
//  unknown write -> sticky[5] + CMD_ERR_INFO BAD_ADDR.
//
//  Keep this file in sync with progress.md "SPI Register Map" and
//  docs/coef_format_v2.md. TBs may keep numeric literals (they document the
//  wire protocol) but RTL decode must use these names.
// =============================================================================

// ---- Write registers ---------------------------------------------------------
`define SPI_W_NOP              7'h00  // explicit NOP (clock out a read response)
`define SPI_W_VOLUME           7'h01  // [23:0] sys_volume
`define SPI_W_LEVEL            7'h02  // [2:0]  output level cap (DIGITAL gain, no relays - bom 7 2026-10-07):
                                      //        000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms; applied by the
                                      //        automute sequencer while muted (click-free); reset = 2 V
`define SPI_W_RATE             7'h03  // Alias of STREAM_RATE: 0/1 retain base 44.1/48k semantics
`define SPI_W_UNMUTE           7'h04  // [0]    spi_unmute
`define SPI_W_BANK_LOAD        7'h05  // [3:0]  legacy fixed DDR4 slot + load trigger
//                             7'h06     RESERVED (was clk_source_sel; merged into 0x03)
`define SPI_W_OUTSEL           7'h07  // [0]    0=line XLR 1=headphone
`define SPI_W_FILTER_LIST_CTRL 7'h08  // [0]=clear list, [1]=select entry 0 (commit)
`define SPI_W_FILTER_LIST_APP  7'h09  // [15:0] append filter_id (max SPI_FLIST_MAX)
`define SPI_W_FILTER_SELECT    7'h0A  // [16]=advance, [4:0]=index
`define SPI_W_DAC_MODE         7'h0B  // [0]    video_mode (status only)
`define SPI_W_CAL_ADDR         7'h0C  // [8:0]  cal_coef_store shadow write pointer
`define SPI_W_CAL_DATA         7'h0D  // [23:0] shadow word, auto-increment
`define SPI_W_CAL_COMMIT       7'h0E  // [0]=1  toggle atomic bank swap
`define SPI_W_CAL_RDADDR       7'h0F  // [8:0]  active-bank readback address
`define SPI_W_FLASH_ADDR_LO    7'h10  // [23:0] flash_cmd_addr[23:0]
`define SPI_W_FLASH_ADDR_HI    7'h11  // [7:0]  flash_cmd_addr[31:24], [9:8]=target flash
                                      //        0 = SoM Flash 1 (coef), 1 = SoM Flash 0 (bin),
                                      //        2 = carrier coef flash (bom 18a; addr[29:28] = chip)
`define SPI_W_FLASH_CMD        7'h12  // [7:0]  0x01 erase / 0x02 program / 0x03 read
`define SPI_W_FLASH_DATA       7'h13  // [7:0]  page-buffer byte, auto-increment
`define SPI_W_FLASH_PTR        7'h14  // [7:0] write ptr, [15:8] read ptr
`define SPI_W_DPD_EN           7'h15  // [0]    dpd_enable
`define SPI_W_STICKY_W1C       7'h16  // [7:0]  clear sticky bits (also clears CMD_ERR_INFO)
`define SPI_W_FILTER_SELECT_ID 7'h17  // [15:0] direct directory filter_id (bypasses list)

`define SPI_W_CELL_TEST_L      7'h18
`define SPI_W_CELL_TEST_R      7'h19
`define SPI_W_STREAM_RATE      7'h1A  // [2:0]={rate_shift[1:0],family48}; 24-bit PCM/32-bit slots
`define SPI_W_STREAM_VALID     7'h1B  // [0]=AP source ready; zero on underrun/stop
`define SPI_W_I2S_RX_TRIM      7'h1C  // [4:0]=extra DSP capture-delay cycles; muted/source stopped only

// ---- Read registers ----------------------------------------------------------
`define SPI_R_MAGIC            7'h10  // 0xDAC02026
`define SPI_R_STICKY_ERR       7'h11  // [7:0] sticky bits (see SPI_STICKY_*)
`define SPI_R_CTRL_STATE       7'h12  // {clk_source_sel, base_rate_sel, outsel, level[1:0]}
`define SPI_R_COEF_STATUS      7'h13  // {bank_valid[12], mgr_busy[11], load_done[10],
                                      //  clk_src[9], base_rate[8], cur_bank[7:4], bank_id[3:0]}
`define SPI_R_MUTE_STATUS      7'h14  // {i2s_err, switch_busy, hp_mute, line_mute, unmute}
`define SPI_R_CLK_STATUS       7'h15  // {dpd_enable, ddr4_calib, clk_locked}
`define SPI_R_FILTER_LIST_STAT 7'h16  // {video_mode[11], list_len[10:5], cur_index[4:0]}
`define SPI_R_FILTER_IDS       7'h17  // {next_in_list_id[31:16], cur_filter_id[15:0]}
`define SPI_R_CAL_STATUS       7'h18  // {calibration_valid[11], cal_wr_ptr[10:2], pending[1], active_bank[0]}
`define SPI_R_CAL_RDDATA       7'h19  // [23:0] active-bank word at CAL_RDADDR
`define SPI_R_BOOT_STATUS      7'h1A  // {boot_src[13], record_count[12:5], axi_fail[4],
                                      //  crc_fail[3], boot_ok[2], boot_done[1], flash_busy[0]}
                                      //  boot_src: 0 = chain from SoM Flash 1, 1 = carrier
`define SPI_R_FLASH_RDDATA     7'h1B  // [7:0] page-buffer byte at FLASH_PTR[15:8]
`define SPI_R_CMD_ERR_INFO     7'h1C  // {detail[11], addr[10:4], reason[3:0]}

`define SPI_R_CELL_TEST_L      7'h1D
`define SPI_R_CELL_TEST_R      7'h1E
`define SPI_R_BENCH_STATUS     7'h1F
`define SPI_R_STREAM_STATUS    7'h20

// ---- Constants ----------------------------------------------------------------
`define SPI_MAGIC_ID           32'hDAC02026
`define SPI_READ_UNMAPPED      32'hDEADBEEF
`define SPI_FLIST_MAX          32     // filter toggle-list capacity

// ---- Sticky error bits (read 0x11, W1C via write 0x16) -----------------------
`define SPI_STICKY_SPI_CRC     0
`define SPI_STICKY_I2S_ERR     1
`define SPI_STICKY_DDR4_CALIB  2
`define SPI_STICKY_PLL_UNLOCK  3
`define SPI_STICKY_FRAME_LEN   4
`define SPI_STICKY_BAD_ADDR    5
`define SPI_STICKY_CMD_REJECT  6     // rejected command OR filter load failed
`define SPI_STICKY_BOOT_FLASH  7

// ---- CMD_ERR_INFO reason codes (read 0x1C [3:0]) ------------------------------
`define SPI_ERR_NONE           4'h0
`define SPI_ERR_BAD_ADDR       4'h1
`define SPI_ERR_FLASH_BUSY     4'h2
`define SPI_ERR_FLASH_OP       4'h3
`define SPI_ERR_FILT_FULL      4'h4
`define SPI_ERR_FILT_EMPTY     4'h5
`define SPI_ERR_FILT_RANGE     4'h6
`define SPI_ERR_CAL_WRAP       4'h7
`define SPI_ERR_FLASH_WDT      4'h8
`define SPI_ERR_FRAME_LEN      4'h9
`define SPI_ERR_FILT_NOTFOUND  4'hA
`define SPI_ERR_FILT_SIZE      4'hB

`define SPI_ERR_TEST_BUSY      4'hC
`define SPI_ERR_TEST_UNSAFE    4'hD
`define SPI_ERR_TEST_FORMAT    4'hE
`define SPI_ERR_FILT_RATE      4'hF

`endif // SPI_REGS_SVH
