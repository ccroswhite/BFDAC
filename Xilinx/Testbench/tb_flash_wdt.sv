`timescale 1ns / 1ps

// =============================================================================
// tb_flash_wdt — qspi_flash_ctrl watchdog abort (2026-08-28)
//
// Models a HUNG flash: MISO tied high, so RDSR always returns WIP=1 and an
// erase command polls forever. With WDT_CYCLES overridden small, verifies:
//   T1: cmd_err pulses exactly once, cmd_busy releases, CS deasserts
//   T2: controller accepts a new command after the abort (returns to IDLE)
// Flow (no project):
//   xvlog -sv ..\qspi_flash_ctrl.sv .\tb_flash_wdt.sv
//   xelab tb_flash_wdt -s tb_wdt
//   xsim tb_wdt -runall
// =============================================================================
module tb_flash_wdt;

    logic clk = 0;
    logic rst_n = 0;
    always #2.5 clk = ~clk;   // 200 MHz

    logic [7:0]  cmd_opcode;
    logic [1:0]  cmd_target = '0;
    logic [31:0] cmd_addr = 32'h0001_0000;
    logic        cmd_trigger = 0;
    logic        cmd_busy, cmd_err;
    logic        spi_sck, spi_cs_n, spi_mosi, sel_flash0;

    qspi_flash_ctrl #(
        .WDT_CYCLES (32'd50_000)   // 250 us @ 200 MHz — fast sim abort
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_opcode (cmd_opcode),
        .cmd_target (cmd_target),
        .cmd_addr   (cmd_addr),
        .cmd_trigger(cmd_trigger),
        .cmd_busy   (cmd_busy),
        .cmd_err    (cmd_err),
        .buf_wdata  (8'h00),
        .buf_we     (1'b0),
        .buf_waddr  (8'h00),
        .buf_raddr  (8'h00),
        .buf_rdata  (),
        .rd_req     (1'b0),
        .rd_target  (1'b0),
        .rd_addr    (32'h0),
        .rd_len     (24'h0),
        .rd_stall   (1'b0),
        .rd_active  (),
        .rd_byte    (),
        .rd_byte_valid(),
        .rd_done    (),
        .spi_sck    (spi_sck),
        .spi_cs_n   (spi_cs_n),
        .spi_mosi   (spi_mosi),
        .sel_flash0 (sel_flash0),
        .spi_miso   (1'b1)         // hung flash: RDSR WIP stuck at 1
    );

    int err_pulses = 0;
    always @(posedge clk) if (cmd_err) err_pulses++;

    int errors = 0;

    task automatic check(input string name, input bit cond);
        if (!cond) begin
            $display("FAIL: %s", name);
            errors++;
        end else
            $display("PASS: %s", name);
    endtask

    initial begin
        $display("=== tb_flash_wdt: flash watchdog abort ===");
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // T1: erase against a hung flash — WIP poll never clears
        cmd_opcode  = 8'h01;
        cmd_trigger = 1;
        @(posedge clk);
        cmd_trigger = 0;
        @(posedge clk);
        check("[T1a] cmd_busy asserted on trigger", cmd_busy === 1'b1);

        // Wait past the watchdog window (50k clk + margin)
        repeat (60_000) @(posedge clk);
        check("[T1b] cmd_err pulsed exactly once", err_pulses == 1);
        check("[T1c] cmd_busy released after abort", cmd_busy === 1'b0);
        check("[T1d] CS deasserted after abort",     spi_cs_n === 1'b1);

        // T2: controller accepts a new command after the abort
        cmd_opcode  = 8'h01;
        cmd_trigger = 1;
        @(posedge clk);
        cmd_trigger = 0;
        @(posedge clk);
        check("[T2a] new command accepted after abort (busy)", cmd_busy === 1'b1);
        repeat (60_000) @(posedge clk);
        check("[T2b] second abort also flagged", err_pulses == 2);

        if (errors == 0) $display("=== tb_flash_wdt: ALL PASS ===");
        else             $display("=== tb_flash_wdt: %0d FAILURES ===", errors);
        $finish;
    end

endmodule
