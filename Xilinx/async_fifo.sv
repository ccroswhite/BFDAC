`timescale 1ns / 1ps

module async_fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 4   // Depth = 2^ADDR_WIDTH
)(
    // Write Domain
    input  logic                  w_clk,
    input  logic                  w_rst_n,
    input  logic                  w_en,
    input  logic [DATA_WIDTH-1:0] w_data,
    output logic                  w_full,

    // Read Domain
    input  logic                  r_clk,
    input  logic                  r_rst_n,
    input  logic                  r_en,
    output logic [DATA_WIDTH-1:0] r_data,
    output logic                  r_empty
);

    localparam int DEPTH = 1 << ADDR_WIDTH;

    // Dual-port memory array
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers - ADDR_WIDTH + 1 bits to distinguish full from empty
    logic [ADDR_WIDTH:0] w_bin, w_bin_next;
    logic [ADDR_WIDTH:0] w_gray, w_gray_next;
    
    logic [ADDR_WIDTH:0] r_bin, r_bin_next;
    logic [ADDR_WIDTH:0] r_gray, r_gray_next;

    // Synchronizers
    logic [ADDR_WIDTH:0] wq1_r_gray, wq2_r_gray; // r_gray synchronized to w_clk
    logic [ADDR_WIDTH:0] rq1_w_gray, rq2_w_gray; // w_gray synchronized to r_clk

    //---------------------------------------------------------
    // WRITE DOMAIN
    //---------------------------------------------------------
    // Next state logic for write pointers
    assign w_bin_next  = w_bin + (w_en & ~w_full);
    assign w_gray_next = w_bin_next ^ (w_bin_next >> 1); // Binary-to-Gray conversion

    always_ff @(posedge w_clk or negedge w_rst_n) begin
        if (!w_rst_n) begin
            w_bin  <= '0;
            w_gray <= '0;
            w_full <= 1'b0;
        end else begin
            w_bin  <= w_bin_next;
            w_gray <= w_gray_next;
            // w_full logic: High when synchronized r_gray equals w_gray_next with top 2 MSBs inverted
            w_full <= (w_gray_next == {~wq2_r_gray[ADDR_WIDTH:ADDR_WIDTH-1], wq2_r_gray[ADDR_WIDTH-2:0]});
        end
    end

    // Memory Write Port
    always_ff @(posedge w_clk) begin
        if (w_en && !w_full) begin
            mem[w_bin[ADDR_WIDTH-1:0]] <= w_data;
        end
    end

    // Synchronize r_gray into w_clk domain (2-stage synchronizer)
    always_ff @(posedge w_clk or negedge w_rst_n) begin
        if (!w_rst_n) begin
            wq1_r_gray <= '0;
            wq2_r_gray <= '0;
        end else begin
            wq1_r_gray <= r_gray;
            wq2_r_gray <= wq1_r_gray;
        end
    end

    //---------------------------------------------------------
    // READ DOMAIN
    //---------------------------------------------------------
    // Next state logic for read pointers
    assign r_bin_next  = r_bin + (r_en & ~r_empty);
    assign r_gray_next = r_bin_next ^ (r_bin_next >> 1); // Binary-to-Gray conversion

    always_ff @(posedge r_clk or negedge r_rst_n) begin
        if (!r_rst_n) begin
            r_bin   <= '0;
            r_gray  <= '0;
            r_empty <= 1'b1; // FIFO originates empty
        end else begin
            r_bin   <= r_bin_next;
            r_gray  <= r_gray_next;
            // r_empty logic: High when synchronized w_gray equals r_gray_next
            r_empty <= (r_gray_next == rq2_w_gray);
        end
    end

    // Memory Read Port - Unclocked combinatorial read (often maps to Distributed RAM)
    assign r_data = mem[r_bin[ADDR_WIDTH-1:0]];

    // Synchronize w_gray into r_clk domain (2-stage synchronizer)
    always_ff @(posedge r_clk or negedge r_rst_n) begin
        if (!r_rst_n) begin
            rq1_w_gray <= '0;
            rq2_w_gray <= '0;
        end else begin
            rq1_w_gray <= w_gray;
            rq2_w_gray <= rq1_w_gray;
        end
    end

endmodule
