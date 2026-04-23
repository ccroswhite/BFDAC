`timescale 1ns / 1ps

module lvds_serial_tx (
    input  logic         bit_clk,
    input  logic         rst_n,
    
    // 256 bits per channel (4 rings x 64 resistors)
    input  logic [255:0] left_ring_data,
    input  logic [255:0] right_ring_data,
    input  logic         data_valid,
    
    // LVDS Physical Pins
    output logic         lvds_bclk_p,
    output logic         lvds_bclk_n,
    output logic         lvds_sync_p,
    output logic         lvds_sync_n,
    output logic         lvds_data_l_p,
    output logic         lvds_data_l_n,
    output logic         lvds_data_r_p,
    output logic         lvds_data_r_n
);

    // ==============================================================
    // 1. Shift Registers & State Logic
    // ==============================================================
    logic [255:0] shift_l = '0;
    logic [255:0] shift_r = '0;
    logic [7:0]   bit_counter = '0;
    logic         sync_pulse = 1'b0;

    always_ff @(posedge bit_clk) begin
        if (!rst_n) begin
            shift_l     <= '0;
            shift_r     <= '0;
            bit_counter <= '0;
            sync_pulse  <= 1'b0;
        end else if (data_valid) begin
            // Load the new 256-bit payloads
            shift_l     <= left_ring_data;
            shift_r     <= right_ring_data;
            bit_counter <= 8'd255;
            sync_pulse  <= 1'b1; // Fire SYNC to align LMK dividers and MAX10s
        end else if (bit_counter > 0) begin
            // Shift out MSB first
            shift_l     <= {shift_l[254:0], 1'b0};
            shift_r     <= {shift_r[254:0], 1'b0};
            bit_counter <= bit_counter - 1'b1;
            sync_pulse  <= 1'b0;
        end
    end

    // ==============================================================
    // 2. Hardware I/O Buffers (OBUFDS & ODDR)
    // ==============================================================
    
    // Forward the Bit Clock using a dedicated ODDR to ensure phase alignment
    logic bclk_fwd;
    ODDR #(
        .DDR_CLK_EDGE("OPPOSITE_EDGE"), 
        .INIT(1'b0), .SRTYPE("SYNC")
    ) u_oddr_bclk (
        .Q(bclk_fwd), .C(bit_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(~rst_n), .S(1'b0)
    );

    OBUFDS u_buf_clk   (.I(bclk_fwd),     .O(lvds_bclk_p),   .OB(lvds_bclk_n));
    OBUFDS u_buf_sync  (.I(sync_pulse),   .O(lvds_sync_p),   .OB(lvds_sync_n));
    OBUFDS u_buf_dat_l (.I(shift_l[255]), .O(lvds_data_l_p), .OB(lvds_data_l_n));
    OBUFDS u_buf_dat_r (.I(shift_r[255]), .O(lvds_data_r_p), .OB(lvds_data_r_n));

endmodule