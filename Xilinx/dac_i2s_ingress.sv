`timescale 1ns / 1ps

// I2S Ingress + Stereo CDC
// Receives I2S frames via i2s_rx, packs L+R into a 64-bit async FIFO,
// then presents both samples atomically to the dsp_clk domain.
// Both clocks here are dsp_clk (the FIFO provides elastic buffering
// between bursty i2s arrival and steady FIR consumption).

module dac_i2s_ingress (
    input  logic        dsp_clk,
    input  logic        sys_rst_n,

    // I2S physical interface
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // Audio outputs (dsp_clk domain)
    output logic [23:0] audio_l,        // Left channel, 24-bit MSB-justified
    output logic [23:0] audio_r,        // Right channel, 24-bit MSB-justified
    output logic        new_sample      // Pulse: new stereo pair available
);

    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [63:0] safe_audio_lr;
    logic        fifo_full, fifo_empty;

    i2s_rx #(.DATA_WIDTH(32)) u_i2s_rx (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .i2s_bclk   (i2s_bclk),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (raw_left_data),
        .right_data (raw_right_data),
        .data_valid (raw_data_valid)
    );

    // CDC-FIXED: i2s_rx clocked on dsp_clk; write clock = dsp_clk ensures the
    // 2.8 ns raw_data_valid pulse is reliably captured.
    async_fifo #(.DATA_WIDTH(64), .ADDR_WIDTH(4)) u_async_fifo (
        .w_clk   (dsp_clk),
        .w_rst_n (sys_rst_n),
        .w_en    (raw_data_valid & ~fifo_full),
        .w_data  ({raw_left_data, raw_right_data}),
        .w_full  (fifo_full),
        .r_clk   (dsp_clk),
        .r_rst_n (sys_rst_n),
        .r_en    (~fifo_empty),
        .r_data  (safe_audio_lr),
        .r_empty (fifo_empty)
    );

    assign audio_l    = safe_audio_lr[63:40]; // Top 24 bits of left word
    assign audio_r    = safe_audio_lr[31:8];  // Top 24 bits of right word
    assign new_sample = ~fifo_empty;

endmodule
