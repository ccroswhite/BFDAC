`timescale 1ns / 1ps

// =============================================================================
// FIR_STAGE1B_INTERP8 — Stereo 48-Bit Rate-Selectable x8/x4/x2/x1 Interpolator
// =============================================================================

module fir_s1b_sync_fifo #(
    parameter int WIDTH = 96,
    parameter int DEPTH = 16
)(
    input  logic             clk,
    input  logic             rst_n,
    input  logic             flush,
    input  logic             in_valid,
    output logic             in_ready,
    input  logic [WIDTH-1:0] in_data,
    output logic             out_valid,
    input  logic             out_ready,
    output logic [WIDTH-1:0] out_data
);
    localparam int AW    = $clog2(DEPTH);
    localparam int CNT_W = AW + 1;

    (* ram_style = "registers" *)
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]    wr_ptr, rd_ptr;
    logic [CNT_W-1:0] count;

    wire full    = (count == CNT_W'(DEPTH));
    wire empty   = (count == '0);
    wire do_push = in_valid && !full;
    wire do_pop  = out_ready && !empty;

    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = mem[rd_ptr];

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_push)
                wr_ptr <= wr_ptr + AW'(1);
            if (do_pop)
                rd_ptr <= rd_ptr + AW'(1);
            case ({do_push, do_pop})
                2'b10:   count <= count + CNT_W'(1);
                2'b01:   count <= count - CNT_W'(1);
                default: count <= count;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (do_push)
            mem[wr_ptr] <= in_data;
    end
endmodule

(* use_dsp = "yes" *)
module fir_s1b_dsp_lane (
    input  logic               clk,
    input  logic               vld_in,
    input  logic               first_in,
    input  logic signed [24:0] a_in,
    input  logic signed [17:0] b_in,
    output logic signed [47:0] acc_out
);
    logic signed [24:0] a_r1 = '0;
    logic signed [17:0] b_r1 = '0;
    logic signed [42:0] m_r2 = '0;
    logic signed [47:0] p_r3 = '0;
    logic               v_r1 = 1'b0, v_r2 = 1'b0;
    logic               f_r1 = 1'b0, f_r2 = 1'b0;

    always_ff @(posedge clk) begin
        v_r1 <= vld_in;
        f_r1 <= first_in;
        if (vld_in) begin
            a_r1 <= a_in;
            b_r1 <= b_in;
        end

        v_r2 <= v_r1;
        f_r2 <= f_r1;
        if (v_r1)
            m_r2 <= a_r1 * b_r1;

        if (v_r2) begin
            if (f_r2)
                p_r3 <= m_r2;
            else
                p_r3 <= p_r3 + m_r2;
        end
    end

    assign acc_out = p_r3;
endmodule

module fir_s1b_hb_poly_x2 #(
    parameter int NUM_TAPS = 63
)(
    input  logic                clk,
    input  logic                rst_n,
    input  logic                flush,
    input  logic                in_valid,
    output logic                in_ready,
    input  logic signed [47:0]  in_l,
    input  logic signed [47:0]  in_r,
    output logic                out_valid,
    input  logic                out_ready,
    output logic signed [47:0]  out_l,
    output logic signed [47:0]  out_r
);
    localparam int K       = (NUM_TAPS + 1) / 4;
    localparam int DL_LEN  = 2 * K;
    localparam int R_WIDTH = $clog2(K);

    initial begin
        assert ((NUM_TAPS == 63) || (NUM_TAPS == 31))
            else $fatal(1, "fir_s1b_hb_poly_x2: NUM_TAPS (%0d) must be 63 or 31", NUM_TAPS);
    end

    function automatic logic signed [17:0] get_coef(input int idx);
        if (NUM_TAPS == 63) begin
            case (idx)
                0:       return 18'sh0A1AA;
                1:       return 18'sh3CD7C;
                2:       return 18'sh01A9D;
                3:       return 18'sh3F065;
                4:       return 18'sh0094C;
                5:       return 18'sh3FA96;
                6:       return 18'sh00303;
                7:       return 18'sh3FE6C;
                8:       return 18'sh000C4;
                9:       return 18'sh3FFAA;
                10:      return 18'sh00022;
                11:      return 18'sh3FFF5;
                12:      return 18'sh00003;
                13:      return 18'sh3FFFF;
                default: return 18'sh00000;
            endcase
        end else begin
            case (idx)
                0:       return 18'sh09E55;
                1:       return 18'sh3D636;
                2:       return 18'sh00F85;
                3:       return 18'sh3FACB;
                4:       return 18'sh0015D;
                5:       return 18'sh3FFC3;
                6:       return 18'sh00005;
                default: return 18'sh00000;
            endcase
        end
    endfunction

    function automatic logic signed [47:0] round_sat48(
        input logic signed [47:0] acc_hi,
        input logic signed [47:0] acc_lo
    );
        logic signed [70:0] ext_hi, ext_lo, full_sum, rounded, scaled;
        ext_hi   = $signed({{23{acc_hi[47]}}, acc_hi});
        ext_lo   = $signed({{23{acc_lo[47]}}, acc_lo});
        full_sum = (ext_hi <<< 24) + ext_lo;
        rounded  = full_sum + 71'sd32768;
        scaled   = rounded >>> 16;

        if (scaled[70:47] == '0 || scaled[70:47] == '1)
            return scaled[47:0];
        else
            return scaled[70] ? 48'sh8000_0000_0000 : 48'sh7FFF_FFFF_FFFF;
    endfunction

    typedef enum logic [2:0] {
        HB_IDLE  = 3'd0,
        HB_SWEEP = 3'd1,
        HB_WAIT  = 3'd2,
        HB_EMIT0 = 3'd3,
        HB_EMIT1 = 3'd4
    } hb_state_t;

    hb_state_t           state;
    logic [R_WIDTH-1:0]  r_cnt;
    logic signed [47:0]  d_l [0:DL_LEN-1];
    logic signed [47:0]  d_r [0:DL_LEN-1];

    logic signed [48:0]  sum_l_p0, sum_r_p0;
    logic signed [17:0]  coef_p0;
    logic                vld_p0, first_p0, last_p0;
    logic                last_r1, last_r2, last_r3;

    logic signed [47:0]  acc_lo_l, acc_hi_l, acc_lo_r, acc_hi_r;
    logic signed [47:0]  mid_l_reg, mid_r_reg;
    logic signed [47:0]  pass_l_reg, pass_r_reg;

    assign in_ready = (state == HB_IDLE) && !flush;

    always_ff @(posedge clk) begin
        if (!rst_n || flush) begin
            state      <= HB_IDLE;
            r_cnt      <= '0;
            for (int i = 0; i < DL_LEN; i++) begin
                d_l[i] <= '0;
                d_r[i] <= '0;
            end
            sum_l_p0   <= '0;
            sum_r_p0   <= '0;
            coef_p0    <= '0;
            vld_p0     <= 1'b0;
            first_p0   <= 1'b0;
            last_p0    <= 1'b0;
            last_r1    <= 1'b0;
            last_r2    <= 1'b0;
            last_r3    <= 1'b0;
            mid_l_reg  <= '0;
            mid_r_reg  <= '0;
            pass_l_reg <= '0;
            pass_r_reg <= '0;
        end else begin
            vld_p0   <= 1'b0;
            first_p0 <= 1'b0;
            last_p0  <= 1'b0;
            last_r1  <= vld_p0 & last_p0;
            last_r2  <= last_r1;
            last_r3  <= last_r2;

            case (state)
                HB_IDLE: begin
                    if (in_valid) begin
                        d_l[0] <= in_l;
                        d_r[0] <= in_r;
                        for (int i = 1; i < DL_LEN; i++) begin
                            d_l[i] <= d_l[i-1];
                            d_r[i] <= d_r[i-1];
                        end
                        r_cnt <= '0;
                        state <= HB_SWEEP;
                    end
                end

                HB_SWEEP: begin
                    if (r_cnt == '0) begin
                        pass_l_reg <= d_l[K - 1];
                        pass_r_reg <= d_r[K - 1];
                    end
                    sum_l_p0 <= d_l[K - 1 - int'(r_cnt)] + d_l[K + int'(r_cnt)];
                    sum_r_p0 <= d_r[K - 1 - int'(r_cnt)] + d_r[K + int'(r_cnt)];
                    coef_p0  <= get_coef(int'(r_cnt));
                    vld_p0   <= 1'b1;
                    first_p0 <= (r_cnt == '0);
                    if (r_cnt == R_WIDTH'(K - 1)) begin
                        last_p0 <= 1'b1;
                        state   <= HB_WAIT;
                    end else begin
                        r_cnt   <= r_cnt + R_WIDTH'(1);
                    end
                end

                HB_WAIT: begin
                    if (last_r3) begin
                        mid_l_reg <= round_sat48(acc_hi_l, acc_lo_l);
                        mid_r_reg <= round_sat48(acc_hi_r, acc_lo_r);
                        state     <= HB_EMIT0;
                    end
                end

                HB_EMIT0: begin
                    if (out_ready)
                        state <= HB_EMIT1;
                end

                HB_EMIT1: begin
                    if (out_ready)
                        state <= HB_IDLE;
                end

                default: state <= HB_IDLE;
            endcase
        end
    end

    wire signed [24:0] lo_l_in = $signed({1'b0, sum_l_p0[23:0]});
    wire signed [24:0] hi_l_in = $signed(sum_l_p0[48:24]);
    wire signed [24:0] lo_r_in = $signed({1'b0, sum_r_p0[23:0]});
    wire signed [24:0] hi_r_in = $signed(sum_r_p0[48:24]);

    fir_s1b_dsp_lane u_dsp_lo_l (
        .clk(clk), .vld_in(vld_p0), .first_in(first_p0),
        .a_in(lo_l_in), .b_in(coef_p0), .acc_out(acc_lo_l)
    );
    fir_s1b_dsp_lane u_dsp_hi_l (
        .clk(clk), .vld_in(vld_p0), .first_in(first_p0),
        .a_in(hi_l_in), .b_in(coef_p0), .acc_out(acc_hi_l)
    );
    fir_s1b_dsp_lane u_dsp_lo_r (
        .clk(clk), .vld_in(vld_p0), .first_in(first_p0),
        .a_in(lo_r_in), .b_in(coef_p0), .acc_out(acc_lo_r)
    );
    fir_s1b_dsp_lane u_dsp_hi_r (
        .clk(clk), .vld_in(vld_p0), .first_in(first_p0),
        .a_in(hi_r_in), .b_in(coef_p0), .acc_out(acc_hi_r)
    );

    always_comb begin
        case (state)
            HB_EMIT0: begin
                out_valid = 1'b1;
                out_l     = mid_l_reg;
                out_r     = mid_r_reg;
            end
            HB_EMIT1: begin
                out_valid = 1'b1;
                out_l     = pass_l_reg;
                out_r     = pass_r_reg;
            end
            default: begin
                out_valid = 1'b0;
                out_l     = '0;
                out_r     = '0;
            end
        endcase
    end
endmodule

module fir_stage1b_interp8 #(
    parameter int DATA_WIDTH     = 48,
    parameter int OUT_SPACING    = 16,
    parameter int IN_FIFO_DEPTH  = 16,
    parameter int OUT_FIFO_DEPTH = 32
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  tri0 [1:0]                    rate_shift,
    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic signed [DATA_WIDTH-1:0] in_l,
    input  logic signed [DATA_WIDTH-1:0] in_r,
    output logic                         input_overrun,
    output logic                         out_valid,
    output logic signed [DATA_WIDTH-1:0] out_l,
    output logic signed [DATA_WIDTH-1:0] out_r,
    output logic                         out_frame_done
);
    initial begin
        assert (DATA_WIDTH == 48)
            else $fatal(1, "fir_stage1b_interp8: DATA_WIDTH (%0d) must be 48", DATA_WIDTH);
        assert (OUT_SPACING >= 8)
            else $fatal(1, "fir_stage1b_interp8: OUT_SPACING (%0d) must be >= 8", OUT_SPACING);
    end

    logic [1:0] rate_shift_q;
    wire        rate_flush = (rate_shift != rate_shift_q);

    always_ff @(posedge clk) begin
        if (!rst_n)
            rate_shift_q <= 2'd0;
        else
            rate_shift_q <= rate_shift;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || rate_flush)
            input_overrun <= 1'b0;
        else if (in_valid && !in_ready)
            input_overrun <= 1'b1;
    end

    logic        ififo_valid, ififo_ready;
    logic [95:0] ififo_dout;
    wire signed [47:0] ififo_l = $signed(ififo_dout[95:48]);
    wire signed [47:0] ififo_r = $signed(ififo_dout[47:0]);

    fir_s1b_sync_fifo #(
        .WIDTH(96),
        .DEPTH(IN_FIFO_DEPTH)
    ) u_in_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .flush    (rate_flush),
        .in_valid (in_valid),
        .in_ready (in_ready),
        .in_data  ({in_l, in_r}),
        .out_valid(ififo_valid),
        .out_ready(ififo_ready),
        .out_data (ififo_dout)
    );

    logic               s1_in_valid,  s1_in_ready;
    logic               s1_out_valid, s1_out_ready;
    logic signed [47:0] s1_out_l,     s1_out_r;

    logic               s2_in_valid,  s2_in_ready;
    logic signed [47:0] s2_in_l,      s2_in_r;
    logic               s2_out_valid, s2_out_ready;
    logic signed [47:0] s2_out_l,     s2_out_r;

    logic               s3_in_valid,  s3_in_ready;
    logic signed [47:0] s3_in_l,      s3_in_r;
    logic               s3_out_valid, s3_out_ready;
    logic signed [47:0] s3_out_l,     s3_out_r;

    logic               ofifo_in_valid, ofifo_in_ready;
    logic signed [47:0] ofifo_in_l,     ofifo_in_r;

    always_comb begin
        case (rate_shift_q)
            2'd0:    ififo_ready = s1_in_ready;
            2'd1:    ififo_ready = s2_in_ready;
            2'd2:    ififo_ready = s3_in_ready;
            default: ififo_ready = ofifo_in_ready;
        endcase

        s1_in_valid = (rate_shift_q == 2'd0) && ififo_valid;

        if (rate_shift_q == 2'd0) begin
            s2_in_valid  = s1_out_valid;
            s2_in_l      = s1_out_l;
            s2_in_r      = s1_out_r;
            s1_out_ready = s2_in_ready;
        end else begin
            s2_in_valid  = (rate_shift_q == 2'd1) && ififo_valid;
            s2_in_l      = ififo_l;
            s2_in_r      = ififo_r;
            s1_out_ready = 1'b0;
        end

        if (rate_shift_q <= 2'd1) begin
            s3_in_valid  = s2_out_valid;
            s3_in_l      = s2_out_l;
            s3_in_r      = s2_out_r;
            s2_out_ready = s3_in_ready;
        end else begin
            s3_in_valid  = (rate_shift_q == 2'd2) && ififo_valid;
            s3_in_l      = ififo_l;
            s3_in_r      = ififo_r;
            s2_out_ready = 1'b0;
        end

        if (rate_shift_q <= 2'd2) begin
            ofifo_in_valid = s3_out_valid;
            ofifo_in_l     = s3_out_l;
            ofifo_in_r     = s3_out_r;
            s3_out_ready   = ofifo_in_ready;
        end else begin
            ofifo_in_valid = ififo_valid;
            ofifo_in_l     = ififo_l;
            ofifo_in_r     = ififo_r;
            s3_out_ready   = 1'b0;
        end
    end

    fir_s1b_hb_poly_x2 #(.NUM_TAPS(63)) u_hb_s1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .flush    (rate_flush || (rate_shift_q != 2'd0)),
        .in_valid (s1_in_valid),
        .in_ready (s1_in_ready),
        .in_l     (ififo_l),
        .in_r     (ififo_r),
        .out_valid(s1_out_valid),
        .out_ready(s1_out_ready),
        .out_l    (s1_out_l),
        .out_r    (s1_out_r)
    );

    fir_s1b_hb_poly_x2 #(.NUM_TAPS(63)) u_hb_s2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .flush    (rate_flush || (rate_shift_q > 2'd1)),
        .in_valid (s2_in_valid),
        .in_ready (s2_in_ready),
        .in_l     (s2_in_l),
        .in_r     (s2_in_r),
        .out_valid(s2_out_valid),
        .out_ready(s2_out_ready),
        .out_l    (s2_out_l),
        .out_r    (s2_out_r)
    );

    fir_s1b_hb_poly_x2 #(.NUM_TAPS(31)) u_hb_s3 (
        .clk      (clk),
        .rst_n    (rst_n),
        .flush    (rate_flush || (rate_shift_q > 2'd2)),
        .in_valid (s3_in_valid),
        .in_ready (s3_in_ready),
        .in_l     (s3_in_l),
        .in_r     (s3_in_r),
        .out_valid(s3_out_valid),
        .out_ready(s3_out_ready),
        .out_l    (s3_out_l),
        .out_r    (s3_out_r)
    );

    localparam int PACE_W = $clog2(OUT_SPACING + 1);
    logic        ofifo_valid, ofifo_ready;
    logic [95:0] ofifo_dout;
    logic [PACE_W-1:0] pace_cnt;
    logic [4:0]        frame_out_cnt;

    wire [4:0] out_per_baseband_frame = 5'd16 >> rate_shift_q;
    assign ofifo_ready = !rate_flush && (pace_cnt == '0);

    fir_s1b_sync_fifo #(
        .WIDTH(96),
        .DEPTH(OUT_FIFO_DEPTH)
    ) u_out_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .flush    (rate_flush),
        .in_valid (ofifo_in_valid),
        .in_ready (ofifo_in_ready),
        .in_data  ({ofifo_in_l, ofifo_in_r}),
        .out_valid(ofifo_valid),
        .out_ready(ofifo_ready),
        .out_data (ofifo_dout)
    );

    always_ff @(posedge clk) begin
        if (!rst_n || rate_flush) begin
            pace_cnt       <= '0;
            frame_out_cnt  <= '0;
            out_valid      <= 1'b0;
            out_l          <= '0;
            out_r          <= '0;
            out_frame_done <= 1'b0;
        end else begin
            out_valid      <= 1'b0;
            out_frame_done <= 1'b0;

            if (out_valid) begin
                if (frame_out_cnt == out_per_baseband_frame - 5'd1) begin
                    out_frame_done <= 1'b1;
                    frame_out_cnt  <= '0;
                end else begin
                    frame_out_cnt  <= frame_out_cnt + 5'd1;
                end
            end

            if (pace_cnt != '0) begin
                pace_cnt <= pace_cnt - PACE_W'(1);
            end else if (ofifo_valid) begin
                out_valid <= 1'b1;
                out_l     <= $signed(ofifo_dout[95:48]);
                out_r     <= $signed(ofifo_dout[47:0]);
                pace_cnt  <= PACE_W'(OUT_SPACING - 1);
            end
        end
    end

endmodule