`timescale 1ns / 1ps

// =============================================================================
// Testbench for automute_controller (Fig. 4d relay set)
//
// Headphone path removed 2026-11-14 ruling: no HP jack / HP mute / HP rails —
// the line XLR mute relay is the only output control.
//
// Verifies:
//   - Reset forces mute (line mute open, force_zero=1, level at 2V default)
//   - spi_unmute brings the controller to Playing (line mute energized)
//   - i2s_err / base_rate_sel change force an immediate return to Muted
//   - Level cap switch happens only while muted, then returns to Playing
//   - force_zero is never released while the line mute is open
// =============================================================================
module tb_automute;

    localparam int CLK_PERIOD_NS = 11; // ~90 MHz

    // Short timings for simulation
    localparam logic [27:0] TB_FLUSH  = 28'd200;
    localparam logic [27:0] TB_SETTLE = 28'd50;
    localparam logic [27:0] TB_SWITCH = 28'd50;

    logic clk;
    logic rst_n;
    logic spi_unmute;
    logic base_rate_sel;
    logic i2s_err;
    logic level_switch_req;
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
        .spi_unmute       (spi_unmute),
        .base_rate_sel    (base_rate_sel),
        .i2s_err          (i2s_err),
        .level_switch_req (level_switch_req),
        .level_target     (level_target),
        .line_mute_drive  (line_mute_drive),
        .level_relay_drive(level_relay_drive),
        .force_zero       (force_zero),
        .switch_busy      (switch_busy)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Invariant: audio must never flow while the line mute relay is open
    always @(posedge clk) begin
        if (rst_n && !line_mute_drive && !force_zero) begin
            $display("FAIL: force_zero released while line mute relay open");
            fail_count++;
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
        $display("Starting automute_controller testbench");
        rst_n             = 0;
        spi_unmute        = 0;
        base_rate_sel     = 0;
        i2s_err           = 0;
        level_switch_req  = 0;
        level_target      = 3'b000;

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // 1. Reset state: muted / de-energized
        check(line_mute_drive === 0 && force_zero === 1 &&
              level_relay_drive === 3'b000 && switch_busy === 0,
              "reset state correct (mute open, clamped, 2V level)");

        // 2. Unmute -> Playing
        spi_unmute = 1;
        wait (switch_busy === 1);
        check(force_zero === 1, "switch_busy asserted while relay is settling");
        wait (line_mute_drive === 1 && force_zero === 0);
        check(switch_busy === 0, "switch_busy is clear during stable playback");
        repeat(10) @(posedge clk);

        // 3. i2s_err -> immediate mute
        i2s_err = 1;
        @(posedge clk); @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1, "i2s_err forced mute");
        i2s_err = 0;
        repeat(10) @(posedge clk);

        // 4. Rate change -> immediate mute
        wait (line_mute_drive === 1 && force_zero === 0);
        base_rate_sel = 1;
        @(posedge clk); @(posedge clk);
        check(line_mute_drive === 0 && force_zero === 1,
              "base_rate_sel change forced mute");
        base_rate_sel = 0;
        repeat(10) @(posedge clk);

        // 5. Level cap 2V -> 6V while playing (digital gain cap, bom 7)
        wait (line_mute_drive === 1 && force_zero === 0);
        repeat(5) @(posedge clk);
        level_target     = 3'b010;
        level_switch_req = 1;
        @(posedge clk);
        level_switch_req = 0;
        // must re-mute before the level changes
        wait (line_mute_drive === 0 && force_zero === 1);
        check(switch_busy === 1, "switch_busy asserts during a relay transition");
        check(level_relay_drive !== 3'b010,
              "level did not change before mute");
        wait (level_relay_drive === 3'b010);
        check(line_mute_drive === 0 && force_zero === 1,
              "level changed while muted");
        wait (line_mute_drive === 1 && force_zero === 0);
        $display("PASS: returned to Playing after level switch");
        repeat(10) @(posedge clk);

        // 5b. Level must SURVIVE a mute (was: reset to 2 V on every mute)
        spi_unmute = 0;
        repeat(5) @(posedge clk);
        check(level_relay_drive === 3'b010, "level held at 6V through SPI mute");
        // 5c. A LEVEL write made while muted is applied on the next unmute pass
        //     (no req pulse at all: pending = target != applied)
        level_target = 3'b100;   // 0.2 Vrms
        repeat(5) @(posedge clk);
        check(level_relay_drive === 3'b010, "level not applied while sitting muted");
        spi_unmute = 1;
        wait (level_relay_drive === 3'b100);
        check(line_mute_drive === 0 && force_zero === 1,
              "0.2V level applied while still muted");
        wait (line_mute_drive === 1 && force_zero === 0);
        $display("PASS: playing at 0.2V level after muted write");
        repeat(10) @(posedge clk);

        if (fail_count == 0) $display("TB_PASS: tb_automute all tests passed");
        else                 $display("TB_FAIL: %0d errors (tb_automute)", fail_count);
        $finish;
    end

endmodule
