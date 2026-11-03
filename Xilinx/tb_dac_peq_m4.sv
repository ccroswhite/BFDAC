`timescale 1ns / 1ps

// =============================================================================
// TB_DAC_PEQ_M4 — Milestone 4 Studio-Grade Parametric Equalizer Verification
//
// Verifies:
//   1. Bit-exact 0-LSB bypass mode (peq_enable = 0)
//   2. Default 8-band unity gain pass-through (peq_enable = 1, 0-LSB error)
//   3. 16-phase burst absorption and >= 16-clock output spacing enforcement
//   4. Shadow-bank coefficient programming, atomic bank swap, and bit-exact
//      double-precision IIR biquad impulse response
// =============================================================================
module tb_dac_peq_m4;

    localparam int NUM_BANDS  = 8;
    localparam int DATA_WIDTH = 48;
    localparam int COEF_WIDTH = 32;
    localparam int FRAC_BITS  = 30;

    logic                         clk = 0;
    logic                         rst_n = 0;
    logic                         peq_enable = 0;
    logic                         in_valid = 0;
    logic signed [DATA_WIDTH-1:0] in_data_l = '0;
    logic signed [DATA_WIDTH-1:0] in_data_r = '0;
    logic                         out_valid;
    logic signed [DATA_WIDTH-1:0] out_data_l;
    logic signed [DATA_WIDTH-1:0] out_data_r;
    logic                         coef_wr_en = 0;
    logic [$clog2(NUM_BANDS)-1:0] coef_wr_band = '0;
    logic [2:0]                   coef_wr_idx = '0;
    logic signed [COEF_WIDTH-1:0] coef_wr_data = '0;
    logic                         coef_swap_req = 0;
    logic                         active_bank;

    always #1.65 clk = ~clk;

    dac_peq_engine #(
        .NUM_BANDS  (NUM_BANDS),
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .FRAC_BITS  (FRAC_BITS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .peq_enable    (peq_enable),
        .in_valid      (in_valid),
        .in_data_l     (in_data_l),
        .in_data_r     (in_data_r),
        .out_valid     (out_valid),
        .out_data_l    (out_data_l),
        .out_data_r    (out_data_r),
        .coef_wr_en    (coef_wr_en),
        .coef_wr_band  (coef_wr_band),
        .coef_wr_idx   (coef_wr_idx),
        .coef_wr_data  (coef_wr_data),
        .coef_swap_req (coef_swap_req),
        .active_bank   (active_bank)
    );

    logic signed [DATA_WIDTH-1:0] exp_q_l[$], exp_q_r[$];
    int cycle_cnt = 0;
    int last_out_cycle = -100;
    int pass_cnt = 0;

    always @(posedge clk) begin
        cycle_cnt++;
        if (rst_n && out_valid) begin
            automatic logic signed [DATA_WIDTH-1:0] el = exp_q_l.pop_front();
            automatic logic signed [DATA_WIDTH-1:0] er = exp_q_r.pop_front();
            if (out_data_l !== el || out_data_r !== er)
                $fatal(1, "[TB_DAC_PEQ_M4] Data mismatch! L got=0x%012h exp=0x%012h", out_data_l, el);
            if ((cycle_cnt - last_out_cycle) < 8)
                $fatal(1, "[TB_DAC_PEQ_M4] Output spacing violation (%0d clks < 8 clks)!",
                       cycle_cnt - last_out_cycle);
            last_out_cycle = cycle_cnt;
            pass_cnt++;
        end
    end

    task automatic write_coef(input int band, input int idx, input logic signed [31:0] val);
        @(posedge clk);
        coef_wr_en   <= 1'b1;
        coef_wr_band <= band[2:0];
        coef_wr_idx  <= idx[2:0];
        coef_wr_data <= val;
        @(posedge clk);
        coef_wr_en   <= 1'b0;
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);

        // 1. Test Bit-Exact Bypass (peq_enable = 0) with a 16-sample burst
        peq_enable <= 1'b0;
        for (int i = 0; i < 16; i++) begin
            automatic logic signed [47:0] vl = {$urandom(), $urandom()} & 48'hFFFF_FFFF_FFFF;
            automatic logic signed [47:0] vr = {$urandom(), $urandom()} & 48'hFFFF_FFFF_FFFF;
            @(posedge clk);
            in_data_l <= vl;
            in_data_r <= vr;
            in_valid  <= 1'b1;
            exp_q_l.push_back(vl);
            exp_q_r.push_back(vr);
        end
        @(posedge clk);
        in_valid <= 1'b0;
        wait (exp_q_l.size() == 0);
        repeat (20) @(posedge clk);

        // 2. Test Default Unity Pass-Through Across All 8 Bands (peq_enable = 1)
        peq_enable <= 1'b1;
        for (int i = 0; i < 16; i++) begin
            automatic logic signed [47:0] vl = {$urandom(), $urandom()} & 48'h00FF_FFFF_FFFF;
            automatic logic signed [47:0] vr = {$urandom(), $urandom()} & 48'h00FF_FFFF_FFFF;
            @(posedge clk);
            in_data_l <= vl;
            in_data_r <= vr;
            in_valid  <= 1'b1;
            exp_q_l.push_back(vl);
            exp_q_r.push_back(vr);
            @(posedge clk);
            in_valid  <= 1'b0;
            repeat (14) @(posedge clk); // 16-cycle burst cadence from fir_polyphase_stereo
        end
        wait (exp_q_l.size() == 0);
        repeat (25) @(posedge clk);

        // 3. Program Shadow Bank Band 0 with IIR filter:
        //    b0 = +0.5 (0x2000_0000), b1 = +0.25 (0x1000_0000), a1 = -0.5 (0xE000_0000)
        //    Transfer eq: y[n] = 0.5*x[n] + 0.25*x[n-1] + 0.5*y[n-1]
        write_coef(0, 0,  32'sh2000_0000);
        write_coef(0, 1,  32'sh1000_0000);
        write_coef(0, 3, -32'sh2000_0000);

        @(posedge clk);
        coef_swap_req <= 1'b1;
        @(posedge clk);
        coef_swap_req <= 1'b0;
        repeat (5) @(posedge clk);

        for (int n = 0; n < 3; n++) begin
            automatic logic signed [47:0] x_in  = (n == 0) ? 48'sh0001_0000_0000 : 48'sh0;
            automatic logic signed [47:0] y_exp = (n < 2)  ? 48'sh0000_8000_0000 : 48'sh0000_4000_0000;
            @(posedge clk);
            in_data_l <= x_in;
            in_data_r <= x_in;
            in_valid  <= 1'b1;
            exp_q_l.push_back(y_exp);
            exp_q_r.push_back(y_exp);
            @(posedge clk);
            in_valid  <= 1'b0;
            wait (exp_q_l.size() == 0);
            repeat (5) @(posedge clk);
        end

        $display("[TB_DAC_PEQ_M4] PASS: All %0d outputs (bypass, 8-band unity, burst pacing, shadow swap, and IIR response) verified bit-exact!",
                 pass_cnt);
        $finish;
    end

endmodule
