`timescale 1ns / 1ps

// =============================================================================
// tb_dpd_engine — bit-exact verification of the EF3-embedded DPD chain:
//   cal_coef_store (image loaded via the ctrl write port) +
//   noise_shaper_ef3 (Stage-E port) + dpd_engine, both channels.
// Golden: Testbench/dpd_golden.mem from utils/dpd_rtl_gen.py (exact RTL
// arithmetic, 2000 vectors x 2 channels, DPD on + off expectations).
//   T1: DPD ON  — L and R codes match golden y_on bit-for-bit
//   T2: DPD OFF — codes match golden y_off (legacy NS behavior preserved)
//   T3: correction must be available before the next Stage-A feedback read.
// EN_PERIOD is tested at the revised 49/50-cycle production cadence and at
// the older 56-cycle unit-test cadence.
// =============================================================================
module tb_dpd_engine #(
    parameter int EN_PERIOD = 56
);

    localparam int N = 2000;
    logic dsp_clk = 0, ctrl_clk = 0;
    always #1.656 dsp_clk = ~dsp_clk;    // approximately 302 MHz
    always #2.5   ctrl_clk = ~ctrl_clk;  // 200 MHz
    logic rst_n = 0;

    // --- cal store -----------------------------------------------------------
    logic        wr_toggle = 0, commit_toggle = 0;
    logic [8:0]  wr_addr = '0;
    logic [23:0] wr_data = '0;
    logic [23:0] rd_data;
    logic        active_bank, commit_pending;
    logic [3:0][8:0]  dpd_addr;
    logic [3:0][23:0] dpd_data;
    logic sample_tick = 0;

    cal_coef_store u_store (
        .dsp_clk(dsp_clk), .dsp_rst_n(rst_n), .sample_tick(sample_tick),
        .dpd_rd_addr(dpd_addr), .dpd_rd_data(dpd_data),
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(rst_n),
        .wr_toggle(wr_toggle), .wr_addr(wr_addr), .wr_data(wr_data),
        .commit_toggle(commit_toggle),
        .rd_addr(9'd0), .rd_data(rd_data),
        .active_bank(active_bank), .commit_pending(commit_pending)
    );

    // --- NS + engine, both channels -------------------------------------------
    logic enable = 0, dpd_enable = 0;
    logic signed [47:0] u_l = '0, u_r = '0;
    logic signed [41:0] d_l = '0, d_r = '0;
    logic [6:0] y_l, y_r;
    logic yv_l, yv_r, cv_l, cv_r;
    logic signed [55:0] corr_l, corr_r;
    logic [7:0] al_a, al_b, ar_a, ar_b;

    assign dpd_addr = {{1'b1, ar_b}, {1'b1, ar_a}, {1'b0, al_b}, {1'b0, al_a}};

    noise_shaper_ef3 #(.INPUT_WIDTH(48), .FRAC_WIDTH(42), .OUT_WIDTH(7)) u_ns_l (
        .clk(dsp_clk), .rst_n(rst_n), .enable(enable),
        .data_in(u_l), .dither_in(d_l), .dem_drive_out(y_l),
        .y_valid(yv_l), .corr_valid(cv_l), .corr(corr_l)
    );
    noise_shaper_ef3 #(.INPUT_WIDTH(48), .FRAC_WIDTH(42), .OUT_WIDTH(7)) u_ns_r (
        .clk(dsp_clk), .rst_n(rst_n), .enable(enable),
        .data_in(u_r), .dither_in(d_r), .dem_drive_out(y_r),
        .y_valid(yv_r), .corr_valid(cv_r), .corr(corr_r)
    );

    dpd_engine u_dpd_l (
        .clk(dsp_clk), .rst_n(rst_n), .dpd_enable(dpd_enable),
        .y_valid(yv_l), .y(y_l),
        .cal_addr_a(al_a), .cal_data_a(dpd_data[0]),
        .cal_addr_b(al_b), .cal_data_b(dpd_data[1]),
        .corr(corr_l), .corr_valid(cv_l)
    );
    dpd_engine u_dpd_r (
        .clk(dsp_clk), .rst_n(rst_n), .dpd_enable(dpd_enable),
        .y_valid(yv_r), .y(y_r),
        .cal_addr_a(ar_a), .cal_data_a(dpd_data[2]),
        .cal_addr_b(ar_b), .cal_data_b(dpd_data[3]),
        .corr(corr_r), .corr_valid(cv_r)
    );

    // --- images / vectors ------------------------------------------------------
    logic [23:0]  cal_img [0:511];
    logic [107:0] golden  [0:2*N-1];   // u[48] d[44] y_on[8] y_off[8]
    initial begin
        $readmemh("dpd_cal_img.mem", cal_img);
        $readmemh("dpd_golden.mem", golden);
    end

    // corr_valid latency check
    int lat_l, cyc_since_yv;
    always @(posedge dsp_clk) begin
        if (yv_l) cyc_since_yv <= 0;
        else      cyc_since_yv <= cyc_since_yv + 1;
        if (cv_l) lat_l = cyc_since_yv + 1;
    end

    int errors = 0;

    task automatic load_cal;
        // write both channel images into the shadow bank, then commit
        for (int a = 0; a < 512; a++) begin
            @(posedge ctrl_clk);
            wr_addr = 9'(a); wr_data = cal_img[a];
            @(posedge ctrl_clk);
            wr_toggle = ~wr_toggle;
            repeat (6) @(posedge ctrl_clk);   // CDC settle
        end
        @(posedge ctrl_clk); commit_toggle = ~commit_toggle;
        repeat (10) @(posedge dsp_clk);
        @(posedge dsp_clk); sample_tick = 1;
        @(posedge dsp_clk); sample_tick = 0;
        repeat (10) @(posedge dsp_clk);
    endtask

    task automatic run_seq(input bit on, input int golden_sel);
        // golden_sel: byte offset of expected code (0 = y_on, 1 = y_off)
        logic [7:0] exp_l, exp_r;
        // reset the NS/engines between runs (fresh state = golden assumption)
        rst_n = 0; repeat (5) @(posedge dsp_clk); rst_n = 1;
        repeat (5) @(posedge dsp_clk);
        if (on) load_cal();
        dpd_enable = on;
        repeat (5) @(posedge dsp_clk);
        for (int k = 0; k < N; k++) begin
            u_l = golden[2*k  ][107:60];
            d_l = golden[2*k  ][59:16];
            u_r = golden[2*k+1][107:60];
            d_r = golden[2*k+1][59:16];
            @(posedge dsp_clk); enable = 1;
            @(posedge dsp_clk); enable = 0;
            repeat (EN_PERIOD - 2) @(posedge dsp_clk);
            exp_l = golden_sel ? golden[2*k  ][7:0] : golden[2*k  ][15:8];
            exp_r = golden_sel ? golden[2*k+1][7:0] : golden[2*k+1][15:8];
            if (y_l !== exp_l[6:0] || y_r !== exp_r[6:0]) begin
                if (errors < 10)
                    $display("FAIL k=%0d on=%b: y_l=%0d exp %0d, y_r=%0d exp %0d",
                             k, on, y_l, exp_l[6:0], y_r, exp_r[6:0]);
                errors++;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge dsp_clk);
        rst_n = 1;

        // --- T1: DPD ON, bit-exact vs golden ------------------------------
        run_seq(1, 0);
        $display("T1 DPD ON  bit-exact (%0d vectors x 2ch): %s",
                 N, errors ? "FAIL" : "PASS");

        // --- T3 (measured during T1): correction latency -------------------
        if (lat_l == 0 || lat_l >= EN_PERIOD - 5) begin
            $display("FAIL T3: corr latency %0d cycles (budget %0d)",
                     lat_l, EN_PERIOD - 5);
            errors++;
        end else begin
            $display("T3 corr latency %0d cycles (strict Stage-A budget %0d): PASS",
                     lat_l, EN_PERIOD - 5);
        end

        // --- T2: DPD OFF, legacy NS behavior --------------------------------
        run_seq(0, 1);
        $display("T2 DPD OFF bit-exact (%0d vectors x 2ch): %s",
                 N, errors ? "FAIL" : "PASS");

        if (errors == 0) $display("ALL TESTS PASS (tb_dpd_engine)");
        else             $display("TESTS FAILED: %0d errors (tb_dpd_engine)", errors);
        $finish;
    end

endmodule
