`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24, 
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 96, // Upgraded to 96-bit
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
    initial begin
        for (int k = 0; k < 2048; k++) coef_rom[k] = '0;
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
    // 3. Dual DSP48E1 Instantiation (96-Bit Cascade)
    // =================================---------------------------------------
    
    // Internal cascade wires
    logic [47:0] pcout_lower_to_upper;
    logic        carry_lower_to_upper;
    
    // Output wires from DSPs
    logic [47:0] p_out_lower;
    logic [47:0] p_out_upper;

    // OpMode Control logic based on phase_sync
    // When phase_sync is HIGH, load current product (OpMode = 0000101)
    // When phase_sync is LOW, accumulate (OpMode = 0100101 for lower, 1010000 for upper)
    logic [6:0] opmode_lower;
    logic [6:0] opmode_upper;
    
    always_comb begin
        if (phase_sync) begin
            opmode_lower = 7'b0000101; // Mult + 0
            opmode_upper = 7'b0000000; // Pass 0
        end else begin
            opmode_lower = 7'b0100101; // Mult + P
            opmode_upper = 7'b1010000; // P + PCIN (Cascade)
        end
    end

    // --- DSP A: Lower 48 Bits (Pre-Adder & Multiplier) ---
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("TRUE"),
        .USE_MULT("MULTIPLY"), .USE_SIMD("ONE48"),
        .ADREG(1), .ALUMODEREG(1), .AREG(1), .BREG(1), .CREG(1), .DREG(1), .MREG(1), .PREG(1), .OPMODEREG(1)
    ) DSP_LOWER (
        .CLK(clk),
        .ALUMODE(4'b0000),    // Add
        .OPMODE(opmode_lower),
        .INMODE(5'b10100),    // D + A (Pre-adder enabled)
        
        // Data Ports (Sign extended to match primitive widths)
        .A({ {6{fwd_reg[DATA_WIDTH-1]}}, fwd_reg }), // 30-bit A
        .D({ {1{rev_reg[DATA_WIDTH-1]}}, rev_reg }), // 25-bit D
        .B(local_coef),                              // 18-bit B
        .C(48'h0),
        
        // Cascade & Outputs
        .P(p_out_lower),
        .PCOUT(pcout_lower_to_upper),
        .CARRYCASCOUT(carry_lower_to_upper),
        
        // Tie-offs and Enables
        .CEA1(1'b0), .CEA2(1'b1), .CEAD(1'b1), .CEALUMODE(1'b1), .CEB1(1'b0), .CEB2(1'b1),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b1), .CED(1'b1), .CEINMODE(1'b0), .CEM(1'b1), .CEP(1'b1),
        .RSTA(~rst_n), .RSTALLCARRYIN(~rst_n), .RSTALUMODE(~rst_n), .RSTB(~rst_n), .RSTC(~rst_n),
        .RSTCTRL(~rst_n), .RSTD(~rst_n), .RSTINMODE(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .CARRYIN(1'b0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .PCIN(48'h0)
    );

    // --- DSP B: Upper 48 Bits (ALU Extension) ---
    DSP48E1 #(
        .A_INPUT("DIRECT"), .B_INPUT("DIRECT"), .USE_DPORT("FALSE"),
        .USE_MULT("NONE"), .USE_SIMD("ONE48"), // No multiplication here
        .ALUMODEREG(1), .AREG(0), .BREG(0), .CREG(1), .MREG(0), .PREG(1), .OPMODEREG(1)
    ) DSP_UPPER (
        .CLK(clk),
        .ALUMODE(4'b0000),     // Add
        .OPMODE(opmode_upper), // PCIN + P
        .INMODE(5'b00000),
        
        // Data Ports (Not used for math, tied off)
        .A(30'h0), .D(25'h0), .B(18'h0), .C(48'h0),
        
        // Cascade Inputs from DSP A
        .PCIN(pcout_lower_to_upper),
        .CARRYCASCIN(carry_lower_to_upper),
        .MULTSIGNIN(p_out_lower[47]), // Sign extension cascade
        
        // Outputs
        .P(p_out_upper),
        .PCOUT(), .CARRYCASCOUT(),
        
        // Tie-offs and Enables
        .CEA1(1'b0), .CEA2(1'b0), .CEAD(1'b0), .CEALUMODE(1'b1), .CEB1(1'b0), .CEB2(1'b0),
        .CEC(1'b0), .CECARRYIN(1'b0), .CECTRL(1'b1), .CED(1'b0), .CEINMODE(1'b0), .CEM(1'b0), .CEP(1'b1),
        .RSTA(~rst_n), .RSTALLCARRYIN(~rst_n), .RSTALUMODE(~rst_n), .RSTB(~rst_n), .RSTC(~rst_n),
        .RSTCTRL(~rst_n), .RSTD(~rst_n), .RSTINMODE(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
        .CARRYIN(1'b0)
    );

    // =================================---------------------------------------
    // 4. Fabric Cascade Addition
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] cascade_sum;
    assign cascade_sum = {p_out_upper, p_out_lower} + acc_in;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else if (phase_sync) begin
            acc_out <= cascade_sum;
        end
    end

endmodule