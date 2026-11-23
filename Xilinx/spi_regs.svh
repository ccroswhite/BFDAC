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
//  DUAL-PORT (2026-11): two independent SPI slaves share this register file —
//  spi_xmos_* (XMOS audio bridge) and spi_ap_* (host AP, isolated). Reads are
//  unrestricted for both ports. Write access is partitioned in dac_ctrl_plane:
//  XMOS owns the audio-path subset {NOP, RATE,
//  STICKY_W1C, STREAM_RATE, STREAM_VALID}; all other
//  write registers (volume/level, filter/bank, cal, flash/update,
//  bench/cell-test) are AP-only — a denied XMOS write reports BAD_ADDR and
//  does not execute. Ruled 2026-11-14: VOLUME and LEVEL are AP-owned (UAC2
//  volume control disabled; the application sets level/volume — XMOS has no
//  access). OUTSEL/headphone path removed entirely (2026-11-14 ruling: no
//  headphone output stage). UNMUTE retired 2026-11-15: stream arm is
//  STREAM_VALID (0x1B); user mute is VOLUME (0x01).
//  Ruled 2026-11-15: RATE/STREAM_RATE are XMOS-ONLY (the XMOS is the sole
//  audio source to the FPGA — USB or AP-network relay — so the rate always
//  originates there; AP writes are denied). SUPERSEDED 2026-11-20: AP is a
//  second direct I2S source — XMOS still owns RATE/STREAM_RATE/STREAM_VALID
//  for ITS stream; the AP declares its rate/valid via I2S_SRC (0x1C, AP-only).
//  The rate machine follows the SELECTED source's declared rate.
//  DAC_MODE/video_mode removed — video-sync streaming is not supported.
//  DRAFT partition pending the SPI access-review TODO.
//
//  Keep this file in sync with progress.md "SPI Register Map" and
//  docs/coef_format_v2.md. TBs may keep numeric literals (they document the
//  wire protocol) but RTL decode must use these names.
// =============================================================================

// ---- Write registers ---------------------------------------------------------
`define SPI_W_NOP              7'h00  // explicit NOP (clock out a read response)
`define SPI_W_VOLUME           7'h01  // [23:0] normalized Q0.24 volume; 0xFFFFFF = full scale
`define SPI_W_LEVEL            7'h02  // [2:0]  output level cap (DIGITAL gain, no relays - bom 7 2026-10-07):
                                      //        000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms; applied by the
                                      //        automute sequencer while muted (click-free); reset = 2 V
`define SPI_W_RATE             7'h03  // Alias of STREAM_RATE: 0/1 retain base 44.1/48k semantics
// 7'h04 RESERVED (was UNMUTE — retired 2026-11-15; stream arm = STREAM_VALID)
`define SPI_W_BANK_LOAD        7'h05  // [3:0]  legacy fixed DDR4 slot + load trigger
//                             7'h06     RESERVED (was clk_source_sel; merged into 0x03)
//                             7'h07     RESERVED (was OUTSEL 0=line/1=HP;
//                                       headphone output stage removed per
//                                       2026-11-14 ruling — no HP hardware)
`define SPI_W_FILTER_LIST_CTRL 7'h08  // [0]=clear list, [1]=select entry 0 (commit)
`define SPI_W_FILTER_LIST_APP  7'h09  // [15:0] append filter_id (max SPI_FLIST_MAX)
`define SPI_W_FILTER_SELECT    7'h0A  // [16]=advance, [4:0]=index
//                             7'h0B     RESERVED (was DAC_MODE video_mode;
//                                       video-sync streaming not supported
//                                       per 2026-11-15 ruling)
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
`define SPI_W_STICKY_W1C        7'h16  // [7:0] write-1-clear; XMOS masked to {CRC,I2S,FRMLEN}
`define SPI_W_FILTER_SELECT_ID 7'h17  // [15:0] direct directory filter_id (bypasses list)

