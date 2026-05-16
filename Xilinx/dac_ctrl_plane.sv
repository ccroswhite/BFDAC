`timescale 1ns / 1ps

// DAC Control Plane
// SPI slave + register file + relay driver.
// Clocked by clk_49m to break any combinatorial loop with audio path.

module dac_ctrl_plane (
    input  logic        clk_49m,
    input  logic        ext_rst_n,

    // SPI interface
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Hardware relays
    output logic        relay_gain_6v,
    output logic        relay_audio_out,

    // Status inputs (for SPI readback)
    input  logic        mgr_busy,
    input  logic        coef_load_done,
    input  logic [3:0]  current_bank_id,

    // Control outputs
    output logic [31:0] sys_volume,
    output logic        base_rate_sel,
    output logic        clk_source_sel,
    output logic [3:0]  coef_bank_id,
    output logic        coef_load_start   // Single-cycle pulse
);

    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;
    logic        spi_crc_error;
    logic        cmd_gain_6v;
    logic        cmd_unmute;

    // Re-register dsp_clk-domain status inputs on clk_49m before use.
    // Prevents CDC combinatorial paths into the SPI readback mux.
    logic        mgr_busy_r;
    logic        coef_load_done_r;
    logic [3:0]  current_bank_id_r;

    always_ff @(posedge clk_49m) begin
        mgr_busy_r        <= mgr_busy;
        coef_load_done_r  <= coef_load_done;
        current_bank_id_r <= current_bank_id;
    end

    spi_slave u_spi_slave (
        .clk            (clk_49m),
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

    always_ff @(posedge clk_49m) begin
        if (!ext_rst_n) begin
            sys_volume      <= 32'hFFFFFFFF;
            cmd_gain_6v     <= 1'b0;
            relay_gain_6v   <= 1'b0;
            base_rate_sel   <= 1'b0;
            clk_source_sel  <= 1'b0;
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
                        7'h02: cmd_gain_6v    <= ctrl_bus_data[0];
                        7'h03: base_rate_sel  <= ctrl_bus_data[0];
                        7'h04: cmd_unmute     <= ctrl_bus_data[0];
                        7'h05: begin
                            coef_bank_id    <= ctrl_bus_data[3:0];
                            coef_load_start <= 1'b1;
                        end
                        7'h06: clk_source_sel <= ctrl_bus_data[0];
                        default: ;
                    endcase
                    relay_gain_6v <= cmd_gain_6v;
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
            7'h10: spi_tx_data = 32'hDAC02026;
            7'h12: spi_tx_data = {28'd0, clk_source_sel, base_rate_sel, relay_gain_6v};
            7'h13: spi_tx_data = {8'd0, mgr_busy_r, 1'b0, coef_load_done_r,
                                  clk_source_sel, base_rate_sel, current_bank_id_r, coef_bank_id};
            default: spi_tx_data = 32'hDEADBEEF;
        endcase
    end

    assign relay_audio_out = 1'b1;

endmodule
