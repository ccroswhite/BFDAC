`timescale 1ns / 1ps

// Per-MAC polyphase engine for TRUE polyphase interpolation.
//
// Audio delivery: each MAC receives x[n-m] as a STATIC direct input
// (audio_in) from the interpolator's audio shift register, which is
// pre-loaded from the audio BRAM at new_sample_valid. There is NO audio
// cascade between MACs -- the audio input is fixed for the entire 2048-
// cycle coefficient sweep.
//
// Accumulator cascade (PCIN/PCOUT) is preserved for the DSP chain.
//
// Pipeline timing (from coef_addr being issued at the wrapper):
//   cycle 0 : coef_addr issued; audio_in valid and stable
//   cycle 1 : coef BRAM read latency (stage 1 inside wrapper)
//   cycle 2 : coef BRAM DO_REG (stage 2 inside wrapper) → coef_in valid
//   cycle 3 : dsp_a1 / coef_out_1  (Stage 1 here)
//   cycle 4 : dsp_b1               (Stage 2 here)
//   cycle 5 : dsp_adreg / dsp_b2   (Stage 3 here) ← phase_sync_d5 fires
//   cycle 6 : dsp_mreg             (Stage 4 - multiplier)
//   cycle 7 : dsp_preg             (Stage 5 - accumulator)
//
// phase_sync is delayed 5 cycles (phase_sync_d5) to align with
// the first valid adreg×b2 product at the start of each phase window.
// (Previously 6 cycles; audio cascade removed saves 2 stages, coef
//  pipeline shortened by 1 stage → net delay = 5.)
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
    input  logic signed [ACC_WIDTH-1:0]   pcin,
    output logic signed [ACC_WIDTH-1:0]   pcout
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps
    //    phase_sync_d5 fires when dsp_adreg and dsp_b2 hold the first
    //    valid product of each phase window.
    // =================================---------------------------------------
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            {phase_sync_d1, phase_sync_d2, phase_sync_d3,
             phase_sync_d4, phase_sync_d5} <= '0;
        end else begin
            phase_sync_d1 <= phase_sync;
            phase_sync_d2 <= phase_sync_d1;
            phase_sync_d3 <= phase_sync_d2;
            phase_sync_d4 <= phase_sync_d3;
            phase_sync_d5 <= phase_sync_d4;
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
    // 6a. STAGE 5a: DSP C-Input Register (CREG)
    //    Pipelines cascade input; Vivado packs into DSP internal CREG.
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] pcin_creg;

    always_ff @(posedge clk) begin
        if (!rst_n) pcin_creg <= '0;
        else        pcin_creg <= pcin;
    end

    // =================================---------------------------------------
    // 6b. STAGE 5b: DSP48 Accumulator (PREG)
    //    phase_sync_d5 resets the accumulator at the start of each phase.
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [47:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_preg <= '0;
        end else if (phase_sync_d5) begin
            dsp_preg <= dsp_mreg;
        end else begin
            dsp_preg <= dsp_mreg + pcin_creg;
        end
    end

    assign pcout = dsp_preg;

    // synthesis translate_off
    always_ff @(posedge clk) begin
`ifdef SIM_DEBUG
        if (MAC_ID == 0) begin
            if (dsp_b2 != 0)
                $display("[MAC0_COEF_NZ @%0t] psync5=%0b coef=%0d audio=%0d mreg=%0d preg=%0d",
                    $time, phase_sync_d5, dsp_b2, dsp_adreg, dsp_mreg, dsp_preg);
        end
`endif
    end
    // synthesis translate_on

endmodule
