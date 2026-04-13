`timescale 1ns / 1ps

module coef_bram #(
    parameter int NUM_COEFS  = 256,
    parameter int COEF_WIDTH = 32
)(
    // Port A Inputs/Outputs (SPI Write Port)
    input  logic                                clka,
    input  logic                                wea,
    input  logic [$clog2(NUM_COEFS)-1:0]        addra,
    input  logic [COEF_WIDTH-1:0]               dina,

    // Port B Inputs/Outputs (DSP Read Port)
    input  logic                                clkb,
    input  logic                                enb,
    output logic [(NUM_COEFS * COEF_WIDTH)-1:0] doutb
);

    // Calculated Localparams (Constraining Synthesis Contexts)
    localparam int PORT_A_DATA_WIDTH = COEF_WIDTH;
    localparam int PORT_A_ADDR_WIDTH = $clog2(NUM_COEFS);
    
    localparam int PORT_B_DATA_WIDTH = NUM_COEFS * COEF_WIDTH;
    localparam int PORT_B_ADDR_WIDTH = 1;

    // Shared memory array physically bridging the dual-port infrastructure
    logic [COEF_WIDTH-1:0] ram [0:NUM_COEFS-1];

    // -----------------------------------------------------------------
    // Port A Logic: Asynchronous Configuration Intake
    // -----------------------------------------------------------------
    always_ff @(posedge clka) begin
        if (wea) begin
            ram[addra] <= dina;
        end
    end

    // -----------------------------------------------------------------
    // Port B Logic: Ultra-Wide DSP Flattened Read Extraction
    // -----------------------------------------------------------------
    // Explicitly forces Vivado Synthesis (XST) to construct dense asymmetric blocks 
    // by restricting reads purely inside synchronous domain registers mirroring Native BRAM
    always_ff @(posedge clkb) begin
        if (enb) begin
            // Generates a fully synchronous parallel unpacking
            for (int i = 0; i < NUM_COEFS; i++) begin
                doutb[i*COEF_WIDTH +: COEF_WIDTH] <= ram[i];
            end
        end
    end

endmodule
