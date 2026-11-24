`timescale 1ns / 1ps

// =============================================================================
// POLYPHASE_MAC_ENGINE — Milestone 2 (Option B Bit-Exact Half-Curve Fold)
//                         + Schema-4 Hybrid Precision (split-MAC / block-exp)
//
// - SYM_FOLD_EN = 0 (Milestone 1):
//     Standard 1-DSP per MAC engine; preg_rev_out tied to 0.
// - SYM_FOLD_EN = 1 (Milestone 2):
//     Evaluates both the forward window product (2 * audio_in * coef_in) into
//     preg_out and the reverse window product (2 * audio_rev_in * coef_in) into
//     preg_rev_out using the shared depth-matched dsp_b2 coefficient pipeline.
// - Schema 4 precision modes (SPLIT_HI_LO):
//     * SPLIT_HI_LO = 0 (outer MACs 0..NUM_MACS-SPLIT_MACS-1): coef stays 18b
//       Q1.17*2^exp_in; the accumulated dsp_preg is round-half-up then
//       arithmetic-shifted right by exp_in at phase end.
//     * SPLIT_HI_LO = 1 (main-lobe MACs): coef_in is C_hi (Q1.17 weight) and
//       coef_lo_in is C_lo (Q1.35 weight, borrow-compensated signed split);
//       a second multiplier lane accumulates (audio >>> 4) * C_lo so that
//       |dsp_preg_lo| <= 2048 * 2^19 * 2^17 < 2^47 for all inputs; the merged
//       output is dsp_preg + ((dsp_preg_lo + 4096) >>> 13).
//     Both modes register the merged result (preg_out/preg_rev_out) one cycle
//     after the DSP48E2 accumulator so the shifter/adder has a full dedicated
//     cycle (SNAP_PIPE_DELAY incremented accordingly upstream).
// =============================================================================
module polyphase_mac_engine #(
    parameter int DATA_WIDTH  = 24,
    parameter int COEF_WIDTH  = 18,
    parameter int ACC_WIDTH   = 48,
    parameter int MAC_ID      = 0,
    parameter bit SYM_FOLD_EN = 1'b0,
    parameter bit SPLIT_HI_LO = 1'b0   // 1 = 36b hi/lo split MAC; 0 = 18b + block exponent
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         phase_sync,
    input  logic signed [COEF_WIDTH-1:0] coef_in,
    input  logic signed [COEF_WIDTH-1:0] coef_lo_in = '0,   // C_lo (split MACs only)
    input  logic [4:0]                   exp_in     = '0,   // block exponent (outer MACs only)
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
            dsp_adreg <= $signed({dsp_a2, 1'b0});
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

    // =========================================================================
    // STAGE 6 (schema 4): merged output register — one extra pipeline stage so
    // the exp shifter / hi-lo merge adder gets a dedicated register-to-register
    // cycle (SNAP_PIPE_DELAY accounts for the added latency upstream).
    // =========================================================================

    // Reverse half-curve accumulator (fwd declared above; rev declared here so
    // both are visible to the stage-6 generate below)
    logic signed [DATA_WIDTH-1:0] dsp_a1_rev, dsp_a2_rev;
    logic signed [DATA_WIDTH:0]   dsp_adreg_rev;
    (* use_dsp = "yes" *) logic signed [47:0]          dsp_mreg_rev;
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] dsp_preg_rev;
    logic                           rev_en;

    always_comb rev_en = SYM_FOLD_EN;

    always_ff @(posedge clk) begin
        if (!rst_n || !rev_en) begin
            dsp_a1_rev    <= '0;
            dsp_a2_rev    <= '0;
            dsp_adreg_rev <= '0;
            dsp_mreg_rev  <= '0;
            dsp_preg_rev  <= '0;
        end else begin
            dsp_a1_rev    <= audio_rev_in;
            dsp_a2_rev    <= dsp_a1_rev;
            dsp_adreg_rev <= $signed({dsp_a2_rev, 1'b0});
            dsp_mreg_rev  <= dsp_adreg_rev * dsp_b2;
            if (phase_sync_d6)
                dsp_preg_rev <= dsp_mreg_rev;
            else
                dsp_preg_rev <= dsp_preg_rev + dsp_mreg_rev;
        end
    end

    generate
        if (SPLIT_HI_LO) begin : gen_split_lo
            // ---------------------------------------------------------------
            // C_lo lane: lo operand is (2*audio) >>> 5 == dsp_a2 >>> 4
            // (20-bit signed, |operand| <= 2^19) so the 2048-tap accumulated
            // |dsp_preg_lo| <= 2048 * 2^19 * (2^17-1) < 2^47 — cannot overflow.
            // C_lo has 2^-18 weight relative to C_hi; the >>>4 pre-shift
            // makes the merge shift (18-5) = >>>13.
            // ---------------------------------------------------------------
            logic signed [COEF_WIDTH-1:0] coef_lo_1, dsp_blo1, dsp_blo2;
            logic signed [DATA_WIDTH-5:0] dsp_adreg_lo;   // exactly 20 bits
            (* use_dsp = "yes" *) logic signed [47:0] dsp_mreg_lo, dsp_preg_lo;
            logic signed [DATA_WIDTH-5:0] dsp_adreg_rev_lo;
            (* use_dsp = "yes" *) logic signed [47:0] dsp_mreg_rev_lo, dsp_preg_rev_lo;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    coef_lo_1     <= '0;
                    dsp_blo1      <= '0;
                    dsp_blo2      <= '0;
                    dsp_adreg_lo  <= '0;
                    dsp_mreg_lo   <= '0;
                    dsp_preg_lo   <= '0;
                    dsp_adreg_rev_lo <= '0;
                    dsp_mreg_rev_lo  <= '0;
                    dsp_preg_rev_lo  <= '0;
                end else begin
                    coef_lo_1     <= coef_lo_in;
                    dsp_blo1      <= coef_lo_1;
                    dsp_blo2      <= dsp_blo1;
                    dsp_adreg_lo  <= $signed(dsp_a2[DATA_WIDTH-1:4]);
                    dsp_mreg_lo   <= dsp_adreg_lo * dsp_blo2;
                    if (phase_sync_d6) dsp_preg_lo <= dsp_mreg_lo;
                    else               dsp_preg_lo <= dsp_preg_lo + dsp_mreg_lo;

                    if (rev_en) begin
                        dsp_adreg_rev_lo <= $signed(dsp_a2_rev[DATA_WIDTH-1:4]);
                        dsp_mreg_rev_lo  <= dsp_adreg_rev_lo * dsp_blo2;
                        if (phase_sync_d6) dsp_preg_rev_lo <= dsp_mreg_rev_lo;
                        else               dsp_preg_rev_lo <= dsp_preg_rev_lo + dsp_mreg_rev_lo;
                    end
                end
            end

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    preg_out     <= '0;
                    preg_rev_out <= '0;
                end else begin
                    preg_out     <= dsp_preg + ((dsp_preg_lo + 48'sd4096) >>> 13);
                    preg_rev_out <= rev_en
                        ? dsp_preg_rev + ((dsp_preg_rev_lo + 48'sd4096) >>> 13)
                        : '0;
                end
            end
        end else begin : gen_exp_shift
            // Outer MACs: round-half-up then arithmetic right-shift by exp_in.
            logic signed [47:0] rnd_bias;
            always_comb rnd_bias = (exp_in == 5'd0) ? 48'sd0
                                                  : (48'sd1 <<< (exp_in - 5'd1));

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    preg_out     <= '0;
                    preg_rev_out <= '0;
                end else begin
                    preg_out     <= (dsp_preg + rnd_bias) >>> exp_in;
                    preg_rev_out <= rev_en
                        ? (dsp_preg_rev + rnd_bias) >>> exp_in
                        : '0;
                end
            end
        end
    endgenerate

endmodule
