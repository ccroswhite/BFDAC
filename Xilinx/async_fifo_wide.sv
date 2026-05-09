`timescale 1ns / 1ps

module async_fifo_wide #(
    parameter int DATA_WIDTH = 512,
    parameter int ADDR_WIDTH = 4 // 16 entries deep is plenty for an elastic buffer
)(
    // Write Domain (345 MHz DSP Core)
    input  logic                  w_clk,
    input  logic                  w_rst_n,
    input  logic                  w_en,
    input  logic [DATA_WIDTH-1:0] w_data,
    output logic                  w_full,

    // Read Domain (196.6 MHz LVDS Egress)
    input  logic                  r_clk,
    input  logic                  r_rst_n,
    input  logic                  r_en,
    output logic [DATA_WIDTH-1:0] r_data,
    output logic                  r_empty
);

    localparam int DEPTH = 1 << ADDR_WIDTH;

    // Force BRAM inference to clear Distributed RAM routing congestion
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers
    logic [ADDR_WIDTH:0] w_bin, w_bin_next;
    logic [ADDR_WIDTH:0] w_gray, w_gray_next;
    logic [ADDR_WIDTH:0] r_bin, r_bin_next;
    logic [ADDR_WIDTH:0] r_gray, r_gray_next;

    // Synchronizers
    logic [ADDR_WIDTH:0] wq1_r_gray, wq2_r_gray;
    logic [ADDR_WIDTH:0] rq1_w_gray, rq2_w_gray;

    // ------------------------------------------------------------------------
    // 1. Write Domain (345 MHz)
    // ------------------------------------------------------------------------
    assign w_bin_next  = w_bin + (w_en & ~w_full);
    assign w_gray_next = w_bin_next ^ (w_bin_next >> 1);

    always_ff @(posedge w_clk) begin
        if (!w_rst_n) begin
            w_bin  <= '0;
            w_gray <= '0;
            w_full <= 1'b0;
        end else begin
            w_bin  <= w_bin_next;
            w_gray <= w_gray_next;
            // Registered full flag (Drops Logic Levels to 0 for the output pin)
            w_full <= (w_gray_next == {~wq2_r_gray[ADDR_WIDTH:ADDR_WIDTH-1], wq2_r_gray[ADDR_WIDTH-2:0]});
        end
    end

    // Memory Write Port
    always_ff @(posedge w_clk) begin
        if (w_en && !w_full) begin
            mem[w_bin[ADDR_WIDTH-1:0]] <= w_data;
        end
    end

    // Synchronize r_gray into w_clk domain
    always_ff @(posedge w_clk) begin
        if (!w_rst_n) {wq2_r_gray, wq1_r_gray} <= '0;
        else          {wq2_r_gray, wq1_r_gray} <= {wq1_r_gray, r_gray};
    end

    // ------------------------------------------------------------------------
    // 2. Read Domain (196.6 MHz)
    // ------------------------------------------------------------------------
    assign r_bin_next  = r_bin + (r_en & ~r_empty);
    assign r_gray_next = r_bin_next ^ (r_bin_next >> 1);

    always_ff @(posedge r_clk) begin
        if (!r_rst_n) begin
            r_bin   <= '0;
            r_gray  <= '0;
            r_empty <= 1'b1;
        end else begin
            r_bin   <= r_bin_next;
            r_gray  <= r_gray_next;
            // Registered empty flag (Drops Logic Levels to 0 for the output pin)
            r_empty <= (r_gray_next == rq2_w_gray);
        end
    end

    // BRAM Compatible Synchronous Read with Look-Ahead
    // Using r_bin_next pre-fetches the data, acting as a First-Word Fall-Through (FWFT)
    always_ff @(posedge r_clk) begin
        r_data <= mem[r_bin_next[ADDR_WIDTH-1:0]];
    end

    // Synchronize w_gray into r_clk domain
    always_ff @(posedge r_clk) begin
        if (!r_rst_n) {rq2_w_gray, rq1_w_gray} <= '0;
        else          {rq2_w_gray, rq1_w_gray} <= {rq1_w_gray, w_gray};
    end

endmodule