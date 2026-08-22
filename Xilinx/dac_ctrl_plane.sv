`timescale 1ns / 1ps

// DAC Control Plane
// SPI slave + register file.
// Clocked by the board-specific system clock; runs independently of the audio path.

module dac_ctrl_plane (
    input  logic        clk,        // Control-plane clock (200 MHz on VU13P)
    input  logic        ext_rst_n,

    // SPI interface
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Relay control (to automute controller, Fig. 4d set)
    output logic        level_switch_req,   // Single-cycle pulse
    output logic [1:0]  level_target,       // 00 = 2 Vrms, 01 = 4 Vrms, 10 = 6 Vrms
    output logic        outsel_switch_req,  // Single-cycle pulse
    output logic        outsel_target,      // 0 = line XLR, 1 = headphone

    // Status inputs (for SPI readback)
    input  logic        mgr_busy,
    input  logic        coef_load_done,
    input  logic [3:0]  current_bank_id,
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
    input  logic        cal_commit_pending
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
    logic [1:0]  cmd_level;
    logic        cmd_outsel;
    logic        cmd_unmute;

    // Filter toggle list storage
    logic [15:0] filter_list [0:15];
    logic [4:0]  filter_list_len;
    logic [3:0]  filter_cur_index;

    // Re-register dsp_clk-domain status inputs on clk_49m before use.
    // Prevents CDC combinatorial paths into the SPI readback mux.
    logic        mgr_busy_r;
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
    logic [3:0] sticky_err;
    logic       spi_crc_err_d;
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            sticky_err    <= 4'b0;
            spi_crc_err_d <= 1'b0;
        end else begin
            spi_crc_err_d <= spi_crc_error;
            // Set sticky bits on rising edges / persistent conditions
            if (spi_crc_error && !spi_crc_err_d) sticky_err[0] <= 1'b1;
            if (i2s_err_r)                       sticky_err[1] <= 1'b1;
            if (!ddr4_calib_sync[1])             sticky_err[2] <= 1'b1;
            if (!clk_locked)                     sticky_err[3] <= 1'b1;
            // Clear on write to register 0x11 (write-1-to-clear)
            if (ctrl_bus_valid &&
                (ctrl_bus_data[31] == 1'b0) &&
                (ctrl_bus_data[30:24] == 7'h11))
                sticky_err <= sticky_err & ~ctrl_bus_data[3:0];
        end
    end

    assign fpga_irq_n = (sticky_err != 4'b0) ? 1'b0 : 1'b1;

    // Level / output-select relays: pulse the automute controller on change.
    // The actual relays are driven by the sequencer in the dsp_clk domain.
    // Change detection compares the INCOMING bus data against the current
    // command register (cmd_* only updates on the same single-cycle valid,
    // so an old-vs-previous compare could never fire the pulse).
    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            level_target      <= 2'b00;
            level_switch_req  <= 1'b0;
            outsel_target     <= 1'b0;
            outsel_switch_req <= 1'b0;
        end else begin
            level_switch_req <= ctrl_bus_valid &&
                                (ctrl_bus_data[31] == 1'b0) &&
                                (ctrl_bus_data[30:24] == 7'h02) &&
                                (ctrl_bus_data[1:0] != cmd_level);
            if (ctrl_bus_valid &&
                (ctrl_bus_data[31] == 1'b0) &&
                (ctrl_bus_data[30:24] == 7'h02))
                level_target <= ctrl_bus_data[1:0];
            outsel_switch_req <= ctrl_bus_valid &&
                                 (ctrl_bus_data[31] == 1'b0) &&
                                 (ctrl_bus_data[30:24] == 7'h07) &&
                                 (ctrl_bus_data[0] != cmd_outsel);
            if (ctrl_bus_valid &&
                (ctrl_bus_data[31] == 1'b0) &&
                (ctrl_bus_data[30:24] == 7'h07))
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
        .crc_err_pulse  (spi_crc_error)
    );

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            sys_volume      <= 32'hFFFFFFFF;
            cmd_level       <= 2'b00;
            cmd_outsel      <= 1'b0;
            base_rate_sel   <= 1'b0;
            cmd_unmute      <= 1'b0;
            coef_bank_id    <= 4'h0;
            coef_load_start <= 1'b0;
            read_addr_reg   <= 7'h00;
            filter_list_len  <= 5'd0;
            filter_cur_index <= 4'd0;
            filter_id        <= 16'd0;
            filter_load_req  <= 1'b0;
            video_mode       <= 1'b0;
            cal_wr_toggle     <= 1'b0;
            cal_wr_ptr        <= 9'd0;
            cal_wr_addr       <= 9'd0;
            cal_wr_data       <= 24'd0;
            cal_commit_toggle <= 1'b0;
            cal_rd_addr       <= 9'd0;
        end else begin
            coef_load_start <= 1'b0;    // Default: deassert each cycle
            filter_load_req <= 1'b0;
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin
                    // WRITE
                    case (ctrl_bus_data[30:24])
                        7'h01: sys_volume     <= {8'h00, ctrl_bus_data[23:0]};
                        7'h02: cmd_level      <= ctrl_bus_data[1:0]; // level relays via sequencer
                        7'h03: base_rate_sel  <= ctrl_bus_data[0]; // rate family: switches DSP
                                                                   // AND the OCXO mux (see alias)
                        7'h04: cmd_unmute     <= ctrl_bus_data[0];
                        7'h05: begin
                            coef_bank_id    <= ctrl_bus_data[3:0];
                            coef_load_start <= 1'b1;
                        end
                        // 7'h06: RESERVED (was clk_source_sel; merged into 0x03 —
                        //        a separate clock register allowed the DSP family and
                        //        the physical mclk to disagree)
                        7'h07: cmd_outsel     <= ctrl_bus_data[0]; // 0=line XLR, 1=headphone
                        7'h08: begin // FILTER_LIST_CTRL: [0]=clear
                            if (ctrl_bus_data[0]) begin
                                filter_list_len  <= 5'd0;
                                filter_cur_index <= 4'd0;
                            end
                        end
                        7'h09: begin // FILTER_LIST_APPEND: [15:0]=filter_id
                            if (filter_list_len < 5'd16) begin
                                filter_list[filter_list_len[3:0]] <= ctrl_bus_data[15:0];
                                filter_list_len <= filter_list_len + 5'd1;
                            end
                        end
                        7'h0A: begin // FILTER_SELECT: [16]=advance, [3:0]=index
                            if (filter_list_len != 5'd0) begin
                                logic [3:0] new_index;
                                if (ctrl_bus_data[16]) begin
                                    // Advance with wrap (customer toggle action)
                                    new_index = (filter_cur_index == filter_list_len[3:0] - 4'd1 ||
                                                 filter_list_len == 5'd16 && filter_cur_index == 4'd15)
                                                ? 4'd0 : filter_cur_index + 4'd1;
                                end else begin
                                    // Explicit index (clamped to list)
                                    new_index = (ctrl_bus_data[3:0] < filter_list_len[3:0] ||
                                                 filter_list_len == 5'd16)
                                                ? ctrl_bus_data[3:0] : 4'd0;
                                end
                                filter_cur_index <= new_index;
                                filter_id        <= filter_list[new_index];
                                filter_load_req  <= 1'b1;
                            end
                        end
                        7'h0B: video_mode <= ctrl_bus_data[0]; // DAC_MODE
                        7'h0C: cal_wr_ptr <= ctrl_bus_data[8:0]; // CAL_ADDR: shadow write pointer
                        7'h0D: begin // CAL_DATA: write word to shadow bank, auto-increment
                            cal_wr_data   <= ctrl_bus_data[23:0];
                            cal_wr_addr   <= cal_wr_ptr;   // stable for the CDC sample
                            cal_wr_toggle <= ~cal_wr_toggle;
                            cal_wr_ptr    <= cal_wr_ptr + 9'd1;
                        end
                        7'h0E: cal_commit_toggle <= cal_commit_toggle ^ ctrl_bus_data[0]; // CAL_COMMIT
                        7'h0F: cal_rd_addr <= ctrl_bus_data[8:0]; // CAL_RDADDR (active-bank readback)
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
            7'h10: spi_tx_data_c = 32'hDAC02026;
            // 0x11: Sticky error register (write-1-to-clear)
            7'h11: spi_tx_data_c = {28'd0, sticky_err};
            // 0x12: Control state
            7'h12: spi_tx_data_c = {27'd0, clk_source_sel, base_rate_sel, cmd_outsel, cmd_level};
            // 0x13: Coefficient loader status
            7'h13: spi_tx_data_c = {8'd0, mgr_busy_r, coef_load_done_r, clk_source_sel,
                                    base_rate_sel, current_bank_id_r, coef_bank_id};
            // 0x14: Mute / relay status
            7'h14: spi_tx_data_c = {27'd0, i2s_err_r, switch_busy_r,
                                    hp_mute_r, line_mute_r, cmd_unmute};
            // 0x15: Clock / PLL status
            7'h15: spi_tx_data_c = {30'd0, ddr4_calib_sync[1], clk_locked};
            // 0x16: Filter list status
            7'h16: spi_tx_data_c = {22'd0, video_mode, filter_list_len, filter_cur_index};
            // 0x17: Current + next (preload) filter IDs
            7'h17: spi_tx_data_c = {filter_next_id, filter_id};
            // 0x18: Cal store status
            7'h18: spi_tx_data_c = {21'd0, cal_wr_ptr, cal_commit_pending, cal_active_bank};
            // 0x19: Cal active-bank readback (address set via 0x0F)
            7'h19: spi_tx_data_c = {8'd0, cal_rd_data};
            default: spi_tx_data_c = 32'hDEADBEEF;
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

    // Next list entry (wrap) — the bank manager's gapless-toggle preload target
    always_comb begin
        logic [3:0] nxt;
        if (filter_list_len == 5'd0) begin
            filter_next_id = 16'd0;
        end else begin
            nxt = (filter_cur_index == filter_list_len[3:0] - 4'd1 ||
                   filter_list_len == 5'd16 && filter_cur_index == 4'd15)
                  ? 4'd0 : filter_cur_index + 4'd1;
            filter_next_id = filter_list[nxt];
        end
    end

endmodule
