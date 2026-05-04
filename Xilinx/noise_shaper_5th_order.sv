`timescale 1ns / 1ps

module noise_shaper_5th_order #(
    parameter int INPUT_WIDTH = 48,  // Catching the top 48 bits of the accumulator
    parameter int FRAC_WIDTH  = 42,
    parameter int OUT_WIDTH   = 9    // 9 bits needed for 256 physical resistors
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         enable,
    input  logic signed [INPUT_WIDTH-1:0] data_in,
    input  logic signed [FRAC_WIDTH-1:0]  dither_in, 
    output logic [OUT_WIDTH-1:0]         dem_drive_out
);

    // =================================---------------------------------------
    // 1. Dynamic Widths & Constants
    // =================================---------------------------------------
    // Dynamically sized internal width provides 6 bits of whole-number headroom 
    // above the fraction, permanently preventing slicing [50:42] out-of-bounds errors.
    localparam int INTERNAL_WIDTH = INPUT_WIDTH + 6;

    localparam logic signed [INTERNAL_WIDTH-1:0] MAX_LEVEL     = 256;
    localparam logic signed [INTERNAL_WIDTH-1:0] CENTER_OFFSET = 128;
    localparam logic signed [INTERNAL_WIDTH-1:0] CLAMP_OFFSET  = {MAX_LEVEL[INTERNAL_WIDTH-FRAC_WIDTH-1:0], {FRAC_WIDTH{1'b0}}};

    // =================================---------------------------------------
    // 2. DC Offset
    // =================================---------------------------------------
    // Shift AC audio to DC Offset (so negative troughs hit 0, center is 128)
    logic signed [INTERNAL_WIDTH-1:0] offset_audio;
    assign offset_audio = $signed(data_in) + $signed({CENTER_OFFSET[INTERNAL_WIDTH-FRAC_WIDTH-1:0], {FRAC_WIDTH{1'b0}}});

    // =================================---------------------------------------
    // 3. The 5-Stage Error Delay Line
    // =================================---------------------------------------
    logic signed [FRAC_WIDTH+4:0] e_z1, e_z2, e_z3, e_z4, e_z5;

    // Explicit sign-extension for the parallel math tree
    logic signed [INTERNAL_WIDTH-1:0] ext_e_z1, ext_e_z2, ext_e_z3, ext_e_z4, ext_e_z5;
    assign ext_e_z1 = $signed(e_z1);
    assign ext_e_z2 = $signed(e_z2);
    assign ext_e_z3 = $signed(e_z3);
    assign ext_e_z4 = $signed(e_z4);
    assign ext_e_z5 = $signed(e_z5);

    // =================================---------------------------------------
    // 4. The Modulator Summation Nodes (Optimized DSP Binary Tree)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] t1, t2, t3, t4;
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] sum_pos_1, sum_pos_2, sum_neg;
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] noise_shaped_audio;

    logic signed [INTERNAL_WIDTH-1:0] dithered_audio;

    always_comb begin
        // Stage A: Hard-wired bit shifts instead of LUT multipliers (Zero logic delay)
        t1 = (ext_e_z1 <<< 2) + ext_e_z1;         
        t2 = (ext_e_z2 <<< 3) + (ext_e_z2 <<< 1); 
        t3 = (ext_e_z3 <<< 3) + (ext_e_z3 <<< 1); 
        t4 = (ext_e_z4 <<< 2) + ext_e_z4;         

        // Stage B: Parallel Binary Tree Addition
        sum_pos_1 = offset_audio + t1;
        sum_pos_2 = t3 + ext_e_z5;
        sum_neg   = t2 + t4;

        // Stage C: Final Recombination (Pure Target)
        noise_shaped_audio = (sum_pos_1 + sum_pos_2) - sum_neg;

        // Stage D: Inject TPDF dither strictly for the physical quantizer decision
        dithered_audio = noise_shaped_audio + $signed(dither_in);
    end

    // =================================---------------------------------------
    // 5. High-Speed Bitwise Bounds Checking & Quantizer
    // =================================---------------------------------------
    logic overflow, underflow;
    
    always_comb begin
        // OVERFLOW: Sign is positive (0) AND any bit at or above the 256 place value is 1
        overflow = (dithered_audio[INTERNAL_WIDTH-1] == 1'b0) && 
                   (|dithered_audio[INTERNAL_WIDTH-2 : FRAC_WIDTH+8]);
        
        // UNDERFLOW: Sign is negative (1)
        underflow = (dithered_audio[INTERNAL_WIDTH-1] == 1'b1);
    end

    logic [OUT_WIDTH-1:0] quantized_step;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            e_z1 <= '0;
            e_z2 <= '0;
            e_z3 <= '0;
            e_z4 <= '0;
            e_z5 <= '0;
            dem_drive_out <= CENTER_OFFSET[OUT_WIDTH-1:0];
        end else if (enable) begin

            // A. Bitwise Hard Limiting (Zero arithmetic routing delay)
            if (overflow) begin
                dem_drive_out <= MAX_LEVEL[OUT_WIDTH-1:0];
                e_z1 <= noise_shaped_audio - CLAMP_OFFSET;
            end
            else if (underflow) begin
                dem_drive_out <= '0;
                e_z1 <= noise_shaped_audio;
            end
            else begin
                // B. Safe Truncation
                quantized_step = dithered_audio[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH];
                dem_drive_out <= quantized_step;

                // C. Track the true error: Pure Target - Physical Output
                e_z1 <= noise_shaped_audio - $signed({quantized_step, {FRAC_WIDTH{1'b0}}});
            end

            // D. Shift the delay line
            e_z2 <= e_z1;
            e_z3 <= e_z2;
            e_z4 <= e_z3;
            e_z5 <= e_z4;
        end
    end

endmodule