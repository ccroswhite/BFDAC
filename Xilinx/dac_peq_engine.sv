`timescale 1ns / 1ps

// =============================================================================
// DAC_PEQ_ENGINE — Milestone 4 Studio-Grade Multi-Band Parametric Equalizer
//
// Architecture:
//   - 8-band stereo time-multiplexed Direct-Form I double-precision IIR biquad
//     cascade operating at the 48-bit 768 / 705.6 kHz post-FIR stream.
//   - 48-bit signed audio datapath & state history (x1, x2, y1, y2) with
//     32-bit signed Q2.30 coefficients (b0, b1, b2, a1, a2) and an 84-bit
//     internal accumulator (>190 dB internal dynamic range, symmetric 48-bit
//     saturation guard).
//   - Built-in 16-deep elastic input FIFO absorbs phase bursts from
//     fir_polyphase_stereo and paces outputs at >= 16 dsp_clk cycles to
//     satisfy downstream halfband_x2 spacing requirements.
//   - Dual coefficient banks (Active + Shadow) with atomic glitch-free swap.
//   - Bit-exact 0-LSB bypass when peq_enable == 1'b0.
// =============================================================================
module dac_peq_engine #(
    parameter int NUM_BANDS      = 8,
    parameter int DATA_WIDTH     = 48,
    parameter int COEF_WIDTH     = 32,   // Signed Q2.30 (1.0 = 32'sh4000_0000)
    parameter int FRAC_BITS      = 30,
    parameter int MIN_OUT_SPACE  = 16    // Guarantees >= 8 clks for halfband_x2
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         peq_enable,     // 0: bit-exact bypass, 1: active

    // Streaming Audio Input (from fir_polyphase_stereo, 768 / 705.6 kHz)
    input  logic                         in_valid,
    input  logic signed [DATA_WIDTH-1:0] in_data_l,
    input  logic signed [DATA_WIDTH-1:0] in_data_r,

    // Streaming Audio Output (to u_hb1_l / u_hb1_r)
    output logic                         out_valid,
    output logic signed [DATA_WIDTH-1:0] out_data_l,
    output logic signed [DATA_WIDTH-1:0] out_data_r,

    // Shadow Coefficient Programming Interface (tied to 0 if unused)
    input  logic                         coef_wr_en     = 1'b0,
    input  logic [$clog2(NUM_BANDS)-1:0] coef_wr_band   = '0,
    input  logic [2:0]                   coef_wr_idx    = '0, // 0:b0, 1:b1, 2:b2, 3:a1, 4:a2
    input  logic signed [COEF_WIDTH-1:0] coef_wr_data   = '0,
    input  logic                         coef_swap_req  = 1'b0,
    output logic                         active_bank
);

    localparam int PROD_W = DATA_WIDTH + COEF_WIDTH; // 80 bits
    localparam int ACC_W  = PROD_W + 4;              // 84 bits
    localparam int BAND_W = $clog2(NUM_BANDS);
    localparam logic signed [COEF_WIDTH-1:0] UNITY_B0 = COEF_WIDTH'(1) <<< FRAC_BITS;

    localparam logic signed [ACC_W-1:0] MAX_POS_48 =  (ACC_W'(1) <<< (DATA_WIDTH - 1)) - 1;
    localparam logic signed [ACC_W-1:0] MIN_NEG_48 = -(ACC_W'(1) <<< (DATA_WIDTH - 1));

    // -------------------------------------------------------------------------
    // 1. 16-Deep Elastic Input FIFO (absorbs phase bursts from Stage 1 FIR)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] fifo_l [0:15];
    logic signed [DATA_WIDTH-1:0] fifo_r [0:15];
    logic [3:0]                   wr_ptr, rd_ptr;
    logic [4:0]                   fifo_cnt;
    logic                         fifo_pop;

    wire fifo_empty = (fifo_cnt == 5'd0);
    wire fifo_push  = in_valid && (fifo_cnt < 5'd16);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            fifo_cnt <= '0;
            for (int i = 0; i < 16; i++) begin
                fifo_l[i] <= '0;
                fifo_r[i] <= '0;
            end
        end else begin
            if (fifo_push) begin
                fifo_l[wr_ptr] <= in_data_l;
                fifo_r[wr_ptr] <= in_data_r;
                wr_ptr         <= wr_ptr + 4'd1;
            end
            if (fifo_pop) begin
                rd_ptr <= rd_ptr + 4'd1;
            end
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_cnt <= fifo_cnt + 5'd1;
                2'b01:   fifo_cnt <= fifo_cnt - 5'd1;
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // 2. Dual-Bank Coefficient Storage & Biquad State Registers
    // -------------------------------------------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_mem [0:1][0:NUM_BANDS-1][0:4];
    logic                         bank_sel;
    logic                         swap_pend;

    assign active_bank = bank_sel;

    logic signed [DATA_WIDTH-1:0] x1_l [0:NUM_BANDS-1], x2_l [0:NUM_BANDS-1];
    logic signed [DATA_WIDTH-1:0] y1_l [0:NUM_BANDS-1], y2_l [0:NUM_BANDS-1];
    logic signed [DATA_WIDTH-1:0] x1_r [0:NUM_BANDS-1], x2_r [0:NUM_BANDS-1];
    logic signed [DATA_WIDTH-1:0] y1_r [0:NUM_BANDS-1], y2_r [0:NUM_BANDS-1];

    typedef enum logic [1:0] {
        ST_IDLE     = 2'd0,
        ST_MUL      = 2'd1,
        ST_ACC      = 2'd2,
        ST_BYP_WAIT = 2'd3
    } state_t;

    state_t                       state;
    logic [BAND_W-1:0]            band_idx;
    logic [4:0]                   byp_wait_cnt;
    logic signed [DATA_WIDTH-1:0] cur_x_l, cur_x_r;

    // Registered 80-bit products for current band
    (* use_dsp = "yes" *) logic signed [PROD_W-1:0] p_b0_l, p_b1_l, p_b2_l, p_a1_l, p_a2_l;
    (* use_dsp = "yes" *) logic signed [PROD_W-1:0] p_b0_r, p_b1_r, p_b2_r, p_a1_r, p_a2_r;

    // Combinational 84-bit accumulation, rounding, and symmetric 48-bit saturation
    logic signed [ACC_W-1:0]      sum_l_comb, sum_r_comb;
    logic signed [ACC_W-1:0]      rnd_l_comb, rnd_r_comb;
    logic signed [DATA_WIDTH-1:0] y_l_comb,   y_r_comb;

    always_comb begin
        sum_l_comb = ACC_W'(p_b0_l) + ACC_W'(p_b1_l) + ACC_W'(p_b2_l)
                   - ACC_W'(p_a1_l) - ACC_W'(p_a2_l);
        sum_r_comb = ACC_W'(p_b0_r) + ACC_W'(p_b1_r) + ACC_W'(p_b2_r)
                   - ACC_W'(p_a1_r) - ACC_W'(p_a2_r);

        rnd_l_comb = (sum_l_comb + (ACC_W'(1) <<< (FRAC_BITS - 1))) >>> FRAC_BITS;
        rnd_r_comb = (sum_r_comb + (ACC_W'(1) <<< (FRAC_BITS - 1))) >>> FRAC_BITS;

        if (rnd_l_comb > MAX_POS_48)      y_l_comb = MAX_POS_48[DATA_WIDTH-1:0];
        else if (rnd_l_comb < MIN_NEG_48) y_l_comb = MIN_NEG_48[DATA_WIDTH-1:0];
        else                              y_l_comb = rnd_l_comb[DATA_WIDTH-1:0];

        if (rnd_r_comb > MAX_POS_48)      y_r_comb = MAX_POS_48[DATA_WIDTH-1:0];
        else if (rnd_r_comb < MIN_NEG_48) y_r_comb = MIN_NEG_48[DATA_WIDTH-1:0];
        else                              y_r_comb = rnd_r_comb[DATA_WIDTH-1:0];
    end

    assign fifo_pop = (state == ST_IDLE) && !fifo_empty;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_sel     <= 1'b0;
            swap_pend    <= 1'b0;
            state        <= ST_IDLE;
            band_idx     <= '0;
            byp_wait_cnt <= '0;
            cur_x_l      <= '0;
            cur_x_r      <= '0;
            p_b0_l <= '0; p_b1_l <= '0; p_b2_l <= '0; p_a1_l <= '0; p_a2_l <= '0;
            p_b0_r <= '0; p_b1_r <= '0; p_b2_r <= '0; p_a1_r <= '0; p_a2_r <= '0;
            out_valid    <= 1'b0;
            out_data_l   <= '0;
            out_data_r   <= '0;
            for (int b = 0; b < NUM_BANDS; b++) begin
                x1_l[b] <= '0; x2_l[b] <= '0; y1_l[b] <= '0; y2_l[b] <= '0;
                x1_r[b] <= '0; x2_r[b] <= '0; y1_r[b] <= '0; y2_r[b] <= '0;
                for (int bank = 0; bank < 2; bank++) begin
                    coef_mem[bank][b][0] <= UNITY_B0; // Default unity gain (b0 = 1.0)
                    coef_mem[bank][b][1] <= '0;
                    coef_mem[bank][b][2] <= '0;
                    coef_mem[bank][b][3] <= '0;
                    coef_mem[bank][b][4] <= '0;
                end
            end
        end else begin
            out_valid <= 1'b0;

            if (coef_wr_en && coef_wr_idx <= 3'd4)
                coef_mem[~bank_sel][coef_wr_band][coef_wr_idx] <= coef_wr_data;

            if (coef_swap_req)
                swap_pend <= 1'b1;

            unique case (state)
                ST_IDLE: begin
                    if (swap_pend && fifo_empty) begin
                        bank_sel  <= ~bank_sel;
                        swap_pend <= 1'b0;
                    end
                    if (!fifo_empty) begin
                        if (swap_pend) begin
                            bank_sel  <= ~bank_sel;
                            swap_pend <= 1'b0;
                        end
                        if (!peq_enable) begin
                            out_data_l <= fifo_l[rd_ptr];
                            out_data_r <= fifo_r[rd_ptr];
                            out_valid  <= 1'b1;
                            if (MIN_OUT_SPACE > 1) begin
                                byp_wait_cnt <= 5'(MIN_OUT_SPACE - 1);
                                state        <= ST_BYP_WAIT;
                            end
                        end else begin
                            cur_x_l  <= fifo_l[rd_ptr];
                            cur_x_r  <= fifo_r[rd_ptr];
                            band_idx <= '0;
                            state    <= ST_MUL;
                        end
                    end
                end

                ST_BYP_WAIT: begin
                    if (byp_wait_cnt <= 5'd1)
                        state <= ST_IDLE;
                    else
                        byp_wait_cnt <= byp_wait_cnt - 5'd1;
                end

                ST_MUL: begin
                    p_b0_l <= $signed(cur_x_l)        * $signed(coef_mem[bank_sel][band_idx][0]);
                    p_b1_l <= $signed(x1_l[band_idx]) * $signed(coef_mem[bank_sel][band_idx][1]);
                    p_b2_l <= $signed(x2_l[band_idx]) * $signed(coef_mem[bank_sel][band_idx][2]);
                    p_a1_l <= $signed(y1_l[band_idx]) * $signed(coef_mem[bank_sel][band_idx][3]);
                    p_a2_l <= $signed(y2_l[band_idx]) * $signed(coef_mem[bank_sel][band_idx][4]);

                    p_b0_r <= $signed(cur_x_r)        * $signed(coef_mem[bank_sel][band_idx][0]);
                    p_b1_r <= $signed(x1_r[band_idx]) * $signed(coef_mem[bank_sel][band_idx][1]);
                    p_b2_r <= $signed(x2_r[band_idx]) * $signed(coef_mem[bank_sel][band_idx][2]);
                    p_a1_r <= $signed(y1_r[band_idx]) * $signed(coef_mem[bank_sel][band_idx][3]);
                    p_a2_r <= $signed(y2_r[band_idx]) * $signed(coef_mem[bank_sel][band_idx][4]);
                    state  <= ST_ACC;
                end

                ST_ACC: begin
                    x2_l[band_idx] <= x1_l[band_idx];
                    x1_l[band_idx] <= cur_x_l;
                    y2_l[band_idx] <= y1_l[band_idx];
                    y1_l[band_idx] <= y_l_comb;

                    x2_r[band_idx] <= x1_r[band_idx];
                    x1_r[band_idx] <= cur_x_r;
                    y2_r[band_idx] <= y1_r[band_idx];
                    y1_r[band_idx] <= y_r_comb;

                    cur_x_l <= y_l_comb;
                    cur_x_r <= y_r_comb;

                    if (band_idx == BAND_W'(NUM_BANDS - 1)) begin
                        out_data_l <= y_l_comb;
                        out_data_r <= y_r_comb;
                        out_valid  <= 1'b1;
                        state      <= ST_IDLE;
                    end else begin
                        band_idx <= band_idx + 1'b1;
                        state    <= ST_MUL;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
