`timescale 1ns / 1ps

// Per-MAC polyphase engine. Each instance owns its own 2K x 18b coefficient
// ROM, which Vivado will place physically adjacent to this MAC's DSP48E1 --
// giving dedicated short routes from BRAM to DSP B-input. This locality is
// what allows the 256-deep cascade to meet 357 MHz timing.
//
// NOTE: This is the baseline architecture. The "shared coef BRAM" variant
// (fir_polyphase_stereo with coef_rom_shared at the wrapper level) was tried
// and rejected because shared BRAMs introduced cross-channel routing
// tension that prevented timing closure (WNS -10 ns).
module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48,
    parameter int MAC_ID     = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          phase_sync,
    input  logic [10:0]                   coef_addr,
    input  logic signed [DATA_WIDTH-1:0]  audio_fwd_in,
    input  logic signed [DATA_WIDTH-1:0]  audio_rev_in,
    output logic signed [DATA_WIDTH-1:0]  audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0]  audio_rev_out,
    input  logic signed [ACC_WIDTH-1:0]   pcin,
    output logic signed [ACC_WIDTH-1:0]   pcout
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps (6 cycles to guarantee BRAM & DSP isolation)
    // =================================---------------------------------------
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5, phase_sync_d6;

    always_ff @(posedge clk) begin
        phase_sync_d1 <= phase_sync;
        phase_sync_d2 <= phase_sync_d1;
        phase_sync_d3 <= phase_sync_d2;
        phase_sync_d4 <= phase_sync_d3;
        phase_sync_d5 <= phase_sync_d4;
        phase_sync_d6 <= phase_sync_d5;
    end

    // =================================---------------------------------------
    // 2. STAGE 1: Local Coef ROM Read & Audio Registration (Fabric)
    //    The coef_rom is local to this MAC -- Vivado will place it
    //    immediately adjacent to the DSP48E1 for short, dedicated routes.
    // =================================---------------------------------------
    (* rom_style = "block" *) logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];

    initial begin
        for (int k = 0; k < 2048; k++) coef_rom[k] = '0;
    end

    logic signed [COEF_WIDTH-1:0] coef_out_1;
    logic signed [DATA_WIDTH-1:0] fwd_reg_1, rev_reg_1;

    always_ff @(posedge clk) begin
        fwd_reg_1  <= audio_fwd_in;
        rev_reg_1  <= audio_rev_in;
        coef_out_1 <= coef_rom[coef_addr]; // Local ROM read
    end

    // ------------------------------------------------------------------------
    // NOTE (CREG alignment, 2026-05-11):
    //   The cascade input below goes through a register (pcin_creg) which
    //   Vivado packs into the DSP48E1's internal CREG. That makes the cascade
    //   propagate at 2 cycles/hop instead of 1. The audio shift register must
    //   match -- so audio_fwd_out / audio_rev_out are sourced from the SECOND
    //   audio pipeline register (fwd_reg_2 / rev_reg_2) rather than the first.
    //   The companion change in fir_polyphase_interpolator.sv doubles the
    //   per-hop pipeline depth of cascade_coef_addr and cascade_phase_sync to
    //   keep all four chain signals at 2 cycles per MAC.
    // ------------------------------------------------------------------------
    assign audio_fwd_out = fwd_reg_2;
    assign audio_rev_out = rev_reg_2;

    // =================================---------------------------------------
    // 3. STAGE 2: BRAM DO_REG & Audio Delay (Fabric)
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_out_2;
    logic signed [DATA_WIDTH-1:0] fwd_reg_2, rev_reg_2;

    always_ff @(posedge clk) begin
        fwd_reg_2  <= fwd_reg_1;
        rev_reg_2  <= rev_reg_1;
        coef_out_2 <= coef_out_1; // Vivado maps this safely to BRAM DO_REG
    end

    // =================================---------------------------------------
    // 4. STAGE 3: DSP48 Input Pins (A1, DREG, B1)
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] dsp_b1;
    logic signed [DATA_WIDTH-1:0] dsp_a1, dsp_d;

    always_ff @(posedge clk) begin
        dsp_a1 <= fwd_reg_2;
        dsp_d  <= rev_reg_2;
        dsp_b1 <= coef_out_2;
    end

    // =================================---------------------------------------
    // 5. STAGE 4: DSP48 Pre-Adder (ADREG) & B2
    // =================================---------------------------------------
    logic signed [DATA_WIDTH:0]   dsp_adreg;
    logic signed [COEF_WIDTH-1:0] dsp_b2;

    always_ff @(posedge clk) begin
        dsp_adreg <= $signed(dsp_a1) + $signed(dsp_d); // ADREG
        dsp_b2    <= dsp_b1;                           // B2
    end

    // =================================---------------------------------------
    // 6. STAGE 5: DSP48 Multiplier (MREG)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [47:0] dsp_mreg;

    always_ff @(posedge clk) begin
        dsp_mreg <= dsp_adreg * dsp_b2; // MREG
    end

    // =================================---------------------------------------
    // 7a. STAGE 6a: DSP48 C-Input Register (CREG)
    //
    //   This register pipelines the cascade input. Vivado packs it into the
    //   DSP48E1's internal CREG (zero fabric cost) when the C-input cascade
    //   path is used -- which happens whenever consecutive DSPs are not
    //   placed PCIN/PCOUT-adjacent (e.g., across clock-region boundaries).
    //   With 256 DSPs per chain spanning ~12 clock regions, ~10-15 cascade
    //   hops MUST cross region boundaries, and without CREG those C-input
    //   paths cannot meet timing (C->P arc alone is 1.325 ns on Artix-7).
    //   With CREG, the long C-input route now terminates at a flop inside
    //   the destination DSP, which has ~0.1 ns setup -- guaranteed close.
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] pcin_creg;

    always_ff @(posedge clk) begin
        pcin_creg <= pcin;
    end

    // =================================---------------------------------------
    // 7b. STAGE 6b: DSP48 Accumulator (PREG)
    //
    //   phase_sync_d6 alignment is unchanged: it still fires the cycle that
    //   dsp_mreg holds the first product of a new filter sweep. Because the
    //   chain coef_addr / phase_sync / audio / cascade signals all shift at
    //   the same per-hop rate (2 cycles/hop), the relative timing inside
    //   each MAC is identical to the pre-CREG design.
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [47:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (phase_sync_d6) begin
            dsp_preg <= dsp_mreg;
        end else begin
            dsp_preg <= dsp_mreg + pcin_creg;
        end
    end

    assign pcout = dsp_preg;

endmodule
