`timescale 1ns / 1ps

// =============================================================================
// Testbench for automute_controller — three-tier mute model (ruling 2026-11-15)
//
// Verifies:
//   - Startup: relay open until sys_ready, then energizes ONCE (single click)
//   - Runtime mute events (i2s_err, rate change, unmute=0) clamp force_zero
//     ONLY — the relay NEVER cycles mid-session
//   - !sys_ready (power fault) and test_active open the relay mid-session
//   - Level cap switch happens only while clamped, then returns to Playing
//   - force_zero is never released while the line relay is open
// =============================================================================
module tb_automute;

    localparam int CLK_PERIOD_NS = 11; // ~90 MHz

    // Short timings for simulation
    localparam logic [27:0] TB_FLUSH  = 28'd200;
    localparam logic [27:0] TB_SETTLE = 28'd50;
    localparam logic [27:0] TB_SWITCH = 28'd50;

    logic clk;
    logic rst_n;
    logic rst_relay_n;   // power-only reset (independent of pipeline rst_n)
    logic sys_ready;
    logic test_active;
    logic unmute_req;
    logic base_rate_sel;
    logic i2s_err;
    logic [2:0] level_target;
    logic line_mute_drive;
    logic [2:0] level_relay_drive;
    logic force_zero;
    logic switch_busy;

    int fail_count = 0;

    automute_controller #(
        .FLUSH_CYCLES       (TB_FLUSH),
        .SETTLE_CYCLES      (TB_SETTLE),
        .SWITCH_CYCLES      (TB_SWITCH)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .rst_relay_n      (rst_relay_n),
        .sys_ready        (sys_ready),
        .test_active      (test_active),
        .unmute_req       (unmute_req),
        .base_rate_sel    (base_rate_sel),
        .i2s_err          (i2s_err),
        .level_target     (level_target),
        .line_mute_drive  (line_mute_drive),
        .level_relay_drive(level_relay_drive),
        .force_zero       (force_zero),
        .switch_busy      (switch_busy)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Invariant: audio must never flow while the line relay is open
    always @(posedge clk) begin
        if (rst_n && !line_mute_drive && !force_zero) begin
            $display("FAIL: force_zero released while line relay open");
            fail_count++;
        end
    end

    // Invariant: the level cap may only change while digitally clamped
    logic [2:0] lvl_prev;
    always @(posedge clk) begin
        if (!rst_n) lvl_prev <= 3'b000;
        else begin
            if (level_relay_drive !== lvl_prev && !force_zero) begin
                $display("FAIL: level cap changed while unclamped (%0d -> %0d)",
                         lvl_prev, level_relay_drive);
                fail_count++;
            end
            lvl_prev <= level_relay_drive;
        end
    end

    task automatic check(input bit cond, input string msg);
        if (cond) $display("PASS: %s", msg);
        else begin
            $display("FAIL: %s", msg);
            fail_count++;
        end
    endtask

    initial begin
        $display("Starting automute_controller testbench (three-tier mute)");
        rst_n            = 0;
        rst_relay_n      = 0;
        sys_ready        = 0;
        test_active      = 0;
        unmute_req       = 0;
        base_rate_sel    = 0;
        i2s_err          = 0;
        level_target     = 3'b000;

        repeat(5) @(posedge clk);
        rst_n = 1;
        rst_relay_n = 1;
        repeat(2) @(posedge clk);

        // 1. Power-up but NOT ready: relay must stay open even with unmute
        unmute_req = 1;
        repeat(10) @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1,
              "relay open while system not ready (unmute ignored)");

        // 2. System ready: relay energizes ONCE (startup click), still clamped
        sys_ready = 1;
        wait (line_mute_drive === 1);
        check(force_zero === 1,
              "relay energized at startup ready, audio still clamped");
        wait (switch_busy === 0);
        check(level_relay_drive === 3'b000, "level at 2V default after start");

        // 3. Unmute was already high -> FLUSH -> PLAYING
        wait (line_mute_drive === 1 && force_zero === 0);
        $display("PASS: reached PLAYING after ready+unmute");
        repeat(10) @(posedge clk);

        // 4. i2s_err mid-session: digital clamp, relay STAYS CLOSED
        i2s_err = 1;
        repeat(3) @(posedge clk);
        check(force_zero === 1 && line_mute_drive === 1,
              "i2s_err: digital mute, relay stays closed (no click)");
        i2s_err = 0;
        repeat(10) @(posedge clk);
        wait (force_zero === 0);
        check(line_mute_drive === 1, "re-unmuted without relay cycling");

        // 5. Rate change: same — clamp only, relay stays closed
        base_rate_sel = 1;
        repeat(3) @(posedge clk);
        check(force_zero === 1 && line_mute_drive === 1,
              "rate change: digital mute, relay stays closed");
        base_rate_sel = 0;
        repeat(10) @(posedge clk);
        wait (force_zero === 0);

        // 6. Level cap 2V -> 6V while playing (digital gain cap, bom 7)
        repeat(5) @(posedge clk);
        level_target     = 3'b010;
        @(posedge clk);
        wait (force_zero === 1);
        check(line_mute_drive === 1,
              "level switch clamps digitally, relay stays closed");
        wait (level_relay_drive === 3'b010);
        check(line_mute_drive === 1 && force_zero === 1,
              "level applied while clamped, relay closed");
        wait (force_zero === 0);
        $display("PASS: playing at 6V after level switch");

        // 7. Level survives digital mute
        unmute_req = 0;
        repeat(5) @(posedge clk);
        check(level_relay_drive === 3'b010 && line_mute_drive === 1,
              "level held + relay closed through SPI mute");
        level_target = 3'b100;
        unmute_req = 1;
        wait (level_relay_drive === 3'b100);
        wait (force_zero === 0);
        $display("PASS: playing at 0.2V after muted level write");

        // 8. TEST MODE: relay opens for output isolation
        test_active = 1;
        repeat(3) @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1,
              "test_active opens relay (factory path)");
        test_active = 0;
        wait (line_mute_drive === 1);
        $display("PASS: relay re-energized after test mode exit");
        wait (force_zero === 0);

        // 9. POWER FAULT: pg_all drop opens the relay mid-session
        sys_ready = 0;
        repeat(3) @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1,
              "power fault opens relay mid-session");
        sys_ready = 1;
        wait (line_mute_drive === 1 && force_zero === 0);
        $display("PASS: recovered to PLAYING after power fault");

        // 10. PIPELINE RESET (rate-change equivalent): rst_n pulses while
        //     rst_relay_n stays high — the mechanical relay must NOT drop.
        //     FSM restarts muted in ARMED, then re-flushes to PLAYING.
        rst_n = 0;
        repeat(3) @(posedge clk);
        check(line_mute_drive === 1 && force_zero === 1,
              "pipeline reset: relay held closed (no click), output clamped");
        check(level_relay_drive === 3'b100,
              "level cap survives pipeline reset (was reverting to 2V)");
        rst_n = 1;
        wait (force_zero === 0);
        $display("PASS: relay held + resumed after pipeline reset");

        // 11. POWER RESET (rst_relay_n): the real open event — relay drops.
        rst_relay_n = 0;
        repeat(3) @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1,
              "power reset opens relay");
        rst_relay_n = 1;
        wait (line_mute_drive === 1);
        $display("PASS: relay re-energized after power reset");

        if (fail_count == 0) $display("TB_PASS: tb_automute all tests passed");
        else                 $display("TB_FAIL: %0d errors (tb_automute)", fail_count);
        $finish;
    end

endmodule
