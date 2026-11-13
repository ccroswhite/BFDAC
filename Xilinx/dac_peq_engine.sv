`timescale 1ns / 1ps

// =============================================================================
// DAC_PEQ_ENGINE — Pipelined 8-Band Stereo Double-Precision Parametric EQ
// =============================================================================

(* use_dsp = "yes" *)
module peq_dsp_lane (
    input  logic               clk,
    input  logic signed [24:0] a_in,
    input  logic signed [17:0] b_in,
    output logic signed [47:0] p_out
);
    logic signed [24:0] a_r1 = '0;
    logic signed [17:0] b_r1 = '0;
    logic signed [42:0] m_r2 = '0;
    logic signed [47:0] p_r3 = '0;

    always_ff @(posedge clk) begin
        a_r1 <= a_in;
        b_r1 <= b_in;
        m_r2 <= a_r1 * b_r1;
        p_r3 <= $signed({{5{m_r2[42]}}, m_r2});
    end

    assign p_out = p_r3;
endmodule

module peq_mul48x32 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               vld_in,
    input  logic               first_in,
    input  logic               sub_in,
    input  logic               last_in,
    input  logic signed [47:0] x_in,
    input  logic signed [31:0] c_in,
    output logic               vld_out,
    output logic               first_out,
    output logic               sub_out,
    output logic               last_out,
    output logic signed [79:0] prod_out
);
    function automatic logic signed [79:0] sext80(input logic signed [47:0] v);
        return $signed({{32{v[47]}}, v});
    endfunction

    wire signed [24:0] x_lo = $signed({1'b0, x_in[23:0]});
    wire signed [24:0] x_hi = $signed({x_in[47], x_in[47:24]});
    wire signed [17:0] c_lo = $signed({2'b00, c_in[15:0]});
    wire signed [17:0] c_hi = $signed({{2{c_in[31]}}, c_in[31:16]});

    logic signed [47:0] p_ll, p_lh, p_hl, p_hh;

    peq_dsp_lane u_ll (.clk(clk), .a_in(x_lo), .b_in(c_lo), .p_out(p_ll));
    peq_dsp_lane u_lh (.clk(clk), .a_in(x_lo), .b_in(c_hi), .p_out(p_lh));
    peq_dsp_lane u_hl (.clk(clk), .a_in(x_hi), .b_in(c_lo), .p_out(p_hl));
    peq_dsp_lane u_hh (.clk(clk), .a_in(x_hi), .b_in(c_hi), .p_out(p_hh));

    logic [4:0] v_pipe, f_pipe, s_pipe, l_pipe;
    logic signed [79:0] pair_a, pair_b, prod_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_pipe <= '0;
            f_pipe <= '0;
            s_pipe <= '0;
            l_pipe <= '0;
            pair_a <= '0;
            pair_b <= '0;
            prod_r <= '0;
        end else begin
            v_pipe <= {v_pipe[3:0], vld_in};
            f_pipe <= {f_pipe[3:0], first_in};
            s_pipe <= {s_pipe[3:0], sub_in};
            l_pipe <= {l_pipe[3:0], last_in};

            pair_a <= sext80(p_ll) + (sext80(p_lh) <<< 16);
            pair_b <= (sext80(p_hl) <<< 24) + (sext80(p_hh) <<< 40);
            prod_r <= pair_a + pair_b;
        end
    end

    assign vld_out   = v_pipe[4];
    assign first_out = f_pipe[4];
    assign sub_out   = s_pipe[4];
    assign last_out  = l_pipe[4];
    assign prod_out  = prod_r;
endmodule

module dac_peq_engine #(
    parameter int NUM_BANDS      = 8,
    parameter int DATA_WIDTH     = 48,
    parameter int COEF_WIDTH     = 32,   // Signed Q2.30 (1.0 = 32'sh4000_0000)
    parameter int FRAC_BITS      = 30,
    parameter int MIN_OUT_SPACE  = 16
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         peq_enable,

    input  logic                         in_valid,
    input  logic signed [DATA_WIDTH-1:0] in_data_l,
    input  logic signed [DATA_WIDTH-1:0] in_data_r,

    output logic                         out_valid,
    output logic signed [DATA_WIDTH-1:0] out_data_l,
    output logic signed [DATA_WIDTH-1:0] out_data_r,

    input  logic                         coef_wr_en     = 1'b0,
    input  logic [$clog2(NUM_BANDS)-1:0] coef_wr_band   = '0,
    input  logic [2:0]                   coef_wr_idx    = '0,
    input  logic signed [COEF_WIDTH-1:0] coef_wr_data   = '0,
    input  logic                         coef_swap_req  = 1'b0,
    output logic                         active_bank
);

    initial begin
        assert (DATA_WIDTH == 48 && COEF_WIDTH == 32)
            else $fatal(1, "dac_peq_engine requires DATA_WIDTH=48, COEF_WIDTH=32");
    end

    localparam int PROD_W   = DATA_WIDTH + COEF_WIDTH; // 80
    localparam int ACC_W    = PROD_W + 4;              // 84
    localparam int BAND_W   = $clog2(NUM_BANDS);
    localparam int FIFO_D   = 32;
    localparam int FIFO_AW  = $clog2(FIFO_D);
    localparam int FIFO_CW  = FIFO_AW + 1;
    localparam int GUARD_HI = ACC_W - 1;
    localparam int SIGN_BIT = DATA_WIDTH - 1;

    localparam logic signed [COEF_WIDTH-1:0] UNITY_B0   = COEF_WIDTH'(1) <<< FRAC_BITS;
    localparam logic signed [ACC_W-1:0]      ROUND_BIAS = ACC_W'(1) <<< (FRAC_BITS - 1);
    localparam logic signed [DATA_WIDTH-1:0] SAT_POS_48 = 48'sh7FFF_FFFF_FFFF;
    localparam logic signed [DATA_WIDTH-1:0] SAT_NEG_48 = 48'sh8000_0000_0000;

    function automatic logic signed [ACC_W-1:0] sext84(input logic signed [PROD_W-1:0] v);
        return $signed({{4{v[PROD_W-1]}}, v});
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] sat_data(input logic signed [ACC_W-1:0] val);
        if (val[GUARD_HI:SIGN_BIT] == '0 || val[GUARD_HI:SIGN_BIT] == '1)
            return val[DATA_WIDTH-1:0];
        else
            return val[GUARD_HI] ? SAT_NEG_48 : SAT_POS_48;
    endfunction

    // -------------------------------------------------------------------------
    // 1. 32-Deep Elastic Input FIFO
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    logic [2*DATA_WIDTH-1:0] fifo_mem [0:FIFO_D-1];
    logic [FIFO_AW-1:0]      wr_ptr, rd_ptr;
    logic [FIFO_CW-1:0]      fifo_cnt;
    logic                    fifo_pop;

    wire fifo_empty = (fifo_cnt == '0);
    wire fifo_push  = in_valid && (fifo_cnt < FIFO_CW'(FIFO_D));
    wire [2*DATA_WIDTH-1:0] fifo_dout = fifo_mem[rd_ptr];
    wire signed [DATA_WIDTH-1:0] fifo_head_l = $signed(fifo_dout[2*DATA_WIDTH-1:DATA_WIDTH]);
    wire signed [DATA_WIDTH-1:0] fifo_head_r = $signed(fifo_dout[DATA_WIDTH-1:0]);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            fifo_cnt <= '0;
        end else begin
            if (fifo_push)
                wr_ptr <= wr_ptr + FIFO_AW'(1);
            if (fifo_pop)
                rd_ptr <= rd_ptr + FIFO_AW'(1);
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_cnt <= fifo_cnt + FIFO_CW'(1);
                2'b01:   fifo_cnt <= fifo_cnt - FIFO_CW'(1);
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (fifo_push)
            fifo_mem[wr_ptr] <= {in_data_l, in_data_r};
    end

    // -------------------------------------------------------------------------
    // 2. Dual-Bank Coefficients, State History & Pipelined Biquad Sequencer
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
        ST_ISSUE    = 2'd1,
        ST_WAIT_ACC = 2'd2,
        ST_BYP_WAIT = 2'd3
    } state_t;

    state_t                       state;
    logic [BAND_W-1:0]            band_idx;
    logic [2:0]                   tap_idx;
    logic [4:0]                   byp_wait_cnt;
    logic signed [DATA_WIDTH-1:0] cur_x_l, cur_x_r;

    // Registered multiplier launch stage
    logic                         op_vld, op_first, op_sub, op_last;
    logic signed [DATA_WIDTH-1:0] op_x_l, op_x_r;
    logic signed [COEF_WIDTH-1:0] op_c;

    // Multiplier outputs
    logic                         mul_vld_l, mul_first_l, mul_sub_l, mul_last_l;
    logic                         mul_vld_r, mul_first_r, mul_sub_r, mul_last_r;
    logic signed [PROD_W-1:0]     prod_l, prod_r;

    peq_mul48x32 u_mul_l (
        .clk      (clk),       .rst_n    (rst_n),
        .vld_in   (op_vld),    .first_in (op_first),
        .sub_in   (op_sub),    .last_in  (op_last),
        .x_in     (op_x_l),    .c_in     (op_c),
        .vld_out  (mul_vld_l), .first_out(mul_first_l),
        .sub_out  (mul_sub_l), .last_out (mul_last_l),
        .prod_out (prod_l)
    );

    peq_mul48x32 u_mul_r (
        .clk      (clk),       .rst_n    (rst_n),
        .vld_in   (op_vld),    .first_in (op_first),
        .sub_in   (op_sub),    .last_in  (op_last),
        .x_in     (op_x_r),    .c_in     (op_c),
        .vld_out  (mul_vld_r), .first_out(mul_first_r),
        .sub_out  (mul_sub_r), .last_out (mul_last_r),
        .prod_out (prod_r)
    );

    // Single 2-input 84-bit running accumulator per channel
    logic signed [ACC_W-1:0] acc_l, acc_r;
    logic                    acc_done_p;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_l      <= '0;
            acc_r      <= '0;
            acc_done_p <= 1'b0;
        end else begin
            acc_done_p <= mul_vld_l && mul_last_l;
            if (mul_vld_l) begin
                if (mul_first_l) begin
                    acc_l <= ROUND_BIAS + sext84(prod_l);
                    acc_r <= ROUND_BIAS + sext84(prod_r);
                end else if (mul_sub_l) begin
                    acc_l <= acc_l - sext84(prod_l);
                    acc_r <= acc_r - sext84(prod_r);
                end else begin
                    acc_l <= acc_l + sext84(prod_l);
                    acc_r <= acc_r + sext84(prod_r);
                end
            end
        end
    end

    wire signed [DATA_WIDTH-1:0] y_l_sat = sat_data(acc_l >>> FRAC_BITS);
    wire signed [DATA_WIDTH-1:0] y_r_sat = sat_data(acc_r >>> FRAC_BITS);

    assign fifo_pop = (state == ST_IDLE) && !fifo_empty;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bank_sel     <= 1'b0;
            swap_pend    <= 1'b0;
            state        <= ST_IDLE;
            band_idx     <= '0;
            tap_idx      <= '0;
            byp_wait_cnt <= '0;
            cur_x_l      <= '0;
            cur_x_r      <= '0;
            op_vld       <= 1'b0;
            op_first     <= 1'b0;
            op_sub       <= 1'b0;
            op_last      <= 1'b0;
            op_x_l       <= '0;
            op_x_r       <= '0;
            op_c         <= '0;
            out_valid    <= 1'b0;
            out_data_l   <= '0;
            out_data_r   <= '0;
            for (int b = 0; b < NUM_BANDS; b++) begin
                x1_l[b] <= '0; x2_l[b] <= '0; y1_l[b] <= '0; y2_l[b] <= '0;
                x1_r[b] <= '0; x2_r[b] <= '0; y1_r[b] <= '0; y2_r[b] <= '0;
                for (int bank = 0; bank < 2; bank++) begin
                    coef_mem[bank][b][0] <= UNITY_B0;
                    coef_mem[bank][b][1] <= '0;
                    coef_mem[bank][b][2] <= '0;
                    coef_mem[bank][b][3] <= '0;
                    coef_mem[bank][b][4] <= '0;
                end
            end
        end else begin
            out_valid <= 1'b0;
            op_vld    <= 1'b0;
            op_first  <= 1'b0;
            op_sub    <= 1'b0;
            op_last   <= 1'b0;

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
                            out_data_l <= fifo_head_l;
                            out_data_r <= fifo_head_r;
                            out_valid  <= 1'b1;
                            if (MIN_OUT_SPACE > 1) begin
                                byp_wait_cnt <= 5'(MIN_OUT_SPACE - 1);
                                state        <= ST_BYP_WAIT;
                            end
                        end else begin
                            cur_x_l  <= fifo_head_l;
                            cur_x_r  <= fifo_head_r;
                            band_idx <= '0;
                            tap_idx  <= '0;
                            state    <= ST_ISSUE;
                        end
                    end
                end

                ST_BYP_WAIT: begin
                    if (byp_wait_cnt <= 5'd1)
                        state <= ST_IDLE;
                    else
                        byp_wait_cnt <= byp_wait_cnt - 5'd1;
                end

                ST_ISSUE: begin
                    op_vld   <= 1'b1;
                    op_first <= (tap_idx == 3'd0);
                    op_sub   <= (tap_idx >= 3'd3);
                    op_last  <= (tap_idx == 3'd4);
                    op_c     <= coef_mem[bank_sel][band_idx][tap_idx];
                    case (tap_idx)
                        3'd0: begin op_x_l <= cur_x_l;        op_x_r <= cur_x_r;        end
                        3'd1: begin op_x_l <= x1_l[band_idx]; op_x_r <= x1_r[band_idx]; end
                        3'd2: begin op_x_l <= x2_l[band_idx]; op_x_r <= x2_r[band_idx]; end
                        3'd3: begin op_x_l <= y1_l[band_idx]; op_x_r <= y1_r[band_idx]; end
                        default: begin op_x_l <= y2_l[band_idx]; op_x_r <= y2_r[band_idx]; end
                    endcase

                    if (tap_idx == 3'd4) begin
                        tap_idx <= '0;
                        state   <= ST_WAIT_ACC;
                    end else begin
                        tap_idx <= tap_idx + 3'd1;
                    end
                end

                ST_WAIT_ACC: begin
                    if (acc_done_p) begin
                        x2_l[band_idx] <= x1_l[band_idx];
                        x1_l[band_idx] <= cur_x_l;
                        y2_l[band_idx] <= y1_l[band_idx];
                        y1_l[band_idx] <= y_l_sat;

                        x2_r[band_idx] <= x1_r[band_idx];
                        x1_r[band_idx] <= cur_x_r;
                        y2_r[band_idx] <= y1_r[band_idx];
                        y1_r[band_idx] <= y_r_sat;

                        cur_x_l <= y_l_sat;
                        cur_x_r <= y_r_sat;

                        if (band_idx == BAND_W'(NUM_BANDS - 1)) begin
                            out_data_l <= y_l_sat;
                            out_data_r <= y_r_sat;
                            out_valid  <= 1'b1;
                            state      <= ST_IDLE;
                        end else begin
                            band_idx <= band_idx + BAND_W'(1);
                            tap_idx  <= '0;
                            state    <= ST_ISSUE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
