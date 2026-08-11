`timescale 1ns / 1ps

// =============================================================================
//  TB_RATE_PROBE — Round 30 diagnostic: measure the interpolation-chain
//  update cadence inside dac_dsp_core.
//
//  Questions answered (hierarchical monitors, no DUT changes):
//    A. valids per input sample at each stage: interp (expect 16),
//       hb1 (expect 32), hb2 (expect 64), hb3/volumed (expect 128)
//    B. minimum spacing (dsp_clk) between dem_enable pulses — dem_sort
//       needs >= 36 cycles sustained
//    C. dem_sort dropped-enable count (enable while FSM busy)
// =============================================================================
module tb_rate_probe;

    localparam int NUM_MACS   = 4;
    localparam real CLK_PERIOD = 2.8;
    localparam real CELL_CLK_PERIOD = CLK_PERIOD * 40.0 / 7.0;

    logic dsp_clk = 0, cell_clk = 0, sys_rst_n = 0;
    logic [23:0] audio_l = 0, audio_r = 0;
    logic new_sample = 0;
    logic coef_we = 0;
    logic [9:0] coef_waddr = 0;
    logic signed [17:0] coef_wdata = 0;
    logic [1:0] coef_wmac = 0;
    logic bank_select = 0, bank_load_target = 0;
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
        .coef_wmac(coef_wmac), .bank_select(bank_select),
        .bank_load_target(bank_load_target), .sys_volume(sys_volume),
        .boot_envelope_gain(boot_envelope_gain),
        .sample_768k_tick(sample_768k_tick),
        .cascode_l(cascode_l), .cascode_r(cascode_r)
    );

    // ---------------- monitors ----------------
    int n_interp = 0, n_hb1 = 0, n_hb2 = 0, n_hb3 = 0, n_vol = 0, n_dem = 0;
    int dem_gap = 0, dem_gap_min = 1_000_000, n_dem_dropped = 0, n_dem_valid = 0;
    longint pk_interp = 0, pk_hb1 = 0, pk_hb2 = 0, pk_hb3 = 0, pk_vol = 0, pk_paced = 0;

    function automatic longint absv(input longint v);
        return (v < 0) ? -v : v;
    endfunction

    always @(posedge dsp_clk) begin
        if (u_dut.interp_l_valid) begin n_interp++; if (absv(u_dut.interp_l)  > pk_interp) pk_interp = absv(u_dut.interp_l); end
        if (u_dut.hb1_l_valid)    begin n_hb1++;    if (absv(u_dut.hb1_l)     > pk_hb1)    pk_hb1    = absv(u_dut.hb1_l); end
        if (u_dut.hb2_l_valid)    begin n_hb2++;    if (absv(u_dut.hb2_l)     > pk_hb2)    pk_hb2    = absv(u_dut.hb2_l); end
        if (u_dut.hb3_l_valid)    begin n_hb3++;    if (absv(u_dut.hb3_l)     > pk_hb3)    pk_hb3    = absv(u_dut.hb3_l); end
        if (u_dut.volumed_valid)  begin n_vol++;    if (absv(u_dut.volumed_l) > pk_vol)    pk_vol    = absv(u_dut.volumed_l); end
        if (u_dut.pace_valid)     begin             if (absv(u_dut.paced_l)   > pk_paced)  pk_paced  = absv(u_dut.paced_l); end
        dem_gap++;
        if (u_dut.dem_enable) begin
            n_dem++;
            if (n_dem > 1 && dem_gap < dem_gap_min) dem_gap_min = dem_gap;
            dem_gap = 0;
            if (u_dut.u_dem_l.state != 0) n_dem_dropped++;   // enable while busy
        end
        if (u_dut.dem_valid_l) n_dem_valid++;
    end

    task send_sample(input logic [23:0] v);
        @(negedge dsp_clk);
        audio_l = v; audio_r = v; new_sample = 1'b1;
        @(posedge dsp_clk);
        @(negedge dsp_clk); new_sample = 1'b0;
        // hardware-realistic spacing: 48 kHz at 357 MHz = 7440 dsp_clk
        repeat (7440) @(posedge dsp_clk);
    endtask

    initial begin
        sys_rst_n = 0;
        repeat (32) @(posedge dsp_clk);
        @(negedge dsp_clk); sys_rst_n = 1;
        repeat (8) @(posedge dsp_clk);

        // uniform coefs
        @(negedge dsp_clk); bank_load_target = 0; coef_we = 1;
        for (int m = 0; m < NUM_MACS; m++)
            for (int p = 0; p < 1024; p++) begin
                @(negedge dsp_clk);
                coef_wmac = 2'(m); coef_waddr = 10'(p); coef_wdata = 18'sh00400;
            end
        @(negedge dsp_clk); coef_we = 0;
        repeat (8) @(posedge dsp_clk);

        // warm up 8 samples (not counted)
        repeat (8) send_sample(24'sh100000);
        n_interp = 0; n_hb1 = 0; n_hb2 = 0; n_hb3 = 0; n_vol = 0;
        n_dem = 0; n_dem_valid = 0; n_dem_dropped = 0; dem_gap_min = 1_000_000;

        // measure over 16 samples at hardware-realistic cadence
        repeat (16) send_sample(24'sh100000);

        $display("per 16 input samples:");
        $display("  interp valids : %0d  (expect 256 = 16/sample)", n_interp);
        $display("  hb1 valids    : %0d  (expect 512 = 32/sample)", n_hb1);
        $display("  hb2 valids    : %0d  (expect 1024 = 64/sample)", n_hb2);
        $display("  hb3 valids    : %0d  (expect 2048 = 128/sample)", n_hb3);
        $display("  volumed valids: %0d", n_vol);
        $display("  dem enables   : %0d,  dem valid_outs: %0d,  DROPPED: %0d",
                 n_dem, n_dem_valid, n_dem_dropped);
        $display("  min dem_enable spacing: %0d dsp_clk (dem_sort needs >= 36)", dem_gap_min);
        $display("peak |levels| (log2): audio_in=%.1f interp=%.1f hb1=%.1f hb2=%.1f hb3=%.1f volumed=%.1f paced=%.1f",
                 $log10(real'(24'sh100000)) / $log10(2.0),
                 $log10(real'(pk_interp) + 1) / $log10(2.0),
                 $log10(real'(pk_hb1) + 1) / $log10(2.0),
                 $log10(real'(pk_hb2) + 1) / $log10(2.0),
                 $log10(real'(pk_hb3) + 1) / $log10(2.0),
                 $log10(real'(pk_vol) + 1) / $log10(2.0),
                 $log10(real'(pk_paced) + 1) / $log10(2.0));
        $finish;
    end

endmodule
