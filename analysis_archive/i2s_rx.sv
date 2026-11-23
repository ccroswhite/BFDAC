`timescale 1ns / 1ps

// =============================================================================
// i2s_rx  --  I2S receiver clocked on i2s_bclk
//
// Clocking on BCLK is required to support bit clocks up to 49.152 MHz
// (768 kHz stereo 32-bit).  Oversampling from a system clock would require
// >2× margin and is not achievable at those rates.
//
// The caller is responsible for:
//   - Crossing data_valid / left_data / right_data into the destination clock
//     domain (async FIFO, Gray-code pointer pair, etc.).
//   - Generating the i2s_err watchdog from the system-clock domain by
//     monitoring whether new_sample activity has stalled.
// =============================================================================
module i2s_rx #(
    parameter int DATA_WIDTH = 32 // Bit depth per channel (typically 32)
)(
    // Clock / reset -- MUST be driven by i2s_bclk and a BCLK-domain reset
    input  logic                  clk,        // Connect to i2s_bclk
    input  logic                  rst_n,      // Active-low reset (BCLK domain)

    // I2S Interface (registered directly on posedge clk = posedge BCLK)
    input  logic                  i2s_lrclk, // Word Select  (Low=Left, High=Right)
    input  logic                  i2s_data,  // Serial audio data (MSB first)

    // Output (BCLK domain -- cross to system domain in caller)
    output logic [DATA_WIDTH-1:0] left_data,  // Left channel word
    output logic [DATA_WIDTH-1:0] right_data, // Right channel word
    output logic                  data_valid  // One-cycle pulse per stereo frame
);

    logic                  lrclk_prev;
    logic [DATA_WIDTH-1:0] shift_reg;
    logic [7:0]            bit_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lrclk_prev <= 1'b0;
            shift_reg  <= '0;
            bit_cnt    <= '0;
            left_data  <= '0;
            right_data <= '0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;
            lrclk_prev <= i2s_lrclk;

            if (i2s_lrclk != lrclk_prev) begin
                // LRCLK edge: latch completed word, restart bit counter
                if (bit_cnt == 8'd1) begin
                    // Last bit arrives on this same edge
                    if (lrclk_prev == 1'b0) begin
                        left_data <= {shift_reg[DATA_WIDTH-2:0], i2s_data};
                    end else begin
                        right_data <= {shift_reg[DATA_WIDTH-2:0], i2s_data};
                        data_valid <= 1'b1;
                    end
                end else begin
                    if (lrclk_prev == 1'b0) begin
                        left_data <= shift_reg;
                    end else begin
                        right_data <= shift_reg;
                        data_valid <= 1'b1;
                    end
                end
                bit_cnt <= DATA_WIDTH[7:0];
            end else begin
                // Shift in data bit (MSB first)
                if (bit_cnt > 0) begin
                    shift_reg <= {shift_reg[DATA_WIDTH-2:0], i2s_data};
                    bit_cnt   <= bit_cnt - 8'd1;
                end
            end
        end
    end

endmodule
