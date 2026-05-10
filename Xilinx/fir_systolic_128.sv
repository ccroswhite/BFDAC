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
    // 1. The 2-Stage Fabric Crossover Registers (Bridge the Columns)
    // =================================---------------------------------------
    // Stage 1
    (* dont_touch = "yes" *) logic signed [47:0] p_cross_s1 [1:3];
    (* dont_touch = "yes" *) logic               sync_cross_s1 [1:3];

    // Stage 2
    (* dont_touch = "yes" *) logic signed [47:0] p_cross_s2 [1:3];
    (* dont_touch = "yes" *) logic               sync_cross_s2 [1:3];

    // =================================---------------------------------------
    // 2. The Wavefront Synchronizer & Crossover Logic
    // =================================---------------------------------------
    logic [6:0]         cycle_count;
    logic               sync_flag [0:127];
    logic signed [47:0] integrated_audio;
    logic signed [47:0] p_reg [0:127];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 1; i <= 3; i++) begin
                p_cross_s1[i] <= '0; p_cross_s2[i] <= '0;
                sync_cross_s1[i] <= 1'b0; sync_cross_s2[i] <= 1'b0;
            end
            cycle_count <= '0;
            integrated_audio <= '0;
            fir_out <= '0;
            fir_out_valid <= 1'b0;
            for (int i = 0; i < 128; i++) sync_flag[i] <= 1'b0;
        end else if (enable) begin
            
            // Trigger the wavefront
            if (cycle_count == 7'd99) begin
                sync_flag[0] <= 1'b1;
                cycle_count  <= '0;
            end else begin
                sync_flag[0] <= 1'b0;
                cycle_count  <= cycle_count + 1'b1;
            end

            // Sync Cascade & Crossovers
            for (int i = 1; i < 32; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[1] <= sync_flag[31]; sync_cross_s2[1] <= sync_cross_s1[1]; sync_flag[32] <= sync_cross_s2[1];

            for (int i = 33; i < 64; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[2] <= sync_flag[63]; sync_cross_s2[2] <= sync_cross_s1[2]; sync_flag[64] <= sync_cross_s2[2];

            for (int i = 65; i < 96; i++) sync_flag[i] <= sync_flag[i-1];
            sync_cross_s1[3] <= sync_flag[95]; sync_cross_s2[3] <= sync_cross_s1[3]; sync_flag[96] <= sync_cross_s2[3];

            for (int i = 97; i < 128; i++) sync_flag[i] <= sync_flag[i-1];

            // Data Crossovers
            p_cross_s1[1] <= p_reg[31]; p_cross_s2[1] <= p_cross_s1[1];
            p_cross_s1[2] <= p_reg[63]; p_cross_s2[2] <= p_cross_s1[2];
            p_cross_s1[3] <= p_reg[95]; p_cross_s2[3] <= p_cross_s1[3];

            // Final Integrator
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

    // =================================---------------------------------------
    // 3. THE NUCLEAR OPTION: Direct DSP48E1 Primitive Array
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < 128; i++) begin : MAC_ARRAY
            logic [47:0] pcin_wire;
            logic [47:0] pcout_wire;

            // Intentionally break the PCIN routing at the 32-slice column boundaries
            // and inject the fabric-delayed crossover registers instead.
            if (i == 0) begin
                assign pcin_wire = 48'd0;
            end else if (i == 32) begin
                assign pcin_wire = p_cross_s2[1];
            end else if (i == 64) begin
                assign pcin_wire = p_cross_s2[2];
            end else if (i == 96) begin
                assign pcin_wire = p_cross_s2[3];
            end else begin
                assign pcin_wire = MAC_ARRAY[i-1].pcout_wire;
            end

            DSP48E1 #(
                .A_INPUT("DIRECT"),
                .B_INPUT("DIRECT"),
                .USE_DPORT("FALSE"),
                .USE_MULT("MULTIPLY"),
                .USE_SIMD("ONE48"),
                .AUTORESET_PATDET("NO_RESET"),
                .MASK(48'h3fffffffffff),
                .PATTERN(48'h000000000000),
                .SEL_MASK("MASK"),
                .SEL_PATTERN("PATTERN"),
                .USE_PATTERN_DETECT("NO_PATDET"),
                .ACASCREG(1),
                .ADREG(0),
                .ALUMODEREG(0),
                .AREG(1),
                .BCASCREG(1),
                .BREG(1),
                .CARRYINREG(0),
                .CARRYINSELREG(0),
                .CREG(0),
                .DREG(0),
                .INMODEREG(0),
                .MREG(1),
                .OPMODEREG(0),
                .PREG(1)
            ) u_dsp (
                .CLK(clk),
                .ALUMODE(4'b0000),   // Z + X + Y
                .CARRYINSEL(3'b000), // No carry in
                .CEINMODE(1'b1),
                .CEALUMODE(1'b1),
                .CECTRL(1'b1),
                // OPMODE: If starting a column (i=0, 32, 64, 96), Z=0. Otherwise, Z=PCIN. X=M, Y=0.
                .OPMODE((i==0 || i==32 || i==64 || i==96) ? 7'b0000001 : 7'b0010001), 
                .INMODE(5'b00000),   // No pre-adder
                
                // Sign extend 25-bit audio_in to 30-bit A port
                .A({ {5{audio_in[24]}}, audio_in }), 
                .B(coeffs_in[i]),                    
                .C(48'd0),
                .D(25'd0),
                
                // Clock Enables tied to datapath enable
                .CEA1(1'b0), .CEA2(enable), .CEAD(1'b0), .CEB1(1'b0), .CEB2(enable), 
                .CEC(1'b0), .CECARRYIN(1'b0), .CED(1'b0), .CEM(enable), .CEP(enable),
                
                // Active-High Resets (Inverted from rst_n)
                .RSTA(~rst_n), .RSTALLCARRYIN(~rst_n), .RSTALUMODE(~rst_n), 
                .RSTB(~rst_n), .RSTC(~rst_n), .RSTCTRL(~rst_n), .RSTD(~rst_n), 
                .RSTINMODE(~rst_n), .RSTM(~rst_n), .RSTP(~rst_n),
                
                // Outputs & Cascades
                .P(p_reg[i]),
                .PCIN(pcin_wire),
                .PCOUT(pcout_wire),
                
                // Unused ports
                .ACIN(30'd0), .BCIN(18'd0), .CARRYCASCIN(1'b0), .MULTSIGNIN(1'b0), .CARRYIN(1'b0),
                .ACOUT(), .BCOUT(), .CARRYCASCOUT(), .CARRYOUT(), .MULTSIGNOUT(), 
                .PATTERNDETECT(), .PATTERNBDETECT(), .OVERFLOW(), .UNDERFLOW()
            );
        end
    endgenerate

endmodule