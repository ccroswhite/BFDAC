`timescale 1ns / 1ps

module lvds_tx_serializer (
    input  logic        bit_clk,       // High-speed clock (e.g., 393.216 MHz)
    input  logic        frame_clk,     // Parallel load clock (e.g., 98.304 MHz)
    input  logic        rst_n,
    
    input  logic [63:0] data_in_64,    // The 64-bit resistor firing sequence
    
    // 9 Differential Pairs: [7:0] are Data, [8] is the Strobe Clock
    output logic [8:0]  lvds_tx_p,
    output logic [8:0]  lvds_tx_n
);

    // =========================================================================
    // 1. Internal Nets for Serialization
    // =========================================================================
    logic [8:0] serial_data_out; // Single-ended serial streams before LVDS buffers

    // =========================================================================
    // 2. Data Lanes [7:0]: 8:1 DDR Serializers
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : gen_data_lanes
            
            // Extract the specific 8-bit chunk for this LVDS lane
            // Lane 0: [7:0], Lane 1: [15:8], ..., Lane 7: [63:56]
            wire [7:0] lane_data = data_in_64[(i*8)+7 : (i*8)];

            OSERDESE2 #(
                .DATA_RATE_OQ      ("DDR"),     // Double Data Rate (transmits on rising & falling edges)
                .DATA_RATE_TQ      ("SDR"),     // Tristate rate (unused here)
                .DATA_WIDTH        (8),         // 8:1 Serialization ratio
                .TRISTATE_WIDTH    (1),
                .SERDES_MODE       ("MASTER"),
                .SRVAL_OQ          (1'b0),      // Reset value
                .SRVAL_TQ          (1'b0),
                .TBYTE_CTL         ("FALSE"),
                .TBYTE_SRC         ("FALSE")
            ) u_oserdes_data (
                .CLK     (bit_clk),             // High-speed serial shift clock
                .CLKDIV  (frame_clk),           // Slower parallel load clock
                .RST     (~rst_n),
                .OCE     (1'b1),                // Clock enable always high
                
                // Parallel data inputs (D1 is transmitted first, D8 last)
                .D1      (lane_data[0]),
                .D2      (lane_data[1]),
                .D3      (lane_data[2]),
                .D4      (lane_data[3]),
                .D5      (lane_data[4]),
                .D6      (lane_data[5]),
                .D7      (lane_data[6]),
                .D8      (lane_data[7]),
                
                .T1      (1'b0),                // Output always enabled (not tristated)
                .T2      (1'b0),
                .T3      (1'b0),
                .T4      (1'b0),
                .TCE     (1'b0),
                .SHIFTIN (1'b0),
                .OQ      (serial_data_out[i]),  // Serialized single-ended output
                .TQ      ()
            );

            // Convert the single-ended OSERDES output into a physical LVDS differential pair
            OBUFDS u_lvds_buf_data (
                .I  (serial_data_out[i]),
                .O  (lvds_tx_p[i]),
                .OB (lvds_tx_n[i])
            );
        end
    endgenerate

    // =========================================================================
    // 3. Strobe Clock Lane [8]: Source-Synchronous Forwarding
    // =========================================================================
    // To guarantee the clock arrives at the DIMM blades with the EXACT same 
    // routing delay and temperature variance as the data, we generate the clock 
    // using an identical OSERDES block, feeding it a constant training pattern.

    OSERDESE2 #(
        .DATA_RATE_OQ      ("DDR"),
        .DATA_RATE_TQ      ("SDR"),
        .DATA_WIDTH        (8),
        .TRISTATE_WIDTH    (1),
        .SERDES_MODE       ("MASTER"),
        .SRVAL_OQ          (1'b0),
        .SRVAL_TQ          (1'b0),
        .TBYTE_CTL         ("FALSE"),
        .TBYTE_SRC         ("FALSE")
    ) u_oserdes_strobe (
        .CLK     (bit_clk),
        .CLKDIV  (frame_clk),
        .RST     (~rst_n),
        .OCE     (1'b1),
        
        // Framing Pattern: 11110000 
        // This generates a square wave that perfectly matches the frame_clk, 
        // but physically aligns perfectly with the data edges.
        .D1      (1'b1),
        .D2      (1'b1),
        .D3      (1'b1),
        .D4      (1'b1),
        .D5      (1'b0),
        .D6      (1'b0),
        .D7      (1'b0),
        .D8      (1'b0),
        
        .T1      (1'b0),
        .T2      (1'b0),
        .T3      (1'b0),
        .T4      (1'b0),
        .TCE     (1'b0),
        .SHIFTIN (1'b0),
        .OQ      (serial_data_out[8]),
        .TQ      ()
    );

    // Convert the single-ended Strobe into physical LVDS
    OBUFDS u_lvds_buf_strobe (
        .I  (serial_data_out[8]),
        .O  (lvds_tx_p[8]),
        .OB (lvds_tx_n[8])
    );

endmodule