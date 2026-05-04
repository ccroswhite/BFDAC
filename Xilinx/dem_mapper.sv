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
    // PIPELINE STAGE 3: Circular Barrel Shifter Synthesis
    // -----------------------------------------------------
    logic [2*ARRAY_SIZE-1:0] barrel_comb;
    
    // Map double-width vector for indexed slicing
    assign barrel_comb = {therm_code_s2, therm_code_s2};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resistor_out <= '0;
        end else if (enable) begin
            // Safely slice exactly ARRAY_SIZE bits using the LFSR random offset.
            // No inversion needed. The analog ECL switch handles the differential!
            resistor_out <= barrel_comb[rot_offset_s2 +: ARRAY_SIZE];
        end
    end

endmodule