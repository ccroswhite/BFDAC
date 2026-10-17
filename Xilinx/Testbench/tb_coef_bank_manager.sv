`timescale 1ns / 1ps

// Testbench: coef_bank_manager boot / request semantics (TODO-16, 2026-09-03)
//
//  T1  reset: ST_BOOT_WAIT, busy=1, bank_valid=0, bank_select=0, no load_start
//  T2  request before ddr4_ready is queued, not started
//  T3  ddr4_ready -> IDLE with NO bank swap; queued request starts a load into
//      the inactive bank (target=1 while select=0)
//  T4  first request is the legacy slot 0 (== reset current_bank_id): it must
//      NOT be swallowed by the same-bank shortcut while bank_valid=0
//  T5  successful load waits for one complete FIR input-frame boundary
//  T6  same-bank request after valid -> silently consumed, no load
//  T7  failed load -> no swap, current/bank_valid unchanged
//  T8  most-recent-wins queue while LOADING
module tb_coef_bank_manager;

    localparam int REQ_BITS = 17;

    logic clk = 0;
    logic rst_n = 0;
    always #1.4 clk = ~clk;   // ~357 MHz

    logic [REQ_BITS-1:0] bank_select_req = '0;
    logic                bank_select_pulse = 0;
    logic                ddr4_ready = 0;
    logic                sample_tick = 0;
    logic                load_done = 0;
    logic                load_failed = 0;

    logic                bank_select, bank_load_target, load_start, bank_valid, busy;
    logic [REQ_BITS-1:0] load_bank_id, current_bank_id;

    coef_bank_manager #(.REQ_BITS(REQ_BITS)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .bank_select_req(bank_select_req), .bank_select_pulse(bank_select_pulse),
        .ddr4_ready(ddr4_ready),
        .bank_select(bank_select), .bank_load_target(bank_load_target),
        .load_start(load_start), .load_bank_id(load_bank_id),
        .load_done(load_done), .load_failed(load_failed),
        .current_bank_id(current_bank_id), .bank_valid(bank_valid), .busy(busy)
    );

    int load_starts = 0;
    always @(posedge clk) if (load_start) load_starts++;

    int errors = 0;
    task automatic check(input string name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL: %s got=0x%0h exp=0x%0h", name, got, exp);
            errors++;
        end else
            $display("PASS: %s = 0x%0h", name, got);
    endtask

    task automatic request(input [REQ_BITS-1:0] req);
        @(posedge clk);
        bank_select_req   <= req;
        bank_select_pulse <= 1'b1;
        @(posedge clk);
        bank_select_pulse <= 1'b0;
    endtask

    task automatic finish_load(input bit fail);
        @(posedge clk);
        load_failed <= fail;
        load_done   <= 1'b1;
        @(posedge clk);
        load_done   <= 1'b0;
        repeat (3) @(posedge clk);   // LOADING -> WAIT_BOUNDARY (or IDLE on failure)
        load_failed <= 1'b0;
    endtask

    task automatic finish_input_frame;
        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        repeat (3) @(posedge clk);   // boundary -> SWITCHING -> IDLE
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        // T1
        check("T1 busy in BOOT_WAIT",     busy,        1);
        check("T1 bank_valid",            bank_valid,  0);
        check("T1 bank_select",           bank_select, 0);
        check("T1 no load_start",         load_starts, 0);

        // T2 + T4: legacy slot 0 request before DDR4 is ready
        request({1'b0, 16'h0000});
        repeat (5) @(posedge clk);
        check("T2 queued, not started",   load_starts, 0);
        check("T2 still busy",            busy,        1);

        // T3
        @(posedge clk); ddr4_ready <= 1'b1;
        repeat (4) @(posedge clk);
        check("T3 load started",          load_starts, 1);
        check("T3 no swap on ready",      bank_select, 0);
        check("T3 load target = shadow",  bank_load_target, 1);
        check("T3 load_bank_id",          load_bank_id, {1'b0, 16'h0000});
        check("T4 slot-0 not swallowed",  busy,        1);

        // A boundary during loading is irrelevant; the finished shadow image
        // must not switch banks in the middle of the current FIR frame.
        @(negedge clk); sample_tick = 1'b1;
        @(negedge clk); sample_tick = 1'b0;
        check("T5 no swap during load", bank_select, 0);

        // T5
        finish_load(0);
        check("T5 waits for frame boundary", bank_select, 0);
        check("T5 reports busy while waiting", busy, 1);
        finish_input_frame();
        check("T5 bank_select swapped",   bank_select, 1);
        check("T5 bank_valid",            bank_valid,  1);
        check("T5 current_bank_id",       current_bank_id, {1'b0, 16'h0000});
        check("T5 idle",                  busy,        0);
        check("T5 next target = old active", bank_load_target, 0);

        // T6
        request({1'b0, 16'h0000});
        repeat (5) @(posedge clk);
        check("T6 same bank consumed",    load_starts, 1);
        check("T6 idle",                  busy,        0);

        // T7: filter ID lookup fails
        request({1'b1, 16'h0BAD});
        repeat (4) @(posedge clk);
        check("T7 load started",          load_starts, 2);
        finish_load(1);
        check("T7 no swap on failure",    bank_select, 1);
        check("T7 current unchanged",     current_bank_id, {1'b0, 16'h0000});
        check("T7 bank_valid unchanged",  bank_valid,  1);
        check("T7 idle",                  busy,        0);

        // T8: two requests while loading -> the last one runs next
        request({1'b1, 16'h0001});
        repeat (4) @(posedge clk);
        check("T8 load 3 started",        load_starts, 3);
        request({1'b1, 16'h0002});
        request({1'b1, 16'h0003});
        finish_load(0);
        check("T8 loaded image waits for frame boundary", current_bank_id,
              {1'b0, 16'h0000});
        check("T8 pending boundary keeps manager busy", busy, 1);
        finish_input_frame();
        check("T8 swapped to id 1",       current_bank_id, {1'b1, 16'h0001});
        repeat (2) @(posedge clk);
        check("T8 queued id 3 started",   load_starts, 4);
        check("T8 load_bank_id = 3",      load_bank_id, {1'b1, 16'h0003});
        finish_load(0);
        finish_input_frame();
        check("T8 current = id 3",        current_bank_id, {1'b1, 16'h0003});
        check("T8 bank_select back to 1", bank_select, 1);

        if (errors == 0) $display("TB_PASS: tb_coef_bank_manager all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $finish;
    end

endmodule
