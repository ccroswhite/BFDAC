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
    // 2. Hardware I/O Buffers (OBUFDS & ODDRE1)
    //
    //   Source-synchronous output: forwarded clock + data must leave the
    //   FPGA with matched delay. All four outputs (bclk, data_l, data_r,
    //   sync) go through ODDRE1 -> OBUFDS so they share identical Tco /
    //   OBUFDS / OLOGIC-net characteristics. For data/sync the ODDRE1
    //   is used as a single-rate flop (D1 = D2 = data); for bclk it is
    //   used as an INVERTED clock forwarder (D1 = 0, D2 = 1) to give a
    //   center-aligned forwarded clock relative to the data eye.
    //
    //   ODDRE1 vs the 7-series ODDR: no CE/S pins, R renamed to SR,
    //   and DDR_CLK_EDGE removed (UltraScale+ ODDRE1 is implicitly
    //   OPPOSITE_EDGE / SAME_EDGE-irrelevant since both data inputs are
    //   captured on the same internal mux clock).
    // ==============================================================

    // Forward the Bit Clock using a dedicated ODDRE1.
    //
    //   IMPORTANT: D1=0, D2=1 (inverted relative to a "normal" clock forwarder).
    //   This produces a forwarded clock whose RISING edge falls at the FALLING
    //   edge of bit_clk -- i.e. at the CENTER of each data bit window. The
    //   MAX10 receiver thus samples data in the middle of the eye and gets
    //   maximum setup and hold margin (~2 ns on each side at this 196 MHz
    //   bit rate), regardless of which clock-recovery mode it uses.
    //
    //   The matching XDC change is `create_generated_clock ... -invert` on
    //   the lvds_bclk_p port, so Vivado's timing analysis correctly accounts
    //   for the half-period phase relationship.
    logic bclk_fwd;
    ODDRE1 #(
        .SRVAL(1'b0),
        .IS_C_INVERTED(1'b0),
        .IS_D1_INVERTED(1'b0),
        .IS_D2_INVERTED(1'b0)
    ) u_oddr_bclk (
        .Q  (bclk_fwd),
        .C  (bit_clk),
        .D1 (1'b0),
        .D2 (1'b1),             // Inverted: center-aligned forwarded clock
        .SR (~rst_n)
    );

    // Matched-delay data and sync forwarding.
    logic data_l_oddr, data_r_oddr, sync_oddr;

    ODDRE1 #(
        .SRVAL(1'b0),
        .IS_C_INVERTED(1'b0),
        .IS_D1_INVERTED(1'b0),
        .IS_D2_INVERTED(1'b0)
    ) u_oddr_data_l (
        .Q  (data_l_oddr),
        .C  (bit_clk),
        .D1 (shift_l[255]),
        .D2 (shift_l[255]),
        .SR (~rst_n)
    );

    ODDRE1 #(
        .SRVAL(1'b0),
        .IS_C_INVERTED(1'b0),
        .IS_D1_INVERTED(1'b0),
        .IS_D2_INVERTED(1'b0)
    ) u_oddr_data_r (
        .Q  (data_r_oddr),
        .C  (bit_clk),
        .D1 (shift_r[255]),
        .D2 (shift_r[255]),
        .SR (~rst_n)
    );

    ODDRE1 #(
        .SRVAL(1'b0),
        .IS_C_INVERTED(1'b0),
        .IS_D1_INVERTED(1'b0),
        .IS_D2_INVERTED(1'b0)
    ) u_oddr_sync (
        .Q  (sync_oddr),
        .C  (bit_clk),
        .D1 (sync_pulse),
        .D2 (sync_pulse),
        .SR (~rst_n)
    );

    OBUFDS u_buf_clk   (.I(bclk_fwd),    .O(lvds_bclk_p),   .OB(lvds_bclk_n));
    OBUFDS u_buf_sync  (.I(sync_oddr),   .O(lvds_sync_p),   .OB(lvds_sync_n));
    OBUFDS u_buf_dat_l (.I(data_l_oddr), .O(lvds_data_l_p), .OB(lvds_data_l_n));
    OBUFDS u_buf_dat_r (.I(data_r_oddr), .O(lvds_data_r_p), .OB(lvds_data_r_n));

endmodule