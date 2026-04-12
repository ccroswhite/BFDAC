`timescale 1ns / 1ps

module volume_multiplier #(
    parameter int DATA_WIDTH = 32
)(
    input  logic                      clk,
    input  logic                      rst_n,

    // Volume Control Interface (From SPI Register)
    // 0xFFFFFFFF = 100% Volume, 0x00000000 = Mute
    input  logic [DATA_WIDTH-1:0]     volume_coef, 

    // Upstream Audio (From Asynchronous Moat)
    input  logic signed [DATA_WIDTH-1:0] audio_in,
    input  logic                      audio_valid_in,

    // Downstream Audio (To DSP Master Controller)
    output logic signed [DATA_WIDTH-1:0] audio_out,
    output logic                      audio_valid_out
);

    // DSP48 Pipeline Registers
    logic signed [DATA_WIDTH-1:0] sample_reg;
    logic        [DATA_WIDTH-1:0] vol_reg;
    logic                         valid_reg1, valid_reg2;
    
    // 65-bit product to safely hold signed 32-bit * unsigned 32-bit
    // Forced into dedicated DSP48E1 silicon (will cascade 4 slices)
    (* use_dsp = "yes" *) logic signed [64:0] full_product;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_reg      <= '0;
            vol_reg         <= '0;
            valid_reg1      <= 1'b0;
            valid_reg2      <= 1'b0;
            full_product    <= '0;
            audio_out       <= '0;
            audio_valid_out <= 1'b0;
        end else begin
            // -------------------------------------------------------------
            // Stage 1: Input Registration
            // -------------------------------------------------------------
            sample_reg <= audio_in;
            vol_reg    <= volume_coef;
            valid_reg1 <= audio_valid_in;

            // -------------------------------------------------------------
            // Stage 2: Multiplication 
            // -------------------------------------------------------------
            // $signed({1'b0, vol_reg}) safely casts the fraction to positive
            if (valid_reg1) begin
                full_product <= $signed(sample_reg) * $signed({1'b0, vol_reg});
            end
            valid_reg2 <= valid_reg1;

            // -------------------------------------------------------------
            // Stage 3: Rounding & Extraction 
            // -------------------------------------------------------------
            // Instead of truncating (which causes harmonic distortion), 
            // we add the MSB of the discarded fraction (bit 31) to round to nearest.
            if (valid_reg2) begin
                audio_out <= full_product[63:32] + full_product[31];
            end
            audio_valid_out <= valid_reg2;
        end
    end
endmodule