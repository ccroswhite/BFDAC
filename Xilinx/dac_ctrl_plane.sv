`timescale 1ns / 1ps

// DAC Control Plane
// SPI slave + register file.
// Clocked by the board-specific system clock; runs independently of the audio path.
// Register addresses / reason codes: spi_regs.svh (single source of truth).

`include "spi_regs.svh"

module dac_ctrl_plane (
    input  logic        clk,        // Control-plane clock (200 MHz on VU13P)
    input  logic        ext_rst_n,

    // SPI interface
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Relay control (to automute controller, Fig. 4d set)
    output logic        level_switch_req,   // Single-cycle pulse (legacy; sequencer now acts on target != applied)
    output logic [2:0]  level_target,       // digital level cap: 000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms
    output logic        outsel_switch_req,  // Single-cycle pulse
    output logic        outsel_target,      // 0 = line XLR, 1 = headphone

    // Status inputs (for SPI readback)
    input  logic        mgr_busy,
    input  logic        bank_valid,         // dsp_clk level: FIR active bank holds a good load
    input  logic        coef_load_done,
    input  logic [3:0]  current_bank_id,
    input  logic        coef_load_err,      // ui_clk level: last filter load failed
    input  logic [1:0]  coef_load_err_code, // 1 = ID not in directory, 2 = size mismatch
    input  logic        i2s_err,             // dsp_clk domain, will be synchronised
    input  logic        switch_busy,         // dsp_clk domain, will be synchronised
    input  logic        clk_locked,
    input  logic        ddr4_init_calib_complete,
    input  logic        line_mute_status,   // dsp_clk domain, will be synchronised
    input  logic        hp_mute_status,     // dsp_clk domain, will be synchronised

    // Control outputs
    output logic [31:0] sys_volume,
    output logic        base_rate_sel,    // 0 = 44.1k family, 1 = 48k family (reg 0x03)
    output logic        clk_source_sel,   // ALIAS of base_rate_sel: one register drives
                                          // both the DSP family select and the LMK00304
                                          // OCXO mux (they can never disagree)
    output logic [3:0]  coef_bank_id,
    output logic        coef_load_start,  // Single-cycle pulse

    // Named-filter toggle list (regs 0x08-0x0B; docs/coef_format_v2.md)
    output logic [15:0] filter_id,        // Currently selected filter (DDR4 directory ID)
    output logic [15:0] filter_next_id,   // Next list entry — bank manager preload target
    output logic        filter_load_req,  // Single-cycle pulse on select/advance
    output logic        video_mode,       // Status flag (host-enforced eligibility)
    output logic        spi_unmute,       // Raw clk_49m-domain unmute command (CDC in top)
    output logic        fpga_irq_n,       // Active-low IRQ to ARM (sticky errors)

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
    input  tri0            bench_busy,
    input  logic [31:0]    bench_status,
    output logic          bench_available,
    output logic [2:0]    stream_rate_request,
    output logic          stream_rate_toggle,
    output logic          stream_source_valid,
    output logic [4:0]    i2s_rx_trim,
    input  tri0           stream_busy,
    input  tri1           stream_clocks_ready,
    input  logic [2:0]    stream_applied_rate,
    input  tri0           stream_fault,
    input  tri1           stream_audio_ready
);

    // Cal shadow-bank write pointer. cal_wr_addr (the exported CDC bus) holds
    // the PRE-increment address of the last write so it is stable when the
    // wr_toggle edge reaches the dsp_clk domain 2-3 cycles later; the pointer
    // itself auto-increments immediately for the next 0x0D frame.
    logic [8:0] cal_wr_ptr;

    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;
    logic        spi_crc_error;
    logic        spi_frame_error;
    logic [2:0]  cmd_level;
    logic        cmd_outsel;
    logic        cmd_unmute;

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
    logic        hp_mute_r;

    (* ASYNC_REG = "TRUE" *) logic [1:0] i2s_err_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] switch_busy_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] line_mute_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] hp_mute_sync;
    // ddr4_init_calib_complete comes from the MIG ui_clk domain (f9wc route
    // review 2026-08-15: it was consumed raw — the last unconstrained CDC).
    // Monotonic level, safe through a 2-FF sync.
    (* ASYNC_REG = "TRUE" *) logic [1:0] ddr4_calib_sync;

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            i2s_err_sync     <= '0;
            switch_busy_sync <= '0;
            line_mute_sync   <= '0;
            hp_mute_sync     <= '0;
            ddr4_calib_sync  <= '0;
        end else begin
            i2s_err_sync     <= {i2s_err_sync[0], i2s_err};
            switch_busy_sync <= {switch_busy_sync[0], switch_busy};
            line_mute_sync   <= {line_mute_sync[0], line_mute_status};
            hp_mute_sync     <= {hp_mute_sync[0], hp_mute_status};
            ddr4_calib_sync  <= {ddr4_calib_sync[0], ddr4_init_calib_complete};
        end
    end

    always_ff @(posedge clk) begin
        mgr_busy_r        <= mgr_busy;
        bank_valid_r      <= bank_valid;
        coef_load_done_r  <= coef_load_done;
        current_bank_id_r <= current_bank_id;
        i2s_err_r         <= i2s_err_sync[1];
        switch_busy_r     <= switch_busy_sync[1];
        line_mute_r       <= line_mute_sync[1];
        hp_mute_r         <= hp_mute_sync[1];
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
    logic       spi_crc_err_d;
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
            `SPI_W_UNMUTE,        `SPI_W_BANK_LOAD,      `SPI_W_OUTSEL,
            `SPI_W_FILTER_LIST_CTRL, `SPI_W_FILTER_LIST_APP, `SPI_W_FILTER_SELECT,
            `SPI_W_DAC_MODE,      `SPI_W_CAL_ADDR,       `SPI_W_CAL_DATA,
            `SPI_W_CAL_COMMIT,    `SPI_W_CAL_RDADDR,     `SPI_W_FLASH_ADDR_LO,
            `SPI_W_FLASH_ADDR_HI, `SPI_W_FLASH_CMD,      `SPI_W_FLASH_DATA,
            `SPI_W_FLASH_PTR,     `SPI_W_DPD_EN,         `SPI_W_STICKY_W1C,
            `SPI_W_FILTER_SELECT_ID,
            `SPI_W_CELL_TEST_L, `SPI_W_CELL_TEST_R,
            `SPI_W_STREAM_RATE, `SPI_W_STREAM_VALID, `SPI_W_I2S_RX_TRIM: wr_addr_invalid = 1'b0;
            default:                                    wr_addr_invalid = 1'b1;
        endcase
    end

    // CMD_ERR_INFO reason codes (read 0x1C [3:0])
    localparam logic [3:0] ERR_NONE       = `SPI_ERR_NONE;
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
    wire cell_test_enabled = cell_test_cfg[0][7] || cell_test_cfg[1][7];
    wire cell_test_channel = (wr_addr == `SPI_W_CELL_TEST_R);
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
                             (cmd_unmute || line_mute_r || hp_mute_r || switch_busy_r)) begin
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
                if (ctrl_bus_data[23:1] != 0) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (ctrl_bus_data[0] && (stream_busy || !stream_clocks_ready || bench_busy || stream_fault)) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end
            end
            `SPI_W_I2S_RX_TRIM: begin
                if (ctrl_bus_data[23:5] != 0) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_FORMAT;
                end else if (cmd_unmute || stream_source_valid || bench_busy || stream_busy) begin
                    wr_rejected = 1;
                    wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
                end
            end
            `SPI_W_UNMUTE: if (ctrl_bus_data[0] && (stream_busy || !stream_clocks_ready || !stream_audio_ready || stream_fault ||
                                          bench_busy || cell_test_enabled || |cell_test_busy)) begin
                wr_rejected = 1'b1;
                wr_rej_reason = `SPI_ERR_TEST_UNSAFE;
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
            `SPI_W_CAL_DATA: if (cal_ptr_wrapped) begin
                wr_rejected   = 1'b1;
                wr_rej_reason = ERR_CAL_WRAP;
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
    end

    // Boot fail flags are latched levels in qspi_boot_loader — edge-detect
    // so the sticky W1C is not immediately re-set while the level persists.
    logic boot_err_lvl;
    assign boot_err_lvl = boot_crc_fail || boot_axi_fail;

    // Filter-load failure: ui_clk level from coef_bank_loader (set on failure,
    // cleared on the next load). 2-FF sync + rising edge -> one event per
    // failure; the code is stable one ui_clk before the level rises.
    (* ASYNC_REG = "TRUE" *) logic [1:0] load_err_sync;
    logic load_err_d;
    wire  load_err_evt = load_err_sync[1] && !load_err_d;
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            load_err_sync <= 2'b00;
            load_err_d    <= 1'b0;
        end else begin
            load_err_sync <= {load_err_sync[0], coef_load_err};
            load_err_d    <= load_err_sync[1];
        end
    end

    // CMD_ERR_INFO (read 0x1C): {addr[6:0], reason[3:0]} of the most recent
    // bit[4]/[5]/[6]/[7] event; cleared together with the sticky W1C (0x16).
    logic [6:0] err_info_addr;
    logic [3:0] err_info_reason;

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            sticky_err      <= 8'b0;
            spi_crc_err_d   <= 1'b0;
            boot_err_d      <= 1'b0;
            err_info_addr   <= 7'd0;
            err_info_reason <= ERR_NONE;
        end else begin
            spi_crc_err_d <= spi_crc_error;
            boot_err_d    <= boot_err_lvl;
            // Set sticky bits on rising edges / persistent conditions
            if (spi_crc_error && !spi_crc_err_d) sticky_err[0] <= 1'b1;
            if (i2s_err_r)                       sticky_err[1] <= 1'b1;
            if (!ddr4_calib_sync[1])             sticky_err[2] <= 1'b1;
            if (!clk_locked)                     sticky_err[3] <= 1'b1;
            if (spi_frame_error)                 sticky_err[4] <= 1'b1;
            if (wr_stb && wr_addr_invalid)       sticky_err[5] <= 1'b1;
            if ((wr_stb && wr_rejected) || load_err_evt)
                                                 sticky_err[6] <= 1'b1;
            if ((boot_err_lvl && !boot_err_d) || flash_cmd_err)
                                                 sticky_err[7] <= 1'b1;
            // Error info latch: most recent event wins
            if (flash_cmd_err) begin
                err_info_addr   <= `SPI_W_FLASH_CMD;
                err_info_reason <= ERR_FLASH_WDT;
            end else if (load_err_evt) begin
                err_info_addr   <= `SPI_W_FILTER_SELECT;
                err_info_reason <= (coef_load_err_code == 2'd3) ? `SPI_ERR_FILT_RATE :
                                   (coef_load_err_code == 2'd2) ? ERR_FILT_SIZE : ERR_FILT_NOTFOUND;
            end else if (wr_stb && (wr_addr_invalid || wr_rejected)) begin
                err_info_addr   <= wr_addr;
                err_info_reason <= wr_addr_invalid ? ERR_BAD_ADDR : wr_rej_reason;
            end else if (spi_frame_error) begin
                err_info_addr   <= 7'd0;
                err_info_reason <= ERR_FRAME_LEN;
            end
            // Clear on write to register 0x16 (write-1-to-clear;
            // moved from 0x11, which is FLASH_ADDR_HI)
            if (wr_stb && (wr_addr == `SPI_W_STICKY_W1C)) begin
                sticky_err      <= sticky_err & ~ctrl_bus_data[7:0];
                err_info_addr   <= 7'd0;
                err_info_reason <= ERR_NONE;
            end
        end
    end

    assign fpga_irq_n = (sticky_err != 8'b0) ? 1'b0 : 1'b1;

    // Level / output-select relays: pulse the automute controller on change.
    // The actual relays are driven by the sequencer in the dsp_clk domain.
    // Change detection compares the INCOMING bus data against the current
    // command register (cmd_* only updates on the same single-cycle valid,
    // so an old-vs-previous compare could never fire the pulse).
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            level_target      <= 3'b000;
            level_switch_req  <= 1'b0;
            outsel_target     <= 1'b0;
            outsel_switch_req <= 1'b0;
        end else begin
            level_switch_req <= wr_stb && (wr_addr == `SPI_W_LEVEL) &&
                                (ctrl_bus_data[2:0] != cmd_level);
            if (wr_stb && (wr_addr == `SPI_W_LEVEL))
                level_target <= ctrl_bus_data[2:0];
            outsel_switch_req <= wr_stb && (wr_addr == `SPI_W_OUTSEL) &&
                                 (ctrl_bus_data[0] != cmd_outsel);
            if (wr_stb && (wr_addr == `SPI_W_OUTSEL))
                outsel_target <= ctrl_bus_data[0];
        end
    end

    spi_slave u_spi_slave (
        .clk            (clk),
        .rst_n          (ext_rst_n),
        .spi_sclk       (spi_sclk),
        .spi_cs_n       (spi_cs_n),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .tx_data_in     (spi_tx_data),
        .data_out       (ctrl_bus_data),
        .data_valid     (ctrl_bus_valid),
        .crc_err_pulse  (spi_crc_error),
        .frame_err_pulse(spi_frame_error)
    );

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            // Fail-safe (2026-10-09): volume resets to ZERO. Relays unmute only on
            // an explicit UNMUTE write, and even then nothing leaves the XLR until
            // the AP has written VOLUME. (Was 0xFFFFFFFF = full scale at unmute.)
            sys_volume      <= 32'h0000_0000;
            cmd_level       <= 3'b000;
            cmd_outsel      <= 1'b0;
            base_rate_sel   <= 1'b0;
            stream_rate_request <= 0;
            stream_rate_toggle <= 0;
            stream_source_valid <= 0;
            i2s_rx_trim <= 5'd8;
            cmd_unmute      <= 1'b0;
            coef_bank_id    <= 4'h0;
            coef_load_start <= 1'b0;
            read_addr_reg   <= `SPI_W_NOP;
            filter_list_len  <= '0;
            filter_cur_index <= '0;
            filter_id        <= 16'd0;
            filter_load_req  <= 1'b0;
            video_mode       <= 1'b0;
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
        end else begin
            coef_load_start <= 1'b0;    // Default: deassert each cycle
            filter_load_req <= 1'b0;
            flash_cmd_trigger <= 1'b0;
            flash_buf_we      <= 1'b0;
            if (bench_busy || stream_busy || !stream_clocks_ready || stream_fault) begin
                cmd_unmute <= 0;
                stream_source_valid <= 0;
            end
            if (stream_busy || !stream_clocks_ready) dpd_enable <= 0;
            if (flash_buf_we) flash_buf_waddr <= flash_buf_waddr + 8'd1;
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin
                    // WRITE
                    case (ctrl_bus_data[30:24])
                        // 24-bit SPI word LEFT-justified into the 32-bit multiplier operand:
                        // 0xFFFFFF -> 0xFFFFFF00 = unity (the value every DSP sim / golden
                        // model used). Right-justified it capped at 0x00FFFFFF = -48 dB
                        // (bug found 2026-10-09).
                        `SPI_W_VOLUME: sys_volume    <= {ctrl_bus_data[23:0], 8'h00};
                        `SPI_W_LEVEL:  cmd_level     <= ctrl_bus_data[2:0]; // digital level cap, applied by the sequencer while muted
                        `SPI_W_RATE, `SPI_W_STREAM_RATE: if (!wr_rejected) begin
                            base_rate_sel <= ctrl_bus_data[0];
                            stream_rate_request <= ctrl_bus_data[2:0];
                            stream_rate_toggle <= ~stream_rate_toggle;
                            cmd_unmute <= 0;
                            stream_source_valid <= 0;
                            dpd_enable <= 0;
                        end
                        `SPI_W_STREAM_VALID: if (!wr_rejected) begin
                            stream_source_valid <= ctrl_bus_data[0];
                            if (!ctrl_bus_data[0]) cmd_unmute <= 0;
                        end
                        `SPI_W_I2S_RX_TRIM: if (!wr_rejected) i2s_rx_trim <= ctrl_bus_data[4:0];
                        `SPI_W_UNMUTE: if (!wr_rejected) cmd_unmute <= ctrl_bus_data[0];
                        `SPI_W_CELL_TEST_L, `SPI_W_CELL_TEST_R: if (!wr_rejected) begin
                            cell_test_cfg[cell_test_channel] <= ctrl_bus_data[7:0];
                            cell_test_req[cell_test_channel] <= ~cell_test_req[cell_test_channel];
                        end
                        `SPI_W_BANK_LOAD: if (!wr_rejected) begin
                            coef_bank_id    <= ctrl_bus_data[3:0];
                            coef_load_start <= 1'b1;
                        end
                        // 7'h06: RESERVED (was clk_source_sel; merged into 0x03 —
                        //        a separate clock register allowed the DSP family and
                        //        the physical mclk to disagree)
                        `SPI_W_OUTSEL: cmd_outsel    <= ctrl_bus_data[0]; // 0=line XLR, 1=headphone
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
                                filter_load_req  <= 1'b1;
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
                                filter_load_req  <= 1'b1;
                            end
                        end
                        `SPI_W_DAC_MODE: video_mode <= ctrl_bus_data[0];
                        `SPI_W_CAL_ADDR: begin // shadow write pointer
                            cal_wr_ptr      <= ctrl_bus_data[8:0];
                            cal_ptr_wrapped <= 1'b0;
                        end
                        `SPI_W_CAL_DATA: if (!stream_busy) begin // write word to shadow bank, auto-increment
                            cal_wr_data   <= ctrl_bus_data[23:0];
                            cal_wr_addr   <= cal_wr_ptr;   // stable for the CDC sample
                            cal_wr_toggle <= ~cal_wr_toggle;
                            cal_wr_ptr    <= cal_wr_ptr + 9'd1;
                            if (cal_wr_ptr == 9'd511)
                                cal_ptr_wrapped <= 1'b1; // overflow flag (sticky[6])
                        end
                        `SPI_W_CAL_COMMIT: if (!stream_busy) cal_commit_toggle <= cal_commit_toggle ^ ctrl_bus_data[0];
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
                            filter_load_req <= 1'b1;
                        end
                        default: ;
                    endcase
                end else begin
                    // READ
                    read_addr_reg <= ctrl_bus_data[30:24];
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
    logic [31:0] spi_tx_data_c;
    always_comb begin
        case (read_addr_reg)
            // 0x10: Magic ID
            `SPI_R_MAGIC: spi_tx_data_c = `SPI_MAGIC_ID;
            // 0x11: Sticky error register (readback; W1C via WRITE addr 0x16)
            `SPI_R_STICKY_ERR: spi_tx_data_c = {24'd0, sticky_err};
            // 0x12: Control state
            `SPI_R_CTRL_STATE: spi_tx_data_c = {26'd0, clk_source_sel, base_rate_sel, cmd_outsel, cmd_level};
            // 0x13: Coefficient loader status
            //       {bank_valid[12], mgr_busy[11], load_done[10], clk_src[9],
            //        base_rate[8], current_bank_id[7:4], coef_bank_id[3:0]}
            `SPI_R_COEF_STATUS: spi_tx_data_c = {19'd0, bank_valid_r, mgr_busy_r, coef_load_done_r,
                                    clk_source_sel, base_rate_sel, current_bank_id_r[3:0],
                                    coef_bank_id};
            // 0x14: Mute / relay status
            `SPI_R_MUTE_STATUS: spi_tx_data_c = {27'd0, i2s_err_r, switch_busy_r,
                                    hp_mute_r, line_mute_r, cmd_unmute};
            // 0x15: Clock / PLL status (+ DPD enable readback, bit 2)
            `SPI_R_CLK_STATUS: spi_tx_data_c = {29'd0, dpd_enable, ddr4_calib_sync[1], clk_locked};
            // 0x16: Filter list status {video_mode[11], list_len[10:5], cur_index[4:0]}
            `SPI_R_FILTER_LIST_STAT: spi_tx_data_c = {20'd0, video_mode, filter_list_len, filter_cur_index};
            // 0x17: Current + next-in-list filter IDs (next is informational only)
            `SPI_R_FILTER_IDS: spi_tx_data_c = {filter_next_id, filter_id};
            // 0x18: Cal store status
            `SPI_R_CAL_STATUS: spi_tx_data_c = {21'd0, cal_wr_ptr, cal_commit_pending, cal_active_bank};
            // 0x19: Cal active-bank readback (address set via 0x0F)
            `SPI_R_CAL_RDDATA: spi_tx_data_c = {8'd0, cal_rd_data};
            // 0x1A: Flash / boot-loader status
            `SPI_R_BOOT_STATUS: spi_tx_data_c = {18'd0, boot_src, boot_record_count, boot_axi_fail,
                                    boot_crc_fail, boot_ok, boot_done, flash_cmd_busy};
            // 0x1B: Flash read-buffer byte (pointer set via 0x14 [15:8];
            //       no auto-inc — set pointer, then read, per byte)
            `SPI_R_FLASH_RDDATA: spi_tx_data_c = {24'd0, flash_buf_rdata};
            // 0x1C: CMD_ERR_INFO — {addr[6:0], reason[3:0]} of the most
            //       recent sticky[4..7] event; cleared by the W1C (0x16)
            `SPI_R_CMD_ERR_INFO: spi_tx_data_c = {21'd0, err_info_addr, err_info_reason};
            `SPI_R_BENCH_STATUS: spi_tx_data_c = bench_status;
            `SPI_R_STREAM_STATUS: spi_tx_data_c = {15'd0, stream_audio_ready, i2s_rx_trim, stream_rate_request,
                stream_applied_rate, stream_fault, bank_valid_r, stream_source_valid,
                stream_clocks_ready, stream_busy};
            `SPI_R_CELL_TEST_L: spi_tx_data_c = {23'd0, cell_test_busy[0], cell_test_cfg[0]};
            `SPI_R_CELL_TEST_R: spi_tx_data_c = {23'd0, cell_test_busy[1], cell_test_cfg[1]};
            default: spi_tx_data_c = `SPI_READ_UNMAPPED;
        endcase
    end

    always_ff @(posedge clk)
        spi_tx_data <= spi_tx_data_c;

    // Single-register clock control: the LMK00304 mux select is the same
    // register as the DSP base-rate select. The top-level switch sequencer
    // mutes (via the automute rate_changed path) and holds the MMCM in reset
    // around the physical mux flip.
    assign clk_source_sel = base_rate_sel;

    assign spi_unmute = cmd_unmute;

    // Next list entry (wrap) — informational readback (0x17); no preload (TODO-16 ruling)
    always_comb begin
        if (filter_list_len == '0)
            filter_next_id = 16'd0;
        else
            filter_next_id = filter_list[filter_adv_index];
    end

endmodule
