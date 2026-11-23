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
//  TWO-STAGE cascade math (TWO_STAGE_EN=1, production config — fixed 2026-11-21):
//    Stage 1A: NUM_PHASES=2, S1A_TPP = 8*TAPS_PER_PHASE = 128 stored taps/phase,
//              symmetric fold → effective taps/phase = 2*S1A_TPP, DC history
//              window = NUM_MACS * 2 * S1A_TPP = 1024 input samples.
//    Stage 1B: 63t→63t→31t halfband cascade, DC gain exactly 1.0 per stage
//              (folded coef sums = 32768 = 2^15 → mid = 2D*Σc/2^16 = D).
//    DC known-answer: y = 2 * C * D * NUM_MACS * (2*S1A_TPP)  — measured
//              converged+flat at 0x080000000000 for C=0x1000, D=0x100000.
//
//  Legacy single-stage math (TWO_STAGE_EN=0): NUM_PHASES=16, TPP=16 taps,
//    y = 2*C*D*NUM_MACS*TAPS_PER_PHASE, history = NUM_MACS*TAPS_PER_PHASE.
// =============================================================================
module tb_fir_polyphase_stereo;

    // -------------------------------------------------------------------------
    //  Small parameter set for simulation
    // -------------------------------------------------------------------------
    localparam int NUM_MACS       = 4;
    localparam int TAPS_PER_PHASE = 16;
    localparam int NUM_PHASES     = 16;   // final interpolated outputs/sample (x16 total)
    localparam int S1A_TPP        = 8 * TAPS_PER_PHASE;          // 128 stored taps/phase
    localparam int S1A_EFF_TPP    = 2 * S1A_TPP;                 // 256 effective (fold)
    localparam int HIST_SAMPLES   = NUM_MACS * S1A_EFF_TPP;      // 1024-sample DC window
    localparam int PRIME_SAMPLES  = 2 * HIST_SAMPLES + 16;       // 2064 — probe-proven convergence
    localparam int COEF_DEPTH     = NUM_PHASES * TAPS_PER_PHASE; // 256
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
    logic                             input_overrun, input_frame_done;

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
        .input_overrun          (input_overrun),
        .input_frame_done       (input_frame_done),
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
        repeat(TAPS_PER_PHASE + 1) @(posedge clk); // let the history RAM clear
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
    int frame_count;
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
        // Two-stage note: S1B's pacing engine needs its input FIFO/halfband
        // center delays populated before the first frame emits — prime ~48
        // zero samples (all-zero coefs → all outputs zero regardless).
        repeat(48) begin
            send_sample(24'h000000, 24'h000000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end
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
        // TEST 3: DC known-answer (two-stage cascade)
        //   Bank A uniform coef C = 18'sh01000, DC input D = 24'sh100000.
        //   S1A: y = 2*C*D*NUM_MACS*S1A_EFF_TPP  (fold doubles effective taps)
        //   S1B: DC gain = 1.0 per halfband stage → output = S1A value.
        //   Expected = 2 * 4096 * 1048576 * 4 * 256 = 0x080000000000
        // =====================================================================
        $display("--- TEST 3: DC known-answer ---");
        do_reset;

        write_all_coefs(18'sh01000, 1'b0);  // Bank A

        // Prime past the folded window edge: measured 1040 samples leaves a
        // ±0.002% residual ripple; 2056 converges EXACTLY flat (probe-verified).
        repeat(PRIME_SAMPLES) begin
            send_sample(24'sh100000, 24'sh100000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end

        // Capture the outputs for the last sample
        send_sample(24'sh100000, 24'sh100000);
        collect_outputs(NUM_PHASES, n_got);

        // y = 2 * C * D * NUM_MACS * S1A_EFF_TPP
        exp_coef  = ACC_WIDTH'(signed'(18'sh01000));
        exp_audio = ACC_WIDTH'(signed'(24'sh100000));
        exp_val   = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(S1A_EFF_TPP);

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

        // Warm up history for both channels (past folded window edge)
        repeat(PRIME_SAMPLES) begin
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

        // Warm up with Bank A active (past folded window edge)
        repeat(PRIME_SAMPLES) begin
            send_sample(24'sh300000, 24'sh300000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end
        send_sample(24'sh300000, 24'sh300000);
        collect_outputs(NUM_PHASES, n_got);
        exp_coef  = ACC_WIDTH'(signed'(18'sh00200));
        exp_audio = ACC_WIDTH'(signed'(24'sh300000));
        exp_val   = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(S1A_EFF_TPP);

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

        // Warm up with Bank B (past folded window edge)
        repeat(PRIME_SAMPLES) begin
            send_sample(24'sh300000, 24'sh300000);
            repeat(FULL_BURST_CYCLES) @(posedge clk);
        end
        send_sample(24'sh300000, 24'sh300000);
        collect_outputs(NUM_PHASES, n_got);
        exp_coef  = ACC_WIDTH'(signed'(18'sh00400));
        exp_val_r = 2 * exp_coef * exp_audio * ACC_WIDTH'(NUM_MACS) * ACC_WIDTH'(S1A_EFF_TPP);

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
        // TEST 7: Overrun guard - a sample during the ACTIVE S1A sweep window
        //         is rejected and flagged; the in-flight frame must still
        //         complete all 16 paced outputs intact.
        //   Two-stage note: the reject window is S1A's ST_SHIFT/ST_SWEEP
        //   (~280 cy after accept). Waiting for FINAL outputs first (the old
        //   single-stage test) lands the second sample in ST_IDLE — it is
        //   legitimately ACCEPTED and overrun does not fire. Strike at +16 cy.
        // =====================================================================
        $display("--- TEST 7: Sweep-overrun guard ---");
        do_reset;
        write_all_coefs(18'sh00100, 1'b0);
        bank_select = 1'b0;

        // Send first sample; strike the second inside the S1A sweep window.
        send_sample(24'sh100000, 24'sh100000);
        repeat(16) @(posedge clk);
        send_sample(24'sh100000, 24'sh100000);

        // Count through the original frame boundary. The rejected input must
        // not reset phase accounting or truncate the active frame.
        n_got = 0;
        wdog = 0;
        frame_count = 0;
        while (frame_count == 0 && wdog < MAX_WAIT_CYCLES) begin
            @(posedge clk); #0.1;
            wdog = wdog + 1;
            if (interpolated_l_valid) n_got = n_got + 1;
            if (input_frame_done) frame_count = frame_count + 1;
        end

        if (n_got !== NUM_PHASES || frame_count !== 1 || !input_overrun) begin
            $display("  FAIL: overrun frame count=%0d frame_done=%0d overrun=%0b",
                     n_got, frame_count, input_overrun);
            fail_count = fail_count + 1;
        end else begin
            $display("  PASS: active frame completed (%0d phases); overrun was reported",
                     NUM_PHASES);
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
