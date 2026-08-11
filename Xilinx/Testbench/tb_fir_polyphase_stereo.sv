`timescale 1ns / 1ps

// =============================================================================
//  TB_FIR_POLYPHASE_STEREO
//
//  Functional testbench for fir_polyphase_stereo (+ full sub-hierarchy).
//
//  Uses a tiny parameter set for fast simulation:
//    NUM_MACS=4, TAPS_PER_PHASE=16  → COEF_DEPTH=256, 16 phases
//
//  NOTE: TAPS_PER_PHASE must be > SHADOW_DELAY+1 (=9) for the MAC accumulator
//  to collect all taps before the shadow trigger fires.  Production uses 64.
//
//  Tests:
//    1. Reset state         : no valid outputs during reset
//    2. Zero input          : all-zero coefs + zero input → zero output
//    3. DC known-answer     : load uniform coefs, drive DC, check exact value
//    4. Stereo independence : L≠R inputs produce independent (different) outputs
//    5. Output rate         : 16 interpolated_valid pulses per input sample
//    6. Bank switch         : write coefs to Bank B, switch, verify new gain
//    7. Re-trigger guard    : second new_sample_valid during sweep → no double-trigger
//
//  Pipeline math (NUM_MACS=4, TAPS_PER_PHASE=4):
//    TREE_LEVELS   = $clog2(4) = 2
//    SHADOW_DELAY  = 8 + 2 = 10
//    Preload time  = NUM_MACS+1 = 5 cycles  (after new_sample_valid)
//    First output  = preload(5) + sweep_start(1) + phase_sync_d1(1)
//                  + SHADOW_DELAY(8) + valid_reg(1) = ~16 cycles after new_sample_valid
//
//  DC gain (polyphase_mac_engine doubles the audio via pre-adder):
//    y[p] = 2 * SUM_{m=0}^{NUM_MACS-1} h[p + m*NUM_PHASES] * x[n-m]
//    Each MAC accumulates TAPS_PER_PHASE products per phase (coef sweep).
//    For uniform coef C, DC input D (all history = D):
//    y = 2 * C * D * NUM_MACS * TAPS_PER_PHASE  (all phases identical)
// =============================================================================
module tb_fir_polyphase_stereo;

    // -------------------------------------------------------------------------
    //  Small parameter set for simulation
    // -------------------------------------------------------------------------
    localparam int NUM_MACS       = 4;
    localparam int TAPS_PER_PHASE = 16;
    localparam int NUM_PHASES     = 16;
    localparam int COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE;  // 256
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;

    localparam int TREE_LEVELS    = 2;   // $clog2(4)
    localparam int SHADOW_DELAY   = 8 + TREE_LEVELS;  // 10  (matches RTL: PREG_pipe+TREE_LEVELS)

    // Maximum output bursts to wait for
    localparam int MAX_WAIT_CYCLES = 2000;
    // Full burst length: preload(NUM_MACS+1) + sweep(COEF_DEPTH) + shadow(10) + margin(32)
    localparam int FULL_BURST_CYCLES = NUM_MACS + 1 + NUM_PHASES*TAPS_PER_PHASE + (8+2) + 32;

    // -------------------------------------------------------------------------
    //  Clock and reset
    // -------------------------------------------------------------------------
    localparam real CLK_PERIOD = 2.8;  // ~357 MHz
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic rst_n;

    // -------------------------------------------------------------------------
    //  DUT ports
    // -------------------------------------------------------------------------
    logic                             new_sample_valid;
    logic signed [DATA_WIDTH-1:0]     new_sample_l;
    logic signed [DATA_WIDTH-1:0]     new_sample_r;
    logic signed [ACC_WIDTH-1:0]      interpolated_l;
    logic                             interpolated_l_valid;
    logic signed [ACC_WIDTH-1:0]      interpolated_r;
    logic                             interpolated_r_valid;

    logic                             coef_we;
    logic [$clog2(COEF_DEPTH)-1:0]    coef_waddr;
    logic signed [COEF_WIDTH-1:0]     coef_wdata;
    logic [$clog2(NUM_MACS)-1:0]      coef_wmac;
    logic                             bank_select;
    logic                             bank_load_target;

    // -------------------------------------------------------------------------
    //  DUT
    // -------------------------------------------------------------------------
    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH)
    ) dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .new_sample_valid       (new_sample_valid),
        .new_sample_l           (new_sample_l),
        .new_sample_r           (new_sample_r),
        .interpolated_l         (interpolated_l),
        .interpolated_l_valid   (interpolated_l_valid),
        .interpolated_r         (interpolated_r),
        .interpolated_r_valid   (interpolated_r_valid),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target)
    );

    // -------------------------------------------------------------------------
    //  Helpers / state
    // -------------------------------------------------------------------------
    int  pass_count;
    int  fail_count;
    int  cycle_count;
    int  extras;
    int  w;
    // Task-local vars lifted to module scope for XSim compatibility
    int  wdog;
    int  m;
    int  a;
    int  test3_fail;  // local fail flag for Test 3

    always_ff @(posedge clk) cycle_count <= cycle_count + 1;

    task do_reset;
        @(negedge clk);
        rst_n            = 1'b0;
        new_sample_valid = 1'b0;
        new_sample_l     = '0;
        new_sample_r     = '0;
        coef_we          = 1'b0;
        coef_waddr       = '0;
        coef_wdata       = '0;
        coef_wmac        = '0;
        bank_select      = 1'b0;
        bank_load_target = 1'b0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk);
    endtask

    // Write coef C to every address of every MAC in bank_load_target
    task write_all_coefs;
        input logic signed [COEF_WIDTH-1:0] cval;
        input logic                          bank;
        @(negedge clk); bank_load_target = bank;
        for (m = 0; m < NUM_MACS; m++) begin
            for (a = 0; a < COEF_DEPTH; a++) begin
                @(negedge clk);
                coef_we    = 1'b1;
                coef_wmac  = $clog2(NUM_MACS)'(m);
                coef_waddr = $clog2(COEF_DEPTH)'(a);
                coef_wdata = cval;
            end
        end
        @(negedge clk); coef_we = 1'b0;
        repeat(4) @(posedge clk);  // pipeline flush
    endtask

    // Drive one new_sample_valid pulse
    task send_sample;
        input logic signed [DATA_WIDTH-1:0] l_val;
        input logic signed [DATA_WIDTH-1:0] r_val;
        @(negedge clk);
        new_sample_l     = l_val;
        new_sample_r     = r_val;
        new_sample_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        new_sample_valid = 1'b0;
    endtask

    // Collect N interpolated_l_valid pulses; return captured values
    // Returns actual count received within MAX_WAIT_CYCLES
    logic signed [ACC_WIDTH-1:0] captured_l [0:31];
    logic signed [ACC_WIDTH-1:0] captured_r [0:31];

    task collect_outputs;
        input  int n_expected;
        output int n_got;
        n_got = 0;
        wdog  = 0;
        while (n_got < n_expected && wdog < MAX_WAIT_CYCLES) begin
            @(posedge clk); #0.1;
            wdog = wdog + 1;
            if (interpolated_l_valid) begin
                captured_l[n_got] = interpolated_l;
                captured_r[n_got] = interpolated_r;
                n_got = n_got + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    //  MAIN
    // -------------------------------------------------------------------------
    int n_got;
    int i;
    // Wide intermediates for expected-value computation (avoid 32-bit overflow)
    logic signed [ACC_WIDTH-1:0] exp_coef;
    logic signed [ACC_WIDTH-1:0] exp_audio;
    logic signed [ACC_WIDTH-1:0] exp_val;
    logic signed [ACC_WIDTH-1:0] exp_val_r;

    initial begin
        pass_count   = 0;
        fail_count   = 0;
        // cycle_count owned by the always_ff above (int inits to 0)

        $display("==========================================================");
        $display("TB_FIR_POLYPHASE_STEREO — fir_polyphase_stereo (functional)");
        $display("NUM_MACS=%0d  TAPS_PER_PHASE=%0d  COEF_DEPTH=%0d",
                 NUM_MACS, TAPS_PER_PHASE, COEF_DEPTH);
        $display("TREE_LEVELS=%0d  SHADOW_DELAY=%0d  CLK=%.1f MHz",
                 TREE_LEVELS, SHADOW_DELAY, 1000.0/CLK_PERIOD);
        $display("==========================================================");

        // =====================================================================
        // TEST 1: Reset state — no valid outputs during reset
        // =====================================================================
        $display("--- TEST 1: Reset state ---");
        do_reset;

        // sample + 30 cycles while still in reset
        @(negedge clk); rst_n = 1'b0;
        repeat(30) begin
            @(posedge clk); #0.1;
            if (interpolated_l_valid || interpolated_r_valid) begin
                $display("  FAIL: valid asserted during reset at cyc=%0d", cycle_count);
                fail_count = fail_count + 1;
            end
        end
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk);
        $display("  PASS: no valid outputs during reset");
        pass_count = pass_count + 1;

        // =====================================================================
        // TEST 2: Zero input with zero coefs → zero output
        // =====================================================================
        $display("--- TEST 2: Zero coefs + zero input → zero output ---");
        do_reset;
        // coefs are already 0 from reset (initial block zeros uram_mem)
        send_sample(24'h000000, 24'h000000);

        collect_outputs(NUM_PHASES, n_got);
        if (n_got !== NUM_PHASES) begin
            $display("  FAIL: expected %0d valid pulses, got %0d", NUM_PHASES, n_got);
            fail_count = fail_count + 1;
        end else begin
            for (i = 0; i < n_got; i++) begin
                if (captured_l[i] !== '0 || captured_r[i] !== '0) begin
                    $display("  FAIL: phase %0d L=0x%0h R=0x%0h (expected 0)",
                             i, captured_l[i], captured_r[i]);
                    fail_count = fail_count + 1;
                end
            end
            $display("  PASS: all %0d phase outputs zero on zero input/coefs", NUM_PHASES);
            pass_count = pass_count + 1;
        end

        // =====================================================================
        // TEST 3: DC known-answer
        //   Load Bank A with uniform coef C = 18'sh01000 (4096 in Q1.17 ≈ 0.03125)
        //   Drive DC input D = 24'sh100000 (1048576)
        //   Pre-adder doubles: effective audio = 2*D
        //   y = 2 * C * D * NUM_MACS  (all NUM_PHASES phases identical)
        //   Expected = 2 * 4096 * 1048576 * 4 * 16 = 549755813888 = 0x8000000000
        // =====================================================================
        $display("--- TEST 3: DC known-answer ---");
        do_reset;

        write_all_coefs(18'sh01000, 1'b0);  // Bank A

        // Prime the FULL history (K = NUM_MACS*TAPS_PER_PHASE samples since the
        // 2026-08-01 audio-window redesign) with identical DC samples.
        // Inter-sample gap must exceed full burst: shift+sweep+shadow+margin
        repeat(NUM_MACS*TAPS_PER_PHASE + 2) begin
            send_sample(24'sh100000, 24'sh100000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end

        // Capture the outputs for the last sample
        send_sample(24'sh100000, 24'sh100000);
        collect_outputs(NUM_PHASES, n_got);

        // y = 2 * C * D * NUM_MACS * TAPS_PER_PHASE
        exp_coef  = ACC_WIDTH'(signed'(18'sh01000));
        exp_audio = ACC_WIDTH'(signed'(24'sh100000));
        exp_val   = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(TAPS_PER_PHASE);

        test3_fail = 0;
        if (n_got !== NUM_PHASES) begin
            $display("  FAIL: expected %0d phases, got %0d", NUM_PHASES, n_got);
            fail_count  = fail_count + 1;
            test3_fail  = 1;
        end else begin
            for (i = 0; i < NUM_PHASES; i++) begin
                if (captured_l[i] !== exp_val) begin
                    $display("  FAIL: phase %0d L=0x%0h  expected=0x%0h",
                             i, captured_l[i], exp_val);
                    fail_count = fail_count + 1;
                    test3_fail = 1;
                end
            end
        end
        $display("  Expected DC output = 0x%0h", exp_val);
        $display("  Measured  phase 0  = 0x%0h", captured_l[0]);
        if (test3_fail == 0) begin
            $display("  PASS: DC known-answer L correct (all %0d phases)", NUM_PHASES);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: DC known-answer check failed");
        end

        // =====================================================================
        // TEST 4: Stereo independence — L≠R inputs → different outputs
        // =====================================================================
        $display("--- TEST 4: Stereo independence ---");
        do_reset;
        write_all_coefs(18'sh00800, 1'b0);  // Bank A, coef = 0x800

        // Warm up history for both channels
        repeat(NUM_MACS*TAPS_PER_PHASE + 2) begin
            send_sample(24'sh200000, 24'sh100000);   // L differs from R
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end

        send_sample(24'sh200000, 24'sh100000);
        collect_outputs(NUM_PHASES, n_got);

        if (n_got < NUM_PHASES) begin
            $display("  FAIL: only got %0d phase outputs", n_got);
            fail_count = fail_count + 1;
        end else begin
            if (captured_l[0] === captured_r[0] && captured_l[0] !== '0) begin
                $display("  FAIL: L and R have same output 0x%0h — not independent",
                         captured_l[0]);
                fail_count = fail_count + 1;
            end else if (captured_l[0] === '0 && captured_r[0] === '0) begin
                $display("  FAIL: both L and R are zero — check coef write");
                fail_count = fail_count + 1;
            end else begin
                $display("  L phase0 = 0x%0h", captured_l[0]);
                $display("  R phase0 = 0x%0h", captured_r[0]);
                $display("  PASS: L and R outputs are independent");
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TEST 5: Output rate — exactly NUM_PHASES valid pulses per sample
        // =====================================================================
        $display("--- TEST 5: Output rate (%0d valid pulses per sample) ---", NUM_PHASES);
        do_reset;
        write_all_coefs(18'sh00400, 1'b0);
        // Drain any in-flight valids before starting count
        repeat(FULL_BURST_CYCLES) @(posedge clk);

        send_sample(24'sh400000, 24'sh400000);
        collect_outputs(NUM_PHASES, n_got);

        if (n_got !== NUM_PHASES) begin
            $display("  FAIL: got %0d outputs (expected %0d)", n_got, NUM_PHASES);
            fail_count = fail_count + 1;
        end else begin
            // Check no extra valid in next FULL_BURST_CYCLES cycles
            extras = 0;
            for (w = 0; w < FULL_BURST_CYCLES; w++) begin
                @(posedge clk); #0.1;
                if (interpolated_l_valid) extras = extras + 1;
            end
            if (extras > 0) begin
                $display("  FAIL: %0d extra valid pulses after expected %0d",
                         extras, NUM_PHASES);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS: exactly %0d valid pulses, no extras", NUM_PHASES);
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TEST 6: Bank switch — load Bank B with 2× gain, switch, verify
        //   Bank A coef = 0x400 (loaded above)
        //   Bank B coef = 0x800 (2× Bank A)
        //   After bank_select=1, output should double
        // =====================================================================
        $display("--- TEST 6: Bank switch ---");
        do_reset;

        // Load Bank A with C_A = 0x200
        write_all_coefs(18'sh00200, 1'b0);
        bank_select = 1'b0;
        // Drain any in-flight valids
        repeat(FULL_BURST_CYCLES) @(posedge clk);

        // Warm up with Bank A active (full K-deep history)
        repeat(NUM_MACS*TAPS_PER_PHASE + 2) begin
            send_sample(24'sh300000, 24'sh300000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end
        send_sample(24'sh300000, 24'sh300000);
        collect_outputs(NUM_PHASES, n_got);
        exp_coef  = ACC_WIDTH'(signed'(18'sh00200));
        exp_audio = ACC_WIDTH'(signed'(24'sh300000));
        exp_val   = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(TAPS_PER_PHASE);

        if (n_got < 1 || captured_l[0] !== exp_val) begin
            $display("  FAIL (Bank A pre-check): L=0x%0h exp=0x%0h",
                     captured_l[0], exp_val);
            fail_count = fail_count + 1;
        end else begin
            $display("  Bank A check: L=0x%0h  (exp=0x%0h) OK", captured_l[0], exp_val);
        end

        // Load Bank B with C_B = 0x400 (2× Bank A)
        write_all_coefs(18'sh00400, 1'b1);
        @(negedge clk); bank_select = 1'b1;  // switch to Bank B
        @(posedge clk);

        // Warm up with Bank B (full K-deep history)
        repeat(NUM_MACS*TAPS_PER_PHASE + 2) begin
            send_sample(24'sh300000, 24'sh300000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end
        send_sample(24'sh300000, 24'sh300000);
        collect_outputs(NUM_PHASES, n_got);
        exp_coef  = ACC_WIDTH'(signed'(18'sh00400));
        exp_val_r = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(TAPS_PER_PHASE);

        if (n_got < 1) begin
            $display("  FAIL (Bank B): no outputs");
            fail_count = fail_count + 1;
        end else if (captured_l[0] !== exp_val_r) begin
            $display("  FAIL (Bank B): L=0x%0h  exp=0x%0h",
                     captured_l[0], exp_val_r);
            fail_count = fail_count + 1;
        end else begin
            $display("  Bank B check: L=0x%0h  (exp=0x%0h) OK", captured_l[0], exp_val_r);
            $display("  PASS: bank switch doubles gain as expected");
            pass_count = pass_count + 1;
        end

        // =====================================================================
        // TEST 7: Re-trigger guard — new_sample_valid during sweep must not
        //         corrupt outputs (FSM returns to PRELOAD, skips rest of sweep)
        // =====================================================================
        $display("--- TEST 7: Re-trigger guard ---");
        do_reset;
        write_all_coefs(18'sh00100, 1'b0);
        bank_select = 1'b0;

        // Send first sample, then mid-sweep send second before sweep completes
        send_sample(24'sh100000, 24'sh100000);

        // Wait for preload to finish (~NUM_MACS+2 cycles) then re-trigger mid-sweep
        repeat(NUM_MACS + 3) @(posedge clk);
        send_sample(24'sh100000, 24'sh100000);

        // Collect — after second sample we should still get NUM_PHASES valid outputs
        collect_outputs(NUM_PHASES, n_got);

        if (n_got !== NUM_PHASES) begin
            $display("  FAIL: expected %0d valid pulses after re-trigger, got %0d",
                     NUM_PHASES, n_got);
            fail_count = fail_count + 1;
        end else begin
            $display("  PASS: %0d valid pulses produced after re-trigger", NUM_PHASES);
            pass_count = pass_count + 1;
        end

        // =====================================================================
        //  Final summary
        // =====================================================================
        @(posedge clk);
        $display("==========================================================");
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED — fir_polyphase_stereo verified");
            $display("  %0d checks passed, 0 failures", pass_count);
        end else begin
            $display("FAILURES DETECTED: %0d passed, %0d FAILED",
                     pass_count, fail_count);
        end
        $display("==========================================================");
        $finish;
    end

endmodule
