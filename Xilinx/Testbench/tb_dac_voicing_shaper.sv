`timescale 1ns / 1ps
// tb_dac_voicing_shaper: verification for the Layer-2 voicing shaper.
//   P0: impulse probe  -> direct latency readout (expect 2-stroke: n_in-3)
//   P1: bypass         -> voicing_en=0 with k2/k3 NONZERO (true 0-LSB mux test)
//   P2: voiced 0 dBFS  -> coherent sine (bin 53/4096), 3-bin DFT of H1/H2/H3,
//                         DC-injection mean after tracker convergence
//   P3: overdrive      -> +-4FS / +-1.7FS burst; output sign must never invert

module tb_dac_voicing_shaper;
    localparam real PI = 3.14159265358979323846;

    logic clk = 0, rst_n = 0, in_valid = 0;
    logic signed [47:0] din = 0;
    logic voicing_en = 0;
    logic signed [26:0] k2 = 0, k3 = 0;
    logic out_valid;
    logic signed [47:0] dout;

    dac_voicing_shaper #(.DC_SHIFT(8)) dut (   // tau=256 samp for sim (HW=2^16)
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .data_in(din),
        .voicing_en(voicing_en), .k2(k2), .k3(k3),
        .out_valid(out_valid), .data_out(dout)
    );

    always #5 clk = ~clk;

    int n_in = 0, n_out = 0, v_out = 0;
    logic signed [47:0] x_hist [0:15];
    real   phase = 0.0;
    int    errors = 0;
    longint diff_sum = 0, usq_sum = 0, ucu_sum = 0;
    int    voiced_seen = 0, cur_phase = 0;
    real   re1 = 0, im1 = 0, re2 = 0, im2 = 0, re3 = 0, im3 = 0;
    int    dft_n = 0;
    logic signed [47:0] od_exp [0:7];
    int    od_err = 0;

    // FS = 2^41; amp in [0,127] where 127 = 0 dBFS
    function automatic logic signed [47:0] sine48(input real ph, input real amp);
        longint v;
        v = longint'(amp * (1.0/127.0) * 2199023255552.0 * $sin(ph));
        return v[47:0];
    endfunction

    task automatic strobe(input logic signed [47:0] v);
        begin
            @(negedge clk);
            din = v;
            x_hist[n_in % 16] = v;
            in_valid = 1; phase += 2.0*PI*53.0/4096.0; n_in++;
            @(negedge clk); in_valid = 0;
            repeat (14) @(negedge clk);
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        rst_n <= 1;

        // ---- P0: impulse probe (voiced) --------------------------------
        voicing_en <= 1; k2 <= 27'sd67109; k3 <= -27'sd2684; cur_phase <= 0;
        repeat (20)
            strobe((n_in == 10) ? 48'sh0000_8000_0000 : 48'sd0);

        // ---- P1: bypass with nonzero k2/k3 (0-LSB mux test) --------------
        voicing_en <= 0; cur_phase <= 1; phase = 0.0;
        repeat (2000)
            strobe(sine48(phase, 63.5));        // -6 dBFS
        if (n_out < 1900) errors++;

        // ---- P2: voiced, coherent 0 dBFS sine, DFT + DC mean -------------
        voicing_en <= 1; cur_phase <= 2; phase = 0.0;
        repeat (8196)
            strobe(sine48(phase, 127.0));       // 0 dBFS, bin 53 coherent

        // ---- P3: overdrive burst (clamp sign-inversion guard) -------------
        cur_phase <= 3;
        od_exp[0] = 48'sh0008_0000_0000; od_exp[1] = -48'sh0008_0000_0000;
        od_exp[2] = 48'sh0003_6666_6666; od_exp[3] = -48'sh0003_6666_6666;
        od_exp[4] = 48'sh0008_0000_0000; od_exp[5] = -48'sh0008_0000_0000;
        od_exp[6] = 48'sd0; od_exp[7] = 48'sd0;
        for (int i = 0; i < 8; i++) strobe(od_exp[i]);

        // ---- report ----------------------------------------------------
        $display("[tb_voicing] errors=%0d dc_avg=%0d voiced=%0d od_err=%0d",
                 errors, diff_sum/4096, voiced_seen, od_err);
        $display("[tb_voicing] dc_est=%0d  E[usq_ac]=%0.1f  E[ucu_q]=%0.1f",
                 dut.dc_acc >>> 8,
                 real'(usq_sum)/4096.0, real'(ucu_sum)/4096.0);
        if (dft_n == 4096) begin
            real m1, m2, m3;
            m1 = $sqrt(re1*re1 + im1*im1);
            m2 = $sqrt(re2*re2 + im2*im2);
            m3 = $sqrt(re3*re3 + im3*im3);
            $display("[tb_voicing] H2=%0.1f dBc  H3=%0.1f dBc",
                     20.0*$log10(m2/m1), 20.0*$log10(m3/m1));
        end
        if (errors == 0 && voiced_seen > 100 && od_err == 0 &&
            (diff_sum/4096 > -262144 && diff_sum/4096 < 262144) &&
            dft_n == 4096)
            $display("[tb_voicing] PASS");
        else
            $display("[tb_voicing] FAIL");
        $finish;
    end

    // Scoreboard
    always @(posedge clk) if (rst_n && out_valid) begin
        n_out++;
        if (n_in <= 22)
            $display("[lat] n_in=%0d dout=%h", n_in, dout);
        if (cur_phase == 1) begin
            if (n_in >= 4 && dout !== x_hist[(n_in-3) % 16]) begin
                errors++;
                if (errors < 10)
                    $display("[tb_voicing] bypass mismatch @%0d: got %h exp %h",
                             n_out, dout, x_hist[(n_in-3) % 16]);
            end
        end else if (cur_phase == 2) begin
            v_out++;
            if (dout !== x_hist[(n_in-3) % 16]) voiced_seen++;
            // coherent window: v_out in [4100,8196) -> exactly 4096 outputs,
            // integer H1/H2/H3 cycles -> boxcar mean sits on spectral nulls.
            // (diff_sum over a non-coherent window telescopes to
            //  2*k2*(dc_acc_end-dc_acc_start) = dc_acc 2w ripple leakage)
            if (v_out >= 4100 && v_out < 8196) begin
                real th;
                diff_sum += dout - x_hist[(n_in-3) % 16];
                usq_sum  += dut.usq_ac;
                ucu_sum  += dut.ucu_q;
                th = 2.0*PI*53.0*dft_n/4096.0;
                re1 += dout * $cos(th);       im1 += dout * $sin(th);
                re2 += dout * $cos(2.0*th);   im2 += dout * $sin(2.0*th);
                re3 += dout * $cos(3.0*th);   im3 += dout * $sin(3.0*th);
                dft_n++;
            end
        end else if (cur_phase == 3) begin
            // output sign must equal its delayed input's sign
            if (n_in >= 4 && x_hist[(n_in-3)%16] !== 0 &&
                dout[47] !== x_hist[(n_in-3)%16][47]) begin
                od_err++;
                $display("[tb_voicing] OD sign inversion: din=%h dout=%h",
                         x_hist[(n_in-3)%16], dout);
            end
        end
    end

endmodule
