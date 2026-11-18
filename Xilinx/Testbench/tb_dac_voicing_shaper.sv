`timescale 1ns / 1ps
// tb_dac_voicing_shaper: smoke checks for the Layer-2 voicing shaper.
//   1) voicing_en=0 -> output == input delayed 5 samples, 0-LSB exact
//   2) voicing_en=1, k2>0 -> output deviates from input; long-run mean of
//      (out-in) stays ~0 (DC tracker strips the k2*A^2/2 shift)
//   3) out_valid strobes once per in_valid, 5-sample latency

module tb_dac_voicing_shaper;
    localparam int FS = 41;

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

    always #5 clk = ~clk;                       // 100 MHz dsp_clk stand-in

    // Sample strobe: 1 clk every 16 clocks (~2x denser than real HW spacing)
    int s_count = 0;
    logic signed [47:0] x_hist [0:15];
    real   phase = 0.0;
    int    n_in = 0, n_out = 0;
    int    errors = 0;
    longint diff_sum = 0;
    int    voiced_seen = 0;

    function automatic logic signed [47:0] sine48(input real ph, input real amp);
        longint v;   // 64-bit: $rtoi would saturate at +-2^31
        v = longint'(amp * (1.0/127.0) * 2199023255552.0 * $sin(ph)); // FS=2^41
        return v[47:0];
    endfunction

    initial begin
        repeat (20) @(posedge clk);
        rst_n <= 1;

        // ---- Phase 1: bypass bit-exactness (2000 samples, -6 dBFS sine) ----
        voicing_en <= 0; k2 <= 0; k3 <= 0;
        repeat (2000) begin
            @(negedge clk);
            din = sine48(phase, 12.7);          // ~-6 dBFS
            x_hist[n_in % 16] = din;
            in_valid = 1; phase += 0.05; n_in++;
            @(negedge clk); in_valid = 0;
            repeat (14) @(negedge clk);
        end
        if (n_out < 1900) errors++;   // lost output strobes

        // ---- Phase 2: k2-only voicing (Nagra-ish), DC check ---------------
        voicing_en <= 1;
        k2 <= 27'sd67109;                        // +2.0e-3 -> H2 ~ -60 dBc
        phase = 0.0; diff_sum = 0; n_out = 0;
        repeat (8000) begin
            @(negedge clk);
            din = sine48(phase, 12.7);
            x_hist[n_in % 16] = din;
            in_valid = 1; phase += 0.05; n_in++;
            @(negedge clk); in_valid = 0;
            repeat (14) @(negedge clk);
        end

        $display("[tb_voicing] errors=%0d  dc_inject_avg=%0d  voiced_samples=%0d",
                 errors, (n_out>2000) ? diff_sum/(n_out-2000) : 0, voiced_seen);
        if (errors == 0 && voiced_seen > 100 &&
            ((n_out>2000) ? (diff_sum/(n_out-2000) > -2097152 && diff_sum/(n_out-2000) < 2097152) : 0))
            $display("[tb_voicing] PASS");
        else
            $display("[tb_voicing] FAIL");
        $finish;
    end

    // Scoreboard: check out_valid data on each strobe
    always @(posedge clk) if (rst_n && out_valid) begin
        n_out++;
        if (!voicing_en) begin
            // bypass: dout must equal the input from 5 strobes ago
            if (n_in >= 6 && dout !== x_hist[(n_in-6) % 16]) begin
                errors++;
                if (errors < 10)
                    $display("[tb_voicing] bypass mismatch @out %0d: got %h exp %h",
                             n_out, dout, x_hist[(n_in-6) % 16]);
            end
        end else begin
            if (dout !== x_hist[(n_in-6) % 16]) voiced_seen++;
            // DC mean only after tracker convergence (~5*tau = 1280 samples)
            if (n_out > 2000)
                diff_sum += dout - x_hist[(n_in-6) % 16];
            if (n_out < 20 || (n_out < 8100 && n_out % 500 == 0))
                $display("[dbg] out%0d dout=%h xexp=%h diff=%0d usq=%h dcacc=%h harm=%h",
                         n_out, dout, x_hist[(n_in-6)%16],
                         dout - x_hist[(n_in-6)%16],
                         dut.usq_full[52:35], dut.dc_acc[25:8], dut.harm_sum);
        end
    end

endmodule
