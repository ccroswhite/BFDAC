`timescale 1ns / 1ps

// =============================================================================
// Testbench for automute_controller (Fig. 4d relay set)
//
// Verifies:
//   - Reset forces mute everywhere (both mute relays open, HP rails off,
//     force_zero=1, level relays at 2V default)
//   - spi_unmute brings the controller to Playing with LINE output active
//     (line mute energized, HP mute open, HP rails off)
//   - i2s_err / base_rate_sel change force an immediate return to Muted
//   - Level tap switch happens only while both mutes are open, then returns
//     to Playing
//   - Output select line->HP: rails energize and RAIL_SETTLE elapses BEFORE
//     hp_mute closes; line mute stays open (mutual exclusivity)
//   - Output select HP->line: HP mute opens, rails drop, line mute closes
//   - Mute relays are never simultaneously energized at any cycle
// =============================================================================
module tb_automute;

    localparam int CLK_PERIOD_NS = 11; // ~90 MHz

    // Short timings for simulation
    localparam logic [25:0] TB_FLUSH  = 26'd200;
    localparam logic [25:0] TB_SETTLE = 26'd50;
    localparam logic [25:0] TB_SWITCH = 26'd50;
    localparam logic [25:0] TB_RAIL   = 26'd400;

    logic clk;
    logic rst_n;
    logic spi_unmute;
    logic base_rate_sel;
    logic i2s_err;
    logic level_switch_req;
    logic [1:0] level_target;
    logic outsel_switch_req;
    logic outsel_target;
    logic line_mute_drive;
    logic hp_mute_drive;
    logic hp_rails_drive;
    logic [1:0] level_relay_drive;
    logic force_zero;
    logic switch_busy;

    int fail_count = 0;

    automute_controller #(
        .FLUSH_CYCLES       (TB_FLUSH),
        .SETTLE_CYCLES      (TB_SETTLE),
        .SWITCH_CYCLES      (TB_SWITCH),
        .RAIL_SETTLE_CYCLES (TB_RAIL)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .spi_unmute       (spi_unmute),
        .base_rate_sel    (base_rate_sel),
        .i2s_err          (i2s_err),
        .level_switch_req (level_switch_req),
        .level_target     (level_target),
        .outsel_switch_req(outsel_switch_req),
        .outsel_target    (outsel_target),
        .line_mute_drive  (line_mute_drive),
        .hp_mute_drive    (hp_mute_drive),
        .hp_rails_drive   (hp_rails_drive),
        .level_relay_drive(level_relay_drive),
        .force_zero       (force_zero),
        .switch_busy      (switch_busy)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Invariant: the two mute relays must never be energized together
    always @(posedge clk) begin
        if (rst_n && line_mute_drive && hp_mute_drive) begin
            $display("FAIL: line and HP mute relays energized simultaneously");
            fail_count++;
        end
    end

    // Invariant: HP mute must never be closed with HP rails off
    always @(posedge clk) begin
        if (rst_n && hp_mute_drive && !hp_rails_drive) begin
            $display("FAIL: HP jack live while HP stage unpowered");
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
        level_target      = 2'b00;
        outsel_switch_req = 0;
        outsel_target     = 1'b0;

        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // 1. Reset state: everything muted / de-energized
        check(line_mute_drive === 0 && hp_mute_drive === 0 &&
              hp_rails_drive === 0 && force_zero === 1 &&
              level_relay_drive === 2'b00,
              "reset state correct (all de-energized, clamped, 2V tap)");

        // 2. Unmute -> Playing on line output
        spi_unmute = 1;
        wait (line_mute_drive === 1 && force_zero === 0);
        check(hp_mute_drive === 0 && hp_rails_drive === 0,
              "playing on line output; HP branch dead");
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

        // 5. Level tap switch 2V -> 6V while playing
        wait (line_mute_drive === 1 && force_zero === 0);
        repeat(5) @(posedge clk);
        level_target     = 2'b10;
        level_switch_req = 1;
        @(posedge clk);
        level_switch_req = 0;
        // must re-mute before the tap moves
        wait (line_mute_drive === 0 && force_zero === 1);
        check(level_relay_drive !== 2'b10,
              "level tap did not move before mute");
        wait (level_relay_drive === 2'b10);
        check(line_mute_drive === 0 && force_zero === 1,
              "level tap moved while muted");
        wait (line_mute_drive === 1 && force_zero === 0);
        $display("PASS: returned to Playing after level switch");
        repeat(10) @(posedge clk);

        // 6. Output select line -> headphone
        outsel_target     = 1'b1;
        outsel_switch_req = 1;
        @(posedge clk);
        outsel_switch_req = 0;
        // rails must energize while both mutes are open
        wait (hp_rails_drive === 1);
        check(line_mute_drive === 0 && hp_mute_drive === 0 && force_zero === 1,
              "HP rails energized while fully muted");
        // then, after rail settle, HP mute closes and line stays open
        wait (hp_mute_drive === 1 && force_zero === 0);
        check(line_mute_drive === 0, "playing on HP; line mute open");
        repeat(10) @(posedge clk);

        // 7. Output select headphone -> line
        outsel_target     = 1'b0;
        outsel_switch_req = 1;
        @(posedge clk);
        outsel_switch_req = 0;
        wait (hp_mute_drive === 0 && force_zero === 1);
        $display("PASS: HP muted before switch back");
        wait (line_mute_drive === 1 && force_zero === 0);
        check(hp_mute_drive === 0 && hp_rails_drive === 0,
              "back on line; HP branch dead again");

        if (fail_count == 0) $display("Testbench complete: ALL PASS");
        else                 $display("Testbench complete: %0d FAILURES", fail_count);
        $stop;
    end

endmodule
