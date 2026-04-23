`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 96,
    parameter int MAC_ID     = 0
)(
    input  logic                  clk,
    input  logic                  rst_n,
    
    // Phase Control
    input  logic                  phase_sync,
    input  logic [10:0]           coef_addr,
    
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

    // Dummy initialization to force Block RAM inference until .mem files are ready
    initial begin
        for (int k = 0; k < 2048; k++) begin
            coef_rom[k] = '0;
        end
    end
    
    logic signed [COEF_WIDTH-1:0] local_coef = '0;

    always_ff @(posedge clk) begin
        local_coef <= coef_rom[coef_addr];
    end

    // =================================---------------------------------------
    // 2. Audio Cascade Registration
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] fwd_reg = '0;
    logic signed [DATA_WIDTH-1:0] rev_reg = '0;

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
    // 3. The Math Core (DSP Multiplier + Fabric Accumulator)
    // =================================---------------------------------------
    
    // Force the heavy multiplication into a single DSP48E1 slice
    (* use_dsp = "yes" *) logic signed [DATA_WIDTH:0]  pre_adder = '0;
    (* use_dsp = "yes" *) logic signed [47:0]          product_reg = '0;
    
    // Force the 96-bit accumulation OUT of the DSP and into the CARRY4 fabric
    // to completely eliminate column-boundary routing failures.
    (* use_dsp = "no" *)  logic signed [ACC_WIDTH-1:0] local_acc = '0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pre_adder   <= '0;
            product_reg <= '0;
            local_acc   <= '0;
        end else begin
            // STAGE 1: The Pre-Adder
            pre_adder <= $signed(fwd_reg) + $signed(rev_reg);
            
            // STAGE 2: The Multiplier (Yields 48-bit product)
            product_reg <= pre_adder * local_coef;
            
            // STAGE 3: Local Accumulation (96-bit Fabric LUTs)
            if (phase_sync) begin
                // Seed the accumulator with the new product (automatically sign-extends to 96 bits)
                local_acc <= product_reg;
            end else begin
                // Standard internal accumulation
                local_acc <= local_acc + product_reg;
            end
        end
    end

    // =================================---------------------------------------
    // 4. Fabric Cascade Addition (The Systolic Highway)
    // =================================---------------------------------------
    (* use_dsp = "no" *) logic signed [ACC_WIDTH-1:0] cascade_sum;

    // Add the local 96-bit sum to the 96-bit sum passed down from the previous MAC
    assign cascade_sum = local_acc + acc_in;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else if (phase_sync) begin
            // Dump the final cascade addition safely down the chain
            acc_out <= cascade_sum;
        end
    end

endmodule