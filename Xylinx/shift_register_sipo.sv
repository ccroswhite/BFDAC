`timescale 1ns / 1ps

module shift_register_sipo #(
    parameter int WIDTH = 32,
    parameter string SHIFT_DIR = "LEFT" // "LEFT" shifts LSB to MSB, "RIGHT" shifts MSB to LSB
)(
    input  logic             clk,          // System clock
    input  logic             rst_n,        // Active-low, synchronous reset
    input  logic             enable,       // When high, the register shifts on the clock edge
    input  logic             serial_in,    // The incoming 1-bit data
    output logic [WIDTH-1:0] parallel_out  // The fully shifted data
);

    // Sequential logic triggered on the positive edge of the clock
    always_ff @(posedge clk) begin
        // Active-low, synchronous reset
        if (!rst_n) begin
            parallel_out <= '0; // Cleanly zero the entire register array
        end else if (enable) begin
            // Shift operations
            if (SHIFT_DIR == "LEFT") begin
                // Left shift (LSB to MSB): 
                // Previous MSB is discarded, remaining bits shift left, and new bit enters at LSB [0].
                parallel_out <= {parallel_out[WIDTH-2:0], serial_in};
            end else if (SHIFT_DIR == "RIGHT") begin
                // Right shift (MSB to LSB): 
                // Previous LSB is discarded, remaining bits shift right, and new bit enters at MSB [WIDTH-1].
                parallel_out <= {serial_in, parallel_out[WIDTH-1:1]};
            end
        end
    end

endmodule
