`timescale 1ns / 1ps
`define SIM

// =============================================================================
// TB_FIR_STEREO_M5 — Milestone 5 Two-Stage (x2 -> x8) Bit-Exact Verification
//
// Verifies fir_polyphase_stereo (TWO_STAGE_EN=1, SYM_FOLD_EN=1, WIN_BRAM_EN=1,
// QUAD_URAM_EN=0) across:
//   1. rate_shift = 3 (DXD x2 total, Stage 1B 0-LSB bypass, 520 samples full
//      forward + reverse DOB_REG=1 BRAM window wrap across group boundaries)
//   2. rate_shift = 2 (x4 total: Stage 1A x2 -> Stage 1B S3 31t)
//   3. rate_shift = 1 (x8 total: Stage 1A x2 -> Stage 1B S2 63t -> S3 31t)
//   4. rate_shift = 0 (x16 total: Stage 1A x2 -> Stage 1B S1 63t -> S2 63t -> S3 31t)
//   5. Live gapless Bank A -> Bank B coefficient switch at rate_shift = 0
//   6. >= 16-clock output spacing & zero input_overrun assertions
// =============================================================================
module tb_fir_stereo_m5;

    localparam int NUM_MACS       = 16;  // 2 groups of 8 MACs, 8 dual-bank URAMs
    localparam int TAPS_PER_PHASE = 16;  // S1A_TPP = 128, COEF_DEPTH = 256
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;

    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE; // 256
    localparam int S1A_TPP        = 8 * TAPS_PER_PHASE;  // 128
    localparam int MAX_HALF_LEN   = NUM_MACS * S1A_TPP;  // 2048
    localparam int MAX_FULL_LEN   = 2 * MAX_HALF_LEN;    // 4096

    logic                                clk              = 1'b0;
    logic                                rst_n            = 1'b0;
    logic [1:0]                          rate_shift       = 2'd3;
    logic                                input_overrun;
    logic                                new_sample_valid = 1'b0;
    logic signed [DATA_WIDTH-1:0]        new_sample_l     = '0;
    logic signed [DATA_WIDTH-1:0]        new_sample_r     = '0;
    logic signed [ACC_WIDTH-1:0]         interpolated_l;
    logic                                interpolated_l_valid;
    logic signed [ACC_WIDTH-1:0]         interpolated_r;
    logic                                interpolated_r_valid;
    logic                                input_frame_done;

    logic                                coef_we          = 1'b0;
    logic [$clog2(COEF_DEPTH)-1:0]       coef_waddr       = '0;
    logic signed [COEF_WIDTH-1:0]        coef_wdata       = '0;
    logic [$clog2(NUM_MACS)-1:0]         coef_wmac        = '0;
    logic                                bank_select      = 1'b0;
    logic                                bank_load_target = 1'b0;

    always #1.65 clk = ~clk; // ~303.03 MHz dsp_clk

    fir_polyphase_stereo #(
        .NUM_MACS      (NUM_MACS),
        .TAPS_PER_PHASE(TAPS_PER_PHASE),
        .DATA_WIDTH    (DATA_WIDTH),
        .COEF_WIDTH    (COEF_WIDTH),
        .ACC_WIDTH     (ACC_WIDTH),
        .SYM_FOLD_EN   (1'b1),
        .QUAD_URAM_EN  (1'b0),
        .TWO_STAGE_EN  (1'b1),
        .WIN_BRAM_EN   (1'b1)
    ) dut (
        .clk                 (clk),
        .rst_n               (rst_n),
        .rate_shift          (rate_shift),
        .input_overrun       (input_overrun),
        .new_sample_valid    (new_sample_valid),
        .new_sample_l        (new_sample_l),
        .new_sample_r        (new_sample_r),
        .interpolated_l      (interpolated_l),
        .interpolated_l_valid(interpolated_l_valid),
        .interpolated_r      (interpolated_r),
        .interpolated_r_valid(interpolated_r_valid),
        .input_frame_done    (input_frame_done),
        .coef_we             (coef_we),
        .coef_waddr          (coef_waddr),
        .coef_wdata          (coef_wdata),
        .coef_wmac           (coef_wmac),
        .bank_select         (bank_select),
        .bank_load_target    (bank_load_target)
    );

    // -------------------------------------------------------------------------
    // Independent Golden Reference State (Dual-Bank Stage 1A + Stage 1B S1..S3)
    // -------------------------------------------------------------------------
    logic signed [COEF_WIDTH-1:0] gold_coef   [0:1][0:NUM_MACS-1][0:COEF_DEPTH-1];
    logic signed [DATA_WIDTH-1:0] gold_hist_l [0:MAX_FULL_LEN-1];
    logic signed [DATA_WIDTH-1:0] gold_hist_r [0:MAX_FULL_LEN-1];

    logic signed [47:0] s1_dl_l [0:31], s1_dl_r [0:31];
    logic signed [47:0] s2_dl_l [0:31], s2_dl_r [0:31];
    logic signed [47:0] s3_dl_l [0:15], s3_dl_r [0:15];

    logic signed [ACC_WIDTH-1:0] exp_queue_l[$];
    logic signed [ACC_WIDTH-1:0] exp_queue_r[$];

    int     pass_cnt         = 0;
    int     fail_cnt         = 0;
    longint cycle_cnt        = 0;
    longint last_valid_cycle = -1000;

    function automatic logic signed [17:0] hb63_coef(input int idx);
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
    endfunction

    function automatic logic signed [17:0] hb31_coef(input int idx);
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
    endfunction

    function automatic logic signed [47:0] sat48_from71(input logic signed [70:0] val);
        localparam logic signed [47:0] MAX_P = 48'sh7FFF_FFFF_FFFF;
        localparam logic signed [47:0] MIN_N = 48'sh8000_0000_0000;
        if (val > 71'(MAX_P))
            return MAX_P;
        else if (val < 71'(MIN_N))
            return MIN_N;
        else
            return val[47:0];
    endfunction

    task automatic clear_golden_history();
        for (int i = 0; i < MAX_FULL_LEN; i++) begin
            gold_hist_l[i] = '0;
            gold_hist_r[i] = '0;
        end
        for (int i = 0; i < 32; i++) begin
            s1_dl_l[i] = '0; s1_dl_r[i] = '0;
            s2_dl_l[i] = '0; s2_dl_r[i] = '0;
        end
        for (int i = 0; i < 16; i++) begin
            s3_dl_l[i] = '0; s3_dl_r[i] = '0;
        end
    endtask

    task automatic push_s3_golden(
        input logic signed [47:0] xl,
        input logic signed [47:0] xr
    );
        logic signed [70:0] acc_l, acc_r;
        logic signed [47:0] mid_l, mid_r, pass_l, pass_r;
        for (int i = 15; i > 0; i--) begin
            s3_dl_l[i] = s3_dl_l[i-1];
            s3_dl_r[i] = s3_dl_r[i-1];
        end
        s3_dl_l[0] = xl;
        s3_dl_r[0] = xr;

        pass_l = s3_dl_l[7];
        pass_r = s3_dl_r[7];
        acc_l  = '0;
        acc_r  = '0;
        for (int r = 0; r < 8; r++) begin
            logic signed [17:0] c;
            c     = hb31_coef(r);
            acc_l = acc_l + (71'(s3_dl_l[7 - r]) + 71'(s3_dl_l[8 + r])) * 71'(c);
            acc_r = acc_r + (71'(s3_dl_r[7 - r]) + 71'(s3_dl_r[8 + r])) * 71'(c);
        end
        mid_l = sat48_from71((acc_l + 71'sd32768) >>> 16);
        mid_r = sat48_from71((acc_r + 71'sd32768) >>> 16);

        exp_queue_l.push_back(mid_l);
        exp_queue_r.push_back(mid_r);
        exp_queue_l.push_back(pass_l);
        exp_queue_r.push_back(pass_r);
    endtask

    task automatic push_s2_golden(
        input logic signed [47:0] xl,
        input logic signed [47:0] xr
    );
        logic signed [70:0] acc_l, acc_r;
        logic signed [47:0] mid_l, mid_r, pass_l, pass_r;
        for (int i = 31; i > 0; i--) begin
            s2_dl_l[i] = s2_dl_l[i-1];
            s2_dl_r[i] = s2_dl_r[i-1];
        end
        s2_dl_l[0] = xl;
        s2_dl_r[0] = xr;

        pass_l = s2_dl_l[15];
        pass_r = s2_dl_r[15];
        acc_l  = '0;
        acc_r  = '0;
        for (int r = 0; r < 16; r++) begin
            logic signed [17:0] c;
            c     = hb63_coef(r);
            acc_l = acc_l + (71'(s2_dl_l[15 - r]) + 71'(s2_dl_l[16 + r])) * 71'(c);
            acc_r = acc_r + (71'(s2_dl_r[15 - r]) + 71'(s2_dl_r[16 + r])) * 71'(c);
        end
        mid_l = sat48_from71((acc_l + 71'sd32768) >>> 16);
        mid_r = sat48_from71((acc_r + 71'sd32768) >>> 16);

        push_s3_golden(mid_l, mid_r);
        push_s3_golden(pass_l, pass_r);
    endtask

    task automatic push_s1_golden(
        input logic signed [47:0] xl,
        input logic signed [47:0] xr
    );
        logic signed [70:0] acc_l, acc_r;
        logic signed [47:0] mid_l, mid_r, pass_l, pass_r;
        for (int i = 31; i > 0; i--) begin
            s1_dl_l[i] = s1_dl_l[i-1];
            s1_dl_r[i] = s1_dl_r[i-1];
        end
        s1_dl_l[0] = xl;
        s1_dl_r[0] = xr;

        pass_l = s1_dl_l[15];
        pass_r = s1_dl_r[15];
        acc_l  = '0;
        acc_r  = '0;
        for (int r = 0; r < 16; r++) begin
            logic signed [17:0] c;
            c     = hb63_coef(r);
            acc_l = acc_l + (71'(s1_dl_l[15 - r]) + 71'(s1_dl_l[16 + r])) * 71'(c);
            acc_r = acc_r + (71'(s1_dl_r[15 - r]) + 71'(s1_dl_r[16 + r])) * 71'(c);
        end
        mid_l = sat48_from71((acc_l + 71'sd32768) >>> 16);
        mid_r = sat48_from71((acc_r + 71'sd32768) >>> 16);

        push_s2_golden(mid_l, mid_r);
        push_s2_golden(pass_l, pass_r);
    endtask

    task automatic push_stereo_golden(
        input logic signed [DATA_WIDTH-1:0] sl,
        input logic signed [DATA_WIDTH-1:0] sr,
        input int                           rs,
        input int                           bank
    );
        int act_tpp;
        int full_len;
        act_tpp  = S1A_TPP >> rs;
        full_len = 2 * NUM_MACS * act_tpp;

        for (int k = full_len - 1; k > 0; k--) begin
            gold_hist_l[k] = gold_hist_l[k-1];
            gold_hist_r[k] = gold_hist_r[k-1];
        end
        gold_hist_l[0] = sl;
        gold_hist_r[0] = sr;

        // Stage 1A: 2-phase symmetric half-curve folded convolution
        for (int p = 0; p < 2; p++) begin
            logic signed [ACC_WIDTH-1:0] sum_l, sum_r;
            int p_conj;
            sum_l  = '0;
            sum_r  = '0;
            p_conj = 1 - p;

            for (int m = 0; m < NUM_MACS; m++) begin
                for (int t = 0; t < act_tpp; t++) begin
                    int k_fwd, k_rev;
                    logic signed [COEF_WIDTH-1:0] c_fwd, c_rev;
                    logic signed [DATA_WIDTH:0]   ad_fl, ad_rl, ad_fr, ad_rr;

                    k_fwd = m * act_tpp + t;
                    k_rev = full_len - 1 - k_fwd;
                    c_fwd = gold_coef[bank][m][p * act_tpp + t];
                    c_rev = gold_coef[bank][m][p_conj * act_tpp + t];

                    ad_fl = $signed(gold_hist_l[k_fwd]) + $signed(gold_hist_l[k_fwd]);
                    ad_rl = $signed(gold_hist_l[k_rev]) + $signed(gold_hist_l[k_rev]);
                    ad_fr = $signed(gold_hist_r[k_fwd]) + $signed(gold_hist_r[k_fwd]);
                    ad_rr = $signed(gold_hist_r[k_rev]) + $signed(gold_hist_r[k_rev]);

                    sum_l = sum_l + ACC_WIDTH'(ad_fl * c_fwd) + ACC_WIDTH'(ad_rl * c_rev);
                    sum_r = sum_r + ACC_WIDTH'(ad_fr * c_fwd) + ACC_WIDTH'(ad_rr * c_rev);
                end
            end

            // Stage 1B routing per rate_shift
            case (rs)
                0: push_s1_golden(sum_l, sum_r);
                1: push_s2_golden(sum_l, sum_r);
                2: push_s3_golden(sum_l, sum_r);
                default: begin
                    exp_queue_l.push_back(sum_l);
                    exp_queue_r.push_back(sum_r);
                end
            endcase
        end
    endtask

    task automatic send_frame_and_wait(
        input int rs,
        input int bank
    );
        logic signed [DATA_WIDTH-1:0] sl, sr;
        int prev_pass;
        int exp_outs;

        sl = $signed(DATA_WIDTH'($urandom_range(0, (1 << DATA_WIDTH) - 1)));
        sr = $signed(DATA_WIDTH'($urandom_range(0, (1 << DATA_WIDTH) - 1)));
        prev_pass = pass_cnt;
        exp_outs  = 16 >> rs;

        push_stereo_golden(sl, sr, rs, bank);
        @(posedge clk);
        new_sample_l     <= sl;
        new_sample_r     <= sr;
        new_sample_valid <= 1'b1;
        @(posedge clk);
        new_sample_valid <= 1'b0;

        wait (input_frame_done == 1'b1);
        @(posedge clk);

        if ((pass_cnt - prev_pass) != exp_outs) begin
            fail_cnt++;
            $error("[TB_M5] Frame output count mismatch at rs=%0d: got %0d, expected %0d",
                   rs, (pass_cnt - prev_pass), exp_outs);
        end
        if (input_overrun) begin
            fail_cnt++;
            $error("[TB_M5] Unexpected input_overrun asserted at rs=%0d!", rs);
        end
    endtask

    initial begin
        clear_golden_history();

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);
        wait (dut.u_l_fir.history_clear == 1'b0);
        repeat (5) @(posedge clk);

        // 1. Populate Bank A (b=0) and Bank B (b=1) in URAM288s
        //    MAC 0 uses full 18-bit range (testing all 4 parity patterns on coef[17:16]);
        //    outer MACs use realistic tail magnitudes so sums stay within 48-bit range.
        $display("[TB_M5] Loading dual-bank URAM coefficients (Bank A & Bank B)...");
        for (int b = 0; b < 2; b++) begin
            for (int m = 0; m < NUM_MACS; m++) begin
                for (int a = 0; a < COEF_DEPTH; a++) begin
                    int raw_val;
                    logic signed [COEF_WIDTH-1:0] c;
                    if (m == 0 && (a % 32 == 0))
                        raw_val = int'($urandom_range(0, 262143)) - 131072;
                    else
                        raw_val = int'($urandom_range(0, 4095)) - 2048;
                    c = $signed(COEF_WIDTH'(raw_val));
                    gold_coef[b][m][a] = c;

                    @(posedge clk);
                    coef_we          <= 1'b1;
                    bank_load_target <= b[0];
                    coef_wmac        <= $clog2(NUM_MACS)'(m);
                    coef_waddr       <= $clog2(COEF_DEPTH)'(a);
                    coef_wdata       <= c;
                end
            end
        end
        @(posedge clk);
        coef_we <= 1'b0;
        repeat (10) @(posedge clk); // Drain 3-stage URAM write broadcast tree

        // 2. rate_shift = 3 (DXD 0-LSB bypass): 520 frames -> full 512-tap fwd+rev BRAM wrap
        $display("[TB_M5] Testing rate_shift=3 (520 frames, full fwd+rev DOB_REG=1 BRAM wrap)...");
        bank_select <= 1'b0;
        repeat (5) @(posedge clk);
        for (int s = 0; s < 520; s++)
            send_frame_and_wait(3, 0);

        // 3. rate_shift = 2, 1, 0: Multi-rate Kaiser Half-Band Cascade
        for (int rs = 2; rs >= 0; rs--) begin
            $display("[TB_M5] Testing rate_shift=%0d (x%0d total interpolation)...", rs, 16 >> rs);
            clear_golden_history();
            last_valid_cycle = -1000;
            @(posedge clk);
            rate_shift <= 2'(rs);
            repeat (3) @(posedge clk);
            wait (dut.u_l_fir.history_clear == 1'b0);
            repeat (5) @(posedge clk);

            for (int s = 0; s < 16; s++)
                send_frame_and_wait(rs, 0);
        end

        // 4. Live Gapless Bank A -> Bank B Switch at rate_shift = 0 (no history flush!)
        $display("[TB_M5] Testing live gapless Bank A -> Bank B switch at rate_shift=0...");
        @(posedge clk);
        bank_select <= 1'b1;
        repeat (6) @(posedge clk); // Allow 3-stage bank_select_s3 pipeline to settle
        for (int s = 0; s < 16; s++)
            send_frame_and_wait(0, 1);

        repeat (20) @(posedge clk);
        if (fail_cnt == 0 && exp_queue_l.size() == 0 && exp_queue_r.size() == 0 && !input_overrun) begin
            $display("========================================================================");
            $display("[TB_FIR_STEREO_M5] PASS: All %0d L+R stereo outputs verified 0-LSB BIT-EXACT!", pass_cnt);
            $display("  - Full fwd+rev DOB_REG=1 BRAM window traversal: OK");
            $display("  - Rate-shift 3, 2, 1, 0 Kaiser cascade & DXD bypass: OK");
            $display("  - Gapless Bank A -> Bank B live filter switch: OK");
            $display("  - Downstream output pacing (>= 16 dsp_clk) & 0 overruns: OK");
            $display("========================================================================");
        end else begin
            $fatal(1, "[TB_FIR_STEREO_M5] FAIL: pass=%0d fail=%0d pend_l=%0d overrun=%0b",
                   pass_cnt, fail_cnt, exp_queue_l.size(), input_overrun);
        end
        $finish;
    end

    // Cycle counter & output scoreboard / pacing checker
    always @(posedge clk) begin
        cycle_cnt <= cycle_cnt + 1;
        if (rst_n && (interpolated_l_valid || interpolated_r_valid)) begin
            if (interpolated_l_valid !== interpolated_r_valid) begin
                fail_cnt++;
                $error("[TB_M5] L/R valid mismatch at cycle %0d", cycle_cnt);
            end else begin
                logic signed [ACC_WIDTH-1:0] exp_l, exp_r;
                if ((cycle_cnt - last_valid_cycle) < 16) begin
                    fail_cnt++;
                    $error("[TB_M5] Output spacing violation: %0d clks (< 16) at cycle %0d",
                           (cycle_cnt - last_valid_cycle), cycle_cnt);
                end
                last_valid_cycle <= cycle_cnt;

                if (exp_queue_l.size() == 0) begin
                    fail_cnt++;
                    $error("[TB_M5] Unexpected output pulse when golden queue is empty!");
                end else begin
                    exp_l = exp_queue_l.pop_front();
                    exp_r = exp_queue_r.pop_front();
                    if (interpolated_l === exp_l && interpolated_r === exp_r) begin
                        pass_cnt++;
                    end else begin
                        fail_cnt++;
                        $error("[TB_M5] Sample #%0d mismatch! L got=0x%012h exp=0x%012h | R got=0x%012h exp=0x%012h",
                               pass_cnt + fail_cnt, interpolated_l, exp_l, interpolated_r, exp_r);
                    end
                end
            end
        end
    end

endmodule