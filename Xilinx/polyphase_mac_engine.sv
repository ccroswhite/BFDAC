`timescale 1ns / 1ps

// Per-MAC polyphase engine for TRUE polyphase interpolation.
//
// Architecture: adder-tree reduction (NO cascade PCIN/PCOUT).
//   Each MAC accumulates independently over its phase window and outputs
//   preg to the polyphase_adder_tree, which sums all NUM_MACS MACs in a
//   pipelined binary tree (log2(NUM_MACS) levels, 12 levels for 4096 MACs).
//   This eliminates the long PCIN/PCOUT routing chain entirely, dramatically improving timing closure.
//
// Audio delivery (audio-window redesign, 2026-08-01): each MAC receives a
// PER-TAP window sample x[n-(TAPS_PER_PHASE*m + t)] on audio_in, CO-TIMED
// with coef_in (the interpolator pipelines both as 3-cycle paths from the
// sweep counter). The audio and coefficient operand pipelines inside this
// module are DEPTH-MATCHED (3 stages each: a1/a2/adreg vs c1/b1/b2) so each
// product pairs the coefficient with its own sample — the previous 2-vs-3
// stage skew was harmless with static audio but wrong for per-tap audio.
//
// Pipeline timing (from coef_addr being issued at the wrapper):
//   cycle 0 : coef_addr issued; window read address in flight
//   cycle 1 : coef BRAM read latency  (stage 1 inside wrapper)
//   cycle 2 : coef BRAM DO_REG        (stage 2 inside wrapper) → coef_in
//             valid, audio_in (win_q2) valid — co-timed
//   cycle 3 : dsp_a1 / coef_out_1    (Stage 1 here)
//   cycle 4 : dsp_a2 / dsp_b1        (Stage 2 here)
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
    input  logic signed [DATA_WIDTH-1:0]  audio_in,    // per-tap window sample, co-timed with coef_in
    output logic signed [ACC_WIDTH-1:0]   preg_out     // partial sum → adder tree
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps
    //    phase_sync_d5 fires when dsp_adreg and dsp_b2 hold the first
    //    valid product of each phase window.
    // =================================---------------------------------------
    // Load-tap accounting (2026-08-01 audio-window bring-up, TB-verified):
    //   Products of master-sweep cycle T reach PREG at the end of T+8.
    //   phase_sync received here is the WRAPPER's phase_sync_d1, i.e. already
    //   high during T_boundary+2. Delayed 6 more (d6, high during T_b+8) it
    //   gates the load exactly as the NEW phase's first product (master T_b)
    //   sits in MREG — each accumulation window is then precisely one phase
    //   (taps 0..TPP-1). Was d8: two cycles late, grouping each output as
    //   taps [2..17] straddling the phase boundary — masked by the old
    //   static-audio collapse, exposed by tb_fir_window (bit-exact).
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

    // =================================---------------------------------------
    // 2. STAGE 1: Audio & Coef Registration (per-tap, both change every cycle)
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
    // 3. STAGE 2: Audio A2 & Coef B1 (DSP48E2 A1→A2 / B1 registers)
    // =================================---------------------------------------
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

    // =================================---------------------------------------
    // 4. STAGE 3: Pre-Adder (ADREG) & B2 — operands now depth-matched.
    //    Pre-adder doubles: adreg = a2 + a2 = 2*x (legacy gain; hook for a
    //    future symmetric fwd+rev coefficient fold: adreg = x_fwd + x_rev).
    // =================================---------------------------------------
    logic signed [DATA_WIDTH:0]   dsp_adreg;
    logic signed [COEF_WIDTH-1:0] dsp_b2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_adreg <= '0;
            dsp_b2    <= '0;
        end else begin
            dsp_adreg <= $signed(dsp_a2) + $signed(dsp_a2);
            dsp_b2    <= dsp_b1;
        end
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
    //    phase_sync_d6 loads (resets) the accumulator at each phase boundary.
    //    Standalone accumulation — no cascade input.
    //    Vivado maps as DSP48E2 PREG with ALUMODE=0000 (P = P + M).
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_preg <= '0;
        end else if (phase_sync_d6) begin
            dsp_preg <= dsp_mreg;        // load first product of new phase
        end else begin
            dsp_preg <= dsp_preg + dsp_mreg;  // accumulate
        end
    end

    assign preg_out = dsp_preg;

`ifdef SIM
    int dbg_acc_count = 0;   // decl-init: no separate initial block
    int dbg_phase_num = 0;   // (always_ff forbids a second procedural driver)
    always_ff @(posedge clk) begin
        if (MAC_ID == 0) begin
            if (!rst_n) begin
                dbg_acc_count <= 0;
                dbg_phase_num <= 0;
            end else if (phase_sync_d6) begin
`ifdef SIM_DEBUG
                if (dbg_acc_count > 0)
                    $display("[MAC0_DBG] phase %0d finished: %0d taps, preg=0x%0h",
                             dbg_phase_num, dbg_acc_count, dsp_preg);
`endif
                dbg_acc_count <= 1;
                dbg_phase_num <= dbg_phase_num + 1;
            end else begin
                dbg_acc_count <= dbg_acc_count + 1;
            end
        end
    end
`endif // SIM

endmodule
