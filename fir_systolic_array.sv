`timescale 1ns / 1ps

module fir_systolic_array #(
    parameter int NUM_MACS   = 256,
    parameter int DATA_WIDTH = 32,
    parameter int COEF_WIDTH = 32,
    parameter int ACC_WIDTH  = 64
)(
    input  logic                                     clk,
    input  logic                                     rst_n,

    // Base upstream inputs targeted to the very first MAC element
    input  logic signed [DATA_WIDTH-1:0]             sample_in,
    input  logic signed [ACC_WIDTH-1:0]              acc_in,

    // Dynamically scalable flattened 1D bus comprising every distributed coefficient
    input  logic [(NUM_MACS * COEF_WIDTH)-1:0]       coef_bus_in,

    // Downstream cascaded outputs exiting the final MAC element
    output logic signed [DATA_WIDTH-1:0]             sample_out,
    output logic signed [ACC_WIDTH-1:0]              acc_out
);

    // -----------------------------------------------------------------
    // Interconnect Routing Arrays
    // Dimensioned functionally to [0 : NUM_MACS] spanning the required 
    // boundary +1 to enclose inputs scaling sequentially up to outputs
    // -----------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] cascade_sample [0:NUM_MACS];
    logic signed [ACC_WIDTH-1:0]  cascade_acc    [0:NUM_MACS];

    // Seed the zero-index element explicitly with external signals
    assign cascade_sample[0] = sample_in;
    assign cascade_acc[0]    = acc_in;

    // -----------------------------------------------------------------
    // Native Systolic Generation Mapping
    // -----------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_mac_array
            
            // Extract strictly the coefficient chunk for this specific pipeline tap
            // Utilizing dynamic indexed part-select avoiding implicit logic wrappers
            logic signed [COEF_WIDTH-1:0] local_coef;
            assign local_coef = $signed(coef_bus_in[i * COEF_WIDTH +: COEF_WIDTH]);

            fir_mac_engine #(
                .DATA_WIDTH(DATA_WIDTH),
                .COEF_WIDTH(COEF_WIDTH),
                .ACC_WIDTH (ACC_WIDTH)
            ) u_mac (
                .clk        (clk),
                .rst_n      (rst_n),
                
                // Read from upstream boundary node
                .sample_in  (cascade_sample[i]),
                .coef_in    (local_coef),
                .acc_in     (cascade_acc[i]),
                
                // Daisy-chain directly outward enforcing physical cascaded constraints
                .sample_out (cascade_sample[i+1]),
                .acc_out    (cascade_acc[i+1])
            );

        end
    endgenerate

    // -----------------------------------------------------------------
    // Final Array Output Boundaries
    // -----------------------------------------------------------------
    // Unload the highest bounding limits cleanly to external downstream wrappers
    assign sample_out = cascade_sample[NUM_MACS];
    assign acc_out    = cascade_acc[NUM_MACS];

endmodule
