`timescale 1ns / 1ps

module lvds_blade_tx (
    input  logic        bit_clk,    // 45.1584 MHz (from MMCM)
    input  logic        rst_n,
    
    // Payload from the DEM Mapper (Crosses from 90MHz to 45MHz natively)
    input  logic [63:0] data_in_64, 
    input  logic        data_valid, // 705.6 kHz pulse
    
    // 8 Blades x 3 Pairs = 24 Differential Pairs
    output logic [7:0]  lvds_data_p,  output logic [7:0]  lvds_data_n,
    output logic [7:0]  lvds_clk_p,   output logic [7:0]  lvds_clk_n,
    output logic [7:0]  lvds_frame_p, output logic [7:0]  lvds_frame_n
);

    // =========================================================================
    // 1. Shift Register & Framing Logic
    // =========================================================================
    logic [63:0] shift_reg;
    logic [5:0]  bit_counter;
    logic        serial_data_out;
    logic        frame_pulse_out;

    always_ff @(posedge bit_clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg       <= '0;
            bit_counter     <= '0;
            serial_data_out <= 1'b0;
            frame_pulse_out <= 1'b0;
        end else begin
            if (data_valid) begin
                // Load the new 64-bit payload
                shift_reg       <= data_in_64;
                bit_counter     <= '0;
                serial_data_out <= data_in_64[63]; // Transmit MSB first
                frame_pulse_out <= 1'b0;
            end else begin
                // Shift the register left
                shift_reg       <= {shift_reg[62:0], 1'b0};
                bit_counter     <= bit_counter + 6'd1;
                serial_data_out <= shift_reg[62]; 
                
                // Fire the global Latch Pulse on the exact cycle the 64th bit arrives
                if (bit_counter == 6'd62) frame_pulse_out <= 1'b1;
                else                      frame_pulse_out <= 1'b0;
            end
        end
    end

    // =========================================================================
    // 2. Physical LVDS Buffer Fanout (8 Blades)
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : gen_blade_outputs
            
            // Broadcast Data
            OBUFDS u_buf_data (
                .I  (serial_data_out),
                .O  (lvds_data_p[i]),
                .OB (lvds_data_n[i])
            );

            // -----------------------------------------------------------
            // Hardware Clock Forwarding (The Golden Rule)
            // Each output pin gets its own dedicated ODDR block physically 
            // located in the I/O ring to ensure perfect clock mirroring.
            // -----------------------------------------------------------
            logic local_forwarded_clk;
            
            ODDR #(
                .DDR_CLK_EDGE ("OPPOSITE_EDGE"), 
                .INIT         (1'b0),
                .SRTYPE       ("SYNC")
            ) u_clk_forwarder (
                .Q  (local_forwarded_clk),
                .C  (bit_clk),
                .CE (1'b1),
                .D1 (1'b1), // Drives High on rising edge
                .D2 (1'b0), // Drives Low on falling edge
                .R  (1'b0),
                .S  (1'b0)
            );

            // Broadcast Continuous Clock
            OBUFDS u_buf_clk (
                .I  (local_forwarded_clk),
                .O  (lvds_clk_p[i]),
                .OB (lvds_clk_n[i])
            );

            // Broadcast 705.6 kHz Frame/Latch Pulse
            OBUFDS u_buf_frame (
                .I  (frame_pulse_out),
                .O  (lvds_frame_p[i]),
                .OB (lvds_frame_n[i])
            );
            
        end
    endgenerate

endmodule