`timescale 1ns / 1ps

// =============================================================================
// TB_FIR_INTERP_M2 — Milestone 2 Bit-Exact Half-Curve Fold Verification
//
// Compares fir_polyphase_interpolator (SYM_FOLD_EN = 1, storing only N_half
// coefficients in coef_rom) against a full 2*N_half-tap symmetric behavioral
// golden reference across rate_shift = 0, 1, 2, 3.
// =============================================================================
module tb_fir_interp_m2;

    localparam int NUM_MACS       = 16;   // 2 Groups of 8 MACs
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;
    localparam int NUM_PHASES     = 16;
    localparam int TAPS_PER_PHASE = 16;   // K_half = 256 samples, Full folded K = 512 samples
    localparam int COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE;
    localparam int HALF_HIST_LEN  = NUM_MACS * TAPS_PER_PHASE;
    localparam int FULL_HIST_LEN  = 2 * HALF_HIST_LEN;

    logic                                clk = 0;
    logic                                rst_n = 0;
    logic [1:0]                          rate_shift = 2'd0;
    logic                                input_overrun;
    logic                                new_sample_valid = 0;
    logic signed [DATA_WIDTH-1:0]        new_sample_data = '0;
    logic signed [ACC_WIDTH-1:0]         interpolated_out;
    logic                                interpolated_valid;
    logic                                input_frame_done;
    logic signed [COEF_WIDTH-1:0]        coef_in [0:NUM_MACS-1];
    logic [$clog2(COEF_DEPTH)-1:0]       coef_addr_out;

    always #1.65 clk = ~clk;

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .NUM_PHASES     (NUM_PHASES),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .SYM_FOLD_EN    (1'b1)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .rate_shift         (rate_shift),
        .input_overrun      (input_overrun),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_data),
        .interpolated_out   (interpolated_out),
        .interpolated_valid (interpolated_valid),
        .input_frame_done   (input_frame_done),
        .coef_in            (coef_in),
        .coef_addr_out      (coef_addr_out)
    );

    // Half-curve coefficient ROM & 4-cycle URAM read pipeline
    logic signed [COEF_WIDTH-1:0]  coef_rom [0:NUM_MACS-1][0:COEF_DEPTH-1];
    logic [$clog2(COEF_DEPTH)-1:0] addr_pipe [0:2];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            addr_pipe[0] <= '0;
            addr_pipe[1] <= '0;
            addr_pipe[2] <= '0;
            for (int m = 0; m < NUM_MACS; m++) coef_in[m] <= '0;
        end else begin
            addr_pipe[0] <= coef_addr_out;
            addr_pipe[1] <= addr_pipe[0];
            addr_pipe[2] <= addr_pipe[1];
            for (int m = 0; m < NUM_MACS; m++)
                coef_in[m] <= coef_rom[m][addr_pipe[2]];
        end
    end

    // Full 2*K_half-deep Golden Reference Delay Line
    logic signed [DATA_WIDTH-1:0] gold_hist [0:FULL_HIST_LEN-1];
    logic signed [ACC_WIDTH-1:0]  exp_queue [$];
    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic push_sample_and_golden(input logic signed [DATA_WIDTH-1:0] sample);
        int active_phases;
        for (int k = FULL_HIST_LEN - 1; k > 0; k--)
            gold_hist[k] = gold_hist[k-1];
        gold_hist[0] = sample;

        active_phases = NUM_PHASES >> rate_shift;
        for (int p = 0; p < active_phases; p++) begin
            automatic logic signed [ACC_WIDTH-1:0] phase_sum = '0;
            automatic int p_conj = active_phases - 1 - p;

            // First half of impulse response (k = 0 .. HALF_HIST_LEN - 1)
            for (int m = 0; m < NUM_MACS; m++) begin
                for (int t = 0; t < TAPS_PER_PHASE; t++) begin
                    automatic int k_fwd = m * TAPS_PER_PHASE + t;
                    automatic logic signed [DATA_WIDTH:0] ad_fwd =
                        $signed(gold_hist[k_fwd]) + $signed(gold_hist[k_fwd]);
                    phase_sum += ad_fwd * $signed(coef_rom[m][p * TAPS_PER_PHASE + t]);
                end
            end

            // Second half of symmetric impulse response (k = HALF_HIST_LEN .. FULL_HIST_LEN - 1)
            for (int m = 0; m < NUM_MACS; m++) begin
                for (int t = 0; t < TAPS_PER_PHASE; t++) begin
                    automatic int k_rev = FULL_HIST_LEN - 1 - (m * TAPS_PER_PHASE + t);
                    automatic logic signed [DATA_WIDTH:0] ad_rev =
                        $signed(gold_hist[k_rev]) + $signed(gold_hist[k_rev]);
                    phase_sum += ad_rev * $signed(coef_rom[m][p_conj * TAPS_PER_PHASE + t]);
                end
            end

            exp_queue.push_back(phase_sum);
        end
    endtask

    initial begin
        for (int m = 0; m < NUM_MACS; m++)
            for (int c = 0; c < COEF_DEPTH; c++)
                coef_rom[m][c] = COEF_WIDTH'($urandom_range(0, (1<<COEF_WIDTH)-1));

        for (int k = 0; k < FULL_HIST_LEN; k++)
            gold_hist[k] = '0;

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        wait (dut.history_clear == 1'b0);
        repeat (10) @(posedge clk);

        // 1. Feed 300 samples at rate_shift=3 to push samples completely through
        //    win (256 deep) and into win_rev (256 deep)
        rate_shift <= 2'd3;
        repeat (5) @(posedge clk);
        for (int s = 0; s < 300; s++) begin
            automatic logic signed [DATA_WIDTH-1:0] samp =
                DATA_WIDTH'($urandom_range(0, (1<<DATA_WIDTH)-1));
            @(posedge clk);
            new_sample_data  <= samp;
            new_sample_valid <= 1'b1;
            push_sample_and_golden(samp);
            @(posedge clk);
            new_sample_valid <= 1'b0;
            wait (input_frame_done == 1'b1);
            repeat (5) @(posedge clk);
        end

        // 2. Verify all four rate_shift modes (0, 1, 2, 3) with full history active
        for (int rs = 0; rs <= 3; rs++) begin
            rate_shift <= 2'(rs);
            repeat (5) @(posedge clk);
            for (int s = 0; s < 4; s++) begin
                automatic logic signed [DATA_WIDTH-1:0] samp =
                    DATA_WIDTH'($urandom_range(0, (1<<DATA_WIDTH)-1));
                @(posedge clk);
                new_sample_data  <= samp;
                new_sample_valid <= 1'b1;
                push_sample_and_golden(samp);
                @(posedge clk);
                new_sample_valid <= 1'b0;
                wait (input_frame_done == 1'b1);
                repeat (5) @(posedge clk);
            end
        end

        repeat (20) @(posedge clk);
        if (fail_cnt == 0 && exp_queue.size() == 0 && !input_overrun)
            $display("[TB_FIR_INTERP_M2] PASS: All %0d folded outputs across rate_shift=0..3 bit-exact (0 LSB error)!",
                     pass_cnt);
        else
            $fatal(1, "[TB_FIR_INTERP_M2] FAIL: pass=%0d fail=%0d pending=%0d overrun=%0b",
                   pass_cnt, fail_cnt, exp_queue.size(), input_overrun);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && interpolated_valid) begin
            automatic logic signed [ACC_WIDTH-1:0] exp_val = exp_queue.pop_front();
            if (interpolated_out === exp_val) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
                $error("[TB_FIR_INTERP_M2] Mismatch at output %0d (rate_shift=%0d): got=0x%012h exp=0x%012h",
                       pass_cnt + fail_cnt, rate_shift, interpolated_out, exp_val);
            end
        end
    end

endmodule
