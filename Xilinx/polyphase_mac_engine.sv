`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 64, // Hybrid: 48-bit DSP + 16-bit CARRY4 Fabric
    parameter int MAC_ID     = 0
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Phase Control
    input  logic                               phase_sync,
    input  logic [10:0]                        coef_addr,

    // The Folded Audio Cascade
    input  logic signed [DATA_WIDTH-1:0]       audio_fwd_in,
    input  logic signed [DATA_WIDTH-1:0]       audio_rev_in,
    output logic signed [DATA_WIDTH-1:0]       audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0]       audio_rev_out,

    // The Systolic Accumulator Chain
    input  logic signed [ACC_WIDTH-1:0]        acc_in,
    output logic signed [ACC_WIDTH-1:0]        acc_out,
    output logic                               valid_out
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps (Matches the 6-stage DSP latency)
    // =================================---------------------------------------
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5, phase_sync_d6;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase_sync_d1 <= 1'b0; phase_sync_d2 <= 1'b0; phase_sync_d3 <= 1'b0;
            phase_sync_d4 <= 1'b0; phase_sync_d5 <= 1'b0; phase_sync_d6 <= 1'b0;
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
    // 2. STAGE 1 & 2: RAM Array Read & Audio Registration
    // =================================---------------------------------------
    (* rom_style = "block" *) logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];

    initial begin
        for (int k = 0; k < 2048; k++) coef_rom[k] = '0;
    end

    logic signed [COEF_WIDTH-1:0] coef_out_1, coef_out_2;
    logic signed [DATA_WIDTH-1:0] fwd_reg_1, rev_reg_1;
    logic signed [DATA_WIDTH-1:0] fwd_reg_2, rev_reg_2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fwd_reg_1 <= '0; rev_reg_1 <= '0;
            fwd_reg_2 <= '0; rev_reg_2 <= '0;
            coef_out_1 <= '0; coef_out_2 <= '0;
        end else begin
            fwd_reg_1  <= audio_fwd_in;
            rev_reg_1  <= audio_rev_in;
            coef_out_1 <= coef_rom[coef_addr];
            
            fwd_reg_2  <= fwd_reg_1;
            rev_reg_2  <= rev_reg_1;
            coef_out_2 <= coef_out_1;
        end
    end

    assign audio_fwd_out = fwd_reg_1;
    assign audio_rev_out = rev_reg_1;

    // =================================---------------------------------------
    // 3. DSP48E1 HARD SILICON PIPELINE (Stages 3 through 6)
    // =================================---------------------------------------
    // By wrapping this in a single synchronous block with resets, Vivado's
    // inference engine will natively map this to the DSP48E1's internal registers:
    // A1/D/B1 -> ADREG/B2 -> MREG -> PREG.
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] dsp_a1, dsp_d;
    logic signed [COEF_WIDTH-1:0] dsp_b1, dsp_b2;
    (* use_dsp = "yes" *) logic signed [DATA_WIDTH:0] dsp_adreg;
    (* use_dsp = "yes" *) logic signed [47:0]         dsp_mreg, dsp_preg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_a1    <= '0;
            dsp_d     <= '0;
            dsp_b1    <= '0;
            dsp_adreg <= '0;
            dsp_b2    <= '0;
            dsp_mreg  <= '0;
            dsp_preg  <= '0;
        end else begin
            // STAGE 3: DSP48 Input Pins
            dsp_a1 <= fwd_reg_2;
            dsp_d  <= rev_reg_2;
            dsp_b1 <= coef_out_2;

            // STAGE 4: Pre-Adder (ADREG) and B2 cascade
            dsp_adreg <= $signed(dsp_a1) + $signed(dsp_d);
            dsp_b2    <= dsp_b1;

            // STAGE 5: Multiplier (MREG)
            dsp_mreg <= dsp_adreg * dsp_b2;

            // STAGE 6: P-Register (PREG) - Final DSP boundary
            dsp_preg <= dsp_mreg;
        end
    end

    // =================================---------------------------------------
    // 4. STAGE 7: THE 64-BIT CARRY4 FABRIC ACCUMULATOR
    // =================================---------------------------------------
    (* use_dsp = "no" *) logic signed [ACC_WIDTH-1:0] cascade_adder;

    // Combinational 64-bit addition (Maps to exactly 16 CARRY4 primitives)
    assign cascade_adder = acc_in + $signed(dsp_preg);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else begin
            if (phase_sync_d6) begin
                // Dump accumulator and restart the new phase securely
                acc_out <= $signed(dsp_preg);
            end else begin
                // Standard CARRY4 accumulation
                acc_out <= cascade_adder;
            end
        end
    end

    // The valid flag pulses exactly when the final accumulated sum is available
    // and ready to be latched by the downstream logic.
    assign valid_out = phase_sync_d6;

endmodule