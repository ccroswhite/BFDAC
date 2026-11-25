// tb_noise_waterfall — D1 RTL bit-exact noise waterfall (NOISE_BUDGET.md §5)
//
// Drives a -60 dBFS 1 kHz coherent sine (or digital silence with +SILENCE)
// through dac_dsp_core and captures all six waterfall probes simultaneously:
//   P1 nw_interp.txt  interp_l      @768 kHz (2^41 = 1.0 FS)
//   P2 nw_vox.txt     vox_l         @768 kHz (2^41)
//   P3 nw_hb3.txt     hb3_l         @6.144 MHz (2^47)
//   P4 nw_paced.txt   paced_l       @6.144 MHz (28 x 2^42)
//   P5 nw_demcmd.txt  dem_cmd_l     @6.144 MHz (cell count, FS = 28)
//   P6 nw_pop.txt     frame popcount(cascode_l) @cell_clk/8 (== countones(dem_out))
//        nw_demout.txt dem_out_l    @6.144 MHz (thermometer word, P6 correlation)
//
// Analysis: utils/noise_waterfall.py — per-node integrated 20 Hz-20 kHz noise
// re each node's own fundamental + P5<->P6 frame-correlation check.
//
// Same fast config as tb_e2e_sine (NUM_MACS=4, SPLIT_MACS=0, boxcar coefs).

