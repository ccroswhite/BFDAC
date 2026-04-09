`timescale 1ns / 1ps

module dem_mapper #(
    parameter int RESISTOR_COUNT = 48,
    parameter int AMP_WIDTH = 6,
    // LFSR Configuration
    parameter int LFSR_WIDTH = 16,
    parameter logic [LFSR_WIDTH-1:0] LFSR_POLY = 16'hB400, // x^16 + x^14 + x^13 + x^11 + 1 right-shifted Galois
    parameter logic [LFSR_WIDTH-1:0] LFSR_SEED = 16'hACE1
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      enable,
    input  logic [AMP_WIDTH-1:0]      amplitude_in,
    output logic [RESISTOR_COUNT-1:0] resistor_out
);

    // -----------------------------------------------------
    // PIPELINE STAGE 1: Thermometer Decoding
    // -----------------------------------------------------
    logic [RESISTOR_COUNT-1:0] therm_code_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            therm_code_s1 <= '0;
        end else if (enable) begin
            // Explicitly cover edge cases for absolute safety
            if (amplitude_in == 0) begin
                therm_code_s1 <= '0;
            end else if (amplitude_in >= RESISTOR_COUNT) begin
                therm_code_s1 <= '1;
            end else begin
                // Safely build the vector iteratively without huge arithmetic bit-shifts that threaten overflow
                for (int i = 0; i < RESISTOR_COUNT; i++) begin
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
    logic [LFSR_WIDTH-1:0]             lfsr;
    logic [RESISTOR_COUNT-1:0]         therm_code_s2;
    logic [$clog2(RESISTOR_COUNT)-1:0] rot_offset_s2;

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

            // 2. Modulo truncation to bind pointer to physical elements
            rot_offset_s2 <= lfsr % RESISTOR_COUNT;

            // 3. Forward the generated thermometer code to stage 2, matching latency
            therm_code_s2 <= therm_code_s1;
        end
    end

    // -----------------------------------------------------
    // PIPELINE STAGE 3: Circular Barrel Shifter Synthesis
    // -----------------------------------------------------
    logic [2*RESISTOR_COUNT-1:0] barrel_comb;
    // Map double-width vector to employ clean dynamic indexed slicing (highly synthesizable block)
    assign barrel_comb = {therm_code_s2, therm_code_s2};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resistor_out <= '0;
        end else if (enable) begin
            // Safely slice exactly RESISTOR_COUNT bits starting at the generated Galois offset.
            // +: represents an upward indexed part-select, driving optimal multiplexer routing bounds.
            resistor_out <= barrel_comb[rot_offset_s2 +: RESISTOR_COUNT];
        end
    end

endmodule
