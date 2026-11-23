`timescale 1ns / 1ps

// =============================================================================
// Testbench for dac_i2s_ingress
//
// Verifies:
//   1. Normal stereo reception at 768 kHz (48k family BCLK = 49.152 MHz)
//      - left/right data correctly captured and output in dsp_clk domain
//      - new_sample pulses at the expected rate
//      - i2s_err remains de-asserted during healthy streaming
//   2. Normal stereo reception at 705.6 kHz (44.1k family BCLK = 45.1584 MHz)
//   3. BCLK idle watchdog: stop BCLK after a few frames, verify i2s_err asserts
//      within the 512-cycle dsp_clk timeout window
//   4. Recovery: restart BCLK, verify i2s_err de-asserts on first valid frame
// =============================================================================
module tb_dac_i2s_ingress;

    // -------------------------------------------------------------------------
    // Clock periods
    // -------------------------------------------------------------------------
    localparam real DSP_CLK_PERIOD  = 11.111; // ~90 MHz (conservative stand-in for 281 MHz)
    localparam real BCLK_48K_PERIOD = 20.345; // 49.152 MHz  (768 kHz × 64)
    localparam real BCLK_441_PERIOD = 22.151; // 45.1584 MHz (705.6 kHz × 64)

    // I2S frame: 32 bits per slot, 2 slots per frame
    localparam int  BITS_PER_FRAME  = 64;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        dsp_clk;
    logic        sys_rst_n;
    logic        i2s_bclk;
    logic        i2s_lrclk;
    logic        i2s_data;

    logic [23:0] audio_l;
    logic [23:0] audio_r;
    logic        new_sample;
    logic        i2s_err;

    dac_i2s_ingress u_dut (
        .dsp_clk    (dsp_clk),
        .sys_rst_n  (sys_rst_n),
        .i2s_bclk   (i2s_bclk),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .audio_l    (audio_l),
        .audio_r    (audio_r),
        .new_sample (new_sample),
        .i2s_err    (i2s_err)
    );

    // -------------------------------------------------------------------------
    // [DEBUG] monitor — enabled by compiling with +define+SIM_DEBUG
    // -------------------------------------------------------------------------
`ifdef SIM_DEBUG
    always @(posedge i2s_bclk) begin
        if (u_dut.u_i2s_rx.i2s_lrclk !== u_dut.u_i2s_rx.lrclk_prev)
            $display("[DEBUG] LRCLK %b->%b at %0t  bit_cnt_before=%0d",
                     u_dut.u_i2s_rx.lrclk_prev, u_dut.u_i2s_rx.i2s_lrclk,
                     $time, u_dut.u_i2s_rx.bit_cnt);
        if (u_dut.u_i2s_rx.data_valid)
            $display("[DEBUG] data_valid: left=0x%08X right=0x%08X",
                     u_dut.u_i2s_rx.left_data, u_dut.u_i2s_rx.right_data);
    end
    always @(posedge dsp_clk) begin
        if (new_sample)
            $display("[DEBUG] new_sample: audio_l=0x%06X audio_r=0x%06X", audio_l, audio_r);
        if (i2s_err)
            $display("[DEBUG] i2s_err asserted at %0t", $time);
    end
