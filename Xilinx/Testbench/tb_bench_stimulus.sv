`timescale 1ns / 1ps
module tb_bench_stimulus;
    logic clk = 0, rst_n = 0, allowed = 1, req = 0;
    logic [10:0] cmd = 0;
    wire ack;
    wire [10:0] applied;
    wire signed [47:0] sample_l, sample_r;
    logic [2:0] div = 0;
    wire tick = div == 7;
    int checks = 0;
    always #5 clk = ~clk;
    always @(posedge clk) div <= div + 1;
    bench_test_stimulus dut (.*);
    task cycles(input int n); repeat(n) @(negedge clk); endtask
    task send(input logic [10:0] value);
        cmd = value; req = 1;
        for (int n = 0; n < 100 && !ack; n++) cycles(1);
        if (!ack) $fatal(1, "ack timeout");
        req = 0;
        for (int n = 0; n < 20 && ack; n++) cycles(1);
        if (ack) $fatal(1, "ack release timeout");
        cycles(2);
    endtask
    initial begin
        cycles(10); rst_n = 1; cycles(10);
        for (int ch = 0; ch < 2; ch++) begin
            for (int s = 0; s < 128; s++) begin
                send({1'b1, 7'(s), 1'(ch), 2'd1});
                if (applied !== cmd) $fatal(1, "cell command transfer");
                checks++;
            end
            for (int s = 0; s < 5; s++) begin
                logic signed [47:0] expected;
                case(s)
                    0: expected = 0;
                    1: expected = 48'sd1 <<< 42;
                    2: expected = -(48'sd1 <<< 42);
                    3: expected = 48'sd4 <<< 42;
                    4: expected = -(48'sd4 <<< 42);
                endcase
                send({1'b1, 7'(s), 1'(ch), 2'd2});
                if (sample_l !== (ch ? 48'sd0 : expected) || sample_r !== (ch ? expected : 48'sd0))
                    $fatal(1, "DC value/channel mismatch");
                checks++;
            end
        end
        for (int rate = 0; rate < 2; rate++) begin
            for (int ch = 0; ch < 2; ch++) begin
                for (int f = 1; f <= 20; f++) begin
                    int fs, samples, first_cross, last_cross, crossings;
                    real measured;
                    logic signed [47:0] value, prev, peak;
                    fs = rate ? 6144000 : 5644800;
                    samples = fs * 5 / (f * 1000);
                    first_cross = -1; last_cross = -1; crossings = 0; prev = 0; peak = 0;
                    send({1'(rate), 7'(f-1), 1'(ch), 2'd3});
                    for (int n = 0; n < samples; n++) begin
                        do cycles(1); while (!tick);
                        value = ch ? sample_r : sample_l;
                        if ((ch ? sample_l : sample_r) !== 0) $fatal(1, "tone leaked to other channel");
                        if (value > peak) peak = value;
                        if (value >= 0 && prev < 0) begin
                            if (first_cross < 0) first_cross = n;
                            last_cross = n;
                            crossings++;
                        end
                        prev = value;
                    end
                    if (crossings < 3) $fatal(1, "missing sine cycles");
                    measured = real'(fs) * (crossings - 1) / (last_cross - first_cross);
                    if (measured < f*998.0 || measured > f*1002.0)
                        $fatal(1, "frequency error rate=%0d channel=%0d target=%0d measured=%f", rate,ch,f,measured);
                    if (peak < ((48'sd39 <<< 42) / 10) || peak > (48'sd4 <<< 42))
                        $fatal(1, "tone amplitude error %h", peak);
                    checks++;
                end
            end
        end
        send({1'b1, 7'd20, 1'b0, 2'd3});
        if (applied != 0) $fatal(1, "invalid frequency accepted");
        allowed = 0; send(11'h401); if (applied != 0) $fatal(1, "unsafe test accepted");
        allowed = 1; send(11'h403); cycles(10); allowed = 0; cycles(2);
        if (applied != 0) $fatal(1, "fault did not disable stimulus");
        allowed = 1; cycles(20); if (applied != 0) $fatal(1, "fault silently restarted stimulus");
        send(0); if (applied != 0) $fatal(1, "stop failed");
        rst_n = 0; cycles(2); if (ack || applied != 0) $fatal(1, "reset failed");
        $display("TB_PASS: bench stimulus %0d checks, 1-20kHz both rates/channels, DC levels, CDC, faults", checks);
        $finish;
    end
    initial begin #100000000; $fatal(1, "watchdog"); end
endmodule
