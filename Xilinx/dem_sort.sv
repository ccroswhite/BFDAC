`timescale 1ns / 1ps

// =============================================================================
//  DEM_SORT — Unconstrained sort-based 2nd-order vector mismatch shaper
//  (Round 30, ratified with the RTZ cell coding)
//
//  Only legal under RTZ: cell toggles carry no glitch cost, so the selector
//  is free to pick ANY c cells each sample. Verified 25-40 dB better than
//  DWA with idle tones <= -168 dBFS (dwa_tones3.py / dem_sort_check.py).
//
//  Algorithm (integer-exact reference: dem_sort_gen.py):
//    metric   M_i  = 2*A1_i + A2_i          (2nd-order, g2 = 0.5 scaled x2)
//    select the c cells with the SMALLEST M (tie-break: lower index wins)
//    update   A1_i += 64*sel_i - c ;  A2_i += A1_i
//
//  Implementation: counting rank, 2 comparison lanes per cycle.
//    rank_i = #{ j : M_j < M_i  or  (M_j == M_i and j < i) }
//    sel_i  = rank_i < c
//  Loop is 32 cycles (j pairs) + 3 overhead = 35 dsp_clk per sample; the
//  6.144 MHz sample period is 56-65 dsp_clk at 350-400 MHz.
//
//  Accumulator bounds (python-verified, dem_sort_gen.py): |A1| <= 63,
//  |A2| <= 382 over all audio stimuli; <= 103k under sustained 0 dBFS
//  modulator overload (self-bounding: no growth at code 0/64). 24-bit
//  signed accumulators give > 100x margin, no saturation logic needed.
//
//  Ports: dem_dwa-compatible plus valid_out (latency is multi-cycle, not
//  the fixed 3 stages of dem_dwa — dac_dsp_core uses valid_out instead of
//  its old shift-register delay).
// =============================================================================
module dem_sort #(
    parameter int ARRAY_SIZE = 64,
    parameter int AMP_WIDTH  = 7,   // 0..64
    parameter int ACC_WIDTH  = 24   // signed accumulators / metric
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    enable,         // one pulse per output sample
    input  logic [AMP_WIDTH-1:0]    amplitude_in,   // 0..ARRAY_SIZE
    output logic [ARRAY_SIZE-1:0]   resistor_out,   // selection word
    output logic                    valid_out       // pulses when resistor_out updates
);

    localparam int JW = $clog2(ARRAY_SIZE);         // 6
    localparam int RW = $clog2(ARRAY_SIZE) + 1;     // rank counter 0..64

    // Per-cell state
    logic signed [ACC_WIDTH-1:0] acc1 [ARRAY_SIZE];
    logic signed [ACC_WIDTH-1:0] acc2 [ARRAY_SIZE];
    logic signed [ACC_WIDTH-1:0] msnap [ARRAY_SIZE];  // frozen metric for this sample
    logic [RW-1:0]               rank  [ARRAY_SIZE];

    typedef enum logic [1:0] {IDLE, RANK, UPDATE} state_t;
    state_t                 state;
    logic [AMP_WIDTH-1:0]   amp_q;
    logic [JW-2:0]          jpair;      // 0..31 (pairs of j)

    // Selection from ranks (comb) — used in UPDATE
    logic [ARRAY_SIZE-1:0] sel_comb;
    always_comb begin
        for (int i = 0; i < ARRAY_SIZE; i++)
            sel_comb[i] = ({1'b0, rank[i]} < {1'b0, amp_q});
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= IDLE;
            amp_q        <= '0;
            jpair        <= '0;
            resistor_out <= '0;
            valid_out    <= 1'b0;
            for (int i = 0; i < ARRAY_SIZE; i++) begin
                acc1[i]  <= '0;
                acc2[i]  <= '0;
                msnap[i] <= '0;
                rank[i]  <= '0;
            end
        end else begin
            valid_out <= 1'b0;
            unique case (state)
                IDLE: if (enable) begin
                    amp_q <= amplitude_in;
                    jpair <= '0;
                    for (int i = 0; i < ARRAY_SIZE; i++) begin
                        msnap[i] <= (acc1[i] <<< 1) + acc2[i];
                        rank[i]  <= '0;
                    end
                    state <= RANK;
                end
                RANK: begin
                    // two comparison lanes: j0 = 2*jpair, j1 = 2*jpair+1
                    for (int i = 0; i < ARRAY_SIZE; i++) begin
                        automatic logic [1:0] inc;
                        automatic int j0 = 2 * int'(jpair);
                        automatic int j1 = 2 * int'(jpair) + 1;
                        inc[0] = (msnap[j0] < msnap[i]) ||
                                 ((msnap[j0] == msnap[i]) && (j0 < i));
                        inc[1] = (msnap[j1] < msnap[i]) ||
                                 ((msnap[j1] == msnap[i]) && (j1 < i));
                        rank[i] <= rank[i] + {{(RW-2){1'b0}}, inc[0]} +
                                             {{(RW-2){1'b0}}, inc[1]};
                    end
                    if (jpair == (JW-1)'((ARRAY_SIZE/2) - 1))
                        state <= UPDATE;
                    else
                        jpair <= jpair + 1'b1;
                end
                UPDATE: begin
                    for (int i = 0; i < ARRAY_SIZE; i++) begin
                        automatic logic signed [ACC_WIDTH-1:0] a1n;
                        a1n = acc1[i]
                            + (sel_comb[i] ? ACC_WIDTH'(signed'(ARRAY_SIZE)) : ACC_WIDTH'(0))
                            - ACC_WIDTH'(signed'({1'b0, amp_q}));
                        acc1[i] <= a1n;
                        acc2[i] <= acc2[i] + a1n;
                    end
                    resistor_out <= sel_comb;
                    valid_out    <= 1'b1;
                    state        <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
