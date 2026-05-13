`timescale 1ns / 1ps

// =============================================================================
// 5th-Order Error-Feedback Noise Shaper (Pipelined)
//
// Architectural note (2026-05-11 refactor):
//   The original implementation computed the entire per-enable update -- the
//   t1..t4 shift-and-add products, the three sum nodes, noise_shaped_audio,
//   dithered_audio, and the e_z1 commit -- in one combinational sweep between
//   the e_zN flops. Vivado synthesised this as 21 CARRY4s in series, ~12.75 ns
//   data delay, which cannot close at the 328-357 MHz dsp_clk (3.045 ns period).
//
//   This version pipelines the per-enable update across four stages. Because
//   `enable` fires only at the output sample rate (768 kHz max, 705.6 kHz on
//   the 44.1k family) -- roughly every 465 dsp_clk cycles -- the e_z1..e_z5
//   state flops still capture each new sample's contribution well before the
//   next enable arrives. The math is bit-exact identical to the un-pipelined
//   version: e_z1..e_z5 only update on the COMMIT stage, so each new enable
//   reads the same previous-sample state it would have in the original code.
//   No coefficient retuning, no transfer-function change.
//
//   Output latency increases by 3 dsp_clk cycles (~9 ns), which is invisible
//   to the downstream dem_mapper and TX FIFO. L and R noise shapers share
//   `enable` so they stay lockstep automatically.
// =============================================================================
module noise_shaper_5th_order #(
    parameter int INPUT_WIDTH = 48,
    parameter int FRAC_WIDTH  = 42,
    parameter int OUT_WIDTH   = 9
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          enable,
    input  logic signed [INPUT_WIDTH-1:0] data_in,
    input  logic signed [FRAC_WIDTH-1:0]  dither_in,
    output logic [OUT_WIDTH-1:0]          dem_drive_out
);

    // ------------------------------------------------------------------------
    // 1. Dynamic widths & scaled constants
    // ------------------------------------------------------------------------
    localparam int IW = INPUT_WIDTH + 6;  // INTERNAL_WIDTH (54 bits with defaults)

    localparam logic signed [IW-1:0] MAX_LEVEL            = 256;
    localparam logic signed [IW-1:0] CENTER_OFFSET        = 128;
    localparam logic signed [IW-1:0] CENTER_OFFSET_SCALED =
        {CENTER_OFFSET[IW-FRAC_WIDTH-1:0], {FRAC_WIDTH{1'b0}}};
    localparam logic signed [IW-1:0] CLAMP_OFFSET         =
        {MAX_LEVEL[IW-FRAC_WIDTH-1:0],     {FRAC_WIDTH{1'b0}}};

    // ------------------------------------------------------------------------
    // 2. Error delay line (only commits on Stage D; stable between enables)
    // ------------------------------------------------------------------------
    logic signed [IW-1:0] e_z1, e_z2, e_z3, e_z4, e_z5;

    // ------------------------------------------------------------------------
    // 3. Enable pipeline (A capture, B sums, C1 combine, C2 dither,
    //                    D1 e_z1 candidates, D2 mux + commit)
    // ------------------------------------------------------------------------
    logic [4:0] en_pipe;

    // ------------------------------------------------------------------------
    // 4. Stage A registers: shift-and-add products, DC-offset audio, dither hold
    // ------------------------------------------------------------------------
    logic signed [IW-1:0]         t1_r, t2_r, t3_r, t4_r;
    logic signed [IW-1:0]         offset_r;
    logic signed [IW-1:0]         e_z5_a;        // snapshot of e_z5 at stage A
    logic signed [FRAC_WIDTH-1:0] dither_a;

    // ------------------------------------------------------------------------
    // 5. Stage B registers: three sum nodes + dither hold
    // ------------------------------------------------------------------------
    logic signed [IW-1:0]         sum_pos_1_r, sum_pos_2_r, sum_neg_r;
    logic signed [FRAC_WIDTH-1:0] dither_b;

    // ------------------------------------------------------------------------
    // 6. Stage C1 register: noise-shaped audio (one 3-operand carry chain).
    //    Stage C2 register: dithered audio (one 2-operand carry chain).
    //    Splitting these prevents two cascaded 54-bit adders in one cycle.
    // ------------------------------------------------------------------------
    logic signed [IW-1:0]         noise_shaped_r;     // Stage C1 output
    logic signed [FRAC_WIDTH-1:0] dither_c;           // Stage C1 dither hold
    logic signed [IW-1:0]         dithered_r;         // Stage C2 output

    // Combinational helper for Stage C1 -- pulled out of the always_ff to
    // keep synthesis well-defined (Vivado-friendly).
    logic signed [IW-1:0] ns_comb;
    assign ns_comb = (sum_pos_1_r + sum_pos_2_r) - sum_neg_r;

    // ------------------------------------------------------------------------
    // 6b. Stage D1 registers: pre-computed e_z1 candidates + range select
    //
    //   The original Stage D did a 54-bit subtract AND a 3-way mux in one
    //   cycle (15 logic levels = 13 CARRY4 + 2 LUTs, failing timing). We
    //   pre-compute the subtracts in D1 and select in D2 so each cycle's
    //   critical path is at most one carry chain.
    // ------------------------------------------------------------------------
    logic signed [IW-1:0]         e_z1_cand_over_d1;   // noise_shaped_r - CLAMP_OFFSET
    logic signed [IW-1:0]         e_z1_cand_under_d1;  // noise_shaped_r (pass-through)
    logic signed [IW-1:0]         e_z1_cand_normal_d1; // noise_shaped_r - dithered_quant
    logic [OUT_WIDTH-1:0]         dem_drive_normal_d1; // dithered_r[OUT slice]
    // range_sel: 2'b01 = overflow, 2'b10 = underflow, 2'b00 = normal
    logic [1:0]                   range_sel_d1;

    // ------------------------------------------------------------------------
    // 7. Pipeline
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            e_z1 <= '0;  e_z2 <= '0;  e_z3 <= '0;  e_z4 <= '0;  e_z5 <= '0;

            en_pipe <= '0;

            t1_r <= '0;  t2_r <= '0;  t3_r <= '0;  t4_r <= '0;
            offset_r <= '0;  e_z5_a <= '0;  dither_a <= '0;

            sum_pos_1_r <= '0;  sum_pos_2_r <= '0;  sum_neg_r <= '0;
            dither_b    <= '0;

            noise_shaped_r <= '0;  dither_c <= '0;  dithered_r <= '0;

            e_z1_cand_over_d1   <= '0;
            e_z1_cand_under_d1  <= '0;
            e_z1_cand_normal_d1 <= '0;
            dem_drive_normal_d1 <= '0;
            range_sel_d1        <= 2'b00;

            dem_drive_out <= CENTER_OFFSET[OUT_WIDTH-1:0];
        end else begin
            // Shift the enable pulse through the pipeline.
            en_pipe <= {en_pipe[3:0], enable};

            // --- Stage A: capture inputs, compute shift-and-add products ----
            if (enable) begin
                t1_r     <= (e_z1 <<< 2) + e_z1;            // 5  * e_z1
                t2_r     <= (e_z2 <<< 3) + (e_z2 <<< 1);    // 10 * e_z2
                t3_r     <= (e_z3 <<< 3) + (e_z3 <<< 1);    // 10 * e_z3
                t4_r     <= (e_z4 <<< 2) + e_z4;            // 5  * e_z4
                offset_r <= $signed(data_in) + CENTER_OFFSET_SCALED;
                e_z5_a   <= e_z5;
                dither_a <= dither_in;
            end

            // --- Stage B: three sum nodes ------------------------------------
            if (en_pipe[0]) begin
                sum_pos_1_r <= offset_r + t1_r;
                sum_pos_2_r <= t3_r + e_z5_a;
                sum_neg_r   <= t2_r + t4_r;
                dither_b    <= dither_a;
            end

            // --- Stage C1: combine sum nodes into noise-shaped audio --------
            if (en_pipe[1]) begin
                noise_shaped_r <= ns_comb;
                dither_c       <= dither_b;
            end

            // --- Stage C2: add dither -- one carry chain in isolation -------
            if (en_pipe[2]) begin
                dithered_r <= noise_shaped_r + $signed(dither_c);
            end

            // --- Stage D1: pre-compute candidate e_z1 values + range_sel ----
            //   Each candidate is at most one 54-bit subtract (one carry
            //   chain). The mux happens in D2 below, isolated by a register.
            if (en_pipe[3]) begin
                e_z1_cand_over_d1   <= noise_shaped_r - CLAMP_OFFSET;
                e_z1_cand_under_d1  <= noise_shaped_r;
                e_z1_cand_normal_d1 <= noise_shaped_r -
                                       $signed({dithered_r[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH],
                                                {FRAC_WIDTH{1'b0}}});
                dem_drive_normal_d1 <= dithered_r[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH];

                if ((dithered_r[IW-1] == 1'b0) &&
                    (|dithered_r[IW-2 : FRAC_WIDTH+OUT_WIDTH-1])) begin
                    range_sel_d1 <= 2'b01; // overflow
                end else if (dithered_r[IW-1] == 1'b1) begin
                    range_sel_d1 <= 2'b10; // underflow
                end else begin
                    range_sel_d1 <= 2'b00; // normal
                end
            end

            // --- Stage D2: mux + commit e_z1, dem_drive_out, shift z-line ---
            if (en_pipe[4]) begin
                case (range_sel_d1)
                    2'b01: begin // overflow
                        dem_drive_out <= MAX_LEVEL[OUT_WIDTH-1:0];
                        e_z1          <= e_z1_cand_over_d1;
                    end
                    2'b10: begin // underflow
                        dem_drive_out <= '0;
                        e_z1          <= e_z1_cand_under_d1;
                    end
                    default: begin // normal
                        dem_drive_out <= dem_drive_normal_d1;
                        e_z1          <= e_z1_cand_normal_d1;
                    end
                endcase
                e_z2 <= e_z1;
                e_z3 <= e_z2;
                e_z4 <= e_z3;
                e_z5 <= e_z4;
            end
        end
    end

endmodule