`timescale 1ns / 1ps
// Dual-source ingress test (2026-11-20, Option A): two slave-TX streams on the
// shared FPGA BCLK/LRCLK pair — i2s_data (XMOS) sends LEFT1/RIGHT1, i2s_data2
// (AP McASP0) sends LEFT2/RIGHT2.  Verifies:
//   - each source captures correctly when selected
//   - a src_sel change flushes + re-arms: the first post-switch sample is a
//     complete frame of the new source — no torn/mixed frames ever
//   - garbage on the DESELECTED pin cannot corrupt the selected stream
//   - a trim change alongside the select is honoured (per-source trim path)
module tb_i2s_dual_src;
    logic dsp_clk=0, cell_clk=0, rst_n=0, enable=0, source_valid=0;
    logic src_sel=0, i2s_data=0, i2s_data2=0;
    logic [1:0] rate_shift=0;
    logic [4:0] rx_trim=0;
    wire i2s_bclk, i2s_lrclk, new_sample, i2s_err, transport_fault, audio_frame_ready;
    wire [23:0] audio_l, audio_r;
    real cell_period=20.345052083, dsp_period=3.560384115;
    int tx_bit=63, src1_n=0, src2_n=0, cases=0;
    logic bad_pin=0;   // garbage driver on the deselected pin
    localparam logic [31:0] LEFT1=32'h81123456, RIGHT1=32'h8FEDCBA9;
    localparam logic [31:0] LEFT2=32'h9CA5A5CA, RIGHT2=32'hA55A3C3C;
    always #(cell_period/2) cell_clk=~cell_clk;
    always #(dsp_period/2) dsp_clk=~dsp_clk;
    i2s_master_ingress dut (.*);
    always @(negedge rst_n) tx_bit=63;
    // Both slaves transmit in lockstep on the shared clock pair (32-bit slots,
    // upper 24 bits used).  bad_pin scrambles whichever pin is deselected.
    always @(negedge i2s_bclk) begin
        if(rst_n && enable) begin
            #0.001;
            if(tx_bit==31 && i2s_lrclk!==1) $fatal(1,"I2S WS right alignment");
            if(tx_bit==63 && i2s_lrclk!==0) $fatal(1,"I2S WS left alignment");
            // scramble only whichever pin is DESELECTED (mux never sees it)
            i2s_data  <= (tx_bit<32 ? LEFT1[31-tx_bit] : RIGHT1[63-tx_bit]) ^ (bad_pin & src_sel);
            i2s_data2 <= (tx_bit<32 ? LEFT2[31-tx_bit] : RIGHT2[63-tx_bit]) ^ (bad_pin & ~src_sel);
            tx_bit=(tx_bit+1)%64;
        end
    end
    task cycles(input int n); repeat(n) @(negedge dsp_clk); endtask
    // Scoreboard: every emitted sample must be a consistent pair of ONE source.
    task watch(output int done1, output int done2);
        done1=0; done2=0;
        while(done1<8 || done2<8) begin
            @(posedge dsp_clk); #0.01;
            if(new_sample) begin
                if(i2s_err) $fatal(1,"i2s_err during stream src_sel=%b L=%h R=%h",src_sel,audio_l,audio_r);
                if(audio_l===LEFT1[31:8] && audio_r===RIGHT1[31:8]) done1++;
                else if(audio_l===LEFT2[31:8] && audio_r===RIGHT2[31:8]) done2++;
                else $fatal(1,"torn/foreign sample L=%h R=%h sel=%b",audio_l,audio_r,src_sel);
            end
        end
    endtask
    int got1, got2;
    initial begin
        // boot: XMOS selected
        rst_n=0; enable=0; source_valid=0; cycles(10);
        tx_bit=63; rst_n=1; cycles(20); enable=1; source_valid=1; cycles(5);
        // T1: src1 capture — take 4 samples of src1 while sel=0
        while(src1_n<4) begin
            @(posedge dsp_clk); #0.01;
            if(new_sample) begin
                if(audio_l!==LEFT1[31:8] || audio_r!==RIGHT1[31:8] || i2s_err)
                    $fatal(1,"src1 mismatch L=%h R=%h err=%b",audio_l,audio_r,i2s_err);
                src1_n++;
            end
        end
        // T2: switch to src2 mid-stream — no torn samples allowed
        src_sel=1;
        got1=0; got2=0;
        repeat(90000) begin @(posedge dsp_clk); #0.01;
            if(new_sample) begin
                if(i2s_err) $fatal(1,"i2s_err after select src2");
                if(audio_l===LEFT2[31:8] && audio_r===RIGHT2[31:8]) got2++;
                else if(audio_l===LEFT1[31:8] && audio_r===RIGHT1[31:8]) got1++;
                else $fatal(1,"torn frame after sel->1 L=%h R=%h",audio_l,audio_r);
                if(got2==6) break;
            end
        end
        if(got2!=6) $fatal(1,"src2 stream never captured (got2=%0d got1=%0d)",got2,got1);
        // <=1 pre-switch src1 frame may legitimately drain inside the 2-cycle
        // sel_sync latency; anything more means the flush didn't happen.
        if(got1>1) $fatal(1,"stale src1 samples after switch (got1=%0d)",got1);
        cases++;
        // T3: scramble the DESELECTED pin — selected stream must stay clean
        bad_pin=1'b1;
        got2=0;
        while(got2<4) begin
            @(posedge dsp_clk); #0.01;
            if(new_sample) begin
                if(i2s_err) $fatal(1,"deselected garbage faulted selected stream");
                if(audio_l!==LEFT2[31:8] || audio_r!==RIGHT2[31:8])
                    $fatal(1,"deselected garbage leaked L=%h R=%h",audio_l,audio_r);
                got2++;
            end
        end
        cases++;
        // T4: switch back to src1 + trim change (per-source trim path)
        bad_pin=1'b0; src_sel=0; rx_trim=5'd4;
        got1=0; got2=0;
        repeat(90000) begin @(posedge dsp_clk); #0.01;
            if(new_sample) begin
                if(i2s_err) $fatal(1,"i2s_err after select src1");
                if(audio_l===LEFT1[31:8] && audio_r===RIGHT1[31:8]) got1++;
                else if(audio_l===LEFT2[31:8] && audio_r===RIGHT2[31:8]) got2++;
                else $fatal(1,"torn frame after sel->0 L=%h R=%h",audio_l,audio_r);
                if(got1==6) break;
            end
        end
        if(got1!=6) $fatal(1,"src1 stream never re-captured (got1=%0d)",got1);
        if(got2>1) $fatal(1,"excess src2 samples after switch-back (got2=%0d)",got2);
        cases++;
        // T5: source_valid contract unchanged — drop valid, expect err+no fault
        source_valid=0; cycles(5);
        if(!audio_frame_ready) $fatal(1,"complete AP audio frame not qualified");
        if(!i2s_err || transport_fault) $fatal(1,"source-valid contract");
        cases++;
        $display("TB_PASS: I2S dual-source %0d cases",cases);
        $finish;
    end
    initial begin #20000000; $fatal(1,"watchdog"); end
endmodule
