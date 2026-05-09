`timescale 1ns / 1ps

module noise_shaper_5th_order #(
    parameter int INPUT_WIDTH = 48,  
    parameter int FRAC_WIDTH  = 42,
    parameter int OUT_WIDTH   = 9    
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         enable,
    input  logic signed [INPUT_WIDTH-1:0] data_in,
    input  logic signed [FRAC_WIDTH-1:0]  dither_in, 
    output logic [OUT_WIDTH-1:0]          dem_drive_out
);

    // =================================---------------------------------------
    // 1. Dynamic Widths & Constants
    // =================================---------------------------------------
    localparam int INTERNAL_WIDTH = INPUT_WIDTH + 6;

    localparam logic signed [INTERNAL_WIDTH-1:0] MAX_LEVEL     = 256;
    localparam logic signed [INTERNAL_WIDTH-1:0] CENTER_OFFSET = 128;
    localparam logic signed [INTERNAL_WIDTH-1:0] CLAMP_OFFSET  = {MAX_LEVEL[INTERNAL_WIDTH-FRAC_WIDTH-1:0], {FRAC_WIDTH{1'b0}}};

    // =================================---------------------------------------
    // 2. DC Offset
    // =================================---------------------------------------
    logic signed [INTERNAL_WIDTH-1:0] offset_audio;
    assign offset_audio = $signed(data_in) + $signed({CENTER_OFFSET[INTERNAL_WIDTH-FRAC_WIDTH-1:0], {FRAC_WIDTH{1'b0}}});

    // =================================---------------------------------------
    // 3. The 5-Stage Error Delay Line (Expanded to 54-bits)
    // =================================---------------------------------------
    logic signed [INTERNAL_WIDTH-1:0] e_z1, e_z2, e_z3, e_z4, e_z5;

    // =================================---------------------------------------
    // 4. The Modulator Summation Nodes (Optimized DSP Binary Tree)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] t1, t2, t3, t4;
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] sum_pos_1, sum_pos_2, sum_neg;
    (* use_dsp = "yes" *) logic signed [INTERNAL_WIDTH-1:0] noise_shaped_audio;

    logic signed [INTERNAL_WIDTH-1:0] dithered_audio;

    always_comb begin
        t1 = (e_z1 <<< 2) + e_z1;         
        t2 = (e_z2 <<< 3) + (e_z2 <<< 1); 
        t3 = (e_z3 <<< 3) + (e_z3 <<< 1); 
        t4 = (e_z4 <<< 2) + e_z4;         

        sum_pos_1 = offset_audio + t1;
        sum_pos_2 = t3 + e_z5;
        sum_neg   = t2 + t4;

        noise_shaped_audio = (sum_pos_1 + sum_pos_2) - sum_neg;
        dithered_audio = noise_shaped_audio + $signed(dither_in);
    end

    // =================================---------------------------------------
    // 5. High-Speed Bitwise Bounds Checking & Quantizer
    // =================================---------------------------------------
    logic overflow, underflow;
    
    always_comb begin
        overflow = (dithered_audio[INTERNAL_WIDTH-1] == 1'b0) && 
                   (|dithered_audio[INTERNAL_WIDTH-2 : FRAC_WIDTH+8]);
        
        underflow = (dithered_audio[INTERNAL_WIDTH-1] == 1'b1);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            e_z1 <= '0;
            e_z2 <= '0;
            e_z3 <= '0;
            e_z4 <= '0;
            e_z5 <= '0;
            dem_drive_out <= CENTER_OFFSET[OUT_WIDTH-1:0];
        end else if (enable) begin

            if (overflow) begin
                dem_drive_out <= MAX_LEVEL[OUT_WIDTH-1:0];
                e_z1 <= noise_shaped_audio - CLAMP_OFFSET;
            end
            else if (underflow) begin
                dem_drive_out <= '0;
                e_z1 <= noise_shaped_audio;
            end
            else begin
                dem_drive_out <= dithered_audio[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH];
                e_z1 <= noise_shaped_audio - $signed({dithered_audio[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH], {FRAC_WIDTH{1'b0}}});
            end

            e_z2 <= e_z1;
            e_z3 <= e_z2;
            e_z4 <= e_z3;
            e_z5 <= e_z4;
        end
    end

endmodule