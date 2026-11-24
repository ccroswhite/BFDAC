`timescale 1ns / 1ps

// DAC Control Plane
// SPI slave + register file.
// Clocked by the board-specific system clock; runs independently of the audio path.
// Register addresses / reason codes: spi_regs.svh (single source of truth).

`include "spi_regs.svh"

module dac_ctrl_plane (
    input  logic        clk,        // Control-plane clock (200 MHz on VU13P)
    input  logic        ext_rst_n,

    // SPI interfaces — two independent slaves sharing one register file.
    //   spi_xmos_* : XMOS audio bridge (restricted write subset, draft ACL
    //                below; access review TODO pending)
    //   spi_ap_*   : host application processor (full access; SPI lines are
    //                digitally isolated on the carrier)
    input  logic        spi_xmos_sclk,
    input  logic        spi_xmos_cs_n,
    input  logic        spi_xmos_mosi,
    output logic        spi_xmos_miso,
    input  logic        spi_ap_sclk,
    input  logic        spi_ap_cs_n,
    input  logic        spi_ap_mosi,
    output logic        spi_ap_miso,

    // Relay control (to automute controller, Fig. 4d set)
    output logic        level_switch_req,   // Single-cycle pulse (legacy; sequencer now acts on target != applied)
    output logic [2:0]  level_target,       // digital level cap: 000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms

    // Status inputs (for SPI readback)
    input  logic        mgr_busy,
    input  logic        bank_valid,         // dsp_clk level: FIR active bank holds a good load
    input  logic        coef_load_done,
    input  logic [3:0]  current_bank_id,
    input  logic        coef_load_err,      // ui_clk level: last filter load failed
    input  logic [2:0]  coef_load_err_code, // 1=ID, 2=size, 3=rate, 4=AXI read error
    input  logic        i2s_err,             // dsp_clk domain, will be synchronised
    input  logic        switch_busy,         // dsp_clk domain, will be synchronised
    input  logic        clk_locked,
    input  logic        ddr4_init_calib_complete,
    input  logic        line_mute_status,   // dsp_clk domain, will be synchronised

    // Control outputs
    output logic [31:0] sys_volume,       // Internal Q16.16 gain in NS code units
    output logic        base_rate_sel,    // 0 = 44.1k family, 1 = 48k family (reg 0x03)
    output logic        clk_source_sel,   // ALIAS of base_rate_sel: one register drives
                                          // both DSP family select and carrier XO enables
    output logic [3:0]  coef_bank_id,
    output logic        coef_load_start,  // Toggle: one flip per 0x05 write

    // Named-filter toggle list (regs 0x08-0x0B; docs/coef_format_v2.md)
    output logic [15:0] filter_id,        // Currently selected filter (DDR4 directory ID)
    output logic [15:0] filter_next_id,   // Next list entry — bank manager preload target
    output logic        filter_load_req,  // Toggle: one flip per filter select
    output logic        fpga_irq_n,       // Active-low IRQ to XMOS (sticky errors)
    output logic        spi_ap_irq_n,     // Active-low IRQ to AP (same sticky source)

    // Calibration coefficient store (regs 0x0C-0x0F, 0x18-0x19; Step 6.3/6.7
    // DECIDED Aug 2026: ARM computes the temperature-corrected values, FPGA
    // only stores + applies them — see cal_coef_store.sv for the bank model)
    output logic        cal_wr_toggle,    // Flips once per shadow-bank word write
    output logic [8:0]  cal_wr_addr,      // [8]=channel, [7:0]=word
    output logic [23:0] cal_wr_data,
    output logic        cal_commit_toggle,// Flips once per atomic bank-swap request
    output logic [8:0]  cal_rd_addr,      // Active-bank verification readback address
    input  logic [23:0] cal_rd_data,      // Quasi-static readback data
    input  logic        cal_active_bank,  // Synced status from cal_coef_store
    input  logic        cal_commit_pending,
    input  logic         cal_write_reject_toggle,
    input  logic         calibration_valid,

    // QSPI flash controller (regs 0x10-0x14, status 0x1A/0x1B — 2026-08-22:
    // ARM-driven coefficient (Flash 1) and bitstream (Flash 0) updates over
    // the SPI control plane; boot staging is FPGA-autonomous, status only)
    output logic [7:0]  flash_cmd_opcode,
    output logic [1:0]  flash_cmd_target, // 0 = SoM Flash 1, 1 = SoM Flash 0, 2 = carrier (bom 18a)
    output logic [31:0] flash_cmd_addr,
    output logic        flash_cmd_trigger,// single-cycle pulse
    input  logic        flash_cmd_busy,
    input  logic        flash_cmd_err,    // single-cycle pulse: watchdog abort
    output logic [7:0]  flash_buf_wdata,
    output logic        flash_buf_we,     // single-cycle pulse
    output logic [7:0]  flash_buf_waddr,
    output logic [7:0]  flash_buf_raddr,
    input  logic [7:0]  flash_buf_rdata,
    input  logic        boot_done,        // qspi_boot_loader status (clk domain)
    input  logic        boot_ok,
    input  logic        boot_crc_fail,
    input  logic        boot_axi_fail,
    input  logic [7:0]  boot_record_count,
    input  logic        boot_src,         // 0 = chain came from SoM Flash 1, 1 = carrier

    // DPD engine enable (reg 0x15 — Step 4D.1; synced to dsp_clk in top)
    output logic        dpd_enable,
    output logic [1:0][7:0] cell_test_cfg,
    output logic [1:0]      cell_test_req,
    input  logic [1:0]      cell_test_ack,
    input  logic            bench_busy,
    input  logic [31:0]    bench_status,
    output logic          bench_available,
    output logic [2:0]    stream_rate_request,
    output logic          stream_rate_toggle,
    output logic          stream_source_valid,   // XMOS stream-live flag (0x1B[0])
    output logic          stream_source_valid2,  // AP stream-live flag (0x1C[1])
    output logic          i2s_src_sel,           // 0 = XMOS, 1 = AP (0x1C[0], AP-only)
    output logic          stream_valid_sel,      // muxed: sel ? svalid2 : svalid1
    output logic [4:0]    i2s_rx_trim,   // selected-source capture trim (0x1C fields;
                                          // per-path because U502-rev+XU316 and
                                          // U503-fwd+McASP0 delays differ)
    input  logic           stream_busy,
    input  logic           stream_clocks_ready,
    input  logic [2:0]    stream_applied_rate,
    input  logic           stream_fault,
    // Sticky dsp_clk DPD deadline overrun, synced to ctrl_clk at top level
    // (read-only, STREAM_STATUS[22]) — distinguishes DPD timing overrun from
    // the i2s/FIFO faults folded into stream_fault.
    input  logic           dpd_deadline_miss,
    input  logic           stream_audio_ready,

    // Voicing shaper shadow set (regs 0x1D-0x1F; Step 2 2026-11-17).
    // Shadow fields are written individually, then VOICING_CTRL[8]=1 flips
    // voicing_commit_toggle — the dsp_clk commit FSM latches the whole set
    // atomically and applies at fir_frame_done. Writes are rejected while
    // commit_pending (ack_toggle hasn't caught up) so the shadow set can
    // never tear mid-commit.
    output logic              voicing_sh_en,
    output logic signed [26:0] voicing_sh_k2,   // Q2.25 (SPI writes [26:3])
    output logic signed [26:0] voicing_sh_k3,
    output logic [15:0]       voicing_sh_fid,     // raw dir ID; 16'hFFFF =
                                                  // don't-touch-bank sentinel
    output logic              voicing_commit_toggle,
    input  logic              voicing_ack_toggle,     // dsp_clk domain
    input  logic              voicing_swap_busy,      // dsp_clk domain
    input  logic              voicing_err_toggle,     // dsp_clk, flips on failed preset load
    input  logic [15:0]       voicing_applied_fid,    // dsp_clk domain
    input  logic              voicing_bank_chg,      // dsp_clk toggle: any swap
    input  logic              voicing_applied_en,     // dsp_clk domain
    output logic              voicing_err_seen        // err parity -> dsp_clk
                                                      // reset parking
);

    // Cal shadow-bank write pointer. cal_wr_addr (the exported CDC bus) holds
    // the PRE-increment address of the last write so it is stable when the
    // wr_toggle edge reaches the dsp_clk domain 2-3 cycles later; the pointer
    // itself auto-increments immediately for the next 0x0D frame.
    logic [8:0] cal_wr_ptr;

    // ---- Dual-SPI front end --------------------------------------------------
    // Each port owns an independent spi_slave + readback path (reads never
    // collide: each port tracks its own read address). WRITE frames enter a
    // one-slot pending queue per port and drain serially through a fixed-
    // priority arbiter (XMOS first) into the shared ctrl_bus_* decode below.
    // ctrl_bus_src tags the originating port for the write-access gate and
    // the last-writer debug bit in CTRL_STATE.
    localparam logic SRC_XMOS = 1'b0, SRC_AP = 1'b1;
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic        ctrl_bus_src;

    logic [31:0] x_bus_data, a_bus_data;
    logic        x_bus_valid, a_bus_valid;
    logic        x_crc_err, x_frame_err, a_crc_err, a_frame_err;

    // Pending write/read slots — depth 1 per port is sufficient: an SPI frame
    // spans >=40 host-SCLK periods while a slot drains in one clk cycle.
    logic        x_pend, a_pend;
    logic [31:0] x_frame, a_frame;
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            x_pend <= 1'b0; a_pend <= 1'b0;
            ctrl_bus_valid <= 1'b0; ctrl_bus_src <= SRC_XMOS;
        end else begin
            ctrl_bus_valid <= 1'b0;
            if (x_pend)      begin ctrl_bus_valid <= 1'b1; ctrl_bus_data <= x_frame; ctrl_bus_src <= SRC_XMOS; x_pend <= 1'b0; end
            else if (a_pend) begin ctrl_bus_valid <= 1'b1; ctrl_bus_data <= a_frame; ctrl_bus_src <= SRC_AP;   a_pend <= 1'b0; end
            // Latch AFTER drain-clear so a same-cycle arrival re-arms the slot
            if (x_bus_valid) begin x_pend <= 1'b1; x_frame <= x_bus_data; end
            if (a_bus_valid) begin a_pend <= 1'b1; a_frame <= a_bus_data; end
        end
    end
    logic spi_crc_error, spi_frame_error;
    assign spi_crc_error   = x_crc_err   | a_crc_err;
    assign spi_frame_error = x_frame_err | a_frame_err;

    logic [6:0]  read_addr_reg;   // XMOS port read-address latch
    logic [6:0]  read_addr_reg_a; // AP port read-address latch
    logic        last_wr_src;     // SRC_* of most recent accepted write frame
    logic [31:0] spi_tx_data;
    logic [31:0] spi_tx_data_a;   // AP port readback register
    logic        spi_crc_err_d;
    logic [2:0]  cmd_level;

    // Filter toggle list storage (TODO-23: 32 entries, 2026-09-03)
    localparam int FLIST_MAX = `SPI_FLIST_MAX;
    localparam int FLIST_IW  = $clog2(FLIST_MAX);      // 5-bit index
    localparam int FLIST_LW  = FLIST_IW + 1;           // 6-bit length (0..32)
    logic [15:0]         filter_list [0:FLIST_MAX-1];
    logic [FLIST_LW-1:0] filter_list_len;
    logic [FLIST_IW-1:0] filter_cur_index;

    // Index arithmetic shared by advance (0x0A[16]) and the 0x17 preload readback
    logic [FLIST_IW-1:0] filter_adv_index;   // cur+1 with wrap to 0 at len
    logic                filter_sel_in_range; // 0x0A explicit index < len
    always_comb begin
        filter_adv_index    = ((FLIST_LW'(filter_cur_index) + FLIST_LW'(1)) >= filter_list_len)
                              ? '0 : filter_cur_index + FLIST_IW'(1);
        filter_sel_in_range = FLIST_LW'(ctrl_bus_data[FLIST_IW-1:0]) < filter_list_len;
    end

    // Re-register dsp_clk-domain status inputs on clk_49m before use.
    // Prevents CDC combinatorial paths into the SPI readback mux.
    logic        mgr_busy_r;
    logic        bank_valid_r;
    logic        coef_load_done_r;
    logic [3:0]  current_bank_id_r;
    logic        i2s_err_r;
    logic        switch_busy_r;
    logic        line_mute_r;

    (* ASYNC_REG = "TRUE" *) logic [1:0] i2s_err_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] switch_busy_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] line_mute_sync;
    // dsp_clk status levels into control logic: proper 2-FF ASYNC_REG
    // chains (2026-11-22 — the previous single-FF re-registers fed
    // wr_rejected/sticky decisions metastability-exposed, CDC-1/CDC-6).
    (* ASYNC_REG = "TRUE" *) logic [1:0] mgr_busy_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] bank_valid_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] load_done_sync;
    // clk_locked is an asynchronous MMCM output — sync before ANY use.
    (* ASYNC_REG = "TRUE" *) logic [1:0] clk_lock_sync;
    logic        load_done_sticky;
    logic        mgr_busy_d;
    // ddr4_init_calib_complete comes from the MIG ui_clk domain (f9wc route
    // review 2026-08-15: it was consumed raw — the last unconstrained CDC).
    // Monotonic level, safe through a 2-FF sync.
    (* ASYNC_REG = "TRUE" *) logic [1:0] ddr4_calib_sync;

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            i2s_err_sync     <= '0;
            switch_busy_sync <= '0;
            line_mute_sync   <= '0;
            mgr_busy_sync    <= '0;
            bank_valid_sync  <= '0;
            load_done_sync   <= '0;
            clk_lock_sync    <= '0;
            ddr4_calib_sync  <= '0;
            mgr_busy_r       <= 1'b0;
            bank_valid_r     <= 1'b0;
            coef_load_done_r <= 1'b0;
            load_done_sticky <= 1'b0;
            mgr_busy_d       <= 1'b0;
            i2s_err_r        <= 1'b0;
            switch_busy_r    <= 1'b0;
            line_mute_r      <= 1'b0;
        end else begin
            i2s_err_sync     <= {i2s_err_sync[0], i2s_err};
            switch_busy_sync <= {switch_busy_sync[0], switch_busy};
            line_mute_sync   <= {line_mute_sync[0], line_mute_status};
            mgr_busy_sync    <= {mgr_busy_sync[0], mgr_busy};
            bank_valid_sync  <= {bank_valid_sync[0], bank_valid};
            load_done_sync   <= {load_done_sync[0], coef_load_done};
            clk_lock_sync    <= {clk_lock_sync[0], clk_locked};
            ddr4_calib_sync  <= {ddr4_calib_sync[0], ddr4_init_calib_complete};
            mgr_busy_r       <= mgr_busy_sync[1];
            bank_valid_r     <= bank_valid_sync[1];
            i2s_err_r        <= i2s_err_sync[1];
            switch_busy_r    <= switch_busy_sync[1];
            line_mute_r      <= line_mute_sync[1];
            // Load-done status for 0x13[10]: the dsp-side done level is
            // stretched ~27 ns so this 2-FF sync cannot miss it; latch a
            // sticky level, cleared when the next load starts (mgr_busy
            // rising) or when the clock regime is torn down.
            mgr_busy_d       <= mgr_busy_sync[1];
            if (!stream_clocks_ready || (mgr_busy_sync[1] && !mgr_busy_d))
                load_done_sticky <= 1'b0;
            else if (load_done_sync[1])
                load_done_sticky <= 1'b1;
            coef_load_done_r <= load_done_sticky;
        end
    end

    // Sticky error register (bits cleared by writing 1 to the bit from ARM)
    // bit [0]: SPI CRC error
    // bit [1]: I2S interface error
    // bit [2]: DDR4 init/calibration not complete
    // bit [3]: PLL not locked
    // bit [4]: SPI frame-length error (runt/overrun frame discarded)
    // bit [5]: invalid write address (unknown or reserved)
    // bit [6]: command rejected (reason in CMD_ERR_INFO, read 0x1C)
    // bit [7]: boot / flash error (boot CRC/AXI fail, flash watchdog abort)
    logic [7:0] sticky_err;
    logic       boot_err_d;

    // ---- Write decode for error detection --------------------------------
    logic       wr_stb;
    logic [6:0] wr_addr;
    assign wr_stb  = ctrl_bus_valid && (ctrl_bus_data[31] == 1'b0);
    assign wr_addr = ctrl_bus_data[30:24];

    // Invalid write address: anything not implemented (incl. reserved 0x06).
    // 0x00 is an explicit NOP — hosts may use a write-0x00 frame to clock
    // out the MISO response of a preceding read command.
    logic wr_addr_invalid;
    always_comb begin
        case (wr_addr)
            `SPI_W_NOP,
            `SPI_W_VOLUME,        `SPI_W_LEVEL,          `SPI_W_RATE,
            `SPI_W_BANK_LOAD,
            `SPI_W_FILTER_LIST_CTRL, `SPI_W_FILTER_LIST_APP, `SPI_W_FILTER_SELECT,
            `SPI_W_CAL_ADDR,       `SPI_W_CAL_DATA,
            `SPI_W_CAL_COMMIT,    `SPI_W_CAL_RDADDR,     `SPI_W_FLASH_ADDR_LO,
            `SPI_W_FLASH_ADDR_HI, `SPI_W_FLASH_CMD,      `SPI_W_FLASH_DATA,
            `SPI_W_FLASH_PTR,     `SPI_W_DPD_EN,         `SPI_W_STICKY_W1C,
            `SPI_W_FILTER_SELECT_ID,
            `SPI_W_CELL_TEST_L, `SPI_W_CELL_TEST_R,
            `SPI_W_STREAM_RATE, `SPI_W_STREAM_VALID, `SPI_W_STREAM_EVENT,
            `SPI_W_I2S_SRC,
            `SPI_W_VOICING_K2, `SPI_W_VOICING_K3, `SPI_W_VOICING_CTRL,
            `SPI_W_VOICING_FILTER_ID:
                                                            wr_addr_invalid = 1'b0;
            default:                                    wr_addr_invalid = 1'b1;
        endcase
    end

    // ---- Per-port write access gate -----------------------------------------
    // DRAFT partition (access-review TODO pending): the XMOS may only write
    // the audio-path registers it owns. Filter/bank selection, calibration,
    // flash/update and bench/cell-test registers are AP-only — they do not
    // exist in the XMOS view, so a denied write is reported exactly like an
    // invalid address (sticky[5] + CMD_ERR_INFO BAD_ADDR).
    logic wr_denied;
    always_comb begin
        wr_denied = 1'b0;
        if (ctrl_bus_src == SRC_XMOS) begin
            case (wr_addr)
                `SPI_W_NOP,
                `SPI_W_RATE,
                `SPI_W_STICKY_W1C,
                `SPI_W_STREAM_EVENT,
                `SPI_W_STREAM_RATE,   `SPI_W_STREAM_VALID:
                    wr_denied = 1'b0;
                default: wr_denied = 1'b1;
            endcase
        end else begin // SRC_AP: RATE/STREAM_RATE/STREAM_VALID are XMOS-only
            // (the XMOS owns ITS stream lifecycle; the AP declares its own
            //  stream + owns input select via SPI_W_I2S_SRC, denied to XMOS
            //  by the default arm above — dual-source rule 2026-11-20).
            case (wr_addr)
                `SPI_W_RATE, `SPI_W_STREAM_RATE, `SPI_W_STREAM_VALID:
                    wr_denied = 1'b1;
                default: wr_denied = 1'b0;
            endcase
        end
    end
    wire wr_exec = wr_stb && !wr_denied;   // gates the register write-decode

    // CMD_ERR_INFO reason codes (read 0x1C [3:0])
    localparam logic [3:0] ERR_NONE       = `SPI_ERR_NONE;
    // XMOS-owned sticky bits it may write-1-clear (2026-11-15 ruling):
    // SPI_CRC[0] + I2S_ERR[1] + FRAME_LEN[4]. Everything else is AP-domain.
    localparam logic [7:0] STICKY_XMOS_W1C_MASK = 8'b0001_0011;

    localparam logic [3:0] ERR_BAD_ADDR   = `SPI_ERR_BAD_ADDR;   // unknown/reserved write addr
    localparam logic [3:0] ERR_FLASH_BUSY = `SPI_ERR_FLASH_BUSY; // FLASH_CMD while busy (dropped)
    localparam logic [3:0] ERR_FLASH_OP   = `SPI_ERR_FLASH_OP;   // FLASH_CMD opcode not 01/02/03 (dropped)
    localparam logic [3:0] ERR_FILT_FULL  = `SPI_ERR_FILT_FULL;  // FILTER_LIST_APPEND with FLIST_MAX entries (dropped)
    localparam logic [3:0] ERR_FILT_EMPTY = `SPI_ERR_FILT_EMPTY; // FILTER_SELECT / commit on empty list (dropped)
    localparam logic [3:0] ERR_FILT_RANGE = `SPI_ERR_FILT_RANGE; // FILTER_SELECT index >= len (clamped to 0)
    localparam logic [3:0] ERR_CAL_WRAP   = `SPI_ERR_CAL_WRAP;   // CAL_DATA past word 511 (ptr wrapped)
    localparam logic [3:0] ERR_FLASH_WDT  = `SPI_ERR_FLASH_WDT;  // flash watchdog abort
    localparam logic [3:0] ERR_FRAME_LEN  = `SPI_ERR_FRAME_LEN;  // SPI frame-length error
    localparam logic [3:0] ERR_FILT_NOTFOUND = `SPI_ERR_FILT_NOTFOUND; // filter_id not in DDR4 directory (no load)
    localparam logic [3:0] ERR_FILT_SIZE     = `SPI_ERR_FILT_SIZE;     // directory payload_bytes != bank size (no load)

    // Cal shadow-pointer wrap tracking: a 0x0D auto-increment past word 511
    // wraps the 9-bit pointer; any further 0x0D write is an upload overflow.
    // Cleared by an explicit CAL_ADDR (0x0C) write.
    logic cal_ptr_wrapped;

    (* ASYNC_REG = "TRUE" *) logic [1:0] cell_test_ack_meta, cell_test_ack_sync;
    wire [1:0] cell_test_busy = cell_test_req ^ cell_test_ack_sync;

    // ---- Voicing commit handshake + applied-side readback (dsp_clk -> clk) --
    // commit_pending spans the whole apply: field-only commits release after
    // one fir_frame_done; preset swaps release after fade-out -> DDR4 load ->
    // apply -> fade-in (~50 ms). Shadow writes are rejected while pending so
    // the quasi-static bus can never tear mid-commit.
    (* ASYNC_REG = "TRUE" *) logic [2:0] vo_ack_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] vo_err_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] vo_busy_sync;
    // The applied preset/en are a multi-bit dsp_clk bus — a 2-FF sync could
    // tear mid-transition (e.g. preset 3->4 reads 0 or 7). They only change
    // inside the commit FSM and are stable BEFORE ack_toggle flips, so
    // capturing them here on the synced ack edge is a tear-free quasi-static
    // sample (stable for the full sync latency).
    (* ASYNC_REG = "TRUE" *) logic [15:0] vo_afid_r;
    (* ASYNC_REG = "TRUE" *) logic [2:0]  vo_bchg_sync;
    logic        vo_bchg_d;
    (* ASYNC_REG = "TRUE" *) logic       vo_aen_r;
    logic        vo_ack_d;
    logic        vo_err_flag;   // sticky "last preset load failed" — clears
                                // on the next executed commit (toggle edge)
    logic        vo_commit_d;
    wire         voicing_commit_pending = (voicing_commit_toggle != vo_ack_sync[2]);
    wire         vo_load_err_evt        = (vo_err_sync[2] != voicing_err_seen);
    wire         vo_commit_evt          = (voicing_commit_toggle != vo_commit_d);
    wire         vo_ack_evt             = (vo_ack_sync[2] != vo_ack_d);

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            vo_ack_sync     <= '0;
            vo_err_sync     <= '0;
            vo_busy_sync    <= '0;
            vo_afid_r       <= 16'hFFFF;
            vo_bchg_sync    <= '0;
            vo_bchg_d       <= 1'b0;
            vo_aen_r        <= 1'b0;
            vo_ack_d        <= 1'b0;
            voicing_err_seen <= 1'b0;
            vo_err_flag     <= 1'b0;
            vo_commit_d     <= 1'b0;
        end else begin
            vo_ack_sync     <= {vo_ack_sync[1:0], voicing_ack_toggle};
            vo_err_sync     <= {vo_err_sync[1:0], voicing_err_toggle};
            vo_busy_sync    <= {vo_busy_sync[0], voicing_swap_busy};
            vo_ack_d        <= vo_ack_sync[2];
            vo_bchg_sync    <= {vo_bchg_sync[1:0], voicing_bank_chg};
            vo_bchg_d       <= vo_bchg_sync[2];
            vo_commit_d     <= voicing_commit_toggle;
            // Stale-readback fix (2026-11-22): across a stream-rate reset
            // the dsp-side commit FSM parks its ack/bchg toggles WITHOUT
            // edges (Catch-5), so no capture event can ever arrive — the
            // readback would keep showing the pre-reset applied set while
            // hardware is actually unapplied. Clear to ground truth when
            // the clock regime is torn down.
            if (!stream_clocks_ready) begin
                vo_aen_r  <= 1'b0;
                vo_afid_r <= 16'hFFFF;
            end else begin
                // Ack edge => dsp commit FSM has fully applied; applied_*
                // have been stable for the entire sync latency — capture.
                if (vo_ack_evt) begin
                    vo_aen_r     <= voicing_applied_en;
                end
                // Bank-changed edge (voicing OR manual load): applied_fid
                // and the applied bank id are quasi-static by then.
                if (vo_bchg_sync[2] != vo_bchg_d) begin
                    vo_afid_r         <= voicing_applied_fid;
                    current_bank_id_r <= current_bank_id;
                end
            end
            if (vo_load_err_evt) begin
                voicing_err_seen <= vo_err_sync[2];
                vo_err_flag <= 1'b1;
            end else if (vo_commit_evt) begin
                vo_err_flag <= 1'b0;
            end
        end
    end
    wire cell_test_enabled = cell_test_cfg[0][7] || cell_test_cfg[1][7];
    wire cell_test_channel = (wr_addr == `SPI_W_CELL_TEST_R);
    // Dual-source I2S (2026-11-20): declared rate + per-path capture trim per
    // source; the applied rate follows the SELECTED source's declared rate.
    logic [2:0] rate_req_src1, rate_req_src2;
    logic [4:0] i2s_rx_trim_src1, i2s_rx_trim_src2;
    // Stream-gate event doorbells (2026-11-21 contract): [0]preempt_xmos —
    // XMOS gate closed or its session consumed; [1]preempt_ap — same for the
    // AP source; [2]echo_mismatch — XMOS 0x1B arm whose expected-rate echo
    // disagreed with the stored declaration (arm refused). W1C via 0x21,
    // XMOS masked to {0,2}; drives fpga_irq_n / spi_ap_irq_n doorbells.
    logic [2:0] stream_event;
    assign i2s_rx_trim = i2s_src_sel ? i2s_rx_trim_src2 : i2s_rx_trim_src1;
    assign stream_valid_sel = i2s_src_sel ? stream_source_valid2 : stream_source_valid;
    // rate a pending 0x1C write would leave as the selected declared rate,
    // and the newly-SELECTED source's live flag — a select write applies the
    // rate only when the source it selects is ARMED (ruled 2026-11-20:
    // input select and rate select are separate decisions; a bare select
    // never churns the clock onto a stale declaration)
    wire [2:0] sel_rate_new = ctrl_bus_data[0] ? ctrl_bus_data[4:2] : rate_req_src1;
    wire       sel_valid_new = ctrl_bus_data[0] ? ctrl_bus_data[1] : stream_source_valid;
    // fresh-declare leg: a CHANGED rate_req_src2 field while the AP is being
    // selected is a declaration — symmetric to an XMOS RATE write (fire only
    // needs the live leg or this leg; rewriting the same r2 is inert)
    wire       ap_decl_new = ctrl_bus_data[0] && (ctrl_bus_data[4:2] != rate_req_src2);
    wire       i2s_src_apply = (sel_valid_new || ap_decl_new) && (sel_rate_new != stream_applied_rate);
    assign bench_available = !cell_test_enabled && !(|cell_test_busy) && !stream_busy;

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            cell_test_ack_meta <= '0;
            cell_test_ack_sync <= '0;
        end else begin
            cell_test_ack_meta <= cell_test_ack;
            cell_test_ack_sync <= cell_test_ack_meta;
        end
    end

    logic flash_op_valid;
    assign flash_op_valid = (ctrl_bus_data[7:0] == 8'h01) ||
                            (ctrl_bus_data[7:0] == 8'h02) ||
                            (ctrl_bus_data[7:0] == 8'h03);

    // Map the AP's normalized Q0.24 volume to the internal Q16.16 scale:
    // unity input maps to 28 NS code units (the full-scale headroom target).
    function automatic logic [31:0] volume_q24_to_gain_q16(input logic [23:0] volume_q24);
        logic [28:0] scaled;
        // 28 code units * Q0.24 volume, converted to Q16.16.
        scaled = 29'(volume_q24) * 29'd28;
        return 32'((scaled + 29'd128) >> 8);
    endfunction

    logic       wr_rejected;
    logic [3:0] wr_rej_reason;
    always_comb begin
        wr_rejected   = 1'b0;
        wr_rej_reason = ERR_NONE;
        case (wr_addr)
            `SPI_W_CELL_TEST_L, `SPI_W_CELL_TEST_R: begin
                if (bench_busy || stream_busy || !stream_clocks_ready || cell_test_busy[cell_test_channel]) begin
                    wr_rejected = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end else if (ctrl_bus_data[23:8] != 0) begin
                    wr_rejected = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (ctrl_bus_data[7] &&
                             (stream_source_valid || stream_source_valid2 ||
                              line_mute_r || switch_busy_r)) begin
                    wr_rejected = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end
            end
            `SPI_W_RATE, `SPI_W_STREAM_RATE: begin
                if (bench_busy || stream_busy || cell_test_enabled || |cell_test_busy || (mgr_busy_r && boot_ok)) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end else if (ctrl_bus_data[23:3] != 0) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end
            end
            `SPI_W_STREAM_VALID: begin
                if (ctrl_bus_data[23:5] != 0) begin   // [4:2] = arm-rate echo
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (ctrl_bus_data[0] && (stream_busy || !stream_clocks_ready || bench_busy || stream_fault ||
                                                cell_test_enabled || |cell_test_busy)) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end
            end
            `SPI_W_I2S_SRC: begin
                // [23:21] unused.  src2_valid=1 gated like STREAM_VALID=1;
                // a write that would trigger a re-rate is gated like RATE.
                if (ctrl_bus_data[23:21] != 0) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (ctrl_bus_data[1] && (stream_busy || !stream_clocks_ready || bench_busy || stream_fault ||
                                                cell_test_enabled || |cell_test_busy)) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end else if (i2s_src_apply &&
                             (bench_busy || stream_busy || cell_test_enabled || |cell_test_busy || (mgr_busy_r && boot_ok))) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end
            end
            `SPI_W_VOICING_K2, `SPI_W_VOICING_K3, `SPI_W_VOICING_FILTER_ID: begin
                if (voicing_commit_pending) begin
                    wr_rejected   = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end
            end
            `SPI_W_VOICING_CTRL: begin
                if (voicing_commit_pending) begin
                    wr_rejected   = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end else if (ctrl_bus_data[23:9] != 0 ||
                             ctrl_bus_data[7:1] != 0) begin
                    wr_rejected   = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (ctrl_bus_data[8] && (stream_busy || mgr_busy_r)) begin
                    wr_rejected   = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end
            end
            `SPI_W_FILTER_LIST_APP: if (filter_list_len >= FLIST_LW'(FLIST_MAX)) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_FILT_FULL;
            end
            `SPI_W_FILTER_LIST_CTRL: if (ctrl_bus_data[1] && !ctrl_bus_data[0] && filter_list_len == '0) begin
                wr_rejected   = 1'b1;          // select-first on an empty list
                wr_rej_reason = ERR_FILT_EMPTY;
            end
            `SPI_W_FILTER_SELECT: if (filter_list_len == '0) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_FILT_EMPTY;
            end else if (!ctrl_bus_data[16] && !filter_sel_in_range) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_FILT_RANGE;
            end
            `SPI_W_CAL_DATA: if (cal_commit_pending) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = `SPI_ERR_TEST_BUSY;
            end else if (cal_ptr_wrapped) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_CAL_WRAP;
            end
            `SPI_W_CAL_COMMIT: if (cal_commit_pending) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = `SPI_ERR_TEST_BUSY;
            end
            `SPI_W_DPD_EN: if (ctrl_bus_data[0] != dpd_enable) begin
                // Dual-source (2026-11-22): either live source means an
                // active stream — AP-valid alone must gate this too.
                if (bench_busy || stream_busy || cal_commit_pending ||
                    stream_source_valid || stream_source_valid2) begin
                    wr_rejected = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_BUSY;
                end else if (ctrl_bus_data[0] &&
                             (!stream_clocks_ready || !bank_valid_r ||
                              !calibration_valid || stream_fault)) begin
                    wr_rejected = 1'b1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end
            end
            `SPI_W_FLASH_CMD: if (flash_cmd_busy) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_FLASH_BUSY;
            end else if (!flash_op_valid) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_FLASH_OP;
            end
            default: ;
        endcase
        if (stream_busy && (wr_addr == `SPI_W_BANK_LOAD ||
                            wr_addr == `SPI_W_FILTER_SELECT || wr_addr == `SPI_W_FILTER_SELECT_ID ||
                            wr_addr == `SPI_W_CAL_DATA || wr_addr == `SPI_W_CAL_COMMIT ||
                            wr_addr == `SPI_W_DPD_EN ||
                            (wr_addr == `SPI_W_FILTER_LIST_CTRL && ctrl_bus_data[1]))) begin
            wr_rejected = 1;
            wr_rej_reason = `SPI_ERR_TEST_BUSY;
        end
        // Mutual exclusion, reverse direction: while a voicing commit is
        // pending, the swap FSM is running, or the bank manager is mid-load,
        // manual bank/filter writes must not interleave a request into the
        // manager (2026-11-22: mgr_busy_r was previously ungated here —
        // a mid-load manual select desynced filter_id from what loaded).
        // (Cal/DPD writes stay unblocked — they don't touch the manager.)
        if ((voicing_commit_pending || vo_busy_sync[1] || mgr_busy_r) &&
            (wr_addr == `SPI_W_BANK_LOAD ||
             wr_addr == `SPI_W_FILTER_SELECT || wr_addr == `SPI_W_FILTER_SELECT_ID ||
             (wr_addr == `SPI_W_FILTER_LIST_CTRL && ctrl_bus_data[1]))) begin
            wr_rejected = 1;
            wr_rej_reason = `SPI_ERR_TEST_BUSY;
        end
    end

    // Boot fail flags are latched levels in qspi_boot_loader — edge-detect
    // so the sticky W1C is not immediately re-set while the level persists.
    logic boot_err_lvl;
    assign boot_err_lvl = boot_crc_fail || boot_axi_fail;

    // Filter-load failure: dsp_clk toggle from dac_coef_subsys (one flip per
    // failed load — 2026-11-22, was a raw ui_clk level). 2-FF sync + XOR
    // edge -> exactly one event per failure; the error code snapshot is
    // stable long before the toggle flips.
    (* ASYNC_REG = "TRUE" *) logic [1:0] load_err_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] cal_write_reject_sync;
    logic load_err_d;
    logic cal_write_reject_seen;
    wire  load_err_evt = (load_err_sync[1] != load_err_d);
    wire  cal_write_reject_evt = cal_write_reject_sync[2] != cal_write_reject_seen;
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            load_err_sync <= 2'b00;
            load_err_d    <= 1'b0;
            cal_write_reject_sync <= '0;
        end else begin
            load_err_sync <= {load_err_sync[0], coef_load_err};
            load_err_d    <= load_err_sync[1];
            cal_write_reject_sync <= {cal_write_reject_sync[1:0], cal_write_reject_toggle};
        end
    end

    // CMD_ERR_INFO (read 0x1C): {addr[6:0], reason[3:0]} of the most recent
    // bit[4]/[5]/[6]/[7] event; cleared together with the sticky W1C (0x16).
    logic [6:0] err_info_addr;
    logic [3:0] err_info_reason;
    logic       err_info_filter_axi;

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            sticky_err      <= 8'b0;
            spi_crc_err_d   <= 1'b0;
            boot_err_d      <= 1'b0;
            err_info_addr   <= 7'd0;
            err_info_reason <= ERR_NONE;
            err_info_filter_axi <= 1'b0;
            cal_write_reject_seen <= 1'b0;
        end else begin
            spi_crc_err_d <= spi_crc_error;
            boot_err_d    <= boot_err_lvl;
            // W1C clear FIRST (2026-11-22): evaluating it after the fault
            // sets meant a same-cycle write-1-clear swallowed a newly
            // occurring fault — last non-blocking assignment wins. With the
            // clear up here, any set below overrides it per-bit.
            if (wr_exec && (wr_addr == `SPI_W_STICKY_W1C)) begin
                if (ctrl_bus_src == SRC_XMOS) begin
                    // XMOS clears only its own domain (2026-11-15 ruling):
                    // SPI_CRC/FRAME_LEN (its bus errors; the bits are shared)
                    // and I2S_ERR. AP-domain bits — DDR4_CALIB, PLL_UNLOCK,
                    // BAD_ADDR, CMD_REJECT, BOOT_FLASH — are masked off, and
                    // the CMD_ERR_INFO debug record is never cleared by XMOS.
                    sticky_err <= sticky_err & ~(ctrl_bus_data[7:0] & STICKY_XMOS_W1C_MASK);
                end else begin
                    sticky_err          <= sticky_err & ~ctrl_bus_data[7:0];
                    err_info_addr       <= 7'd0;
                    err_info_reason     <= ERR_NONE;
                    err_info_filter_axi <= 1'b0;
                end
            end
            // Set sticky bits on rising edges / persistent conditions
            if (spi_crc_error && !spi_crc_err_d) sticky_err[0] <= 1'b1;
            if (i2s_err_r)                       sticky_err[1] <= 1'b1;
            if (!ddr4_calib_sync[1])             sticky_err[2] <= 1'b1;
            if (!clk_lock_sync[1])               sticky_err[3] <= 1'b1;
            if (spi_frame_error)                 sticky_err[4] <= 1'b1;
            if (wr_stb && (wr_addr_invalid || wr_denied)) sticky_err[5] <= 1'b1;
            if ((wr_stb && wr_rejected) || load_err_evt)
                                                 sticky_err[6] <= 1'b1;
            if (cal_write_reject_evt || vo_load_err_evt)
                                                 sticky_err[6] <= 1'b1;
            if ((boot_err_lvl && !boot_err_d) || flash_cmd_err)
                                                 sticky_err[7] <= 1'b1;
            // Error info latch: most recent event wins
            if (flash_cmd_err) begin
                err_info_addr   <= `SPI_W_FLASH_CMD;
                err_info_reason <= ERR_FLASH_WDT;
                err_info_filter_axi <= 1'b0;
            end else if (load_err_evt) begin
                err_info_addr   <= `SPI_W_FILTER_SELECT;
                err_info_reason <= (coef_load_err_code == 3'd3) ? `SPI_ERR_FILT_RATE :
                                   ((coef_load_err_code == 3'd2) ||
                                    (coef_load_err_code == 3'd4)) ? ERR_FILT_SIZE :
                                                                    ERR_FILT_NOTFOUND;
                err_info_filter_axi <= (coef_load_err_code == 3'd4);
            end else if (cal_write_reject_evt) begin
                err_info_addr   <= `SPI_W_CAL_DATA;
                err_info_reason <= `SPI_ERR_TEST_BUSY;
                err_info_filter_axi <= 1'b0;
            end else if (vo_load_err_evt) begin
                // Preserve the real failure reason (2026-11-22): the loader
                // reported it via load_err_evt a few cycles earlier — decode
                // coef_load_err_code identically instead of stomping it
                // with a generic NOTFOUND.
                err_info_addr   <= `SPI_W_VOICING_CTRL;
                err_info_reason <= (coef_load_err_code == 3'd3) ? `SPI_ERR_FILT_RATE :
                                   ((coef_load_err_code == 3'd2) ||
                                    (coef_load_err_code == 3'd4)) ? ERR_FILT_SIZE :
                                                                    ERR_FILT_NOTFOUND;
                err_info_filter_axi <= (coef_load_err_code == 3'd4);
            end else if (wr_stb && (wr_addr_invalid || wr_denied || wr_rejected)) begin
                err_info_addr   <= wr_addr;
                err_info_reason <= (wr_addr_invalid || wr_denied) ? ERR_BAD_ADDR : wr_rej_reason;
                err_info_filter_axi <= 1'b0;
            end else if (spi_frame_error) begin
                err_info_addr   <= 7'd0;
                err_info_reason <= ERR_FRAME_LEN;
                err_info_filter_axi <= 1'b0;
            end
            // (W1C clear for register 0x16 moved ABOVE the fault sets —
            //  a same-cycle fault must win over the clear.)
            if (cal_write_reject_evt)
                cal_write_reject_seen <= cal_write_reject_sync[2];
        end
    end

    // Doorbell IRQs (2026-11-21 contract): sticky errors are shared; each port
    // additionally sees its own stream-gate events — XMOS: preempt_xmos[0] +
    // echo_mismatch[2]; AP: preempt_ap[1]. The flags live in STREAM_EVENT
    // (read 0x22 / W1C 0x21) because sticky_err is fully allocated.
    assign fpga_irq_n   = (sticky_err != 8'b0 || stream_event[0] || stream_event[2]) ? 1'b0 : 1'b1;
    assign spi_ap_irq_n = (sticky_err != 8'b0 || stream_event[1]) ? 1'b0 : 1'b1;

    // Level / output-select relays: pulse the automute controller on change.
    // The actual relays are driven by the sequencer in the dsp_clk domain.
    // Change detection compares the INCOMING bus data against the current
    // command register (cmd_* only updates on the same single-cycle valid,
    // so an old-vs-previous compare could never fire the pulse).
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            level_target      <= 3'b000;
            level_switch_req  <= 1'b0;
        end else begin
            level_switch_req <= wr_exec && (wr_addr == `SPI_W_LEVEL) &&
                                (ctrl_bus_data[2:0] != cmd_level);
            if (wr_exec && (wr_addr == `SPI_W_LEVEL))
                level_target <= ctrl_bus_data[2:0];
        end
    end

    spi_slave u_spi_slave_xmos (
        .clk            (clk),
        .rst_n          (ext_rst_n),
        .spi_sclk       (spi_xmos_sclk),
        .spi_cs_n       (spi_xmos_cs_n),
        .spi_mosi       (spi_xmos_mosi),
        .spi_miso       (spi_xmos_miso),
        .tx_data_in     (spi_tx_data),
        .data_out       (x_bus_data),
        .data_valid     (x_bus_valid),
        .crc_err_pulse  (x_crc_err),
        .frame_err_pulse(x_frame_err)
    );

    spi_slave u_spi_slave_ap (
        .clk            (clk),
        .rst_n          (ext_rst_n),
        .spi_sclk       (spi_ap_sclk),
        .spi_cs_n       (spi_ap_cs_n),
        .spi_mosi       (spi_ap_mosi),
        .spi_miso       (spi_ap_miso),
        .tx_data_in     (spi_tx_data_a),
        .data_out       (a_bus_data),
        .data_valid     (a_bus_valid),
        .crc_err_pulse  (a_crc_err),
        .frame_err_pulse(a_frame_err)
    );

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            // Fail-safe (2026-10-09): volume resets to ZERO. The digital clamp
            // releases only once stream_source_valid is armed (0x1B), and even
            // then nothing leaves the XLR until the AP has written VOLUME.
            // (Was 0xFFFFFFFF = full scale at unmute.)
            sys_volume      <= 32'h0000_0000;
            cmd_level       <= 3'b000;
            // base_rate_sel is now derived (assign) from stream_applied_rate[0]
            // — a deselected XMOS RATE write must not corrupt the running
            // oscillator-family readback (2026-11-22).
            stream_rate_request <= 0;
            stream_rate_toggle <= 0;
            stream_source_valid <= 0;
            stream_source_valid2 <= 0;
            i2s_src_sel     <= 1'b0;
            rate_req_src1   <= 3'd0;
            rate_req_src2   <= 3'd0;
            stream_event    <= 3'd0;
            i2s_rx_trim_src1 <= 5'd8;
            i2s_rx_trim_src2 <= 5'd8;
            coef_bank_id    <= 4'h0;
            coef_load_start <= 1'b0;
            read_addr_reg   <= `SPI_W_NOP;
            read_addr_reg_a <= `SPI_W_NOP;
            last_wr_src     <= SRC_XMOS;
            filter_list_len  <= '0;
            filter_cur_index <= '0;
            filter_id        <= 16'd0;
            filter_load_req  <= 1'b0;
            cal_wr_toggle     <= 1'b0;
            cal_wr_ptr        <= 9'd0;
            cal_wr_addr       <= 9'd0;
            cal_wr_data       <= 24'd0;
            cal_commit_toggle <= 1'b0;
            cal_rd_addr       <= 9'd0;
            flash_cmd_opcode  <= 8'd0;
            flash_cmd_target  <= 2'b00;
            flash_cmd_addr    <= 32'd0;
            flash_cmd_trigger <= 1'b0;
            flash_buf_wdata   <= 8'd0;
            flash_buf_we      <= 1'b0;
            flash_buf_waddr   <= 8'd0;
            flash_buf_raddr   <= 8'd0;
            dpd_enable        <= 1'b0;
            cell_test_cfg     <= '0;
            cell_test_req     <= '0;
            cal_ptr_wrapped   <= 1'b0;
            // Voicing: fail-safe = bypass preset 0, no commit pending
            voicing_sh_en        <= 1'b0;
            voicing_sh_k2        <= '0;
            voicing_sh_k3        <= '0;
            voicing_sh_fid       <= 16'hFFFF;
            voicing_commit_toggle <= 1'b0;
        end else begin
            // coef_load_start / filter_load_req are TOGGLES now (one flip per
            // accepted write — was a 5 ns pulse the dsp_clk side could slip,
            // CDC-2). No per-cycle default.
            flash_cmd_trigger <= 1'b0;
            flash_buf_we      <= 1'b0;
            // 0x21 STREAM_EVENT W1C FIRST so a same-cycle fault/event set
            // wins per-bit (was inside the write decode — a W1C coinciding
            // with a preemption swallowed the event).
            if (wr_exec && (wr_addr == `SPI_W_STREAM_EVENT)) begin
                if (ctrl_bus_src == SRC_XMOS)
                    stream_event <= stream_event & ~(ctrl_bus_data[2:0] & 3'b101);
                else
                    stream_event <= stream_event & ~ctrl_bus_data[2:0];
            end
            if (bench_busy || stream_busy || !stream_clocks_ready || stream_fault) begin
                // A session that existed is being consumed -> preempt doorbell
                // for that source (stream-gate contract: it must re-check its
                // gate, then re-declare/re-arm to come back).
                if (stream_source_valid)  stream_event[0] <= 1'b1;
                if (stream_source_valid2) stream_event[1] <= 1'b1;
                stream_source_valid <= 0;
                stream_source_valid2 <= 0;
            end
            if (stream_busy || !stream_clocks_ready) dpd_enable <= 0;
            if (flash_buf_we) flash_buf_waddr <= flash_buf_waddr + 8'd1;
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin
                    // WRITE — gated by the per-port access mask (wr_denied):
                    // a denied XMOS frame lands as BAD_ADDR, never executes.
                    if (wr_exec) last_wr_src <= ctrl_bus_src;
                    case (wr_exec ? ctrl_bus_data[30:24] : `SPI_W_NOP)
                        // AP Q0.24 normalized amplitude -> internal Q16.16
                        // NS code gain; 0xFFFFFF maps to 28.0 code units.
                        `SPI_W_VOLUME: sys_volume <= volume_q24_to_gain_q16(ctrl_bus_data[23:0]);
                        `SPI_W_LEVEL:  cmd_level     <= ctrl_bus_data[2:0]; // digital level cap, applied by the sequencer while muted
                        `SPI_W_RATE, `SPI_W_STREAM_RATE: if (!wr_rejected) begin
                            rate_req_src1 <= ctrl_bus_data[2:0];
                            // 2026-11-20 dual-source: the declared rate is stored even while the
                            // XMOS is deselected, but it only APPLIES while XMOS is selected —
                            // an XMOS rate change must not tear the AP stream's clock regime.
                            // Delta-gated (idempotent): a same-rate rewrite still invalidates
                            // the stream (RATE write = restart) but must not burn a
                            // mute+relock cycle that changes nothing.
                            if (!i2s_src_sel) begin
                                stream_source_valid <= 0;
                                stream_source_valid2 <= 0;
                                dpd_enable <= 0;
                                if (ctrl_bus_data[2:0] != stream_applied_rate) begin
                                    stream_rate_request <= ctrl_bus_data[2:0];
                                    stream_rate_toggle <= ~stream_rate_toggle;
                                    // Any apply destroys the clock regime for
                                    // BOTH sources -> both must re-check gate.
                                    stream_event[1:0] <= 2'b11;
                                end
                            end
                        end
                        // 0x1B arm while XMOS is selected applies its declared rate if it
                        // diverged while deselected — the arm, not the input select, is the
                        // event that owns the clock decision (2026-11-20 ruling).
                        `SPI_W_STREAM_VALID: if (!wr_rejected) begin
                            // Arm-echo (2026-11-21 ruling): an arm write must echo
                            // the rate the source believes is stored in
                            // rate_req_src1 at [4:2]. A mismatch means the
                            // source's view of its own declaration is stale —
                            // refuse the arm and flag it; no relock is burned.
                            if (ctrl_bus_data[0] && ctrl_bus_data[4:2] != rate_req_src1) begin
                                stream_source_valid <= 1'b0;
                                stream_event[2] <= 1'b1;
                            end else begin
                                stream_source_valid <= ctrl_bus_data[0];
                                if (ctrl_bus_data[0] && !i2s_src_sel && rate_req_src1 != stream_applied_rate) begin
                                    stream_rate_request <= rate_req_src1;
                                    stream_rate_toggle <= ~stream_rate_toggle;
                                    // base_rate_sel follows applied_rate (assign)
                                    stream_source_valid <= 0;   // arm consumed — re-arm post-relock
                                    stream_source_valid2 <= 0;
                                    dpd_enable <= 0;
                                    stream_event[1:0] <= 2'b11;
                                end
                            end
                        end
                        // 0x21 STREAM_EVENT W1C: handled BEFORE this case so
                        // same-cycle fault sets win (see top of this block).
                        `SPI_W_STREAM_EVENT: ;
                        // 0x1C I2S_SRC (AP-only): input select + AP stream declaration.  The
                        // rate machine follows the SELECTED source's declared rate: after a
                        // write, if the newly-selected declared rate differs from applied_rate
                        // the FSM is toggled (shared single clock pair — Option A ruling:
                        // deselected sources conform to the live interface rate or go idle).
                        `SPI_W_I2S_SRC: if (!wr_rejected) begin
                            // Gate transition: the source being deselected gets
                            // a preempt doorbell (its gate is closing — teardown
                            // + refuse new streams until reselected + renegotiated).
                            if (ctrl_bus_data[0] != i2s_src_sel)
                                stream_event[ctrl_bus_data[0] ? 0 : 1] <= 1'b1;
                            i2s_src_sel <= ctrl_bus_data[0];
                            stream_source_valid2 <= ctrl_bus_data[1];
                            rate_req_src2 <= ctrl_bus_data[4:2];
                            i2s_rx_trim_src1 <= ctrl_bus_data[12:8];
                            i2s_rx_trim_src2 <= ctrl_bus_data[20:16];
                            if (i2s_src_apply) begin
                                stream_rate_request <= sel_rate_new;
                                stream_rate_toggle <= ~stream_rate_toggle;
                                // base_rate_sel follows applied_rate (assign)
                                stream_source_valid <= 0;
                                stream_source_valid2 <= 0;
                                dpd_enable <= 0;
                                stream_event[1:0] <= 2'b11;
                            end
                        end
                        `SPI_W_CELL_TEST_L, `SPI_W_CELL_TEST_R: if (!wr_rejected) begin
                            cell_test_cfg[cell_test_channel] <= ctrl_bus_data[7:0];
                            cell_test_req[cell_test_channel] <= ~cell_test_req[cell_test_channel];
                        end
                        `SPI_W_BANK_LOAD: if (!wr_rejected) begin
                            coef_bank_id    <= ctrl_bus_data[3:0];
                            coef_load_start <= ~coef_load_start;
                        end
                        // 7'h06: RESERVED (was clk_source_sel; merged into 0x03 —
                        //        a separate clock register allowed the DSP family and
                        //        the physical mclk to disagree)
                        // 7'h07: RESERVED (was OUTSEL 0=line/1=HP; headphone
                        //        output stage removed 2026-11-14 — no HP hw)
                        `SPI_W_FILTER_LIST_CTRL: begin // [0]=clear, [1]=select entry 0
                            // [1] is the list "commit": after appending, one write
                            // loads the user's default (entry 0). Ignored when [0]
                            // is also set or the list is empty (FILT_EMPTY).
                            if (ctrl_bus_data[0]) begin
                                filter_list_len  <= '0;
                                filter_cur_index <= '0;
                            end else if (!wr_rejected && ctrl_bus_data[1] && filter_list_len != '0) begin
                                filter_cur_index <= '0;
                                filter_id        <= filter_list[0];
                                filter_load_req  <= ~filter_load_req;
                            end
                        end
                        `SPI_W_FILTER_LIST_APP: begin // [15:0]=filter_id
                            if (filter_list_len < FLIST_LW'(FLIST_MAX)) begin
                                filter_list[filter_list_len[FLIST_IW-1:0]] <= ctrl_bus_data[15:0];
                                filter_list_len <= filter_list_len + FLIST_LW'(1);
                            end
                        end
                        `SPI_W_FILTER_SELECT: begin // [16]=advance, [FLIST_IW-1:0]=index
                            if (filter_list_len != '0 && !stream_busy) begin
                                logic [FLIST_IW-1:0] new_index;
                                if (ctrl_bus_data[16])
                                    new_index = filter_adv_index;          // toggle with wrap
                                else
                                    new_index = filter_sel_in_range
                                                ? ctrl_bus_data[FLIST_IW-1:0] : '0; // clamp
                                filter_cur_index <= new_index;
                                filter_id        <= filter_list[new_index];
                                filter_load_req  <= ~filter_load_req;
                            end
                        end
                        // 7'h0B: RESERVED (was DAC_MODE video_mode; video-sync
                        //        streaming not supported per 2026-11-15 ruling)
                        `SPI_W_CAL_ADDR: begin // shadow write pointer
                            cal_wr_ptr      <= ctrl_bus_data[8:0];
                            cal_ptr_wrapped <= 1'b0;
                        end
                        `SPI_W_CAL_DATA: if (!stream_busy && !cal_commit_pending) begin // write word to shadow bank, auto-increment
                            cal_wr_data   <= ctrl_bus_data[23:0];
                            cal_wr_addr   <= cal_wr_ptr;   // stable for the CDC sample
                            cal_wr_toggle <= ~cal_wr_toggle;
                            cal_wr_ptr    <= cal_wr_ptr + 9'd1;
                            if (cal_wr_ptr == 9'd511)
                                cal_ptr_wrapped <= 1'b1; // overflow flag (sticky[6])
                        end
                        `SPI_W_CAL_COMMIT: if (!stream_busy && !cal_commit_pending)
                                               cal_commit_toggle <= cal_commit_toggle ^ ctrl_bus_data[0];
                        `SPI_W_CAL_RDADDR:    cal_rd_addr <= ctrl_bus_data[8:0]; // active-bank readback
                        `SPI_W_FLASH_ADDR_LO: flash_cmd_addr[23:0] <= ctrl_bus_data[23:0];
                        `SPI_W_FLASH_ADDR_HI: begin // + target select [9:8]
                            flash_cmd_addr[31:24] <= ctrl_bus_data[7:0];
                            flash_cmd_target      <= ctrl_bus_data[9:8];
                        end
                        `SPI_W_FLASH_CMD: begin // 0x01 erase / 0x02 program / 0x03 read
                            // Busy drop and unknown-opcode drop both flag
                            // sticky[6] + CMD_ERR_INFO (see wr_rejected)
                            if (!flash_cmd_busy && flash_op_valid) begin
                                flash_cmd_opcode  <= ctrl_bus_data[7:0];
                                flash_cmd_trigger <= 1'b1;
                            end
                        end
                        `SPI_W_FLASH_DATA: begin // page-buffer byte, auto-increment
                            flash_buf_wdata <= ctrl_bus_data[7:0];
                            flash_buf_we    <= 1'b1;
                        end
                        `SPI_W_FLASH_PTR: begin // [7:0] write ptr, [15:8] read ptr
                            flash_buf_waddr <= ctrl_bus_data[7:0];
                            flash_buf_raddr <= ctrl_bus_data[15:8];
                        end
                        `SPI_W_DPD_EN: if (!wr_rejected) dpd_enable <= ctrl_bus_data[0]; // Step 4D.1
                        `SPI_W_FILTER_SELECT_ID: if (!wr_rejected) begin // [15:0]=directory filter_id, bypasses
                                     // the toggle list ("any filter at any time", TODO-23).
                                     // filter_cur_index is left untouched; 0x17 readback
                                     // shows the loaded ID.
                            filter_id       <= ctrl_bus_data[15:0];
                            filter_load_req <= ~filter_load_req;
                        end
                        // Voicing shadow set: the 24-bit SPI field IS the
                        // Q2.25 coefficient, sign-extended to 27 bits —
                        // range (-0.25,+0.25) at full 2^-25 resolution
                        // (k2=+2.0e-3 -> 24'sd67109, k3=-8.0e-5 -> -24'sd2684
                        // exactly; |k|>=0.25 would be -18dBc H2 anyway).
                        // !wr_rejected is mandatory: a commit-pending write
                        // here would tear the quasi-static CDC bus mid-apply.
                        `SPI_W_VOICING_K2: if (!wr_rejected)
                            voicing_sh_k2 <= {{3{ctrl_bus_data[23]}}, ctrl_bus_data[23:0]};
                        `SPI_W_VOICING_K3: if (!wr_rejected)
                            voicing_sh_k3 <= {{3{ctrl_bus_data[23]}}, ctrl_bus_data[23:0]};
                        `SPI_W_VOICING_FILTER_ID: if (!wr_rejected)
                            voicing_sh_fid <= ctrl_bus_data[15:0];
                        `SPI_W_VOICING_CTRL: if (!wr_rejected) begin
                            voicing_sh_en <= ctrl_bus_data[0];
                            // [8]=1: atomic commit — all fields apply at ONE
                            // fir_frame_done downstream (or after the bank
                            // swap for a preset change).
                            if (ctrl_bus_data[8])
                                voicing_commit_toggle <= ~voicing_commit_toggle;
                        end
                        default: ;
                    endcase
                end else begin
                    // READ — per-port latch; readback muxes are independent
                    if (ctrl_bus_src == SRC_XMOS) read_addr_reg   <= ctrl_bus_data[30:24];
                    else                          read_addr_reg_a <= ctrl_bus_data[30:24];
                end
            end
        end
    end

    // SPI readback MUX — registered (f9wc route review 2026-08-15): the mux
    // feeds the spi_slave TX CRC-8 cone (4 chained byte CRCs, 9 logic levels
    // total) which failed clk_200m by -0.59 ns as one combinational cone.
    // Registering here is free: spi_slave samples tx_data_in only on the
    // synchronized cs_n falling edge, and read_addr_reg is written by the
    // PREVIOUS SPI frame, so spi_tx_data is stable many cycles before use.
    logic [31:0] spi_tx_data_c, spi_tx_data_c_a;
    // Shared readback function — both ports read the SAME register view; the
    // per-port write-access gate (wr_denied) is the only partition. last_wr_src
    // rides CTRL_STATE[6] so a master can see who touched control last.
    function automatic logic [31:0] reg_read(input logic [6:0] a);
        case (a)
            // 0x10: Magic ID
            `SPI_R_MAGIC: reg_read = `SPI_MAGIC_ID;
            // 0x11: Sticky error register (readback; W1C via WRITE addr 0x16)
            `SPI_R_STICKY_ERR: reg_read = {24'd0, sticky_err};
            // 0x12: Control state
            `SPI_R_CTRL_STATE: reg_read = {25'd0, last_wr_src, clk_source_sel, base_rate_sel, 1'b0, cmd_level};
            // 0x13: Coefficient loader status
            //       {bank_valid[12], mgr_busy[11], load_done[10], clk_src[9],
            //        base_rate[8], current_bank_id[7:4], coef_bank_id[3:0]}
            `SPI_R_COEF_STATUS: reg_read = {19'd0, bank_valid_r, mgr_busy_r, coef_load_done_r,
                                    clk_source_sel, base_rate_sel, current_bank_id_r[3:0],
                                    coef_bank_id};
            // 0x14: Mute / relay status
            `SPI_R_MUTE_STATUS: reg_read = {27'd0, i2s_err_r, switch_busy_r,
                                    1'b0, line_mute_r, 1'b0};
            // 0x15: Clock / PLL status (+ DPD enable readback, bit 2)
            `SPI_R_CLK_STATUS: reg_read = {29'd0, dpd_enable, ddr4_calib_sync[1], clk_lock_sync[1]};
            // 0x16: Filter list status {rsvd[11], list_len[10:5], cur_index[4:0]}
            `SPI_R_FILTER_LIST_STAT: reg_read = {21'd0, filter_list_len, filter_cur_index};
            // 0x17: Current + next-in-list filter IDs (next is informational only)
            `SPI_R_FILTER_IDS: reg_read = {filter_next_id, filter_id};
            // 0x18: Cal store status
            `SPI_R_CAL_STATUS: reg_read = {20'd0, calibration_valid, cal_wr_ptr,
                                                cal_commit_pending, cal_active_bank};
            // 0x19: Cal active-bank readback (address set via 0x0F)
            `SPI_R_CAL_RDDATA: reg_read = {8'd0, cal_rd_data};
            // 0x1A: Flash / boot-loader status
            `SPI_R_BOOT_STATUS: reg_read = {18'd0, boot_src, boot_record_count, boot_axi_fail,
                                    boot_crc_fail, boot_ok, boot_done, flash_cmd_busy};
            // 0x1B: Flash read-buffer byte (pointer set via 0x14 [15:8];
            //       no auto-inc — set pointer, then read, per byte)
            `SPI_R_FLASH_RDDATA: reg_read = {24'd0, flash_buf_rdata};
            // 0x1C: CMD_ERR_INFO — {addr[6:0], reason[3:0]} of the most
            //       recent sticky[4..7] event; cleared by the W1C (0x16)
            `SPI_R_CMD_ERR_INFO: reg_read = {20'd0, err_info_filter_axi,
                                                   err_info_addr, err_info_reason};
            `SPI_R_BENCH_STATUS: reg_read = bench_status;
            // 0x20 STREAM_STATUS: [0]busy [1]clocks_ready [2]svalid_xmos [3]bank_valid
            //   [4]fault [7:5]applied_rate [10:8]req_rate [15:11]rx_trim(sel)
            //   [16]audio_ready [17]src_sel [18]svalid_ap [21:19]rate_req_src2
            //   [22]dpd_deadline_miss (RO, sticky until stream teardown)
            `SPI_R_STREAM_STATUS: reg_read = {10'd0, dpd_deadline_miss, rate_req_src2, stream_source_valid2, i2s_src_sel,
                stream_audio_ready, i2s_rx_trim, stream_rate_request,
                stream_applied_rate, stream_fault, bank_valid_r, stream_source_valid,
                stream_clocks_ready, stream_busy};
            // 0x21: Voicing status — APPLIED set is the dsp_clk truth; the
            // requested/shadow set diverges while commit_pending is high.
            `SPI_R_VOICING_STATUS: reg_read = {
                vo_afid_r, 10'd0, voicing_commit_pending,
                vo_busy_sync[1], vo_err_flag, vo_aen_r,
                (voicing_sh_fid == 16'hFFFF), voicing_sh_en};
            // 0x22 STREAM_EVENT: [0]preempt_xmos [1]preempt_ap [2]echo_mismatch
            //   (W1C via write 0x21), [5:3] rate_req_src1 — informational
            //   shadow only; it never authorizes a stream (renegotiate->declare
            //   ->arm is always required after a select).
            `SPI_R_STREAM_EVENT: reg_read = {18'd0, rate_req_src1, stream_event};
            `SPI_R_CELL_TEST_L: reg_read = {23'd0, cell_test_busy[0], cell_test_cfg[0]};
            `SPI_R_CELL_TEST_R: reg_read = {23'd0, cell_test_busy[1], cell_test_cfg[1]};
            default: reg_read = `SPI_READ_UNMAPPED;
        endcase
    endfunction

    always_comb begin
        spi_tx_data_c   = reg_read(read_addr_reg);
        spi_tx_data_c_a = reg_read(read_addr_reg_a);
    end
    always_ff @(posedge clk) begin
        spi_tx_data   <= spi_tx_data_c;
        spi_tx_data_a <= spi_tx_data_c_a;
    end

    // Single-register clock control: the LMK00304 mux select is the same
    // register as the DSP base-rate select. The top-level switch sequencer
    // mutes (via the automute rate_changed path) and holds the MMCM in reset
    // around the physical mux flip.
    // base_rate_sel / clk_source_sel reflect the RUNNING oscillator family —
    // derived from the applied rate, never a deselected source's declaration.
    assign base_rate_sel  = stream_applied_rate[0];
    assign clk_source_sel = base_rate_sel;


    // Next list entry (wrap) — informational readback (0x17); no preload (TODO-16 ruling)
    always_comb begin
        if (filter_list_len == '0)
            filter_next_id = 16'd0;
        else
            filter_next_id = filter_list[filter_adv_index];
    end

endmodule