module tb_noise_waterfall;

    localparam int NUM_MACS   = 4;
    localparam real CLK_PERIOD = 2.8;
    localparam real CELL_CLK_PERIOD = CLK_PERIOD * 40.0 / 7.0;
    localparam int N_IN      = 512;    // one sine period, input-domain
    localparam int N_WARM    = 300;
    localparam int N_SKIP    = N_WARM * 128;
    localparam int N_CAP_DEF = 131072; // pace/DEM words = 21.3 ms @6.144 MHz
    int N_CAP;                         // +SHORT plusarg -> 8192 (smoke runs)
    localparam int K_CYC     = 11;     // sine cycles over N_IN inputs
    localparam real PI       = 3.14159265358979;
    localparam real DRIVE    = 1.0e-3; // -60 dBFS (EIAJ DNR tone); 0 = silence

    logic dsp_clk = 0, cell_clk = 0, sys_rst_n = 0;
    logic [23:0] audio_l = 0, audio_r = 0;
    logic new_sample = 0;
    logic coef_we = 0;
    logic [11:0] coef_waddr = 0;
    logic signed [17:0] coef_wdata = 0;
    logic [2:0] coef_wmac = 0;
    logic [31:0] sys_volume = 32'h001C0000;  // 28.0 NS code units = 6 Vrms FS
    logic [15:0] boot_envelope_gain = 16'hFFFF;
    wire sample_768k_tick;
    wire [63:0] cascode_l, cascode_r;

    always #(CLK_PERIOD/2)      dsp_clk  = ~dsp_clk;
    always #(CELL_CLK_PERIOD/2) cell_clk = ~cell_clk;

    dac_dsp_core #(.NUM_MACS(NUM_MACS), .SPLIT_MACS(0)) u_dut (
        .dsp_clk(dsp_clk), .cell_clk(cell_clk), .sys_rst_n(sys_rst_n), .fir_rst_n(sys_rst_n),
        .audio_l(audio_l), .audio_r(audio_r), .new_sample(new_sample),
        .force_zero(1'b0),
        .coef_we(coef_we), .coef_waddr(coef_waddr), .coef_wdata(coef_wdata),
        .coef_wmac(coef_wmac), .bank_select(1'b0), .bank_load_target(1'b0),
        .sys_volume(sys_volume), .boot_envelope_gain(boot_envelope_gain),
        .voicing_en(1'b0), .voicing_k2('0), .voicing_k3('0),
        .cell_test_cfg('0), .cell_test_req(2'd0), .cell_test_safe(1'b0),
        .cell_test_dc_hold(1'b0),
        .bench_cmd(11'd0),
        .dpd_enable(1'b0), .dpd_cal_addr(), .dpd_cal_data('0),
        .sample_768k_tick(sample_768k_tick),
        .cascode_l(cascode_l), .cascode_r(cascode_r)
    );

    // ---------------- probe captures (dsp_clk domain) ----------------
    int f_i, f_v, f_h, f_p, f_c, f_o, f_d, f_e;
    int n_pace = 0, n_dem = 0, n_interp = 0, n_vox = 0, n_hb3 = 0, n_ef3 = 0;
    initial begin
        f_i = $fopen("nw_interp.txt", "w");
        f_v = $fopen("nw_vox.txt", "w");
        f_h = $fopen("nw_hb3.txt", "w");
        f_p = $fopen("nw_paced.txt", "w");
        f_c = $fopen("nw_demcmd.txt", "w");
        f_o = $fopen("nw_demout.txt", "w");
        f_d = $fopen("nw_dither.txt", "w");
        f_e = $fopen("nw_ef3in.txt", "w");
    end

    always @(posedge dsp_clk) begin
        if (u_dut.interp_l_valid && n_pace > N_SKIP/8 && n_interp < N_CAP/8) begin
            $fwrite(f_i, "%012x\n", u_dut.interp_l[47:0]); n_interp++;
        end
        if (u_dut.vox_l_valid && n_pace > N_SKIP/8 && n_vox < N_CAP/8) begin
            $fwrite(f_v, "%012x\n", u_dut.vox_l[47:0]); n_vox++;
        end
        if (u_dut.hb3_l_valid && n_pace > N_SKIP && n_hb3 < N_CAP) begin
            $fwrite(f_h, "%012x\n", u_dut.hb3_l[47:0]); n_hb3++;
        end
        if (u_dut.pace_valid) begin
            n_pace++;
            if (n_pace > N_SKIP && n_pace <= N_SKIP + N_CAP) begin
                $fwrite(f_p, "%012x\n", u_dut.paced_l);
                $fwrite(f_d, "%011x\n", u_dut.dither_l);
            end
        end
        if (u_dut.dem_valid_l && n_pace > N_SKIP && n_dem < N_CAP) begin
            $fwrite(f_c, "%02x\n", u_dut.dem_cmd_l);
            $fwrite(f_o, "%016x\n", u_dut.dem_out_l);
            n_dem++;
        end
        // EF3 stage-A registers: the EXACT inputs the shaper consumed
        // (u_off_r - 32*2^42 = data_in; dith_a = dither at latch edge)
        if (u_dut.u_ns_l.en_pipe[0] && n_pace > N_SKIP && n_ef3 < N_CAP) begin
            $fwrite(f_e, "%014x%011x\n", u_dut.u_ns_l.u_off_r[55:0],
                    u_dut.u_ns_l.dith_a[42:0]);
            n_ef3++;
        end
    end

    // ---------------- P6: per-frame cascode popcount (cell_clk) ------------
    // Sum countones(cascode_l) over a whole pace_div frame. cascode_iob is
    // registered, so the driven window appears one div late (observed div
    // 2..7); counting ALL 8 divs is alignment-proof since off-cycles add 0.
    // Written on the div==0 boundary; divide by 6 to get cells-on.
    int f_pop, frame_pops = 0;
    initial f_pop = $fopen("nw_pop.txt", "w");

    always @(posedge cell_clk) begin
        if (n_pace > N_SKIP) begin
            frame_pops <= frame_pops + $countones(cascode_l);
            if (u_dut.pace_div == 3'd0) begin
                $fwrite(f_pop, "%0d\n", frame_pops + $countones(cascode_l));
                frame_pops <= 0;
            end
        end
    end

    // ---------------- stimulus ----------------
    int smp;

    task send_sample(input logic [23:0] v);
        @(negedge dsp_clk);
        audio_l = v; audio_r = v; new_sample = 1'b1;
        @(posedge dsp_clk);
        @(negedge dsp_clk); new_sample = 1'b0;
        repeat (7440) @(posedge dsp_clk);
    endtask

    function automatic logic [23:0] sine_val(input int n);
        real x;
        if ($test$plusargs("SILENCE"))
            x = 0.0;
        else
            x = DRIVE * $sin(2.0 * PI * K_CYC * n / N_IN);
        return 24'(int'(x * 8388607.0));
    endfunction

    initial begin
        N_CAP = $test$plusargs("SHORT") ? 8192 : N_CAP_DEF; // +SHORT: smoke runs
        sys_rst_n = 0;
        repeat (32) @(posedge dsp_clk);
        @(negedge dsp_clk); sys_rst_n = 1;
        repeat (8) @(posedge dsp_clk);

        // uniform coefs 0x1800 (boxcar) — same fast config as tb_e2e_sine
        @(negedge dsp_clk); coef_we = 1;
        for (int m = 0; m < NUM_MACS; m++)
            for (int p = 0; p < 4096; p++) begin
                @(negedge dsp_clk);
                coef_wmac = m; coef_waddr = p; coef_wdata = 18'sh01800;
            end
        @(negedge dsp_clk); coef_we = 0;
        repeat (8) @(posedge dsp_clk);

        for (smp = -N_WARM; smp < 0; smp++)
            send_sample(sine_val((smp + N_IN) % N_IN));

        smp = 0;
        while (n_pace < N_SKIP + N_CAP) begin
            send_sample(sine_val(smp % N_IN));
            smp++;
            if (smp > 3 * N_IN + 40) begin
                $display("ERROR: capture did not complete (pace=%0d)", n_pace);
                break;
            end
        end

        $fclose(f_i); $fclose(f_v); $fclose(f_h);
        $fclose(f_p); $fclose(f_c); $fclose(f_o); $fclose(f_pop); $fclose(f_d); $fclose(f_e);
        $display("waterfall capture done: pace=%0d dem=%0d interp=%0d vox=%0d hb3=%0d",
                 n_pace, n_dem, n_interp, n_vox, n_hb3);
        $finish;
    end

endmodule
