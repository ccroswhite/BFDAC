`timescale 1ns / 1ps

// Pipelined binary adder tree: NUM_INPUTS signed 48-bit inputs → 1 signed 48-bit sum.
//
// NUM_INPUTS may be ANY value >= 1 (2026-08-17: non-power-of-2 support so the
// MAC count — and therefore the coefficient count — is freely scalable, e.g.
// 1280 MACs x 256 taps/phase = 5M taps gapless). Inputs are zero-padded up to
// the next power of 2; the constant-zero terms prune away in synthesis.
//
// Structure: $clog2(NUM_INPUTS) registered levels (8 for 256, 11 for 1280).
//   Level 0 (input):  NUM_INPUTS terms, zero-padded to PAD  [MAC preg outputs]
//   Level 1 (reg):    PAD/2 sums
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

    localparam int LEVELS = (NUM_INPUTS <= 1) ? 1 : $clog2(NUM_INPUTS);

    // Internal pipeline: each level holds exactly PAD>>l partial sums after
    // l cycles. Per-level arrays are declared INSIDE the generate blocks and
    // referenced hierarchically (gen_level[l-1].sums), keeping total variable
    // size ~2*PAD*WIDTH bits. (A rectangular [0:LEVELS][0:PAD-1] array blew
    // Vivado's 1M-bit per-variable limit at 1280 MACs / PAD=2048.)

    // Padded size: next power of 2 >= NUM_INPUTS (equal when already pow2)
    localparam int PAD = 2 ** LEVELS;

    // Level 0: wire through inputs, zero-pad the rest (prunes in synthesis)
    logic signed [WIDTH-1:0] stage0 [0:PAD-1];
    genvar i;
    generate
        for (i = 0; i < NUM_INPUTS; i++) begin : gen_l0
            assign stage0[i] = data_in[i];
        end
        for (i = NUM_INPUTS; i < PAD; i++) begin : gen_l0_pad
            assign stage0[i] = '0;
        end
    endgenerate

    // Levels 1..LEVELS: registered pairwise addition
    genvar l, j;
    generate
        for (l = 1; l <= LEVELS; l++) begin : gen_level
            localparam int N_OUT = PAD >> l;   // outputs of this level

            logic signed [WIDTH-1:0] sums [0:N_OUT-1];

            for (j = 0; j < N_OUT; j++) begin : gen_adder
                if (l == 1) begin : gen_from_input
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            sums[j] <= '0;
                        else
                            sums[j] <= stage0[2*j] + stage0[2*j+1];
                    end
                end else begin : gen_from_prev
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            sums[j] <= '0;
                        else
                            sums[j] <= gen_level[l-1].sums[2*j] + gen_level[l-1].sums[2*j+1];
                    end
                end
            end
        end
    endgenerate

    assign tree_out = gen_level[LEVELS].sums[0];

endmodule
