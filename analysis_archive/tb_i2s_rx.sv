`timescale 1ns / 1ps

// =============================================================================
// Testbench for i2s_rx (BCLK-domain version)
//
// i2s_rx is now clocked on i2s_bclk itself to support BCLK rates up to
// 49.152 MHz (768 kHz stereo 32-bit).  This testbench drives it at
// 49.152 MHz to exercise the maximum rate.
//
// Verifies:
//   - Stereo I2S reception (32-bit left/right samples)
//   - data_valid pulse after each right-channel word (BCLK domain)
//
// NOTE: the first frame after reset is a priming frame — the receiver
// aligns on the first LRCLK transition, so the first left word begins
// before sync and is legitimately incomplete. The checker skips it.
// =============================================================================
module tb_i2s_rx;

    localparam int DATA_WIDTH = 32;
    // 49.152 MHz BCLK: half-period = ~10.17 ns -> use 10 ns for simulation
    localparam real BCLK_HALF_NS = 10.0; // 50 MHz for integer timescale

    logic                  bclk;
    logic                  rst_n;
    logic                  i2s_lrclk;
    logic                  i2s_data;
    logic [DATA_WIDTH-1:0] left_data;
    logic [DATA_WIDTH-1:0] right_data;
    logic                  data_valid;

    i2s_rx #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_dut (
        .clk        (bclk),
        .rst_n      (rst_n),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (left_data),
        .right_data (right_data),
        .data_valid (data_valid)
    );

    // BCLK generation at 50 MHz
    initial begin
        bclk = 0;
        forever #(BCLK_HALF_NS) bclk = ~bclk;
    end

    logic [DATA_WIDTH-1:0] tx_left;
    logic [DATA_WIDTH-1:0] tx_right;
    int                    bit_idx;
    logic [DATA_WIDTH-1:0] tx_word;

    // Checker state (valid_count==0 = un-synced priming frame, not checked)
    int valid_count    = 0;
    int frames_checked = 0;
    int err_count      = 0;

    initial begin
        rst_n     = 0;
        i2s_lrclk = 0;
        i2s_data  = 0;
        tx_left   = 32'h12345678;
        tx_right  = 32'hABCDEF01;

        repeat(10) @(posedge bclk);
        rst_n = 1;
        repeat(5) @(posedge bclk);

        // Run 6 frames: frame 1 primes LRCLK sync (not checked); the final
        // frame's data_valid needs the NEXT LRCLK edge, so >=4 are checked.
        repeat(6) send_frame();
        repeat(8) @(posedge bclk);   // drain last data_valid

        if (frames_checked < 4) begin
            $display("FAIL: only %0d/4 frames checked (data_valid missing)", frames_checked);
            err_count = err_count + 1;
        end
        if (err_count == 0)
            $display("ALL TESTS PASSED - i2s_rx verified (%0d frames)", frames_checked);
        else
            $display("FAILED - %0d error(s)", err_count);
        $stop;
    end

    // Send one stereo I2S frame (left then right channel, 32 bits each)
    task automatic send_frame();
        for (int ch = 0; ch < 2; ch++) begin
            tx_word   = (ch == 0) ? tx_left : tx_right;
            i2s_lrclk = (ch == 0) ? 1'b0 : 1'b1;
            @(negedge bclk); // LRCLK changes on falling BCLK (1-bit I2S delay)
            for (bit_idx = DATA_WIDTH - 1; bit_idx >= 0; bit_idx--) begin
                i2s_data = tx_word[bit_idx];
                @(negedge bclk);
            end
        end
    endtask

    // Check received data on data_valid (BCLK domain).
    // plain always: err_count is also written by the final-verdict initial block
    always @(posedge bclk) begin
        if (data_valid) begin
            valid_count <= valid_count + 1;
            if (valid_count > 0) begin
                frames_checked <= frames_checked + 1;
                if (left_data !== tx_left) begin
                    $display("FAIL: left data mismatch: got 0x%08X expected 0x%08X", left_data, tx_left);
                    err_count <= err_count + 1;
                end else if (right_data !== tx_right) begin
                    $display("FAIL: right data mismatch: got 0x%08X expected 0x%08X", right_data, tx_right);
                    err_count <= err_count + 1;
                end else
                    $display("PASS: stereo frame L=0x%08X R=0x%08X", left_data, right_data);
            end else
                $display("INFO: priming frame skipped (pre-sync)");
        end
    end

endmodule
