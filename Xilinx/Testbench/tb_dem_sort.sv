`timescale 1ns / 1ps

// =============================================================================
//  TB_DEM_SORT — Self-checking testbench for dem_sort (Round 30)
//
//  Tests:
//    1. RESET STATE     : resistor_out = 0, valid_out = 0 during/after reset
//    2. GOLDEN MATCH    : 2000 samples of -1 dBFS modulator output vs the
//                         integer-exact python reference (dem_sort_gen.py,
//                         dem_sort_golden.mem: [71:64]=amplitude, [63:0]=sel)
//                         — bit-exact selection match required
//    3. BIT COUNT       : popcount(resistor_out) == amplitude for every sample
//    4. LATENCY BUDGET  : valid_out within 40 clk of enable (must fit the
//                         56-cycle sample period at 350 MHz)
//    5. EXTREMES        : amplitude=0 -> no bits; amplitude=64 -> all bits
//    6. BALANCE         : after N samples of amplitude=32, per-cell usage
//                         is uniform within +-2 (shaper equalization property)
// =============================================================================
module tb_dem_sort;

    localparam int ARRAY_SIZE  = 64;
    localparam int AMP_WIDTH   = 7;
    localparam real CLK_PERIOD = 2.8;   // ~357 MHz
    localparam int N_GOLDEN    = 2000;

    logic                  clk    = 0;
    logic                  rst_n  = 0;
    logic                  enable = 0;
    logic [AMP_WIDTH-1:0]  amplitude_in = '0;
    logic [ARRAY_SIZE-1:0] resistor_out;
    logic                  valid_out;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    dem_sort #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .AMP_WIDTH  (AMP_WIDTH)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .amplitude_in (amplitude_in),
        .resistor_out (resistor_out),
        .valid_out    (valid_out)
    );

    // -------------------------------------------------------------------------
    //  Golden vectors
    // -------------------------------------------------------------------------
    logic [71:0] golden [0:N_GOLDEN-1];
    initial $readmemh("dem_sort_golden.mem", golden);

    int error_count = 0;
    int lat;
    int usage [ARRAY_SIZE];
    int umin, umax;

    function automatic int popcount(input logic [ARRAY_SIZE-1:0] v);
        int cnt = 0;
        for (int i = 0; i < ARRAY_SIZE; i++)
            if (v[i]) cnt++;
        return cnt;
    endfunction

    // Drive one sample: pulse enable, wait for valid_out, return latency in clks
    task automatic do_sample(input logic [AMP_WIDTH-1:0] amp, output int latency);
        @(negedge clk);
        amplitude_in = amp;
        enable       = 1'b1;
        @(negedge clk);
        enable       = 1'b0;
        latency      = 1;
        while (!valid_out) begin
            @(negedge clk);
            latency++;
            if (latency > 100) begin
                $display("ERROR: valid_out timeout (amp=%0d)", amp);
                error_count++;
                return;
            end
        end
    endtask

    initial begin
        // ---------------- Test 1: reset state ----------------
        rst_n = 0;
        repeat (5) @(negedge clk);
        if (resistor_out !== '0 || valid_out !== 1'b0) begin
            $display("ERROR T1: outputs not zero in reset");
            error_count++;
        end
        rst_n = 1;
        repeat (3) @(negedge clk);
        $display("T1 reset state: %s", (error_count == 0) ? "PASS" : "FAIL");

        // ---------------- Test 2+3+4: golden match ----------------
        begin
            int t2_errs = 0, t3_errs = 0, max_lat = 0;
            for (int s = 0; s < N_GOLDEN; s++) begin
                do_sample(golden[s][71:64], lat);
                if (lat > max_lat) max_lat = lat;
                if (resistor_out !== golden[s][63:0]) begin
                    if (t2_errs < 5)
                        $display("ERROR T2: sample %0d amp=%0d got=%h exp=%h",
                                 s, golden[s][71:64], resistor_out, golden[s][63:0]);
                    t2_errs++;
                end
                if (popcount(resistor_out) != int'(golden[s][71:64])) begin
                    if (t3_errs < 5)
                        $display("ERROR T3: sample %0d popcount=%0d amp=%0d",
                                 s, popcount(resistor_out), golden[s][71:64]);
                    t3_errs++;
                end
            end
            error_count += t2_errs + t3_errs;
            $display("T2 golden match (%0d samples): %s (%0d mismatches)",
                     N_GOLDEN, (t2_errs == 0) ? "PASS" : "FAIL", t2_errs);
            $display("T3 bit count: %s (%0d errors)", (t3_errs == 0) ? "PASS" : "FAIL", t3_errs);
            if (max_lat > 40) begin
                $display("T4 latency: FAIL (max %0d clk > 40)", max_lat);
                error_count++;
            end else
                $display("T4 latency: PASS (max %0d clk of 40 budget)", max_lat);
        end

        // ---------------- Test 5: extremes ----------------
        do_sample(7'd0, lat);
        if (resistor_out !== '0) begin
            $display("ERROR T5: amp=0 -> %h", resistor_out);
            error_count++;
        end
        do_sample(7'd64, lat);
        if (resistor_out !== '1) begin
            $display("ERROR T5: amp=64 -> %h", resistor_out);
            error_count++;
        end
        $display("T5 extremes: done");

        // ---------------- Test 6: usage balance at amp=32 ----------------
        foreach (usage[i]) usage[i] = 0;
        repeat (256) begin
            do_sample(7'd32, lat);
            for (int i = 0; i < ARRAY_SIZE; i++)
                if (resistor_out[i]) usage[i]++;
        end
        umin = 999; umax = -1;
        for (int i = 0; i < ARRAY_SIZE; i++) begin
            if (usage[i] < umin) umin = usage[i];
            if (usage[i] > umax) umax = usage[i];
        end
        // 256 samples * 32/64 = 128 expected per cell
        if (umax - umin > 2) begin
            $display("ERROR T6: usage spread %0d..%0d (expect within +-2 of 128)", umin, umax);
            error_count++;
        end else
            $display("T6 balance: PASS (usage %0d..%0d)", umin, umax);

        // ---------------- summary ----------------
        if (error_count == 0)
            $display("ALL TESTS PASS (tb_dem_sort)");
        else
            $display("TESTS FAILED: %0d errors (tb_dem_sort)", error_count);
        $finish;
    end

endmodule
