`timescale 1ns / 1ps

// Probe TB: measure per-stage DC response of the two-stage cascade
// (fir_polyphase_stereo with TWO_STAGE_EN=1 default) so the stale
// tb_fir_polyphase_stereo expected values can be re-derived analytically.
module tb_s1_probe;

    localparam int NUM_MACS       = 4;
    localparam int TAPS_PER_PHASE = 16;
    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE;  // 256
    localparam int DATA_WIDTH     = 24;
    localparam int COEF_WIDTH     = 18;
    localparam int ACC_WIDTH      = 48;

    localparam real CLK_PERIOD = 2.8;
    logic clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic rst_n;
    logic                             new_sample_valid;
    logic signed [DATA_WIDTH-1:0]     new_sample_l, new_sample_r;
    logic signed [ACC_WIDTH-1:0]      interpolated_l, interpolated_r;
    logic                             interpolated_l_valid, interpolated_r_valid;
    logic                             input_overrun, input_frame_done;
    logic                             coef_we;
    logic [$clog2(COEF_DEPTH)-1:0]    coef_waddr;
    logic signed [COEF_WIDTH-1:0]     coef_wdata;
    logic [$clog2(NUM_MACS)-1:0]      coef_wmac;
    logic                             bank_select, bank_load_target;

    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH)
    ) dut (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .rate_shift             (2'b00),
        .new_sample_valid       (new_sample_valid),
        .new_sample_l           (new_sample_l),
        .new_sample_r           (new_sample_r),
        .interpolated_l         (interpolated_l),
        .interpolated_l_valid   (interpolated_l_valid),
        .interpolated_r         (interpolated_r),
        .interpolated_r_valid   (interpolated_r_valid),
        .input_overrun          (input_overrun),
        .input_frame_done       (input_frame_done),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target)
    );

    int m, a;
    int cyc;
    always_ff @(posedge clk) cyc <= cyc + 1;

    // Print stage outputs as they occur (hierarchical probes)
    always_ff @(posedge clk) begin
        if (dut.s1a_valid_l)
            $display("[%0d] S1A out_l=0x%h", cyc, dut.s1a_out_l);
        if (dut.gen_stage1b.u_stage1b.u_hb_s1.out_valid)
            $display("[%0d] HB1 out_l=0x%h (mid=0x%h pass=0x%h)", cyc,
                     dut.gen_stage1b.u_stage1b.u_hb_s1.out_l,
                     dut.gen_stage1b.u_stage1b.u_hb_s1.mid_l_reg,
                     dut.gen_stage1b.u_stage1b.u_hb_s1.pass_l_reg);
        if (dut.gen_stage1b.u_stage1b.u_hb_s2.out_valid)
            $display("[%0d] HB2 out_l=0x%h (mid=0x%h pass=0x%h)", cyc,
                     dut.gen_stage1b.u_stage1b.u_hb_s2.out_l,
                     dut.gen_stage1b.u_stage1b.u_hb_s2.mid_l_reg,
                     dut.gen_stage1b.u_stage1b.u_hb_s2.pass_l_reg);
        if (dut.gen_stage1b.u_stage1b.u_hb_s3.out_valid)
            $display("[%0d] HB3 out_l=0x%h (mid=0x%h pass=0x%h)", cyc,
                     dut.gen_stage1b.u_stage1b.u_hb_s3.out_l,
                     dut.gen_stage1b.u_stage1b.u_hb_s3.mid_l_reg,
                     dut.gen_stage1b.u_stage1b.u_hb_s3.pass_l_reg);
        if (interpolated_l_valid)
            $display("[%0d] FINAL out_l=0x%h", cyc, interpolated_l);
    end

    task do_reset;
        @(negedge clk);
        rst_n = 0; new_sample_valid = 0; new_sample_l = '0; new_sample_r = '0;
        coef_we = 0; coef_waddr = '0; coef_wdata = '0; coef_wmac = '0;
        bank_select = 0; bank_load_target = 0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat(TAPS_PER_PHASE + 1) @(posedge clk);
    endtask

    task write_all_coefs(input logic signed [COEF_WIDTH-1:0] cval, input logic bank);
        @(negedge clk); bank_load_target = bank;
        for (m = 0; m < NUM_MACS; m++)
            for (a = 0; a < COEF_DEPTH; a++) begin
                @(negedge clk);
                coef_we = 1'b1; coef_wmac = m; coef_waddr = a; coef_wdata = cval;
            end
        @(negedge clk); coef_we = 1'b0;
        repeat(4) @(posedge clk);
    endtask

    task send_sample(input logic signed [DATA_WIDTH-1:0] lv, input logic signed [DATA_WIDTH-1:0] rv);
        @(negedge clk);
        new_sample_l = lv; new_sample_r = rv; new_sample_valid = 1'b1;
        @(posedge clk); @(negedge clk); new_sample_valid = 1'b0;
    endtask

    localparam int FULL_BURST = NUM_MACS + 1 + COEF_DEPTH + 10 + 64;
    int overrun_seen = 0;
    int n_valids = 0;

    always @(posedge clk) begin
        if (input_overrun && overrun_seen == 0) overrun_seen = cyc;
        if (interpolated_l_valid) n_valids = n_valids + 1;
    end

    initial begin
        $display("=== S1 probe: uniform coef 0x1000, DC 0x100000 ===");
        do_reset;
        write_all_coefs(18'sh01000, 1'b0);
        bank_select = 1'b0;
        // prime FULL two-stage S1A history incl. stride-2 window: ~2048 samples
        repeat(NUM_MACS * 8 * TAPS_PER_PHASE * 4 + 8) begin
            send_sample(24'sh100000, 24'sh100000);
            repeat(FULL_BURST) @(posedge clk);
        end
        $display("=== primed: valids=%0d (~%0d accepted frames) first_overrun@%0d ===",
                 n_valids, n_valids/16, overrun_seen);
        send_sample(24'sh100000, 24'sh100000);
        repeat(FULL_BURST * 2) @(posedge clk);
        $display("=== done ===");
        $finish;
    end
endmodule
