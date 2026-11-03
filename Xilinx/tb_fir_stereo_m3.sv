`timescale 1ns / 1ps
`define SIM

// =============================================================================
// TB_FIR_STEREO_M3 — Milestone 3 End-to-End Stereo Wrapper + Quad-MAC URAM Test
//
// Instantiates fir_polyphase_stereo (with QUAD_URAM_EN=1 and SYM_FOLD_EN=1),
// loads all 18-bit coefficients through the coef_we/coef_wmac/coef_waddr port
// into the PARITY_INTERLEAVED Quad-MAC URAMs, and verifies both Left and Right
// interpolated outputs for 0-LSB bit-exactness against a 2N-tap golden model.
// =============================================================================
module tb_fir_stereo_m3;

    localparam int NUM_MACS       = 64;   // 16 Quad-MAC URAM288 instances
    localparam int TAPS_PER_PHASE = 16;
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;
    localparam int NUM_PHASES     = 16;
    localparam int COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE;
    localparam int HALF_HIST_LEN  = NUM_MACS * TAPS_PER_PHASE;
    localparam int FULL_HIST_LEN  = 2 * HALF_HIST_LEN;

    logic                                clk = 0;
    logic                                rst_n = 0;
    logic [1:0]                          rate_shift = 2'd0;
    logic                                input_overrun;
    logic                                new_sample_valid = 0;
    logic signed [DATA_WIDTH-1:0]        new_sample_l = '0;
    logic signed [DATA_WIDTH-1:0]        new_sample_r = '0;
    logic signed [ACC_WIDTH-1:0]         interpolated_l;
    logic                                interpolated_l_valid;
    logic signed [ACC_WIDTH-1:0]         interpolated_r;
    logic                                interpolated_r_valid;
    logic                                input_frame_done;

    logic                                coef_we = 0;
    logic [$clog2(COEF_DEPTH)-1:0]       coef_waddr = '0;
    logic signed [COEF_WIDTH-1:0]        coef_wdata = '0;
    logic [$clog2(NUM_MACS)-1:0]         coef_wmac = '0;

    always #1.65 clk = ~clk;

    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .SYM_FOLD_EN    (1'b1),
        .QUAD_URAM_EN   (1'b1)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .rate_shift           (rate_shift),
        .input_overrun        (input_overrun),
        .new_sample_valid     (new_sample_valid),
        .new_sample_l         (new_sample_l),
        .new_sample_r         (new_sample_r),
        .interpolated_l       (interpolated_l),
        .interpolated_l_valid (interpolated_l_valid),
        .interpolated_r       (interpolated_r),
        .interpolated_r_valid (interpolated_r_valid),
        .input_frame_done     (input_frame_done),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (1'b0),
        .bank_load_target     (1'b0)
    );

    logic signed [COEF_WIDTH-1:0] gold_coef  [0:NUM_MACS-1][0:COEF_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] gold_hist_l[0:FULL_HIST_LEN-1];
    logic signed [DATA_WIDTH-1:0] gold_hist_r[0:FULL_HIST_LEN-1];
    logic signed [ACC_WIDTH-1:0]  exp_queue_l[$];
    logic signed [ACC_WIDTH-1:0]  exp_queue_r[$];
    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic push_stereo_golden(
        input logic signed [DATA_WIDTH-1:0] sl,
        input logic signed [DATA_WIDTH-1:0] sr
    );
        int active_phases;
        for (int k = FULL_HIST_LEN - 1; k > 0; k--) begin
            gold_hist_l[k] = gold_hist_l[k-1];
            gold_hist_r[k] = gold_hist_r[k-1];
        end
        gold_hist_l[0] = sl;
        gold_hist_r[0] = sr;

        active_phases = NUM_PHASES >> rate_shift;
        for (int p = 0; p < active_phases; p++) begin
            automatic logic signed [ACC_WIDTH-1:0] sum_l = '0;
            automatic logic signed [ACC_WIDTH-1:0] sum_r = '0;
            automatic int p_conj = active_phases - 1 - p;

            for (int m = 0; m < NUM_MACS; m++) begin
                for (int t = 0; t < TAPS_PER_PHASE; t++) begin
                    automatic int k_fwd = m * TAPS_PER_PHASE + t;
                    automatic int k_rev = FULL_HIST_LEN - 1 - k_fwd;
                    automatic logic signed [COEF_WIDTH-1:0] c_fwd = gold_coef[m][p * TAPS_PER_PHASE + t];
                    automatic logic signed [COEF_WIDTH-1:0] c_rev = gold_coef[m][p_conj * TAPS_PER_PHASE + t];

                    sum_l += ($signed(gold_hist_l[k_fwd]) + $signed(gold_hist_l[k_fwd])) * c_fwd
                           + ($signed(gold_hist_l[k_rev]) + $signed(gold_hist_l[k_rev])) * c_rev;
                    sum_r += ($signed(gold_hist_r[k_fwd]) + $signed(gold_hist_r[k_fwd])) * c_fwd
                           + ($signed(gold_hist_r[k_rev]) + $signed(gold_hist_r[k_rev])) * c_rev;
                end
            end
            exp_queue_l.push_back(sum_l);
            exp_queue_r.push_back(sum_r);
        end
    endtask

    initial begin
        for (int k = 0; k < FULL_HIST_LEN; k++) begin
            gold_hist_l[k] = '0;
            gold_hist_r[k] = '0;
        end

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        wait (dut.u_l_fir.history_clear == 1'b0);
        repeat (5) @(posedge clk);

        // 1. Load all 64 MACs x 256 addresses via the write bus into the 16 Quad-MAC URAMs
        for (int m = 0; m < NUM_MACS; m++) begin
            for (int a = 0; a < COEF_DEPTH; a++) begin
                automatic logic signed [COEF_WIDTH-1:0] c =
                    COEF_WIDTH'($urandom_range(0, (1<<COEF_WIDTH)-1));
                gold_coef[m][a] = c;
                @(posedge clk);
                coef_we    <= 1'b1;
                coef_wmac  <= $clog2(NUM_MACS)'(m);
                coef_waddr <= $clog2(COEF_DEPTH)'(a);
                coef_wdata <= c;
            end
        end
        @(posedge clk);
        coef_we <= 1'b0;
        repeat (10) @(posedge clk); // Let 3-stage write broadcast tree drain

        // 2. Test stereo samples across rate_shift = 2, 1, 0
        for (int rs = 2; rs >= 0; rs--) begin
            rate_shift <= 2'(rs);
            repeat (5) @(posedge clk);
            for (int s = 0; s < 4; s++) begin
                automatic logic signed [DATA_WIDTH-1:0] sl =
                    DATA_WIDTH'($urandom_range(0, (1<<DATA_WIDTH)-1));
                automatic logic signed [DATA_WIDTH-1:0] sr =
                    DATA_WIDTH'($urandom_range(0, (1<<DATA_WIDTH)-1));
                @(posedge clk);
                new_sample_l     <= sl;
                new_sample_r     <= sr;
                new_sample_valid <= 1'b1;
                push_stereo_golden(sl, sr);
                @(posedge clk);
                new_sample_valid <= 1'b0;
                wait (input_frame_done == 1'b1);
                repeat (5) @(posedge clk);
            end
        end

        repeat (20) @(posedge clk);
        if (fail_cnt == 0 && exp_queue_l.size() == 0 && exp_queue_r.size() == 0 && !input_overrun)
            $display("[TB_FIR_STEREO_M3] PASS: All %0d L+R stereo outputs with Quad-MAC URAM + Half-Curve Fold verified bit-exact (0 LSB error)!",
                     pass_cnt);
        else
            $fatal(1, "[TB_FIR_STEREO_M3] FAIL: pass=%0d fail=%0d pend_l=%0d overrun=%0b",
                   pass_cnt, fail_cnt, exp_queue_l.size(), input_overrun);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && interpolated_l_valid) begin
            automatic logic signed [ACC_WIDTH-1:0] exp_l = exp_queue_l.pop_front();
            automatic logic signed [ACC_WIDTH-1:0] exp_r = exp_queue_r.pop_front();
            if (interpolated_l === exp_l && interpolated_r === exp_r) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
                $error("[TB_FIR_STEREO_M3] Mismatch! L got=0x%012h exp=0x%012h | R got=0x%012h exp=0x%012h",
                       interpolated_l, exp_l, interpolated_r, exp_r);
            end
        end
    end

endmodule
