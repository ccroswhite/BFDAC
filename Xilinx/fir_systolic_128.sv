`timescale 1ns / 1ps

module fir_systolic_128 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               enable,
    
    input  logic signed [24:0] audio_in,
    input  logic signed [17:0] coeffs_in [0:127],
    
    output logic signed [47:0] fir_out,
    output logic               fir_out_valid
);

    // =================================---------------------------------------
    // 1. Pipeline Register Arrays
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [24:0] a_reg [0:127];
    (* use_dsp = "yes" *) logic signed [17:0] b_reg [0:127];
    (* use_dsp = "yes" *) logic signed [42:0] m_reg [0:127];
    (* use_dsp = "yes" *) logic signed [47:0] p_reg [0:127];

    // =================================---------------------------------------
    // 2. The 2-Stage Fabric Crossover Registers (Bridge the Columns)
    // =================================---------------------------------------
    // Stage 1
    (* dont_touch = "yes" *) logic signed [24:0] a_cross_s1 [1:3];
    (* dont_touch = "yes" *) logic signed [47:0] p_cross_s1 [1:3];
    (* dont_touch = "yes" *) logic               sync_cross_s1 [1:3];
    
    // Stage 2
    (* dont_touch = "yes" *) logic signed [24:0] a_cross_s2 [1:3];
    (* dont_touch = "yes" *) logic signed [47:0] p_cross_s2 [1:3];
    (* dont_touch = "yes" *) logic               sync_cross_s2 [1:3];

    logic signed [17:0] b_delay_1 [32:127];
    logic signed [17:0] b_delay_2 [64:127];
    logic signed [17:0] b_delay_3 [96:127];

    // =================================---------------------------------------
    // 3. The Wavefront Synchronizer
    // =================================---------------------------------------
    logic [6:0]         cycle_count;
    logic               sync_flag [0:127];
    logic signed [47:0] integrated_audio;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < 128; i++) begin
                a_reg[i] <= '0; b_reg[i] <= '0;
                m_reg[i] <= '0; p_reg[i] <= '0;
                sync_flag[i] <= 1'b0;
            end
            for (int i=32; i<128; i++) b_delay_1[i] <= '0;
            for (int i=64; i<128; i++) b_delay_2[i] <= '0;
            for (int i=96; i<128; i++) b_delay_3[i] <= '0;
            
            for (int i=1; i<=3; i++) begin
                a_cross_s1[i] <= '0; p_cross_s1[i] <= '0; sync_cross_s1[i] <= 1'b0;
                a_cross_s2[i] <= '0; p_cross_s2[i] <= '0; sync_cross_s2[i] <= 1'b0;
            end
            
            cycle_count <= '0; integrated_audio <= '0;
            fir_out <= '0; fir_out_valid <= 1'b0;
            
        end else if (enable) begin

            // =================================-------------------------------
            // STAGE 1: Audio Shift & 2-Stage Crossovers
            // =================================-------------------------------
            a_reg[0] <= audio_in;
            for (int i = 1; i < 32; i++) a_reg[i] <= a_reg[i-1];
            a_cross_s1[1] <= a_reg[31]; a_cross_s2[1] <= a_cross_s1[1]; a_reg[32] <= a_cross_s2[1];
            
            for (int i = 33; i < 64; i++) a_reg[i] <= a_reg[i-1];
            a_cross_s1[2] <= a_reg[63]; a_cross_s2[2] <= a_cross_s1[2]; a_reg[64] <= a_cross_s2[2];
            
            for (int i = 65; i < 96; i++) a_reg[i] <= a_reg[i-1];
            a_cross_s1[3] <= a_reg[95]; a_cross_s2[3] <= a_cross_s1[3]; a_reg[96] <= a_cross_s2[3];
            
            for (int i = 97; i < 128; i++) a_reg[i] <= a_reg[i-1];

            // =================================-------------------------------
            // STAGE 2: Progressive Coefficient Delays (Add extra cycles for 2-stage bridge)
            // =================================-------------------------------
            // We must add 1 extra cycle of delay to b_delay_1, 2 to b_delay_2, and 3 to b_delay_3 
            // to perfectly match the new 2-stage audio/accumulator crossovers.
            // For simplicity, we just register them an extra time.
            
            for (int i = 32; i < 128; i++) b_delay_1[i] <= coeffs_in[i];
            for (int i = 64; i < 128; i++) b_delay_2[i] <= b_delay_1[i];
            for (int i = 96; i < 128; i++) b_delay_3[i] <= b_delay_2[i];

            for (int i = 0;  i < 32;  i++) b_reg[i] <= coeffs_in[i];
            for (int i = 32; i < 64;  i++) b_reg[i] <= b_delay_1[i]; // +1 cycle
            for (int i = 64; i < 96;  i++) b_reg[i] <= b_delay_2[i]; // +2 cycles
            for (int i = 96; i < 128; i++) b_reg[i] <= b_delay_3[i]; // +3 cycles

            // =================================-------------------------------
            // STAGE 3: Multipliers
            // =================================-------------------------------
            for (int i = 0; i < 128; i++) m_reg[i] <= a_reg[i] * b_reg[i];

            // =================================-------------------------------
            // STAGE 4: The Segmented Accumulator Cascade (2-Stage Crossovers)
            // =================================-------------------------------
            p_reg[0] <= m_reg[0];
            for (int i = 1; i < 32; i++) p_reg[i] <= p_reg[i-1] + m_reg[i];
            p_cross_s1[1] <= p_reg[31]; p_cross_s2[1] <= p_cross_s1[1]; p_reg[32] <= p_cross_s2[1] + m_reg[32];
            
            for (int i = 33; i < 64; i++) p_reg[i] <= p_reg[i-1] + m_reg[i];
            p_cross_s1[2] <= p_reg[63]; p_cross_s2[2] <= p_cross_s1[2]; p_reg[64] <= p_cross_s2[2] + m_reg[64];
            
            for (int i = 65; i < 96; i++) p_reg[i] <= p_reg[i-1] + m_reg[i];
            p_cross_s1[3] <= p_reg[95]; p_cross_s2[3] <= p_cross_s1[3]; p_reg[96] <= p_cross_s2[3] + m_reg[96];
            
            for (int i = 97; i < 128; i++) p_reg[i] <= p_reg[i-1] + m_reg[i];

            // =================================-------------------------------
            // STAGE 5: The Segmented Wavefront Integrator (2-Stage Crossovers)
            // =================================-------------------------------
            if (cycle_count == 7'd99) begin
                sync_flag[0] <= 1'b1; cycle_count  <= '0;
            end else begin
                sync_flag[0] <= 1'b0; cycle_count  <= cycle_count + 1'b1;
            end

            for (int i = 1; i < 32; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[1] <= sync_flag[31]; sync_cross_s2[1] <= sync_cross_s1[1]; sync_flag[32] <= sync_cross_s2[1];
            
            for (int i = 33; i < 64; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[2] <= sync_flag[63]; sync_cross_s2[2] <= sync_cross_s1[2]; sync_flag[64] <= sync_cross_s2[2];
            
            for (int i = 65; i < 96; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[3] <= sync_flag[95]; sync_cross_s2[3] <= sync_cross_s1[3]; sync_flag[96] <= sync_cross_s2[3];
            
            for (int i = 97; i < 128; i++) sync_flag[i] <= sync_flag[i-1];

            if (sync_flag[127]) begin
                fir_out <= integrated_audio + p_reg[127];
                fir_out_valid <= 1'b1;
                integrated_audio <= '0;
            end else begin
                integrated_audio <= integrated_audio + p_reg[127];
                fir_out_valid <= 1'b0;
            end
        end
    end
endmodule