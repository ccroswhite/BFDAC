`timescale 1ns / 1ps

// =============================================================================
// TB_FIR_INTERP_M1 — End-to-End Milestone 1 Verification Testbench
//
// Verifies fir_polyphase_interpolator + polyphase_mac_engine + Milestone 1
// time-multiplexed polyphase_adder_tree against a bit-exact behavioral FIR
// reference across all four sample-rate shifts (rate_shift = 0, 1, 2, 3).
// =============================================================================
module tb_fir_interp_m1;

    localparam int NUM_MACS       = 64;   // Exercises multiple groups & Tier-1 accumulators
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;
    localparam int NUM_PHASES     = 16;
    localparam int TAPS_PER_PHASE = 64;   // Exercises production G1=32, G2=8 reduction
    localparam int COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE;
    localparam int HIST_LEN       = NUM_MACS * TAPS_PER_PHASE;

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

    always #1.65 clk = ~clk; // ~302 MHz dsp_clk

    // -------------------------------------------------------------------------
    // DUT: Mono Polyphase Interpolator + MAC Array + Milestone 1 Adder Tree
    // -------------------------------------------------------------------------
    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .NUM_PHASES     (NUM_PHASES),
        .TAPS_PER_PHASE (TAPS_PER_PHASE)
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

    // -------------------------------------------------------------------------
    // Coefficient ROM & 4-Cycle Pipeline Model (Matches fir_polyphase_stereo:
    // 2-stage URAM address broadcast tree + 2-cycle URAM288 read latency)
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Behavioral Golden Reference Model (Bit-Exact 48-Bit Accumulator)
    // -------------------------------------------------------------------------
    logic signed [DATA_WIDTH-1:0] gold_hist [0:HIST_LEN-1];
    logic signed [ACC_WIDTH-1:0]  exp_queue [$];
    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic push_sample_and_golden(input logic signed [DATA_WIDTH-1:0] sample);
        int active_phases;
        // Shift golden delay line
        for (int k = HIST_LEN - 1; k > 0; k--)
            gold_hist[k] = gold_hist[k-1];
        gold_hist[0] = sample;

        active_phases = NUM_PHASES >> rate_shift;
        for (int p = 0; p < active_phases; p++) begin
            automatic logic signed [ACC_WIDTH-1:0] phase_sum = '0;
            for (int m = 0; m < NUM_MACS; m++) begin
                for (int t = 0; t < TAPS_PER_PHASE; t++) begin
                    automatic logic signed [DATA_WIDTH:0] ad =
                        $signed(gold_hist[m * TAPS_PER_PHASE + t]) +
                        $signed(gold_hist[m * TAPS_PER_PHASE + t]);
                    automatic logic signed [47:0] prod =
                        ad * $signed(coef_rom[m][p * TAPS_PER_PHASE + t]);
                    phase_sum += prod;
                end
            end
            exp_queue.push_back(phase_sum);
        end
    endtask

    // -------------------------------------------------------------------------
    // Test Stimulus across rate_shift = 0, 1, 2, 3
    // -------------------------------------------------------------------------
    initial begin
        // Initialize deterministic pseudo-random coefficients & zero history
        for (int m = 0; m < NUM_MACS; m++)
            for (int c = 0; c < COEF_DEPTH; c++)
                coef_rom[m][c] = COEF_WIDTH'($urandom_range(0, (1<<COEF_WIDTH)-1));

        for (int k = 0; k < HIST_LEN; k++)
            gold_hist[k] = '0;

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;

        // Wait for internal history_clear to complete
        wait (dut.history_clear == 1'b0);
        repeat (10) @(posedge clk);

        for (int rs = 0; rs <= 3; rs++) begin
            rate_shift <= 2'(rs);
            repeat (5) @(posedge clk);

            // Feed 4 consecutive baseband samples at this rate_shift
            for (int s = 0; s < 4; s++) begin
                automatic logic signed [DATA_WIDTH-1:0] samp =
                    DATA_WIDTH'($urandom_range(0, (1<<DATA_WIDTH)-1));

                @(posedge clk);
                new_sample_data  <= samp;
                new_sample_valid <= 1'b1;
                push_sample_and_golden(samp);

                @(posedge clk);
                new_sample_valid <= 1'b0;

                // Wait for frame sweep + reduction drain to complete
                wait (input_frame_done == 1'b1);
                repeat (5) @(posedge clk);
            end
        end

        repeat (20) @(posedge clk);
        if (fail_cnt == 0 && pass_cnt == 60 && exp_queue.size() == 0 && !input_overrun)
            $display("[TB_FIR_INTERP_M1] PASS: All %0d polyphase outputs across rate_shift=0..3 bit-exact (0 LSB error)!",
                     pass_cnt);
        else
            $fatal(1, "[TB_FIR_INTERP_M1] FAIL: pass=%0d fail=%0d pending=%0d overrun=%0b",
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
                $error("[TB_FIR_INTERP_M1] Mismatch at output %0d (rate_shift=%0d): got=0x%012h exp=0x%012h",
                       pass_cnt + fail_cnt, rate_shift, interpolated_out, exp_val);
            end
        end
    end

endmodule
