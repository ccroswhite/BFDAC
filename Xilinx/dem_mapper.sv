`timescale 1ns / 1ps

module dem_mapper #(
    parameter int ARRAY_SIZE = 256, // Dynamically scalable array size
    parameter int AMP_WIDTH  = 9,   // Addressing width
    parameter int LFSR_WIDTH = 16,
    parameter logic [LFSR_WIDTH-1:0] LFSR_POLY = 16'hB400,
    parameter logic [LFSR_WIDTH-1:0] LFSR_SEED = 16'hACE1
)(
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   enable,
    input  logic [AMP_WIDTH-1:0]   amplitude_in,
    
    // Output strictly 1 bit per ECL transistor switch (256 bits total)
    output logic [ARRAY_SIZE-1:0]  resistor_out
);

    // -----------------------------------------------------
    // PIPELINE STAGE 1: Thermometer Decoding
    // -----------------------------------------------------
    logic [ARRAY_SIZE-1:0] therm_code_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            therm_code_s1 <= '0;
        end else if (enable) begin
            if (amplitude_in == 0) begin
                therm_code_s1 <= '0;
            end else if (amplitude_in >= ARRAY_SIZE) begin
                therm_code_s1 <= '1;
            end else begin
                for (int i = 0; i < ARRAY_SIZE; i++) begin
                    if (amplitude_in > i)
                        therm_code_s1[i] <= 1'b1;
                    else
                        therm_code_s1[i] <= 1'b0;
                end
            end
        end
    end

    // -----------------------------------------------------
    // PIPELINE STAGE 2: LFSR Pointer & Synchronization
    // -----------------------------------------------------
    logic [LFSR_WIDTH-1:0]           lfsr;
    logic [ARRAY_SIZE-1:0]           therm_code_s2;
    logic [$clog2(ARRAY_SIZE)-1:0]   rot_offset_s2; 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr          <= LFSR_SEED;
            therm_code_s2 <= '0;
            rot_offset_s2 <= '0;
        end else if (enable) begin
            // 1. Galois LFSR Shift Logic
            if (lfsr[0] == 1'b1) begin
                lfsr <= (lfsr >> 1) ^ LFSR_POLY;
            end else begin
                lfsr <= (lfsr >> 1);
            end

            // 2. Hardware-Optimized Modulo
            rot_offset_s2 <= lfsr[$clog2(ARRAY_SIZE)-1:0];

            // 3. Forward the thermometer code
            therm_code_s2 <= therm_code_s1;
        end
    end

    // -----------------------------------------------------
    // PIPELINE STAGE 3a: Coarse Barrel Rotation (stride 16, 16 positions)
    //
    // The original single-cycle 256-position rotate produced a 256:1 mux
    // per output bit (4 levels of LUT6). With ARRAY_SIZE=256 destinations
    // pulling from ARRAY_SIZE=256 sources via a full cross-bar, the placer
    // cannot avoid long routes, producing routing-dominated timing
    // failures. We split the single rotate into two cascaded 16-position
    // rotates: coarse (this stage, stride 16) and fine (next stage,
    // stride 1). Each stage is one 16:1 mux = 1 level of LUT6, with a
    // register in between giving the placer freedom to localise each half.
    // Mathematically: N = 16 * rot_offset[7:4] + rot_offset[3:0], so the
    // composition is bit-exact to the original rotate-by-N.
    // -----------------------------------------------------
    logic [ARRAY_SIZE-1:0]                  therm_code_s3a;
    logic [$clog2(ARRAY_SIZE/16)-1:0]       rot_offset_fine_s3a; // 4 bits

    logic [2*ARRAY_SIZE-1:0]                barrel_s3a_comb;
    assign barrel_s3a_comb = {therm_code_s2, therm_code_s2};

    // Coarse index = rot_offset_s2[7:4] * 16 (zero LSBs).
    logic [$clog2(ARRAY_SIZE)-1:0] coarse_index;
    assign coarse_index = {rot_offset_s2[$clog2(ARRAY_SIZE)-1 : $clog2(ARRAY_SIZE/16)],
                           {$clog2(ARRAY_SIZE/16){1'b0}}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            therm_code_s3a      <= '0;
            rot_offset_fine_s3a <= '0;
        end else if (enable) begin
            therm_code_s3a      <= barrel_s3a_comb[coarse_index +: ARRAY_SIZE];
            rot_offset_fine_s3a <= rot_offset_s2[$clog2(ARRAY_SIZE/16)-1 : 0];
        end
    end

    // -----------------------------------------------------
    // PIPELINE STAGE 3b: Fine Barrel Rotation (stride 1, 16 positions)
    // -----------------------------------------------------
    logic [2*ARRAY_SIZE-1:0] barrel_s3b_comb;
    assign barrel_s3b_comb = {therm_code_s3a, therm_code_s3a};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resistor_out <= '0;
        end else if (enable) begin
            // Safely slice exactly ARRAY_SIZE bits using the fine offset.
            // No inversion needed. The analog ECL switch handles the differential!
            resistor_out <= barrel_s3b_comb[rot_offset_fine_s3a +: ARRAY_SIZE];
        end
    end

endmodule