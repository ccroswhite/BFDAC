`timescale 1ns / 1ps

module tpdf_dither_gen #(
    parameter int DITHER_WIDTH = 42
)(
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    output logic signed [DITHER_WIDTH-1:0] dither_out
);

    logic [31:0] lfsr_1;
    logic [31:0] lfsr_2;
    logic signed [32:0] tpdf_raw;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr_1 <= 32'hACE11001; 
            lfsr_2 <= 32'h1337BEEF; 
            tpdf_raw <= '0;
        end else if (enable) begin
            // Shift registers with XOR feedback
            lfsr_1 <= {lfsr_1[30:0], lfsr_1[31] ^ lfsr_1[21] ^ lfsr_1[1] ^ lfsr_1[0]};
            lfsr_2 <= {lfsr_2[30:0], lfsr_2[31] ^ lfsr_2[21] ^ lfsr_2[1] ^ lfsr_2[0]};
            
            // TPDF is the sum of two independent uniform random variables
            tpdf_raw <= $signed({1'b0, lfsr_1}) - $signed({1'b0, lfsr_2});
        end
    end

    // Safely pad the random number with zeros to match the requested fractional width
    generate
        if (DITHER_WIDTH > 33) begin
            assign dither_out = {tpdf_raw, {(DITHER_WIDTH - 33){1'b0}}};
        end else begin
            assign dither_out = tpdf_raw[32 : 33 - DITHER_WIDTH];
        end
    endgenerate

endmodule