`timescale 1ns / 1ps
(* use_dsp = "no" *)
module noise_shaper_2nd_order #(
    parameter int INPUT_WIDTH = 32, // High-precision input
    parameter int FRAC_WIDTH  = 26  // Bits discarded during truncation
)(
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   enable,  // Pulled high when FIR outputs a valid sample

    // High-precision signed audio from the FIR Interpolator.
    // Assumes scaled so the top 6 bits represent -16 to +15.
    input  logic signed [INPUT_WIDTH-1:0] data_in, 
    
    // Unsigned 0 to 32 physical drive for the DEM Mapper
    output logic [5:0]                    dem_drive_out 
);

    // =================================---------------------------------------
    // Fixed Point Architecture
    // Top 6 bits = Integer (Physical Resistors)
    // Bottom 26 bits = Fraction (Quantization Error)
    // =================================---------------------------------------

    // 1. Shift AC audio to DC Offset (so -16 becomes 0, and +15 becomes 31)
    logic signed [INPUT_WIDTH:0] offset_audio;
    assign offset_audio = $signed(data_in) + $signed({7'd16, {FRAC_WIDTH{1'b0}}});

    // 2. The Error Registers (e[n-1] and e[n-2])
    // Must be signed to handle negative error injection
    logic signed [FRAC_WIDTH+2:0] error_z1; 
    logic signed [FRAC_WIDTH+2:0] error_z2;

// 3. The Modulator Summation Node
    logic signed [INPUT_WIDTH+3:0] partial_sum;
    logic signed [INPUT_WIDTH+3:0] noise_shaped_audio;

    // Explicitly cast to 36-bits
    logic signed [INPUT_WIDTH+3:0] ext_offset;
    logic signed [INPUT_WIDTH+3:0] ext_err_z1;
    logic signed [INPUT_WIDTH+3:0] ext_err_z2;

    assign ext_offset = $signed(offset_audio);
    assign ext_err_z1 = $signed(error_z1);
    assign ext_err_z2 = $signed(error_z2);

    // Pre-calculate the 32-level clamp offset to prevent runtime subtraction inference
    localparam logic signed [35:0] CLAMP_OFFSET = $signed({3'b000, 7'd32, 26'd0});

    always_comb begin
        // The 2nd Order Error Feedback Formula
        // Broken into two explicit stages to prevent ternary adder QoR warnings
        
        // Stage 1: Add offset to (error * 2). 
        // Using '<<< 1' is functionally *2 but guarantees Vivado treats it as free wiring.
        partial_sum = ext_offset + (ext_err_z1 <<< 1);
        
        // Stage 2: Subtract older error
        noise_shaped_audio = partial_sum - ext_err_z2;
    end

    // 4. The Quantizer & Feedback Loop
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_z1      <= '0;
            error_z2      <= '0;
            dem_drive_out <= 6'd16; // Default to physical zero (center)
        end else if (enable) begin
            
            // A. Hard Limiting (Protecting the physical Array bounds 0 to 32)
            if (noise_shaped_audio[INPUT_WIDTH+3 : FRAC_WIDTH] > 32) begin
                dem_drive_out <= 6'd32;
                // Subtract the pre-calculated localparam
                error_z1 <= noise_shaped_audio - CLAMP_OFFSET;
            end 
            else if (noise_shaped_audio[INPUT_WIDTH+3] == 1'b1) begin // Negative
                dem_drive_out <= 6'd0;
                error_z1 <= noise_shaped_audio; 
            end 
            else begin
                // Normal Operation
                dem_drive_out <= noise_shaped_audio[FRAC_WIDTH+5 : FRAC_WIDTH];
                error_z1 <= $signed({1'b0, noise_shaped_audio[FRAC_WIDTH-1 : 0]});
            end
            
            // B. Shift the delay line
            error_z2 <= error_z1;
        end
    end

endmodule