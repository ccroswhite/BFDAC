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
    output logic                      audio_valid_out,
    output logic                      audio_clip_out // NEW: Clip flag
);

    // DSP48 Pipeline Registers
    logic signed [DATA_WIDTH-1:0] sample_reg;
    logic        [DATA_WIDTH-1:0] vol_reg;
    logic                         valid_reg1, valid_reg2;
    
    // 65-bit product to safely hold signed 32-bit * unsigned 32-bit
    (* use_dsp = "yes" *) logic signed [64:0] full_product;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sample_reg      <= '0;
            vol_reg         <= '0;
            valid_reg1      <= 1'b0;
            valid_reg2      <= 1'b0;
            full_product    <= '0;
            audio_out       <= '0;
            audio_valid_out <= 1'b0;
            audio_clip_out  <= 1'b0;
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
            if (valid_reg1) begin
                full_product <= $signed(sample_reg) * $signed({1'b0, vol_reg});
            end
            valid_reg2 <= valid_reg1;

            // -------------------------------------------------------------
            // Stage 3: Saturation, Rounding & Extraction 
            // -------------------------------------------------------------
            if (valid_reg2) begin
                // Use a 34-bit signed intermediate to safely catch any overflow
                // during the rounding addition.
                automatic logic signed [33:0] rounded;
                rounded = full_product[64:32] + full_product[31];

                // Hard clamp (Saturate) to 32-bit MAX/MIN bounds
                if (rounded > 34'sd2147483647) begin
                    audio_out      <= 32'sd2147483647; // 32'h7FFFFFFF
                    audio_clip_out <= 1'b1;
                end else if (rounded < -34'sd2147483648) begin
                    audio_out      <= -32'sd2147483648; // 32'h80000000
                    audio_clip_out <= 1'b1;
                end else begin
                    audio_out      <= rounded[31:0];
                    audio_clip_out <= 1'b0;
                end
            end else begin
                audio_clip_out <= 1'b0;
            end
            
            audio_valid_out <= valid_reg2;
        end
    end
endmodule