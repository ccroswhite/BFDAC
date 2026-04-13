`timescale 1ns / 1ps

module dem_mapper #(
    parameter int ARRAY_SIZE = 32, // 32 resistors for Hot, 32 for Cold (64 total)
    parameter int AMP_WIDTH  = 6,  // Needs to represent 0 to 32

    // LFSR Configuration
    parameter int LFSR_WIDTH = 16,
    parameter logic [LFSR_WIDTH-1:0] LFSR_POLY = 16'hB400, // x^16 + x^14 + x^13 + x^11 + 1
    parameter logic [LFSR_WIDTH-1:0] LFSR_SEED = 16'hACE1
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable,
    input  logic [AMP_WIDTH-1:0] amplitude_in,
    
    // The 64-bit physical output to the LVDS serializer
    // [31:0]  = Positive Phase (Hot)
    // [63:32] = Negative Phase (Cold)
    output logic [63:0]        resistor_out
);

    // -----------------------------------------------------
    // PIPELINE STAGE 1: Thermometer Decoding
    // -----------------------------------------------------
    logic [ARRAY_SIZE-1:0] therm_code_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            therm_code_s1 <= '0;
        end else if (enable) begin
            // Explicitly cover edge cases for absolute safety
            if (amplitude_in == 0) begin
                therm_code_s1 <= '0;
            end else if (amplitude_in >= ARRAY_SIZE) begin
                therm_code_s1 <= '1;
            end else begin
                // Safely build the vector iteratively
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
    logic [LFSR_WIDTH-1:0]       lfsr;
    logic [ARRAY_SIZE-1:0]       therm_code_s2;
    logic [$clog2(ARRAY_SIZE)-1:0] rot_offset_s2; // 5-bit register for 0-31

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
            // Since ARRAY_SIZE is 32, modulo 32 is exactly the bottom 5 bits.
            // This prevents the synthesis tool from building a division circuit.
            rot_offset_s2 <= lfsr[4:0];

            // 3. Forward the generated thermometer code to stage 2
            therm_code_s2 <= therm_code_s1;
        end
    end

    // -----------------------------------------------------
    // PIPELINE STAGE 3: Circular Barrel Shifter Synthesis
    // -----------------------------------------------------
    logic [2*ARRAY_SIZE-1:0] barrel_comb;
    logic [ARRAY_SIZE-1:0]   rotated_hot;
    
    // Map double-width vector for indexed slicing
    assign barrel_comb = {therm_code_s2, therm_code_s2};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resistor_out <= '0;
        end else if (enable) begin
            // A. Safely slice exactly ARRAY_SIZE bits using the LFSR random offset
            rotated_hot = barrel_comb[rot_offset_s2 +: ARRAY_SIZE];
            
            // B. Pack the 64-bit Differential Output for the blades
            resistor_out[31:0]  <= rotated_hot;        // Positive Phase (Hot)
            resistor_out[63:32] <= ~rotated_hot;       // Negative Phase (Cold)
        end
    end

endmodule
