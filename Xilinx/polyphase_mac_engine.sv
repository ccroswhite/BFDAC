`timescale 1ns / 1ps

// Per-MAC polyphase engine for TRUE polyphase interpolation.
//
// Architecture: adder-tree reduction (NO cascade PCIN/PCOUT).
//   Each MAC accumulates independently over its phase window and outputs
//   preg to the polyphase_adder_tree, which sums all NUM_MACS MACs in a
//   pipelined binary tree (log2(NUM_MACS) levels, 12 levels for 4096 MACs).
//   This eliminates the long PCIN/PCOUT routing chain entirely, dramatically improving timing closure.
//
// Audio delivery: each MAC receives x[n-m] as a STATIC direct input
// (audio_in) from the interpolator's audio shift register, which is
// pre-loaded from the audio BRAM at new_sample_valid.
//
// Pipeline timing (from coef_addr being issued at the wrapper):
//   cycle 0 : coef_addr issued; audio_in valid and stable
//   cycle 1 : coef BRAM read latency  (stage 1 inside wrapper)
//   cycle 2 : coef BRAM DO_REG        (stage 2 inside wrapper) → coef_in valid
//   cycle 3 : dsp_a1 / coef_out_1    (Stage 1 here)
//   cycle 4 : dsp_b1                  (Stage 2 here)
//   cycle 5 : dsp_adreg / dsp_b2     (Stage 3 here) ← phase_sync_d5 fires
//   cycle 6 : dsp_mreg               (Stage 4 - multiplier)
//   cycle 7 : dsp_preg               (Stage 5 - accumulator, output to tree)
//
// phase_sync is delayed 5 cycles (phase_sync_d5) to align with the first
// valid adreg×b2 product at the start of each phase window.
// Shadow trigger in wrapper = phase_sync_d1 + 5 (MAC) + tree_levels + 1.
// For 256 MACs: +5 + 8 + 1 = +14 cycles. For 4096 MACs: +5 + 12 + 1 = +18 cycles.
module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48,
    parameter int MAC_ID     = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          phase_sync,
    input  logic signed [COEF_WIDTH-1:0]  coef_in,
    input  logic signed [DATA_WIDTH-1:0]  audio_in,    // x[n-m], static during sweep
    output logic signed [ACC_WIDTH-1:0]   preg_out     // partial sum → adder tree
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps
    //    phase_sync_d5 fires when dsp_adreg and dsp_b2 hold the first
    //    valid product of each phase window.
    // =================================---------------------------------------
    // phase_sync delay: 2 (BRAM latency) + 5 (MAC stages) + 1 (accumulate before reset) = 8.
    // This aligns the accumulator reset/load with the first product of the new phase
    // arriving at PREG (stage 5).
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5, phase_sync_d6;
    (* shreg_extract = "no" *) logic phase_sync_d7, phase_sync_d8;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {phase_sync_d1, phase_sync_d2, phase_sync_d3, phase_sync_d4,
             phase_sync_d5, phase_sync_d6, phase_sync_d7, phase_sync_d8} <= '0;
        end else begin
            phase_sync_d1 <= phase_sync;
            phase_sync_d2 <= phase_sync_d1;
            phase_sync_d3 <= phase_sync_d2;
            phase_sync_d4 <= phase_sync_d3;
            phase_sync_d5 <= phase_sync_d4;
            phase_sync_d6 <= phase_sync_d5;
            phase_sync_d7 <= phase_sync_d6;
            phase_sync_d8 <= phase_sync_d7;
        end
    end

    // =================================---------------------------------------
    // 2. STAGE 1: Audio & Coef Registration
    //    audio_in is stable for the entire sweep — register once.
    // =================================---------------------------------------
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

    // =================================---------------------------------------
    // 3. STAGE 2: Pre-Adder (ADREG) & Coef Stage 2 (B1)
    //    Pre-adder doubles: adreg = a1 + a1 = 2*x[n-m]  (matches RTL intent
    //    of fwd+rev paths both carrying x[n-m]).
    // =================================---------------------------------------
    logic signed [DATA_WIDTH:0]   dsp_adreg;
    logic signed [COEF_WIDTH-1:0] dsp_b1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_adreg <= '0;
            dsp_b1    <= '0;
        end else begin
            dsp_adreg <= $signed(dsp_a1) + $signed(dsp_a1);
            dsp_b1    <= coef_out_1;
        end
    end

    // =================================---------------------------------------
    // 4. STAGE 3: B2
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] dsp_b2;

    always_ff @(posedge clk) begin
        if (!rst_n) dsp_b2 <= '0;
        else        dsp_b2 <= dsp_b1;
    end

    // =================================---------------------------------------
    // 5. STAGE 4: DSP48 Multiplier (MREG)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [47:0] dsp_mreg;

    always_ff @(posedge clk) begin
        if (!rst_n) dsp_mreg <= '0;
        else        dsp_mreg <= dsp_adreg * dsp_b2;
    end

    // =================================---------------------------------------
    // 6. STAGE 5: DSP48 Accumulator (PREG)
    //    phase_sync_d5 resets accumulator at start of each phase window.
    //    Standalone accumulation — no cascade input.
    //    Vivado maps as DSP48E2 PREG with ALUMODE=0000 (P = P + M).
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_preg <= '0;
        end else if (phase_sync_d8) begin
            dsp_preg <= dsp_mreg;        // load first product of new phase
        end else begin
            dsp_preg <= dsp_preg + dsp_mreg;  // accumulate
        end
    end

    assign preg_out = dsp_preg;

    // synthesis translate_off
`ifdef SIM_DEBUG
    int mac0_dbg_cnt = 0;
    always_ff @(posedge clk) begin
        if (MAC_ID == 0 && mac0_dbg_cnt < 3) begin
            if (dsp_b2 != 0) begin
                $display("[MAC0 @%0t] coef_in=%0d b1=%0d b2=%0d adreg=%0d mreg=%0d preg=%0d ps8=%b",
                    $time, coef_in, dsp_b1, dsp_b2, dsp_adreg, dsp_mreg, dsp_preg, phase_sync_d8);
                mac0_dbg_cnt <= mac0_dbg_cnt + 1;
            end
        end
    end
`endif
    // synthesis translate_on

endmodule
