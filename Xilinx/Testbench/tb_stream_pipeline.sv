`timescale 1ns / 1ps
module tb_stream_pipeline;
    logic dsp_clk=0, cell_clk=0, rst_n=0, enable=0;
    logic [1:0] shift=0;
    real cp=20.345052083, dp=3.560384115;
    wire bclk, lrclk, sample_valid, serial_error, serial_fault, stream_fault;
    wire fir_frame_done;
    wire [23:0] audio_l, audio_r;
    wire [63:0] cascode_l, cascode_r;
    int cases=0;
    always #(cp/2) cell_clk=~cell_clk;
    always #(dp/2) dsp_clk=~dsp_clk;
    i2s_master_ingress ingress (
        .dsp_clk(dsp_clk), .cell_clk(cell_clk), .rst_n(rst_n), .enable(enable),
        .source_valid(1'b1), .rate_shift(shift), .rx_trim(5'd0), .i2s_data(1'b0),
        .i2s_bclk(bclk), .i2s_lrclk(lrclk), .audio_l(audio_l), .audio_r(audio_r),
        .new_sample(sample_valid), .i2s_err(serial_error), .transport_fault(serial_fault)
    );
    dac_dsp_core #(.NUM_MACS(4), .TAPS_PER_PHASE(16)) core (
        .dsp_clk(dsp_clk), .cell_clk(cell_clk), .sys_rst_n(rst_n),
        .audio_l(audio_l), .audio_r(audio_r), .new_sample(sample_valid), .force_zero(1'b0),
        .rate_shift(shift), .stream_fault(stream_fault),
        .fir_frame_done(fir_frame_done),
        .coef_we(1'b0), .coef_waddr(8'd0), .coef_wdata(18'd0), .coef_wmac(2'd0),
        .bank_select(1'b0), .bank_load_target(1'b0), .sys_volume(32'h001c0000),
        .boot_envelope_gain(16'hffff), .dpd_enable(1'b0), .dpd_cal_data('0),
        .cell_test_cfg('0), .cell_test_req(2'd0), .cell_test_safe(1'b0),
        .bench_req(1'b0), .bench_cmd(11'd0), .cascode_l(cascode_l), .cascode_r(cascode_r)
    );
    int fir_frame_count=0;
    always @(posedge dsp_clk) begin
        if(!rst_n) fir_frame_count<=0;
        else if(fir_frame_done) fir_frame_count<=fir_frame_count+1;
    end
    initial begin
        for(int f=0;f<2;f++) begin
            for(int r=0;r<4;r++) begin
                int frames, captures, run_length, cell_cycle, last_capture;
                rst_n=0; enable=0;
                cp=f ? 20.345052083 : 22.144274376;
                dp=cp*3.25/20.0;
                shift=2'(r);
                repeat(20) @(negedge dsp_clk);
                rst_n=1;
                repeat(40) @(negedge dsp_clk);
                enable=1;
                frames=0;
                while(frames<32) begin
                    @(posedge dsp_clk); #0.01;
                    if(sample_valid) frames++;
                end
                begin
                    int wait_cycles;
                    wait_cycles=0;
                    while(fir_frame_count<frames && wait_cycles<20000) begin
                        @(posedge dsp_clk); wait_cycles++;
                    end
                    if(fir_frame_count!=frames)
                        $fatal(1,"FIR input-frame boundary count %0d expected %0d",
                               fir_frame_count,frames);
                end
                if(!core.pace_started || stream_fault || serial_fault)
                    $fatal(1,"stream failed to prime/conserve samples family=%0d shift=%0d",f,r);
                while(cascode_l!=0) @(negedge cell_clk);
                captures=0; run_length=0; cell_cycle=0; last_capture=-1;
                repeat(4096) begin
                    @(posedge cell_clk); #0.01;
                    cell_cycle++;
                    if(core.cell_capture_en) begin
                        if(last_capture>=0 && cell_cycle-last_capture!=8)
                            $fatal(1,"converter capture interval %0d cell clocks; expected 8",
                                   cell_cycle-last_capture);
                        last_capture=cell_cycle;
                        captures++;
                    end
                    if(cascode_l!=0) run_length++;
                    else if(run_length!=0) begin
                        if(run_length!=6) $fatal(1,"RTZ pulse %0d, expected 6",run_length);
                        run_length=0;
                    end
                    if(stream_fault || serial_fault || $isunknown(cascode_l))
                        $fatal(1,"FIFO/serial/X fault in rate matrix");
                end
                if(captures<510 || captures>514) $fatal(1,"wrong converter cadence %0d",captures);
                cases++;
            end
        end
        $display("TB_PASS: %0d native-rate I2S/FIR/HB/pacer/RTZ pipeline configurations",cases);
        $finish;
    end
    initial begin #10000000; $fatal(1,"watchdog"); end
endmodule
