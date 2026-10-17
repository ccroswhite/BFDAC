`timescale 1ns / 1ps

// =============================================================================
//  TB_E2E_SINE — Round 30 end-to-end spectral verification (#29 RTL leg)
//
//  Coherent sine -> full dac_dsp_core chain (FIR boxcar -> HB1/2/3 -> volume
//  -> pacer -> NS -> dem_sort) -> capture the DEM selection words -> python
//  FFT (e2e_sine_fft.py) measures in-band SNDR of the popcount sequence.
//
//  Stimulus: 512 input samples, k=11 cycles -> f = 11 * 48k/512 = 1031.25 Hz,
//  coherent in the 65536-update output FFT (bin 11). Amplitude -1 dBFS;
//  uniform FIR coefs 0x1800 (recalibrated 2026-08-01: the corrected FIR sums
//  2*c*256 per phase vs the old collapsed 2*c*64, so the R30 value 0x6000 is
//  rescaled /4 to keep the same DC gain / NS headroom. NOTE: the now-real
//  256-deep boxcar attenuates bin 11 by ~25 dB (first null 187.5 Hz), so the
//  measured SNDR ceiling drops accordingly — designed coefficients are the
//  planned upgrade for a full-quality gate.)
//  (original R30 note: with the Round 30 ns_feed scaling this drives
//  the NS to ~+-21 of +-32 levels; boxcar is LTI so spectrum purity holds).
//
//  Output files (all captured from reset, N_SKIP=0, for state-aligned python
//  replay): e2e_dem_l.txt (hex DEM words), e2e_paced_l.txt (NS inputs),
//  e2e_dither_l.txt (dither). Analysis: e2e_final_fft.py (Kaiser beta=38 —
//  rectangular windows leak out-of-band shaped noise; see progress.md R30).
// =============================================================================
module tb_e2e_sine;

    localparam int NUM_MACS   = 4;
    localparam real CLK_PERIOD = 2.8;
    localparam real CELL_CLK_PERIOD = CLK_PERIOD * 40.0 / 7.0;
    localparam int N_IN      = 512;    // input samples captured (x128 updates)
    localparam int N_WARM    = 300;    // warmup: must exceed K=256 FIR history depth
    localparam int N_SKIP    = N_WARM * 128;  // skip warmup: the corrected FIR's
                                       // 256-sample fill ramp is no longer inside
                                       // the Kaiser edge taper (2026-08-01); any
                                       // contiguous 512-sample window of the
                                       // periodic-512 sine stays bin-11 coherent
    localparam int N_CAP     = 65536;  // DEM updates captured
    localparam int K_CYC     = 11;     // sine cycles over N_IN inputs
    localparam real PI       = 3.14159265358979;

    logic dsp_clk = 0, cell_clk = 0, sys_rst_n = 0;
    logic [23:0] audio_l = 0, audio_r = 0;
    logic new_sample = 0;
    logic coef_we = 0;
    logic [9:0] coef_waddr = 0;
    logic signed [17:0] coef_wdata = 0;
    logic [1:0] coef_wmac = 0;
    logic [31:0] sys_volume = 32'hFFFFFFFF;
    logic [15:0] boot_envelope_gain = 16'hFFFF;
    wire sample_768k_tick;
    wire [63:0] cascode_l, cascode_r;

    always #(CLK_PERIOD/2)      dsp_clk  = ~dsp_clk;
    always #(CELL_CLK_PERIOD/2) cell_clk = ~cell_clk;

    dac_dsp_core #(.NUM_MACS(NUM_MACS)) u_dut (
        .dsp_clk(dsp_clk), .cell_clk(cell_clk), .sys_rst_n(sys_rst_n),
        .audio_l(audio_l), .audio_r(audio_r), .new_sample(new_sample),
        .force_zero(1'b0),
        .coef_we(coef_we), .coef_waddr(coef_waddr), .coef_wdata(coef_wdata),
        .coef_wmac(coef_wmac), .bank_select(1'b0), .bank_load_target(1'b0),
        .sys_volume(sys_volume), .boot_envelope_gain(boot_envelope_gain),
        .dpd_enable(1'b0), .dpd_cal_addr(), .dpd_cal_data('0),
        .sample_768k_tick(sample_768k_tick),
        .cascode_l(cascode_l), .cascode_r(cascode_r)
    );

    // ---------------- DEM word capture ----------------
    int fd, fd2, fd3, n_seen = 0, n_written = 0, n_seen2 = 0, n_written2 = 0;
    int fd4, fd5, n_fir = 0, n_hb3 = 0;
    initial begin
        fd  = $fopen("e2e_dem_l.txt", "w");
        fd2 = $fopen("e2e_paced_l.txt", "w");
        fd3 = $fopen("e2e_dither_l.txt", "w");
        fd4 = $fopen("e2e_fir_l.txt", "w");     // debug tap: FIR output
        fd5 = $fopen("e2e_hb3_l.txt", "w");     // debug tap: HB3 output
    end

    always @(posedge dsp_clk) begin
        if (u_dut.dem_valid_l) begin
            n_seen++;
            if (n_seen > N_SKIP && n_written < N_CAP) begin
                $fwrite(fd, "%016x\n", u_dut.dem_out_l);
                n_written++;
            end
        end
        if (u_dut.pace_valid) begin
            n_seen2++;
            if (n_seen2 > N_SKIP && n_written2 < N_CAP) begin
                $fwrite(fd2, "%012x\n", u_dut.paced_l);
                $fwrite(fd3, "%011x\n", u_dut.dither_l);
                n_written2++;
            end
        end
        if (u_dut.interp_l_valid && n_fir < N_CAP/8) begin
            $fwrite(fd4, "%012x\n", u_dut.interp_l[47:0]);
            n_fir++;
        end
        if (u_dut.hb3_l_valid && n_hb3 < N_CAP) begin
            $fwrite(fd5, "%012x\n", u_dut.hb3_l);
            n_hb3++;
        end
    end

    // ---------------- stimulus ----------------
    real ph;
    int  smp;

    task send_sample(input logic [23:0] v);
        @(negedge dsp_clk);
        audio_l = v; audio_r = v; new_sample = 1'b1;
        @(posedge dsp_clk);
        @(negedge dsp_clk); new_sample = 1'b0;
        repeat (7440) @(posedge dsp_clk);
    endtask

    function automatic logic [23:0] sine_val(input int n);
        real x;
        x = 0.891 * $sin(2.0 * PI * K_CYC * n / N_IN);   // -1 dBFS
        return 24'(int'(x * 8388607.0));
    endfunction

    initial begin
        sys_rst_n = 0;
        repeat (32) @(posedge dsp_clk);
        @(negedge dsp_clk); sys_rst_n = 1;
        repeat (8) @(posedge dsp_clk);

        // uniform coefs 0x1800 (boxcar, /4 rescale for corrected FIR; NS drive ~ +-21 levels DC-equiv)
        @(negedge dsp_clk); coef_we = 1;
        for (int m = 0; m < NUM_MACS; m++)
            for (int p = 0; p < 1024; p++) begin
                @(negedge dsp_clk);
                coef_wmac = 2'(m); coef_waddr = 10'(p); coef_wdata = 18'sh01800;
            end
        @(negedge dsp_clk); coef_we = 0;
        repeat (8) @(posedge dsp_clk);

        // warmup (sine keeps phase continuity: use negative indices mod N_IN)
        for (smp = -N_WARM; smp < 0; smp++)
            send_sample(sine_val((smp + N_IN) % N_IN));

        // capture run: keep streaming until N_CAP DEM words written
        smp = 0;
        while (n_written < N_CAP) begin
            send_sample(sine_val(smp % N_IN));
            smp++;
            if (smp > N_IN + 40) begin
                $display("ERROR: capture did not complete (written=%0d)", n_written);
                break;
            end
        end

        $fclose(fd);
        $fclose(fd2);
        $fclose(fd3);
        $display("e2e capture done: %0d DEM words, %0d paced words (%0d input samples)",
                 n_written, n_written2, smp);
        $finish;
    end

endmodule