`endif

    // -------------------------------------------------------------------------
    // dsp_clk generation (free-running)
    // -------------------------------------------------------------------------
    initial dsp_clk = 1'b0;
    always #(DSP_CLK_PERIOD / 2.0) dsp_clk = ~dsp_clk;

    // -------------------------------------------------------------------------
    // BCLK: controlled by task (can be stopped to test watchdog)
    // -------------------------------------------------------------------------
    real         bclk_period;
    logic        bclk_en;

    initial begin
        i2s_bclk   = 1'b0;
        bclk_en    = 1'b0;
        bclk_period = BCLK_48K_PERIOD;
    end

    always begin
        if (bclk_en)
            #(bclk_period / 2.0) i2s_bclk = ~i2s_bclk;
        else begin
            i2s_bclk = 1'b0;
            @(posedge bclk_en);
        end
    end

    // -------------------------------------------------------------------------
    // Task: send one I2S stereo frame
    //   left_val / right_val : 32-bit values shifted MSB-first
    //   LRCLK low  = left channel
    //   LRCLK high = right channel
    //   Data transitions on falling BCLK edge (standard I2S), sampled on rising
    // -------------------------------------------------------------------------
    // send_frame drives one complete I2S stereo frame matched to i2s_rx.sv.
    //
    // i2s_rx posedge-BCLK behavior:
    //   - LRCLK edge posedge: latch completed channel (or bit_cnt==1 combined
    //     shift+latch), reset bit_cnt=32.  No extra shift on that posedge.
    //   - Non-edge posedge (bit_cnt>0): shift i2s_data into shift_reg, decrement.
    //   - data_valid fires when lrclk_prev==1 (right channel) and LRCLK->0.
    //
    // Frame structure (each step = one negedge BCLK, sampled next posedge):
    //   1. LRCLK=1  (ensure 1-state; if already 1 this is a NOP for i2s_rx)
    //   2. LRCLK=0  (1->0 edge: i2s_rx resets bit_cnt=32 for left channel)
    //   3. 32x data left[31:0]  (32 non-edge posedges, bit_cnt 32->0)
    //   4. LRCLK=1  (0->1 edge: i2s_rx latches left_data, resets bit_cnt=32)
    //   5. 32x data right[31:0] (32 non-edge posedges, bit_cnt 32->0)
    //   6. LRCLK=0  (1->0 edge: i2s_rx latches right_data, asserts data_valid)
    //
    // Ends with LRCLK=0. Next send_frame call starts with step 1 (LRCLK=1)
    // which drives a 0->1 edge on i2s_rx — then step 2 drives the real 1->0.
    task automatic send_frame(input logic [31:0] left_val,
                               input logic [31:0] right_val);
        @(negedge i2s_bclk); i2s_lrclk = 1'b1; // step 1: ensure LRCLK=1
        @(negedge i2s_bclk); i2s_lrclk = 1'b0; // step 2: 1->0 edge, bit_cnt=32
        for (int b = 31; b >= 0; b--) begin      // step 3: 32 left bits
            @(negedge i2s_bclk); i2s_data = left_val[b];
        end
        @(negedge i2s_bclk); i2s_lrclk = 1'b1; // step 4: 0->1, latch left
        for (int b = 31; b >= 0; b--) begin      // step 5: 32 right bits
            @(negedge i2s_bclk); i2s_data = right_val[b];
        end
        @(negedge i2s_bclk); i2s_lrclk = 1'b0; // step 6: 1->0, data_valid
    endtask

    // -------------------------------------------------------------------------
    // Sample counter: increments on every new_sample pulse.
    // wait_new_sample waits until the count advances by 1 from the snapshot
    // taken just before send_frame, then reads audio_l/r.
    // This is race-free: send_frame blocks on BCLK edges; the counter catches
    // the pulse that fires at end-of-frame regardless of dsp_clk alignment.
    // -------------------------------------------------------------------------
    int sample_count;

    always_ff @(posedge dsp_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) sample_count <= 0;
        else if (new_sample) sample_count <= sample_count + 1;
    end

    // Snapshot count before send_frame, then wait for it to increment.
    // audio_l/r are registered on new_sample and stable one cycle later.
    task automatic wait_new_sample(input int timeout_cycles, output logic got_it);
        automatic int snap = sample_count;
        got_it = 1'b0;
        for (int i = 0; i < timeout_cycles; i++) begin
            @(posedge dsp_clk);
            if (sample_count != snap) begin
                @(posedge dsp_clk); // one extra cycle: audio_l/r registered on new_sample
                got_it = 1'b1;
                break;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        int pass_count, fail_count;
        logic        got_sample;
        logic [23:0] expected_l, expected_r;

        pass_count = 0;
        fail_count = 0;

        // --- Reset ---
        sys_rst_n   = 1'b0;
        i2s_lrclk   = 1'b0;
        i2s_data    = 1'b0;
        bclk_en     = 1'b0;
        repeat (20) @(posedge dsp_clk);
        sys_rst_n = 1'b1;
        repeat (10) @(posedge dsp_clk);

        $display("=== TEST 1: 768 kHz (49.152 MHz BCLK) normal streaming ===");
        bclk_period = BCLK_48K_PERIOD;
        bclk_en     = 1'b1;
        repeat (4) @(posedge i2s_bclk); // let BCLK stabilise / reset sync settle

        // Send 4 stereo frames with incrementing data.
        // i2s_rx latches left_data on LRCLK rising edge (start of right channel)
        // and pulses data_valid on LRCLK falling edge one full frame later.
        // So the sample delivered on frame N carries left from frame N, right from frame N.
        // Frame 0: left_data captured from first LRCLK rise — valid data.
        begin
            automatic logic [31:0] lv [4], rv [4];
            for (int f = 0; f < 4; f++) begin
                lv[f] = 32'hA0B0_0000 + f;
                rv[f] = 32'hC0D0_0000 + f;
            end
            // Prime the receiver: send one frame before checking
            send_frame(lv[0], rv[0]);
            wait_new_sample(500, got_sample);
            // Now send+check frames 0-3: the sample received carries the data just sent
            for (int f = 0; f < 4; f++) begin
                send_frame(lv[f], rv[f]);
                wait_new_sample(500, got_sample);
                if (!got_sample) begin
                    $display("FAIL [TEST1] frame %0d: new_sample never asserted", f);
                    fail_count++;
                end else begin
                    expected_l = lv[f][31:8];
                    expected_r = rv[f][31:8];
                    if (audio_l !== expected_l || audio_r !== expected_r) begin
                        $display("FAIL [TEST1] frame %0d: L=0x%06X exp=0x%06X  R=0x%06X exp=0x%06X",
                                 f, audio_l, expected_l, audio_r, expected_r);
                        fail_count++;
                    end else begin
                        $display("PASS [TEST1] frame %0d: L=0x%06X R=0x%06X", f, audio_l, audio_r);
                        pass_count++;
                    end
                end
            end
        end

        if (i2s_err) begin
            $display("FAIL [TEST1] i2s_err unexpectedly asserted during healthy stream");
            fail_count++;
        end else begin
            $display("PASS [TEST1] i2s_err de-asserted during healthy stream");
            pass_count++;
        end

        // --- Stop BCLK and let things settle ---
        bclk_en = 1'b0;
        repeat (20) @(posedge dsp_clk);

        $display("=== TEST 2: 705.6 kHz (45.1584 MHz BCLK) normal streaming ===");
        bclk_period = BCLK_441_PERIOD;
        sys_rst_n   = 1'b0;
        repeat (10) @(posedge dsp_clk);
        sys_rst_n = 1'b1;
        bclk_en   = 1'b1;
        repeat (4) @(posedge i2s_bclk);

        begin
            automatic logic [31:0] lv [4], rv [4];
            for (int f = 0; f < 4; f++) begin
                lv[f] = 32'hDEAD_0000 + f;
                rv[f] = 32'hBEEF_0000 + f;
            end
            send_frame(lv[0], rv[0]);
            wait_new_sample(500, got_sample);
            for (int f = 0; f < 4; f++) begin
                send_frame(lv[f], rv[f]);
                wait_new_sample(500, got_sample);
                if (!got_sample) begin
                    $display("FAIL [TEST2] frame %0d: new_sample never asserted", f);
                    fail_count++;
                end else begin
                    expected_l = lv[f][31:8];
                    expected_r = rv[f][31:8];
                    if (audio_l !== expected_l || audio_r !== expected_r) begin
                        $display("FAIL [TEST2] frame %0d: L=0x%06X exp=0x%06X  R=0x%06X exp=0x%06X",
                                 f, audio_l, expected_l, audio_r, expected_r);
                        fail_count++;
                    end else begin
                        $display("PASS [TEST2] frame %0d: L=0x%06X R=0x%06X", f, audio_l, audio_r);
                        pass_count++;
                    end
                end
            end
        end

        $display("=== TEST 3: BCLK idle watchdog ===");
        // Send one good frame then stop BCLK; i2s_err must assert within 512+margin dsp_clk cycles
        send_frame(32'h1234_5678, 32'h9ABC_DEF0);
        bclk_en = 1'b0;
        begin : watchdog_check
            automatic int   timeout   = 700;
            automatic int   elapsed   = 0;
            automatic logic triggered = 1'b0;
            while (elapsed < timeout) begin
                @(posedge dsp_clk);
                elapsed++;
                if (i2s_err) begin
                    triggered = 1'b1;
                    break;
                end
            end
            if (!triggered) begin
                $display("FAIL [TEST3] i2s_err did not assert after BCLK stopped (%0d cycles)", elapsed);
                fail_count++;
            end else begin
                $display("PASS [TEST3] i2s_err asserted %0d dsp_clk cycles after BCLK stop", elapsed);
                pass_count++;
            end
        end

        $display("=== TEST 4: Recovery after BCLK restart ===");
        // Re-assert reset, restart BCLK, send a frame; i2s_err must clear
        sys_rst_n = 1'b0;
        repeat (10) @(posedge dsp_clk);
        sys_rst_n = 1'b1;
        bclk_en   = 1'b1;
        bclk_period = BCLK_48K_PERIOD;
        repeat (4) @(posedge i2s_bclk);

        send_frame(32'hCAFE_0001, 32'hF00D_0001);
        wait_new_sample(500, got_sample);
        if (i2s_err) begin
            $display("FAIL [TEST4] i2s_err still asserted after recovery frame");
            fail_count++;
        end else if (!got_sample) begin
            $display("FAIL [TEST4] new_sample did not arrive after recovery");
            fail_count++;
        end else begin
            $display("PASS [TEST4] i2s_err cleared and new_sample received after recovery");
            pass_count++;
        end

        // --- Summary ---
        $display("========================================");
        $display("Results: %0d PASS  %0d FAIL", pass_count, fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILURES DETECTED");
        $display("========================================");
        $stop;
    end

endmodule
