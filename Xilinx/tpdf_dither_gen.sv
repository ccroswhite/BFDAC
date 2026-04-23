`timescale 1ns / 1ps

module tpdf_dither_gen #(
    parameter int DITHER_WIDTH = 26 
)(
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    
    output logic signed [DITHER_WIDTH-1:0] tpdf_out
);

    // High-speed Linear Feedback Shift Registers for uniform noise
    logic [31:0] lfsr_1;
    logic [31:0] lfsr_2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr_1 <= 32'h0000ACE1; 
            lfsr_2 <= 32'h00001337; 
        end else if (enable) begin
            // Galois LFSR 1
            if (lfsr_1[0] == 1'b1) lfsr_1 <= (lfsr_1 >> 1) ^ 32'h80200003;
            else                   lfsr_1 <= (lfsr_1 >> 1);
            
            // Galois LFSR 2
            if (lfsr_2[0] == 1'b1) lfsr_2 <= (lfsr_2 >> 1) ^ 32'h80000057;
            else                   lfsr_2 <= (lfsr_2 >> 1);
        end
    end

    // TPDF is created by subtracting two independent uniform random variables
    (* use_dsp = "yes" *) logic signed [32:0] tpdf_raw;
    
    always_ff @(posedge clk) begin
        if (enable) begin
            tpdf_raw <= $signed({1'b0, lfsr_1}) - $signed({1'b0, lfsr_2});
        end
    end

    // Safely route the bit slicing depending on the requested width
    // This prevents negative index synthesis errors if DITHER_WIDTH > 32
    generate
        if (DITHER_WIDTH <= 32) begin : gen_narrow_dither
            assign tpdf_out = tpdf_raw[31 : 32 - DITHER_WIDTH];
        end else begin : gen_wide_dither
            // If requesting more than 32 bits of dither, use all 32 bits and pad the rest with zero.
            // Dither energy below the 32nd bit (-192dB) is practically irrelevant.
            assign tpdf_out = {tpdf_raw[31:0], {(DITHER_WIDTH - 32){1'b0}}};
        end
    endgenerate

endmodule