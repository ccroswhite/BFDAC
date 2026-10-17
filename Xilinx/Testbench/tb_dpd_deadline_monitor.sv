`timescale 1ns / 1ps
module tb_dpd_deadline_monitor;
    logic clk=0, rst_n=0, dpd_enabled=0;
    logic sample_advance=0, result_started=0, correction_applied=0;
    wire deadline_miss;
    int checks=0;
    always #1 clk=~clk;
    dpd_deadline_monitor dut (.*);

    task run_period(input int period, input bit expect_miss);
        rst_n=0; dpd_enabled=0; sample_advance=0;
        result_started=0; correction_applied=0;
        repeat(4) @(negedge clk);
        rst_n=1; dpd_enabled=1;
        for (int cycle=0; cycle<period*3+50; cycle++) begin
            @(negedge clk);
            sample_advance = (cycle % period) == 0;
            result_started = (cycle % period) == 5;
            correction_applied = cycle >= 47 && ((cycle - 47) % period) == 0;
        end
        @(negedge clk);
        sample_advance=0; result_started=0; correction_applied=0;
        if (deadline_miss !== expect_miss)
            $fatal(1,"period %0d: deadline_miss=%b expected %b",
                   period,deadline_miss,expect_miss);
        checks++;
    endtask

    initial begin
        run_period(45,1);
        run_period(46,1);
        run_period(47,1);
        run_period(48,0);
        run_period(49,0);
        run_period(50,0);
        $display("TB_PASS: DPD deadline monitor %0d consumption-boundary cases",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"watchdog"); end
endmodule
