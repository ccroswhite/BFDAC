`timescale 1ns / 1ps
module tb_stream_rate_controller;
    logic clk=0, rst_n=0, clk_locked=0, req_toggle=0;
    logic [2:0] requested_rate=0;
    wire ack_toggle, busy, ready, mmcm_rst, path_reset, clk_sel, serial_enable;
    wire [2:0] applied_rate;
    int checks=0, lock_timer=0;
    logic fail_clock=0;
    always #2.5 clk=~clk;
    stream_rate_controller #(.MUTE_CYCLES(20), .SETTLE_CYCLES(8), .STARTUP_CYCLES(12)) dut (.*);
    always @(posedge clk) begin
        if (!rst_n || mmcm_rst || fail_clock) begin clk_locked<=0; lock_timer<=0; end
        else if(lock_timer==6) clk_locked<=1;
        else lock_timer<=lock_timer+1;
    end
    task cycles(input int n); repeat(n) @(negedge clk); endtask
    task wait_ready;
        for(int n=0;n<250 && !ready;n++) cycles(1);
        if(!ready || busy || path_reset || mmcm_rst) $fatal(1,"rate transaction stalled");
    endtask
    initial begin
        cycles(5); rst_n=1; wait_ready();
        if(applied_rate!=0 || clk_sel!=1) $fatal(1,"initial family polarity");
        for(int r=0;r<8;r++) begin
            logic [2:0] old_rate;
            old_rate=applied_rate;
            requested_rate=3'(r); req_toggle=~req_toggle;
            cycles(1);
            if(!busy || ready) $fatal(1,"request not busy/muted");
            cycles(15);
            if(applied_rate!=old_rate || path_reset) $fatal(1,"switched before mute delay");
            wait_ready();
            if(applied_rate!=r || ack_toggle!=req_toggle || clk_sel!==!r[0])
                $fatal(1,"wrong applied rate/ack/polarity");
            checks++;
        end
        fail_clock=1; cycles(20);
        if(ready) $fatal(1,"ready while clock failed");
        fail_clock=0; wait_ready();
        if(applied_rate!=7) $fatal(1,"recovery changed rate");
        requested_rate=2; req_toggle=~req_toggle; cycles(5);
        rst_n=0; cycles(3);
        if(ready || !mmcm_rst || !path_reset) $fatal(1,"reset unsafe");
        $display("TB_PASS: stream controller %0d rate configurations, fault/recovery/reset",checks);
        $finish;
    end
    initial begin #100000; $fatal(1,"watchdog"); end
endmodule
