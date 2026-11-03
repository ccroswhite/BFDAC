`timescale 1ns / 1ps

// =============================================================================
// POLYPHASE_MAC_ENGINE — Milestone 2 (Option B Bit-Exact Half-Curve Fold)
//
// - SYM_FOLD_EN = 0 (Milestone 1):
//     Standard 1-DSP per MAC engine; preg_rev_out tied to 0.
// - SYM_FOLD_EN = 1 (Milestone 2):
//     Evaluates both the forward window product (2 * audio_in * coef_in) into
//     preg_out and the reverse window product (2 * audio_rev_in * coef_in) into
//     preg_rev_out using the shared depth-matched dsp_b2 coefficient pipeline.
// =============================================================================
module polyphase_mac_engine #(
    parameter int DATA_WIDTH  = 24,
    parameter int COEF_WIDTH  = 18,
    parameter int ACC_WIDTH   = 48,
    parameter int MAC_ID      = 0,
    parameter bit SYM_FOLD_EN = 1'b0
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         phase_sync,
    input  logic signed [COEF_WIDTH-1:0] coef_in,
    input  logic signed [DATA_WIDTH-1:0] audio_in,          // forward window sample, co-timed with coef_in
    input  logic signed [DATA_WIDTH-1:0] audio_rev_in = '0, // reverse window sample, co-timed with coef_in
    output logic signed [ACC_WIDTH-1:0]  preg_out,          // forward partial sum -> u_adder_tree
    output logic signed [ACC_WIDTH-1:0]  preg_rev_out       // reverse partial sum -> u_adder_tree_rev
);

    // 1. Pipeline Delay Taps
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5, phase_sync_d6;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {phase_sync_d1, phase_sync_d2, phase_sync_d3, phase_sync_d4,
             phase_sync_d5, phase_sync_d6} <= '0;
        end else begin
            phase_sync_d1 <= phase_sync;
            phase_sync_d2 <= phase_sync_d1;
            phase_sync_d3 <= phase_sync_d2;
            phase_sync_d4 <= phase_sync_d3;
            phase_sync_d5 <= phase_sync_d4;
            phase_sync_d6 <= phase_sync_d5;
        end
    end

    // 2. STAGE 1: Audio & Coef Registration
    logic signed [COEF_WIDTH-1:0] coef_out_1;
    logic signed [DATA_WIDTH-1:0] dsp_a1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_a1     <= '0;
            coef_out_1 <= '0;
        end else begin
            dsp_a1     <= audio_in;
            coef_out_1 <= coef_in;
        end
    end

    // 3. STAGE 2: Audio A2 & Coef B1
    logic signed [DATA_WIDTH-1:0] dsp_a2;
    logic signed [COEF_WIDTH-1:0] dsp_b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_a2 <= '0;
            dsp_b1 <= '0;
        end else begin
            dsp_a2 <= dsp_a1;
            dsp_b1 <= coef_out_1;
        end
    end

    // 4. STAGE 3: Pre-Adder (ADREG) & B2
    logic signed [DATA_WIDTH:0]   dsp_adreg;
    logic signed [COEF_WIDTH-1:0] dsp_b2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_adreg <= '0;
            dsp_b2    <= '0;
        end else begin
            dsp_adreg <= $signed(dsp_a2) +$signed(dsp_a2);
            dsp_b2    <= dsp_b1;
        end
    end

    // 5. STAGE 4: DSP48 Multiplier (MREG)
    (* use_dsp = "yes" *) logic signed [47:0] dsp_mreg;

    always_ff @(posedge clk) begin
        if (!rst_n) dsp_mreg <= '0;
        else        dsp_mreg <= dsp_adreg * dsp_b2;
    end

    // 6. STAGE 5: DSP48 Accumulator (PREG)
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_preg <= '0;
        end else if (phase_sync_d6) begin
            dsp_preg <= dsp_mreg;
        end else begin
            dsp_preg <= dsp_preg + dsp_mreg;
        end
    end

    assign preg_out = dsp_preg;

    // 7. Reverse Half-Curve Lane (shares dsp_b2 and phase_sync_d6)
    generate
        if (SYM_FOLD_EN) begin : gen_rev_mac
            logic signed [DATA_WIDTH-1:0] dsp_a1_rev, dsp_a2_rev;
            logic signed [DATA_WIDTH:0]   dsp_adreg_rev;
            (* use_dsp = "yes" *) logic signed [47:0]          dsp_mreg_rev;
            (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] dsp_preg_rev;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    dsp_a1_rev    <= '0;
                    dsp_a2_rev    <= '0;
                    dsp_adreg_rev <= '0;
                    dsp_mreg_rev  <= '0;
                    dsp_preg_rev  <= '0;
                end else begin
                    dsp_a1_rev    <= audio_rev_in;
                    dsp_a2_rev    <= dsp_a1_rev;
                    dsp_adreg_rev <= $signed(dsp_a2_rev) +$signed(dsp_a2_rev);
                    dsp_mreg_rev  <= dsp_adreg_rev * dsp_b2;
                    if (phase_sync_d6)
                        dsp_preg_rev <= dsp_mreg_rev;
                    else
                        dsp_preg_rev <= dsp_preg_rev + dsp_mreg_rev;
                end
            end
            assign preg_rev_out = dsp_preg_rev;
        end else begin : gen_no_rev_mac
            assign preg_rev_out = '0;
        end
    endgenerate

endmodule
