`timescale 1ns / 1ps
module tb_bench_controller;
    logic clk = 0, rst_n = 0, select_n = 1, step_n = 1;
    logic available = 1, ready = 1, healthy = 1, rate_48 = 1, ack = 0;
    logic allow_ack = 1;
    wire req, busy, led;
    wire [10:0] cmd;
    wire [31:0] status;
    int ack_timer = 0, checks = 0;
    always #5 clk = ~clk;
    bench_test_controller #(.CLK_HZ(120), .DEBOUNCE_CYCLES(4), .SELECT_CYCLES(360), .CANCEL_CYCLES(240)) dut (
        .clk(clk), .rst_n(rst_n), .select_n(select_n), .step_n(step_n),
        .available(available), .ready(ready), .healthy(healthy), .rate_48(rate_48),
        .cmd_ack(ack), .cmd_req(req), .cmd(cmd), .busy(busy), .led(led), .status(status)
    );
    always @(posedge clk) begin
        if (!rst_n || !req) begin ack <= 0; ack_timer <= 0; end
        else if (allow_ack) begin
            if (ack_timer == 7) ack <= 1;
            else ack_timer <= ack_timer + 1;
        end
    end
    task cycles(input int n);
        repeat(n) @(negedge clk);
    endtask
    task tap(input bit step_button);
        if (step_button) step_n = 0; else select_n = 0;
        cycles(12);
        if (step_button) step_n = 1; else select_n = 1;
        cycles(12);
    endtask
    task idle;
        for (int n = 0; n < 1000 && busy; n++) cycles(1);
        if (busy || led) $fatal(1, "not idle/dark");
        checks++;
    endtask
    task held(input int mode, input int ch, input int step_index);
        for (int n = 0; n < 1200 && dut.state != dut.HOLD; n++) cycles(1);
        if (dut.state != dut.HOLD || cmd !== {rate_48, 7'(step_index), 1'(ch), 2'(mode)})
            $fatal(1, "held state mismatch cmd=%h mode=%0d ch=%0d step=%0d state=%0d", cmd, mode, ch, step_index, dut.state);
        checks++;
    endtask
    task choose(input int mode);
        for (int i = 0; i < mode; i++) tap(0);
    endtask
    initial begin
        cycles(10); rst_n = 1; cycles(15);
        for (int i = 0; i < 6; i++) begin select_n = 0; cycles(1); select_n = 1; cycles(2); end
        if (busy) $fatal(1, "bounce started selection");
        available = 0; tap(0); if (busy) $fatal(1, "stole SPI ownership"); available = 1;
        choose(4); cycles(400); idle();
        ready = 0; choose(1); cycles(400);
        if (req || led || !busy || dut.state != dut.ARM) $fatal(1, "did not wait for mute/PG");
        ready = 1; held(1,0,0);
        select_n = 0; cycles(270); select_n = 1; cycles(20); idle();
        for (int mode = 1; mode <= 3; mode++) begin
            int last_step;
            logic [10:0] saved;
            int edges;
            bit prev;
            last_step = mode == 1 ? 127 : mode == 2 ? 4 : 19;
            choose(mode); held(mode,0,0);
            saved = cmd;
            edges = 0; prev = led;
            repeat(120) begin cycles(1); if (led != prev) edges++; prev = led; end
            if (edges != mode * 2 || cmd != saved) $fatal(1, "blink cadence/autostep %0d %0d", mode, edges);
            step_n = 0; cycles(130); step_n = 1; cycles(15);
            held(mode,0,1);
            for (int ch = 0; ch < 2; ch++) begin
                for (int s = ch == 0 ? 2 : 0; s <= last_step; s++) begin
                    tap(1); held(mode,ch,s);
                end
            end
            saved = cmd; cycles(150);
            if (!busy || cmd != saved) $fatal(1, "final condition did not hold");
            tap(1); idle();
        end
        choose(2); held(2,0,0);
        tap(0); tap(0); held(2,0,0);
        allow_ack = 0;
        tap(1);
        begin
            logic [10:0] saved;
            saved = cmd;
            tap(1); cycles(40);
            if (!req || cmd != saved) $fatal(1, "command changed while awaiting ack");
        end
        healthy = 0; cycles(20); allow_ack = 1; idle();
        healthy = 1; cycles(400); if (busy) $fatal(1, "test restarted after fault");
        choose(3); held(3,0,0);
        rst_n = 0; cycles(10);
        if (busy || led || req || cmd != 0) $fatal(1, "reset failed");
        select_n = 0; rst_n = 1; cycles(400);
        if (busy) $fatal(1, "held button at boot started test");
        select_n = 1; cycles(15);
        choose(1); held(1,0,0);
        $display("TB_PASS: bench controller %0d checks, all cell/DC/frequency steps, debounce, LED, faults, ownership", checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "watchdog"); end
endmodule
