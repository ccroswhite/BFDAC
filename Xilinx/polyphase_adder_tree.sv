`timescale 1ns / 1ps

// Pipelined binary adder tree: NUM_INPUTS signed 48-bit inputs → 1 signed 48-bit sum.
//
// Structure: $clog2(NUM_INPUTS) registered levels (8 for 256, 12 for 4096).
//   Level 0 (input):  NUM_INPUTS terms  [MAC preg outputs]
//   Level 1 (reg):    NUM_INPUTS/2 sums
//   ...
//   Level LEVELS (reg): 1 sum  [tree_out, TREE_LATENCY=$clog2(NUM_INPUTS) cycles]
//
// Vivado inference: each registered add maps to DSP48E2 in P=A+B mode
// (AREG=0, BREG=0, PREG=1).  NUM_INPUTS-1 DSP48E2 adders per tree.
//
// Shadow trigger in fir_polyphase_interpolator:
//   phase_sync_d1 + 5 (MAC pipe) + LEVELS (tree) + 1 (margin).
//   For 256 MACs: 5 + 8 + 1 = 14. For 4096 MACs: 5 + 12 + 1 = 18.

module polyphase_adder_tree #(
    parameter int NUM_INPUTS = 256,
    parameter int WIDTH      = 48
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic signed [WIDTH-1:0]     data_in [0:NUM_INPUTS-1],
    output logic signed [WIDTH-1:0]     tree_out
);

    localparam int LEVELS = $clog2(NUM_INPUTS);  // $clog2(NUM_INPUTS) levels

    // Internal pipeline: level[l] holds 2^(LEVELS-l) partial sums after l cycles.
    // level[0] = data_in (combinatorial, not registered)
    // level[l] = registered sum of pairs from level[l-1]
    // We use a flat 2D array: stage[l][i]

    // Compute padded size (power of 2 already for NUM_INPUTS=256)
    localparam int PAD = NUM_INPUTS;  // already a power of 2

    logic signed [WIDTH-1:0] stage [0:LEVELS][0:PAD-1];

    // Level 0: wire through inputs
    genvar i;
    generate
        for (i = 0; i < NUM_INPUTS; i++) begin : gen_l0
            assign stage[0][i] = data_in[i];
        end
    endgenerate

    // Levels 1..LEVELS: registered pairwise addition
    genvar l, j;
    generate
        for (l = 1; l <= LEVELS; l++) begin : gen_level
            localparam int N_IN  = PAD >> (l - 1);  // inputs to this level
            localparam int N_OUT = PAD >> l;         // outputs of this level

            for (j = 0; j < N_OUT; j++) begin : gen_adder
                always_ff @(posedge clk) begin
                    if (!rst_n)
                        stage[l][j] <= '0;
                    else
                        stage[l][j] <= stage[l-1][2*j] + stage[l-1][2*j+1];
                end
            end

            // Pad upper half to 0 for unused entries (synthesis will prune)
            for (j = N_OUT; j < PAD; j++) begin : gen_pad
                assign stage[l][j] = '0;
            end
        end
    endgenerate

    assign tree_out = stage[LEVELS][0];

endmodule