`define SPI_W_CELL_TEST_L      7'h18
`define SPI_W_CELL_TEST_R      7'h19
`define SPI_W_STREAM_RATE      7'h1A  // [2:0]={rate_shift[1:0],family48}; 24-bit PCM/32-bit slots
`define SPI_W_STREAM_VALID     7'h1B  // [0]=XMOS stream-live flag; zero on underrun/stop (XMOS-only 11-15)
`define SPI_W_I2S_SRC          7'h1C  // DUAL-SOURCE restore 2026-11-20 (AP-only): the AP owns input
                                      // select and its own stream declaration; XMOS writes denied.
                                      //   [0]    src_sel: 0 = XMOS (i2s_data), 1 = AP (i2s_data2)
                                      //   [1]    src2_valid: AP stream-live flag (same semantics as
                                      //          STREAM_VALID[0] but for the AP McASP0 source)
                                      //   [4:2]  rate_req_src2: AP declared rate, same {shift,fam48}
                                      //          encoding as STREAM_RATE[2:0].
                                      //   [12:8] rx_trim_src1: XMOS-path capture trim (reset 8)
                                      //   [20:16] rx_trim_src2: AP-path capture trim (reset 8);
                                      //          differs: U503 fwd ch + McASP0 vs U502 rev + XU316
                                      // SELECT vs RATE are separate decisions: a bare src_sel
                                      // change on an UNARMED source never touches the clock.
                                      // Apply fires on exactly two events: (a) the selected
                                      // source live with declared!=applied — select-to-armed,
                                      // or its own arm (this reg's [1] while sel=1, XMOS 0x1B
                                      // while sel=0); (b) a FRESH declare while selected — a
                                      // CHANGED [4:2] field while sel=1, symmetric to an XMOS
                                      // RATE write. Same-rate writes never relock (idempotent);
                                      // an apply consumes the arm — re-arm post clocks_ready.
                                      // Deselected source conforms to the wire rate or goes idle.
// ---- Voicing shaper (Layer 2, Step-2 commit contract 2026-11-17) -----------
// Shadow + atomic commit: host writes K2, K3, then VOICING_CTRL with [8]=1.
// All fields latch in dsp_clk at ONE fir_frame_done — no k2/k3 tearing.
// commit_pending (VOICING_STATUS[8]) blocks further voicing writes until the
// applied set acks; a filter_id change runs fade-out -> DDR4 bank load ->
// apply -> fade-in. RTL holds ZERO persona/rate convention: filter_id is an
// opaque 16-bit directory ID ({persona[6:0], filter_idx[5:0], rate[2:0]} is
// the generator/firmware packing contract). 16'hFFFF = don't-touch sentinel.
// K2/K3 carry the signed Q2.25 coefficient directly (sign-extended to the
// shaper's 27-bit port): usable range (-0.25,+0.25), resolution 2^-25.
`define SPI_W_VOICING_K2       7'h1D  // [23:0] = k2 raw Q2.25 LSBs, sign-extended
                                      //   to 27b (LSB = 2^-25; +2.0e-3 = 67109)
`define SPI_W_VOICING_K3       7'h1E  // [23:0] = k3 raw Q2.25 LSBs, sign-extended
                                      //   to 27b (LSB = 2^-25; -8.0e-5 = -2684)
`define SPI_W_VOICING_CTRL     7'h1F  // [0]=voicing_en shadow,
                                      //     [8]=commit (1 = apply at fir_frame_done)
`define SPI_W_VOICING_FILTER_ID 7'h20  // [15:0] raw directory ID; 16'hFFFF =
                                      //   don't-touch-bank sentinel (fields only)
`define SPI_W_STREAM_EVENT     7'h21  // W1C [2:0]: [0]=preempt_xmos [1]=preempt_ap
                                      //   [2]=echo_mismatch.  XMOS masked to {0,2}
                                      //   (its own domain); AP clears all.
                                      //   (stream-gate contract 2026-11-21)

// ---- Read registers ----------------------------------------------------------
`define SPI_R_MAGIC            7'h10  // 0xDAC02026
`define SPI_R_STICKY_ERR       7'h11  // [7:0] sticky bits (see SPI_STICKY_*)
`define SPI_R_CTRL_STATE       7'h12  // {clk_source_sel, base_rate_sel, rsvd, level[1:0]}
`define SPI_R_COEF_STATUS      7'h13  // {bank_valid[12], mgr_busy[11], load_done[10],
                                      //  clk_src[9], base_rate[8], cur_bank[7:4], bank_id[3:0]}
`define SPI_R_MUTE_STATUS      7'h14  // {i2s_err, switch_busy, rsvd, line_mute, unmute}
`define SPI_R_CLK_STATUS       7'h15  // {dpd_enable, ddr4_calib, clk_locked}
`define SPI_R_FILTER_LIST_STAT 7'h16  // {rsvd[11], list_len[10:5], cur_index[4:0]}
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
// 0x21: Voicing status {applied_filter_id[31:16], rsvd[15:6],
//        commit_pending[5], swap_busy[4], load_err_seen[3],
//        applied_en[2], fid_is_sentinel[1], sh_en[0]}
`define SPI_R_VOICING_STATUS   7'h21
// 0x22: Stream event flags {rsvd[23:6], rate_req_src1[5:3] (RO shadow,
//        informational only), echo_mismatch[2], preempt_ap[1], preempt_xmos[0]}
`define SPI_R_STREAM_EVENT     7'h22

// ---- Constants ----------------------------------------------------------------
`define SPI_MAGIC_ID           32'hDAC02026
`define SPI_READ_UNMAPPED      32'hDEADBEEF
`define SPI_FLIST_MAX          32     // filter toggle-list capacity
// Voicing filter_id convention (GENERATOR/FIRMWARE contract only — RTL
// treats the 16-bit ID as opaque):
//   filter_id[15:0] = {persona_id[6:0], filter_idx[5:0], stream_rate[2:0]}
//   persona 7'd127 is RESERVED so 16'hFFFF stays out of generated space:
//   127 personas x 64 filters x 8 rate slots.
//   Persona names (generator order): 0 reference_bench 1 chord_wta_hf
//   2 dcs_apodizing 3 dcs_berkeley_fast 4 msb_ladder_contour
//   5 nagra_pure_time 6 nagra_tube_xfmr

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
