`timescale 1ns / 1ps

// =============================================================================
//  TB_NS_EF3 — Self-checking testbench for noise_shaper_ef3 (Round 30)
//
//  Tests:
//    1. RESET STATE  : dem_drive_out = 32 (midscale) after reset
//    2. GOLDEN MATCH : 3000 vectors (1500 sine + 1500 random) bit-exact vs
//                      the integer reference ns_ef3_gen.py
//                      (ns_ef3_golden.mem: [99:52]=u, [51:8]=dither, [7:0]=y)
//    3. OVERLOAD RECOVERY : slam +40-level DC for 200 samples (clamps), then
//                      return to 0 — output must re-settle around 32
// =============================================================================
module tb_ns_ef3;

    localparam int N_GOLDEN = 3000;
    localparam real CLK_PERIOD = 2.8;

    logic clk = 0, rst_n = 0, enable = 0;
    logic signed [47:0] data_in = '0;
    logic signed [41:0] dither_in = '0;
    logic [6:0] dem_drive_out;

    always #(CLK_PERIOD/2) clk = ~clk;

    noise_shaper_ef3 #(
        .INPUT_WIDTH(48), .FRAC_WIDTH(42), .OUT_WIDTH(7)
    ) u_dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .data_in(data_in), .dither_in(dither_in),
        .dem_drive_out(dem_drive_out),
        .y_valid(), .corr_valid(1'b0), .corr(56'sd0)   // DPD off: legacy exact
    );

    logic [99:0] golden [0:N_GOLDEN-1];
    initial $readmemh("ns_ef3_golden.mem", golden);

    int error_count = 0;
    int mean_acc;

    // one sample: drive inputs, pulse enable, wait for the 4-stage pipeline
    task automatic do_sample(input logic signed [47:0] u,
                             input logic signed [41:0] d);
        @(negedge clk);
        data_in = u; dither_in = d; enable = 1'b1;
        @(negedge clk);
        enable = 1'b0;
        repeat (6) @(negedge clk);   // 4 pipeline stages + margin
    endtask

    initial begin
        rst_n = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);

        // ---------------- Test 1 ----------------
        if (dem_drive_out !== 7'd32) begin
            $display("ERROR T1: reset output %0d != 32", dem_drive_out);
            error_count++;
        end
        $display("T1 reset state: %s", (error_count == 0) ? "PASS" : "FAIL");

        // ---------------- Test 2: golden ----------------
        begin
            int errs = 0;
            for (int s = 0; s < N_GOLDEN; s++) begin
                do_sample($signed(golden[s][99:52]), $signed(golden[s][49:8]));
                if (dem_drive_out !== golden[s][6:0]) begin
                    if (errs < 5)
                        $display("ERROR T2: sample %0d got %0d exp %0d",
                                 s, dem_drive_out, golden[s][6:0]);
                    errs++;
                end
            end
            error_count += errs;
            $display("T2 golden match (%0d samples): %s (%0d mismatches)",
                     N_GOLDEN, (errs == 0) ? "PASS" : "FAIL", errs);
        end

        // ---------------- Test 3: overload recovery ----------------
        repeat (200) do_sample(48'sd40 <<< 42, 42'sd0);
        repeat (200) do_sample(48'sd0, 42'sd0);
        mean_acc = 0;
        repeat (64) begin
            do_sample(48'sd0, 42'sd0);
            mean_acc += int'(dem_drive_out);
        end
        if (mean_acc / 64 < 30 || mean_acc / 64 > 34) begin
            $display("ERROR T3: post-overload mean %0d not ~32", mean_acc / 64);
            error_count++;
        end else
            $display("T3 overload recovery: PASS (mean %0d)", mean_acc / 64);

        if (error_count == 0)
            $display("ALL TESTS PASS (tb_ns_ef3)");
        else
            $display("TESTS FAILED: %0d errors (tb_ns_ef3)", error_count);
        $finish;
    end

endmodule
