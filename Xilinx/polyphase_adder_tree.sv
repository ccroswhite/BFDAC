`timescale 1ns / 1ps

// =============================================================================
// POLYPHASE_ADDER_TREE — Milestone 1 Time-Multiplexed Phase-End Reduction
//
// Replaces the full NUM_INPUTS-1 spatial binary tree with a 3-tier
// phase-end snapshot + time-multiplexed DSP48E2 reduction engine:
//   - Tier 1 (G1 = 32): ceil(NUM_INPUTS/32) local accumulators (32 cycles)
//   - Tier 2 (G2 = 8) : ceil(NUM_G1/8) cluster accumulators   (8 cycles)
//   - Tier 3          : Registered binary tree over NUM_G2    (T3_LEVELS cycles)
//
// Total latency from snap_en = G1 + G2 + T3_LEVELS (43 cycles for 1280 MACs).
// Reclaims 96.2% of adder-tree DSP48E2 slices (98 vs 2,558 stereo at 1280 MACs)
// while remaining 100% bit-exact (0-LSB difference).
// =============================================================================
module polyphase_adder_tree #(
    parameter int NUM_INPUTS = 256,
    parameter int WIDTH      = 48,
    parameter int G1         = 32,
    parameter int G2         = 8,
    parameter int NUM_G1     = (NUM_INPUTS + G1 - 1) / G1,
    parameter int NUM_G2     = (NUM_G1 + G2 - 1) / G2,
    parameter int T3_LEVELS  = (NUM_G2 <= 1) ? 1 : $clog2(NUM_G2),
    parameter int TREE_LATENCY = G1 + G2 + T3_LEVELS
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        snap_en,   // Pulses on phase_sync_d6 when data_in holds completed phase sum
    input  logic signed [WIDTH-1:0]     data_in [0:NUM_INPUTS-1],
    output logic signed [WIDTH-1:0]     tree_out,
    output logic                        valid_out  // Pulses 1 cycle when tree_out is valid
);

    localparam int G1_W  = (G1 <= 1) ? 1 : $clog2(G1);
    localparam int G2_W  = (G2 <= 1) ? 1 : $clog2(G2);
    localparam int T3_PAD = 2 ** T3_LEVELS;

    // -------------------------------------------------------------------------
    // Controller Sequencing (Tier 1 -> Tier 2 -> Tier 3)
    // -------------------------------------------------------------------------
    logic            t1_busy;
    logic [G1_W-1:0] t1_idx;
    logic            t1_done;

    logic            t2_busy;
    logic [G2_W-1:0] t2_idx;
    logic            t2_done;

    logic [T3_LEVELS:0] t3_valid_pipe;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            t1_busy <= 1'b0;
            t1_idx  <= '0;
            t1_done <= 1'b0;
            t2_busy <= 1'b0;
            t2_idx  <= '0;
            t2_done <= 1'b0;
            t3_valid_pipe <= '0;
        end else begin
            t1_done <= 1'b0;
            t2_done <= 1'b0;

            // Tier 1 sequencer (runs for G1-1 cycles after snap_en loads slot 0)
            if (snap_en) begin
                if (G1 > 1) begin
                    t1_busy <= 1'b1;
                    t1_idx  <= G1_W'(1);
                end else begin
                    t1_busy <= 1'b0;
                    t1_done <= 1'b1;
                end
            end else if (t1_busy) begin
                if (t1_idx == G1_W'(G1 - 1)) begin
                    t1_busy <= 1'b0;
                    t1_done <= 1'b1;
                end else begin
                    t1_idx <= t1_idx + 1'b1;
                end
            end

            // Tier 2 sequencer (runs for G2-1 cycles after t1_done loads slot 0)
            if (t1_done) begin
                if (G2 > 1) begin
                    t2_busy <= 1'b1;
                    t2_idx  <= G2_W'(1);
                end else begin
                    t2_busy <= 1'b0;
                    t2_done <= 1'b1;
                end
            end else if (t2_busy) begin
                if (t2_idx == G2_W'(G2 - 1)) begin
                    t2_busy <= 1'b0;
                    t2_done <= 1'b1;
                end else begin
                    t2_idx <= t2_idx + 1'b1;
                end
            end

            // Tier 3 valid pipeline
            t3_valid_pipe <= {t3_valid_pipe[T3_LEVELS-1:0], t2_done};
        end
    end

    // -------------------------------------------------------------------------
    // Tier 1: Local Group Snapshot & Serial Accumulation (NUM_G1 DSP48s)
    // -------------------------------------------------------------------------
    logic signed [WIDTH-1:0] t1_acc [0:NUM_G1-1];

    genvar g1, k1;
    generate
        for (g1 = 0; g1 < NUM_G1; g1++) begin : gen_t1
            logic signed [WIDTH-1:0] snap_buf [1:G1-1];
            logic signed [WIDTH-1:0] slot0_in;

            assign slot0_in = (g1 * G1 < NUM_INPUTS) ? data_in[g1 * G1] : '0;

            for (k1 = 1; k1 < G1; k1++) begin : gen_snap1
                localparam int IDX = g1 * G1 + k1;
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        snap_buf[k1] <= '0;
                    end else if (snap_en) begin
                        snap_buf[k1] <= (IDX < NUM_INPUTS) ? data_in[IDX] : '0;
                    end
                end
            end

            (* use_dsp = "yes" *) logic signed [WIDTH-1:0] acc1;
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    acc1 <= '0;
                end else if (snap_en) begin
                    acc1 <= slot0_in;
                end else if (t1_busy) begin
                    acc1 <= acc1 + snap_buf[t1_idx];
                end
            end
            assign t1_acc[g1] = acc1;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Tier 2: Cluster Snapshot & Serial Accumulation (NUM_G2 DSP48s)
    // -------------------------------------------------------------------------
    logic signed [WIDTH-1:0] t2_acc [0:NUM_G2-1];

    genvar g2, k2;
    generate
        for (g2 = 0; g2 < NUM_G2; g2++) begin : gen_t2
            logic signed [WIDTH-1:0] snap_buf2 [1:G2-1];
            logic signed [WIDTH-1:0] slot0_in2;

            assign slot0_in2 = (g2 * G2 < NUM_G1) ? t1_acc[g2 * G2] : '0;

            for (k2 = 1; k2 < G2; k2++) begin : gen_snap2
                localparam int IDX2 = g2 * G2 + k2;
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        snap_buf2[k2] <= '0;
                    end else if (t1_done) begin
                        snap_buf2[k2] <= (IDX2 < NUM_G1) ? t1_acc[IDX2] : '0;
                    end
                end
            end

            (* use_dsp = "yes" *) logic signed [WIDTH-1:0] acc2;
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    acc2 <= '0;
                end else if (t1_done) begin
                    acc2 <= slot0_in2;
                end else if (t2_busy) begin
                    acc2 <= acc2 + snap_buf2[t2_idx];
                end
            end
            assign t2_acc[g2] = acc2;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Tier 3: Compact Registered Binary Tree across NUM_G2 Cluster Sums
    // -------------------------------------------------------------------------
    logic signed [WIDTH-1:0] t3_stage0 [0:T3_PAD-1];

    genvar i, l, j;
    generate
        for (i = 0; i < NUM_G2; i++) begin : gen_t3_in
            assign t3_stage0[i] = t2_acc[i];
        end
        for (i = NUM_G2; i < T3_PAD; i++) begin : gen_t3_pad
            assign t3_stage0[i] = '0;
        end

        for (l = 1; l <= T3_LEVELS; l++) begin : gen_t3_level
            localparam int N_OUT = T3_PAD >> l;
            (* use_dsp = "yes" *) logic signed [WIDTH-1:0] sums [0:N_OUT-1];

            for (j = 0; j < N_OUT; j++) begin : gen_t3_adder
                if (l == 1) begin : gen_from_t2
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            sums[j] <= '0;
                        else if (t2_done)
                            sums[j] <= t3_stage0[2*j] + t3_stage0[2*j+1];
                    end
                end else begin : gen_from_prev
                    always_ff @(posedge clk) begin
                        if (!rst_n)
                            sums[j] <= '0;
                        else if (t3_valid_pipe[l-2])
                            sums[j] <= gen_t3_level[l-1].sums[2*j] + gen_t3_level[l-1].sums[2*j+1];
                    end
                end
            end
        end
    endgenerate

    assign tree_out  = gen_t3_level[T3_LEVELS].sums[0];
    assign valid_out = t3_valid_pipe[T3_LEVELS-1];

endmodule
