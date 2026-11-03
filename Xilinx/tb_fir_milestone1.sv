`timescale 1ns / 1ps

module tb_fir_milestone1;

    localparam int NUM_INPUTS = 1280;
    localparam int WIDTH      = 48;
    localparam int TPP        = 64; // Tests tightest 64-cycle phase spacing (production is 256)

    logic                    clk = 0;
    logic                    rst_n = 0;
    logic                    snap_en = 0;
    logic signed [WIDTH-1:0] data_in [0:NUM_INPUTS-1];
    logic signed [WIDTH-1:0] tree_out;
    logic                    valid_out;

    always #1.65 clk = ~clk; // ~302 MHz dsp_clk

    polyphase_adder_tree #(
        .NUM_INPUTS (NUM_INPUTS),
        .WIDTH      (WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .snap_en   (snap_en),
        .data_in   (data_in),
        .tree_out  (tree_out),
        .valid_out (valid_out)
    );

    logic signed [WIDTH-1:0] exp_queue [$];
    int pass_cnt = 0;
    int fail_cnt = 0;

    initial begin
        for (int i = 0; i < NUM_INPUTS; i++) data_in[i] = '0;
        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (5) @(posedge clk);

        // Run 32 consecutive polyphase windows spaced by TPP cycles
        for (int p = 0; p < 32; p++) begin
            for (int t = 0; t < TPP; t++) begin
                @(posedge clk);
                if (t == TPP - 1) begin
                    automatic logic signed [WIDTH-1:0] gold_sum = '0;
                    snap_en <= 1'b1;
                    for (int m = 0; m < NUM_INPUTS; m++) begin
                        automatic logic signed [WIDTH-1:0] v =
                            {$urandom(), $urandom()} & ((1<<WIDTH)-1);
                        data_in[m] <= v;
                        gold_sum += v;
                    end
                    exp_queue.push_back(gold_sum);
                end else begin
                    // Drive random intermediate accumulator activity on non-boundary cycles
                    snap_en <= 1'b0;
                    for (int m = 0; m < NUM_INPUTS; m++)
                        data_in[m] <= {$urandom(), $urandom()};
                end
            end
        end
        @(posedge clk);
        snap_en <= 1'b0;

        repeat (100) @(posedge clk);
        if (fail_cnt == 0 && pass_cnt == 32 && exp_queue.size() == 0)
            $display("[TB_MILESTONE1] PASS: All %0d phases bit-exact (0 LSB error, latency=%0d clks)",
                     pass_cnt, dut.TREE_LATENCY);
        else
            $fatal(1, "[TB_MILESTONE1] FAIL: pass=%0d fail=%0d pending=%0d",
                   pass_cnt, fail_cnt, exp_queue.size());
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n && valid_out) begin
            automatic logic signed [WIDTH-1:0] exp_val = exp_queue.pop_front();
            if (tree_out === exp_val) begin
                pass_cnt++;
            end else begin
                fail_cnt++;
                $error("[TB_MILESTONE1] Mismatch! got=0x%012h exp=0x%012h", tree_out, exp_val);
            end
        end
    end

endmodule
