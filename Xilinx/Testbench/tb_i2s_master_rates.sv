`timescale 1ns / 1ps
module tb_i2s_master_rates;
    logic dsp_clk=0, cell_clk=0, rst_n=0, enable=0, source_valid=0, i2s_data=0;
    logic [1:0] rate_shift=0;
    logic [4:0] rx_trim=0;
    wire i2s_bclk, i2s_lrclk, new_sample, i2s_err, transport_fault;
    wire [23:0] audio_l, audio_r;
    real cell_period=20.345052083, dsp_period=3.560384115;
    real return_delay=0;
    int tx_bit=63, received=0, cases=0;
    localparam logic [31:0] LEFT=32'h81234567, RIGHT=32'h5abcde98;
    always #(cell_period/2) cell_clk=~cell_clk;
    always #(dsp_period/2) dsp_clk=~dsp_clk;
    i2s_master_ingress dut (.*);
    always @(negedge rst_n) tx_bit=63;
    always @(negedge i2s_bclk) begin
        if(rst_n && enable) begin
            #0.001;
            if(tx_bit==31 && i2s_lrclk!==1) $fatal(1,"I2S WS right alignment");
            if(tx_bit==63 && i2s_lrclk!==0) $fatal(1,"I2S WS left alignment");
            i2s_data <= #(return_delay) (tx_bit<32 ? LEFT[31-tx_bit] : RIGHT[63-tx_bit]);
            tx_bit=(tx_bit+1)%64;
        end
    end
    task cycles(input int n); repeat(n) @(negedge dsp_clk); endtask
    initial begin
        for(int family=0;family<2;family++) begin
            cell_period=family ? 20.345052083 : 22.144274376;
            dsp_period=cell_period*3.5/20.0;
            for(int shift=0;shift<4;shift++) begin
                for(int d=0;d<3;d++) begin
                    real first_frame, last_frame, measured_period, expected_period;
                    rst_n=0; enable=0; source_valid=0; cycles(10);
                    rate_shift=2'(shift);
                    return_delay=d*20.0;
                    rx_trim=d==0 ? 0 : d==1 ? 4 : 10;
                    tx_bit=63; rst_n=1; cycles(20); enable=1; source_valid=1;
                    received=0; first_frame=0; last_frame=0;
                    while(received<12) begin
                        @(posedge dsp_clk); #0.01;
                        if(new_sample) begin
                            if(audio_l!==LEFT[31:8] || audio_r!==RIGHT[31:8] || i2s_err)
                                $fatal(1,"serial mismatch family=%0d shift=%0d delay=%0d L=%h R=%h err=%b",
                                       family,shift,d,audio_l,audio_r,i2s_err);
                            if(received==0) first_frame=$realtime;
                            last_frame=$realtime;
                            received++;
                        end
                    end
                    measured_period=(last_frame-first_frame)/11.0;
                    expected_period=cell_period*(1024>>shift);
                    if(measured_period<expected_period-dsp_period || measured_period>expected_period+dsp_period)
                        $fatal(1,"wrong frame rate %f expected %f",measured_period,expected_period);
                    source_valid=0; cycles(5);
                    if(!i2s_err || transport_fault) $fatal(1,"source-valid contract");
                    cases++;
                end
            end
        end
        $display("TB_PASS: I2S master %0d family/rate/return-delay cases",cases);
        $finish;
    end
    initial begin #20000000; $fatal(1,"watchdog"); end
endmodule
