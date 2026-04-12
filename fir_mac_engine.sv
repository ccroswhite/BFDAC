`timescale 1ns / 1ps

module fir_mac_engine #(
    parameter int DATA_WIDTH = 32,
    parameter int COEF_WIDTH = 32,
    parameter int ACC_WIDTH  = 64
)(
    input  logic                                clk,
    input  logic                                rst_n,

    // Upstream Logic Interface (From previous tap)
    input  logic signed [DATA_WIDTH-1:0]        sample_in,
    input  logic signed [COEF_WIDTH-1:0]        coef_in,
    input  logic signed [ACC_WIDTH-1:0]         acc_in,

    // Downstream Systolic Tap Interface (To next tap)
    output logic signed [DATA_WIDTH-1:0]        sample_out,
    output logic signed [ACC_WIDTH-1:0]         acc_out
);

    // -----------------------------------------------------
    // STAGE 1: Input Registration (Maps to DSP48 A1 & B1)
    // -----------------------------------------------------
    logic signed [DATA_WIDTH-1:0] sample_s1;
    logic signed [COEF_WIDTH-1:0] coef_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_s1 <= '0;
            coef_s1   <= '0;
        end else begin
            sample_s1 <= sample_in;
            coef_s1   <= coef_in;
        end
    end

    // -----------------------------------------------------
    // STAGE 2: Second Data Pipeline (Maps to DSP48 A2 & B2)
    // -----------------------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_s2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_out <= '0; // Cascades to next MAC with exactly 2 cycles of delay
            coef_s2    <= '0;
        end else begin
            sample_out <= sample_s1;
            coef_s2    <= coef_s1;
        end
    end

// -----------------------------------------------------
    // STAGE 3: Multiplier Pipeline (Maps to DSP48 M Register)
    // -----------------------------------------------------
    localparam int PROD_WIDTH = DATA_WIDTH + COEF_WIDTH;
    
    // Force synthesis to use dedicated DSP slices
    (* use_dsp = "yes" *) logic signed [PROD_WIDTH-1:0] product_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_reg <= '0;
        end else begin
            product_reg <= $signed(sample_out) * $signed(coef_s2);
        end
    end

    // -----------------------------------------------------
    // STAGE 4: Accumulator Pipeline (Maps to DSP48 P Register)
    // -----------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else begin
            // acc_in routes directly to the adder. No prior pipelining.
            acc_out <= $signed(acc_in) + $signed(product_reg);
        end
    end

endmodule
