`timescale 1ns / 1ps

// Force Vivado to map this entire module into a single DSP48E1 slice
(* use_dsp = "yes" *)
module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24, // Locked to 24 for the 25-bit Pre-Adder limit
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48, // Locked to 48 for the DSP P-Register limit
    parameter int MAC_ID     = 0   
)(
    input  logic                      clk,
    input  logic                      rst_n,

    // Phase Control
    input  logic                      phase_sync, 
    input  logic [10:0]               coef_addr,  

    // The Folded Audio Cascade
    input  logic signed [DATA_WIDTH-1:0] audio_fwd_in,
    input  logic signed [DATA_WIDTH-1:0] audio_rev_in,
    
    output logic signed [DATA_WIDTH-1:0] audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0] audio_rev_out,

    // The Systolic Accumulator Chain
    input  logic signed [ACC_WIDTH-1:0]  acc_in,
    output logic signed [ACC_WIDTH-1:0]  acc_out
);

    // =================================---------------------------------------
    // 1. Local Coefficient ROM 
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];
    logic signed [COEF_WIDTH-1:0] local_coef;

    // STRICTLY SYNCHRONOUS
    always_ff @(posedge clk) begin
        local_coef <= coef_rom[coef_addr];
    end

    // =================================---------------------------------------
    // 2. Audio Cascade Registration
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] fwd_reg, rev_reg;

    // STRICTLY SYNCHRONOUS - No negedge rst_n
    always_ff @(posedge clk) begin
        // We use synchronous reset here if needed, but for datapath 
        // it's safer for DSP inference to just let it pipeline.
        if (!rst_n) begin
            fwd_reg <= '0;
            rev_reg <= '0;
        end else begin
            fwd_reg <= audio_fwd_in;
            rev_reg <= audio_rev_in;
        end
    end
    
    assign audio_fwd_out = fwd_reg;
    assign audio_rev_out = rev_reg;

    // =================================---------------------------------------
    // 3. The DSP48E1 Math Core (Pre-Adder + Multiplier + Accumulator)
    // =================================---------------------------------------
    logic signed [DATA_WIDTH:0]  pre_adder;    // 25-bit
    logic signed [ACC_WIDTH-1:0] product_reg;  // 48-bit (holds 43-bit result)
    logic signed [ACC_WIDTH-1:0] local_acc;    // 48-bit

    // STRICTLY SYNCHRONOUS - No negedge rst_n allowed in DSP math blocks!
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Synchronous resets map perfectly to the DSP's RSTA/RSTM/RSTP pins
            pre_adder   <= '0;
            product_reg <= '0;
            local_acc   <= '0;
            acc_out     <= '0;
        end else begin
            // STAGE 1: The Pre-Adder (Maps to AD_REG)
            pre_adder <= $signed(fwd_reg) + $signed(rev_reg);
            
            // STAGE 2: The Multiplier (Maps to M_REG)
            product_reg <= pre_adder * local_coef;
            
            // STAGE 3: The Accumulator & Systolic Shift (Maps to P_REG)
            if (phase_sync) begin
                acc_out   <= local_acc + acc_in;
                local_acc <= product_reg; 
            end else begin
                local_acc <= local_acc + product_reg;
            end
        end
    end
endmodule