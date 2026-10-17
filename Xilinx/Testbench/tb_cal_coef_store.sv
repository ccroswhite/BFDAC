`timescale 1ns / 1ps

// =============================================================================
// tb_cal_coef_store — verifies the ARM-writes / FPGA-applies cal store:
//   T1: reset state — bank0 active, no pending, readback zeros
//   T2: shadow write + commit — flip happens ONLY at the sample tick
//   T3: active-bank readback matches the written pattern (all 512 words)
//   T4: writes to the new shadow do NOT disturb the active bank (isolation)
//   T5: second commit swaps back; both banks retain their patterns
//   T6: dpd read port returns the active bank word
// =============================================================================
module tb_cal_coef_store;

    // dsp_clk 280 MHz, ctrl_clk 200 MHz
    logic dsp_clk = 0, ctrl_clk = 0;
    always #1.7857 dsp_clk  = ~dsp_clk;
    always #2.5    ctrl_clk = ~ctrl_clk;

    logic dsp_rst_n = 0, ctrl_rst_n = 0;

    // sample tick: every 365 dsp_clk (~768 kHz)
    logic        sample_tick = 0;
    int          tick_cnt = 0;
    always @(posedge dsp_clk) begin
        tick_cnt    <= (tick_cnt == 364) ? 0 : tick_cnt + 1;
        sample_tick <= (tick_cnt == 364);
    end

    logic        wr_toggle = 0, commit_toggle = 0;
    logic [8:0]  wr_addr = '0, rd_addr = '0;
    logic [23:0] wr_data = '0, rd_data;
    logic        active_bank, commit_pending;
    logic [3:0][8:0]  dpd_rd_addr = '0;
    logic [3:0][23:0] dpd_rd_data;

    cal_coef_store dut (
        .dsp_clk(dsp_clk), .dsp_rst_n(dsp_rst_n), .sample_tick(sample_tick),
        .dpd_rd_addr(dpd_rd_addr), .dpd_rd_data(dpd_rd_data),
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(ctrl_rst_n),
        .wr_toggle(wr_toggle), .wr_addr(wr_addr), .wr_data(wr_data),
        .commit_toggle(commit_toggle),
        .rd_addr(rd_addr), .rd_data(rd_data),
        .active_bank(active_bank), .commit_pending(commit_pending)
    );

    int errors = 0;

    // Emulates one SPI 0x0D frame: set addr/data, flip toggle, wait "frame gap"
    task automatic spi_write(input [8:0] a, input [23:0] d);
        @(posedge ctrl_clk);
        wr_addr   <= a;
        wr_data   <= d;
        wr_toggle <= ~wr_toggle;
        repeat (20) @(posedge ctrl_clk);   // frame gap >> sync latency
    endtask

    task automatic spi_read(input [8:0] a, output [23:0] d);
        @(posedge ctrl_clk);
        rd_addr <= a;
        repeat (20) @(posedge ctrl_clk);   // settle across domains
        d = rd_data;
    endtask

    function automatic [23:0] pat_a(input [8:0] a);
        pat_a = {3'b101, a, ~a, 3'b010};
    endfunction
    function automatic [23:0] pat_b(input [8:0] a);
        pat_b = {3'b011, ~a, a, 3'b110};
    endfunction

    logic [23:0] got;

    initial begin
        repeat (10) @(posedge ctrl_clk);
        dsp_rst_n = 1; ctrl_rst_n = 1;
        repeat (10) @(posedge ctrl_clk);

        // --- T1: reset state ---------------------------------------------
        if (active_bank !== 1'b0 || commit_pending !== 1'b0) begin
            $display("FAIL T1: active=%b pending=%b after reset", active_bank, commit_pending);
            errors++;
        end
        spi_read(9'd7, got);
        if (got !== 24'd0) begin
            $display("FAIL T1: reset readback %h != 0", got);
            errors++;
        end
        if (errors == 0) $display("T1 reset state: PASS");

        // --- T2: write pattern A to shadow, commit ------------------------
        for (int a = 0; a < 512; a++) spi_write(a[8:0], pat_a(a[8:0]));

        // Not committed yet: active bank still zeros
        spi_read(9'd100, got);
        if (got !== 24'd0) begin
            $display("FAIL T2: active bank changed before commit (%h)", got);
            errors++;
        end

        @(posedge ctrl_clk);
        commit_toggle <= ~commit_toggle;
        // pending must assert, then clear at a tick
        repeat (10) @(posedge ctrl_clk);
        if (commit_pending !== 1'b1 && active_bank !== 1'b1) begin
            $display("FAIL T2: no pending and no flip after commit request");
            errors++;
        end
        // wait past one full sample period
        repeat (200) @(posedge ctrl_clk);
        if (active_bank !== 1'b1 || commit_pending !== 1'b0) begin
            $display("FAIL T2: active=%b pending=%b after tick", active_bank, commit_pending);
            errors++;
        end
        $display("T2 shadow write + tick-aligned commit: %s", errors ? "FAIL" : "PASS");

        // --- T3: full active-bank readback --------------------------------
        for (int a = 0; a < 512; a++) begin
            spi_read(a[8:0], got);
            if (got !== pat_a(a[8:0])) begin
                if (errors < 5)
                    $display("FAIL T3: addr %0d read %h expect %h", a, got, pat_a(a[8:0]));
                errors++;
            end
        end
        $display("T3 active-bank readback (512 words): %s", errors ? "FAIL" : "PASS");

        // --- T4: writes to new shadow do not disturb active ---------------
        for (int a = 0; a < 512; a++) begin
            spi_write(a[8:0], pat_b(a[8:0]));
            if (a % 128 == 0) begin
                spi_read(a[8:0], got);
                if (got !== pat_a(a[8:0])) begin
                    $display("FAIL T4: active bank disturbed at %0d (%h)", a, got);
                    errors++;
                end
            end
        end
        $display("T4 shadow-write isolation: %s", errors ? "FAIL" : "PASS");

        // --- T5: second commit swaps to pattern B -------------------------
        @(posedge ctrl_clk);
        commit_toggle <= ~commit_toggle;
        repeat (300) @(posedge ctrl_clk);
        if (active_bank !== 1'b0) begin
            $display("FAIL T5: active_bank=%b after second commit", active_bank);
            errors++;
        end
        for (int a = 0; a < 512; a += 37) begin
            spi_read(a[8:0], got);
            if (got !== pat_b(a[8:0])) begin
                $display("FAIL T5: addr %0d read %h expect %h", a, got, pat_b(a[8:0]));
                errors++;
            end
        end
        $display("T5 second commit swap: %s", errors ? "FAIL" : "PASS");

        // --- T6: dpd read port -------------------------------------------
        dpd_rd_addr[0] = 9'd42;
        dpd_rd_addr[3] = 9'd42;
        repeat (5) @(posedge dsp_clk);
        if (dpd_rd_data[0] !== pat_b(9'd42) || dpd_rd_data[3] !== pat_b(9'd42)) begin
            $display("FAIL T6: dpd ports read %h/%h expect %h",
                     dpd_rd_data[0], dpd_rd_data[3], pat_b(9'd42));
            errors++;
        end
        $display("T6 dpd read port: %s", errors ? "FAIL" : "PASS");

        if (errors == 0) $display("ALL TESTS PASS (tb_cal_coef_store)");
        else             $display("TESTS FAILED: %0d errors (tb_cal_coef_store)", errors);
        $finish;
    end

endmodule
