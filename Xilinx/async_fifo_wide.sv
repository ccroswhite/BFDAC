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

    logic [DATA_WIDTH-1:0] mem [(1<<ADDR_WIDTH)-1:0];
    logic [ADDR_WIDTH:0]   w_ptr = '0, w_ptr_gray = '0, w_ptr_gray_sync1 = '0, w_ptr_gray_sync2 = '0;
    logic [ADDR_WIDTH:0]   r_ptr = '0, r_ptr_gray = '0, r_ptr_gray_sync1 = '0, r_ptr_gray_sync2 = '0;

    // --- Write Domain ---
    always_ff @(posedge w_clk) begin
        if (!w_rst_n) begin
            w_ptr <= '0; w_ptr_gray <= '0;
        end else if (w_en && !w_full) begin
            mem[w_ptr[ADDR_WIDTH-1:0]] <= w_data;
            w_ptr <= w_ptr + 1'b1;
            w_ptr_gray <= (w_ptr + 1'b1) ^ ((w_ptr + 1'b1) >> 1);
        end
    end

    always_ff @(posedge w_clk) begin
        if (!w_rst_n) {r_ptr_gray_sync2, r_ptr_gray_sync1} <= '0;
        else          {r_ptr_gray_sync2, r_ptr_gray_sync1} <= {r_ptr_gray_sync1, r_ptr_gray};
    end
    assign w_full = (w_ptr_gray == {~r_ptr_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1], r_ptr_gray_sync2[ADDR_WIDTH-2:0]});

    // --- Read Domain ---
    always_ff @(posedge r_clk) begin
        if (!r_rst_n) begin
            r_ptr <= '0; r_ptr_gray <= '0;
        end else if (r_en && !r_empty) begin
            r_ptr <= r_ptr + 1'b1;
            r_ptr_gray <= (r_ptr + 1'b1) ^ ((r_ptr + 1'b1) >> 1);
        end
    end

    assign r_data = mem[r_ptr[ADDR_WIDTH-1:0]];

    always_ff @(posedge r_clk) begin
        if (!r_rst_n) {w_ptr_gray_sync2, w_ptr_gray_sync1} <= '0;
        else          {w_ptr_gray_sync2, w_ptr_gray_sync1} <= {w_ptr_gray_sync1, w_ptr_gray};
    end
    assign r_empty = (r_ptr_gray == w_ptr_gray_sync2);

endmodule