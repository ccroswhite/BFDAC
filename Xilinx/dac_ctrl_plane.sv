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
    output logic        spi_unmute,       // Raw clk_49m-domain unmute command (CDC in top)
    output logic        fpga_irq_n        // Active-low IRQ to ARM (sticky errors)
);

    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;
    logic        spi_crc_error;
    logic [1:0]  cmd_level;
    logic        cmd_outsel;
    logic        cmd_unmute;

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

    always_ff @(posedge clk) begin
        if (!ext_rst_n) begin
            i2s_err_sync     <= '0;
            switch_busy_sync <= '0;
            line_mute_sync   <= '0;
            hp_mute_sync     <= '0;
        end else begin
            i2s_err_sync     <= {i2s_err_sync[0], i2s_err};
            switch_busy_sync <= {switch_busy_sync[0], switch_busy};
            line_mute_sync   <= {line_mute_sync[0], line_mute_status};
            hp_mute_sync     <= {hp_mute_sync[0], hp_mute_status};
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
            if (!ddr4_init_calib_complete)       sticky_err[2] <= 1'b1;
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
        end else begin
            coef_load_start <= 1'b0;    // Default: deassert each cycle
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
                        default: ;
                    endcase
                end else begin
                    // READ
                    read_addr_reg <= ctrl_bus_data[30:24];
                end
            end
        end
    end

    // SPI readback MUX
    always_comb begin
        case (read_addr_reg)
            // 0x10: Magic ID
            7'h10: spi_tx_data = 32'hDAC02026;
            // 0x11: Sticky error register (write-1-to-clear)
            7'h11: spi_tx_data = {28'd0, sticky_err};
            // 0x12: Control state
            7'h12: spi_tx_data = {27'd0, clk_source_sel, base_rate_sel, cmd_outsel, cmd_level};
            // 0x13: Coefficient loader status
            7'h13: spi_tx_data = {8'd0, mgr_busy_r, coef_load_done_r, clk_source_sel,
                                  base_rate_sel, current_bank_id_r, coef_bank_id};
            // 0x14: Mute / relay status
            7'h14: spi_tx_data = {27'd0, i2s_err_r, switch_busy_r,
                                  hp_mute_r, line_mute_r, cmd_unmute};
            // 0x15: Clock / PLL status
            7'h15: spi_tx_data = {30'd0, ddr4_init_calib_complete, clk_locked};
            default: spi_tx_data = 32'hDEADBEEF;
        endcase
    end

    // Single-register clock control: the LMK00304 mux select is the same
    // register as the DSP base-rate select. The top-level switch sequencer
    // mutes (via the automute rate_changed path) and holds the MMCM in reset
    // around the physical mux flip.
    assign clk_source_sel = base_rate_sel;

    assign spi_unmute = cmd_unmute;

endmodule
