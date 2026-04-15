`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24, 
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48, 
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
    
    // Tagging the port itself creates a hard boundary preventing DSP absorption
    (* use_dsp = "no" *) output logic signed [ACC_WIDTH-1:0]  acc_out
);

    // =================================---------------------------------------
    // 1. Local Coefficient ROM 
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];
    // Dummy initialization to force Block RAM inference until .mem files are ready
    initial begin
        for (int k = 0; k < 2048; k++) begin
            coef_rom[k] = '0;
        end
    end
    
    logic signed [COEF_WIDTH-1:0] local_coef;

    always_ff @(posedge clk) begin
        local_coef <= coef_rom[coef_addr];
    end

    // =================================---------------------------------------
    // 2. Audio Cascade Registration
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] fwd_reg, rev_reg;

    always_ff @(posedge clk) begin
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
    // 3. The DSP48E1 Math Core (Strictly Isolated)
    // =================================---------------------------------------
    (* use_dsp = "yes" *) logic signed [DATA_WIDTH:0]  pre_adder;    
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] product_reg;  
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0] local_acc;    

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pre_adder   <= '0;
            product_reg <= '0;
            local_acc   <= '0;
        end else begin
            // STAGE 1: The Pre-Adder (Maps to AD_REG)
            pre_adder <= $signed(fwd_reg) + $signed(rev_reg);
            
            // STAGE 2: The Multiplier (Maps to M_REG)
            product_reg <= pre_adder * local_coef;
            
            // STAGE 3: Local Accumulation
            if (phase_sync) begin
                // Seed the DSP's internal P-register with the new product
                local_acc <= product_reg; 
            end else begin
                // Standard DSP48 internal accumulation
                local_acc <= local_acc + product_reg;
            end
        end
    end

    // =================================---------------------------------------
    // 4. Fabric Cascade Addition (Forced into standard LUTs)
    // =================================---------------------------------------
    (* use_dsp = "no" *) logic signed [ACC_WIDTH-1:0] cascade_sum;
    assign cascade_sum = local_acc + acc_in;

    // By placing this in a completely separate block, Vivado cannot absorb it
    (* use_dsp = "no" *) 
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else if (phase_sync) begin
            // Dump the cascade addition (computed safely in LUTs) down the chain
            acc_out <= cascade_sum;
        end
    end

endmodule