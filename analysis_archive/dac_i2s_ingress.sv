`timescale 1ns / 1ps

// =============================================================================
// dac_i2s_ingress  --  I2S Ingress + BCLK -> dsp_clk domain crossing
//
// i2s_rx is now clocked on i2s_bclk directly so that BCLK rates up to
// 49.152 MHz (768 kHz stereo 32-bit) are correctly captured.
//
// Domain crossing strategy:
//   - A toggle synchronizer promotes the BCLK-domain data_valid pulse into
//     the dsp_clk domain.  left_data/right_data are stable for a full LRCLK
//     half-period (>= 1 us at 768 kHz) so the single toggle-sync edge is
//     safely within the setup window.
//   - A 64-bit async FIFO then provides elastic buffering between bursty I2S
//     arrival and steady FIR consumption.
//   - The i2s_err watchdog runs entirely in dsp_clk domain: it counts dsp_clk
//     cycles since the last toggle_sync edge and asserts if the gap exceeds
//     the maximum expected LRCLK period (~2 us at 768 kHz, use 4 us timeout).
// =============================================================================
module dac_i2s_ingress (
    input  logic        dsp_clk,
    input  logic        sys_rst_n,   // dsp_clk domain reset

    // I2S physical interface
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // Audio outputs (dsp_clk domain)
    output logic [23:0] audio_l,    // Left channel, 24-bit MSB-justified
    output logic [23:0] audio_r,    // Right channel, 24-bit MSB-justified
    output logic        new_sample, // Pulse: new stereo pair available
    output logic        i2s_err     // BCLK idle timeout / stuck I2S interface
);

    // -------------------------------------------------------------------------
    // BCLK-domain reset synchronizer (2-stage, async assert / sync deassert)
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [1:0] bclk_rst_sync;
    logic bclk_rst_n;

    always_ff @(posedge i2s_bclk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            bclk_rst_sync <= 2'b00;
        else
            bclk_rst_sync <= {bclk_rst_sync[0], 1'b1};
    end
    assign bclk_rst_n = bclk_rst_sync[1];

    // -------------------------------------------------------------------------
    // i2s_rx  (BCLK domain)
    // -------------------------------------------------------------------------
    logic [31:0] bclk_left, bclk_right;
    logic        bclk_valid;

    i2s_rx #(.DATA_WIDTH(32)) u_i2s_rx (
        .clk        (i2s_bclk),
        .rst_n      (bclk_rst_n),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (bclk_left),
        .right_data (bclk_right),
        .data_valid (bclk_valid)
    );

    // -------------------------------------------------------------------------
    // Toggle synchronizer: BCLK data_valid -> dsp_clk domain
    // -------------------------------------------------------------------------
    logic                        bclk_toggle;
    (* ASYNC_REG = "TRUE" *) logic [2:0] dsp_toggle_sync;
    logic                        dsp_toggle_prev;
    logic                        dsp_valid_pulse; // one dsp_clk cycle

    always_ff @(posedge i2s_bclk or negedge bclk_rst_n) begin
        if (!bclk_rst_n)
            bclk_toggle <= 1'b0;
        else if (bclk_valid)
            bclk_toggle <= ~bclk_toggle;
    end

    always_ff @(posedge dsp_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            dsp_toggle_sync <= 3'b000;
            dsp_toggle_prev <= 1'b0;
        end else begin
            dsp_toggle_sync <= {dsp_toggle_sync[1:0], bclk_toggle};
            dsp_toggle_prev <= dsp_toggle_sync[2];
        end
    end
    assign dsp_valid_pulse = dsp_toggle_sync[2] ^ dsp_toggle_prev;

    // -------------------------------------------------------------------------
    // Output registers: latch audio on dsp_valid_pulse; pulse new_sample the
    // following cycle so downstream logic sees stable audio_l/r on new_sample.
    // bclk_left/right are stable for >= 1 LRCLK half-period after bclk_valid,
    // which is >> the 3-cycle toggle-sync latency, so direct capture is safe.
    // -------------------------------------------------------------------------
    logic dsp_valid_d1;

    always_ff @(posedge dsp_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            audio_l      <= '0;
            audio_r      <= '0;
            dsp_valid_d1 <= 1'b0;
        end else begin
            dsp_valid_d1 <= dsp_valid_pulse;
            if (dsp_valid_pulse) begin
                audio_l <= bclk_left[31:8];
                audio_r <= bclk_right[31:8];
            end
        end
    end

    assign new_sample = dsp_valid_d1;

    // -------------------------------------------------------------------------
    // i2s_err watchdog (dsp_clk domain)
    // Timeout = 4 us @ 90 MHz = 360 cycles (round up to 512 = 9-bit counter)
    // Covers worst-case 768/705.6 kHz LRCLK period of ~1.3/1.4 us with 3x margin.
    // -------------------------------------------------------------------------
    localparam int WATCHDOG_TIMEOUT = 512;
    logic [9:0] wd_cnt;

    always_ff @(posedge dsp_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            wd_cnt  <= '0;
            i2s_err <= 1'b0;
        end else if (dsp_valid_pulse) begin
            wd_cnt  <= '0;
            i2s_err <= 1'b0;
        end else if (wd_cnt < WATCHDOG_TIMEOUT) begin
            wd_cnt <= wd_cnt + 1'b1;
        end else begin
            i2s_err <= 1'b1;
        end
    end

endmodule
