`timescale 1ns / 1ps

// 1. THE FIREWALL: Forbid Vivado from flattening and cross-optimizing boundaries
// (* keep_hierarchy = "yes" *) 
module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48,
    parameter int MAC_ID     = 0
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 phase_sync,
    input  logic [10:0]          coef_addr,
    input  logic signed [DATA_WIDTH-1:0] audio_fwd_in,
    input  logic signed [DATA_WIDTH-1:0] audio_rev_in,
    output logic signed [DATA_WIDTH-1:0] audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0] audio_rev_out,
    input  logic signed [ACC_WIDTH-1:0]  pcin,
    output logic signed [ACC_WIDTH-1:0]  pcout
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
    // 2. STAGE 1: RAM Array Read & Audio Registration (Fabric)
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
        coef_out_1 <= coef_rom[coef_addr]; // RAM Matrix Read
    end

    assign audio_fwd_out = fwd_reg_1;
    assign audio_rev_out = rev_reg_1;

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
    // 7. STAGE 6: DSP48 Accumulator (PREG)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [47:0] dsp_preg;

    always_ff @(posedge clk) begin
        if (phase_sync_d6) begin           
            dsp_preg <= dsp_mreg;                
        end else begin
            dsp_preg <= dsp_mreg + pcin;         
        end
    end

    assign pcout = dsp_preg;

endmodule