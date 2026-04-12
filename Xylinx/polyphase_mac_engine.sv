`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 32,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 64,
    parameter int MAC_ID     = 0   // Unique ID to load the correct ROM file
)(
    input  logic                      clk,
    input  logic                      rst_n,

    // Phase Control (Broadcast globally from the master controller)
    input  logic                      phase_sync,  // Triggers the start of a 128-cycle phase
    input  logic [10:0]               coef_addr,   // 0 to 2047 (128 cycles * 16 phases)

    // The Folded Audio Cascade (The "U-Shape" Delay Line)
    input  logic signed [DATA_WIDTH-1:0] audio_fwd_in,  // Audio moving New -> Old
    input  logic signed [DATA_WIDTH-1:0] audio_rev_in,  // Audio moving Old -> New
    
    output logic signed [DATA_WIDTH-1:0] audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0] audio_rev_out,

    // The Systolic Accumulator Chain
    input  logic signed [ACC_WIDTH-1:0]  acc_in,
    output logic signed [ACC_WIDTH-1:0]  acc_out
);

    // =================================---------------------------------------
    // 1. Local Coefficient ROM (Inferred as 1x RAMB36 Block RAM)
    // 1,048,576 taps / 256 MACs / 2 (Symmetry) = 2048 coefficients per MAC
    // =================================---------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];
    logic signed [COEF_WIDTH-1:0] local_coef;

    // In a real build, you use $readmemh to load the specific slice of the Sinc filter
    // initial $readmemh($sformatf("sinc_coef_mac_%0d.mem", MAC_ID), coef_rom);

    always_ff @(posedge clk) begin
        local_coef <= coef_rom[coef_addr];
    end

    // =================================---------------------------------------
    // 2. Audio Cascade Registration
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] fwd_reg, rev_reg;

    always_ff @(posedge clk or negedge rst_n) begin
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
    (* use_dsp = "yes" *) logic signed [DATA_WIDTH:0]   pre_adder;    // 33-bit to prevent overflow
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0]  product_reg;
    (* use_dsp = "yes" *) logic signed [ACC_WIDTH-1:0]  local_acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_adder   <= '0;
            product_reg <= '0;
            local_acc   <= '0;
            acc_out     <= '0;
        end else begin
            // STAGE 1: The Pre-Adder (Exploiting Sinc Symmetry to cut silicon in half)
            pre_adder <= $signed(fwd_reg) + $signed(rev_reg);
            
            // STAGE 2: The Multiplier
            product_reg <= pre_adder * local_coef;
            
            // STAGE 3: The Accumulator & Systolic Shift
            if (phase_sync) begin
                // Phase is complete: Dump the local total into the systolic chain
                acc_out   <= local_acc + acc_in;
                // Instantly seed the new phase with the current product
                local_acc <= product_reg; 
            end else begin
                // Accumulate the 128 taps locally
                local_acc <= local_acc + product_reg;
            end
        end
    end
endmodule