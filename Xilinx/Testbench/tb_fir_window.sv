`timescale 1ns / 1ps

// =============================================================================
// Bit-exact verification of the FIR audio-window redesign (2026-08-01).
//
// Small config: NUM_MACS=8, TAPS_PER_PHASE=16, NUM_PHASES=16 -> 2048 taps,
// history K = 128 samples. Random coefficients, random audio.
//
// Reference (mod-2^48 wrap, matching DUT accumulator/tree semantics):
//   y[16n+p] = sum_{k=0}^{K-1} 2 * x[n-k] * h[p+16k]
// Coefficient layout (per redesigned interpolator header):
//   k = TPP*m + t  ->  h[p+16k] = cmem[m][p*TPP + t]
//
// The behavioral coefficient store models the URAM 2-cycle registered read
// (IREG + OREG) exactly as fir_polyphase_stereo presents it.
// =============================================================================
module tb_fir_window #(
    parameter int NM  = 8,
    parameter int TPP = 16
);

    localparam int NP  = 16;
    localparam int CD  = NP * TPP;    // 256
    localparam int K   = NM * TPP;    // 128
    localparam int DW  = 24;
    localparam int CW  = 18;
    localparam int AW  = 48;
    localparam int NSAMP = 40;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #1.25 clk = ~clk;   // 400 MHz

    logic                  nsv = 1'b0;
    logic signed [DW-1:0]  nsd = '0;
    logic signed [AW-1:0]  y;
    logic                  yv;
    logic signed [CW-1:0]  coef_in [0:NM-1];
    logic [$clog2(CD)-1:0] coef_addr;

    fir_polyphase_interpolator #(
        .NUM_MACS      (NM),
        .DATA_WIDTH    (DW),
        .COEF_WIDTH    (CW),
        .ACC_WIDTH     (AW),
        .NUM_PHASES    (NP),
        .TAPS_PER_PHASE(TPP)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .new_sample_valid (nsv),
        .new_sample_data  (nsd),
        .interpolated_out (y),
        .interpolated_valid(yv),
        .coef_in          (coef_in),
        .coef_addr_out    (coef_addr)
    );

    // ---- behavioral coef store: URAM model, 2-cycle registered read --------
    logic signed [CW-1:0]  cmem [0:NM-1][0:CD-1];
    logic [$clog2(CD)-1:0] addr_q;
    logic signed [CW-1:0]  cq [0:NM-1];

    always_ff @(posedge clk) begin
        addr_q <= coef_addr;
        for (int m = 0; m < NM; m++)
            cq[m] <= cmem[m][addr_q];
    end
    assign coef_in = cq;

    // ---- reference model ----------------------------------------------------
    logic signed [DW-1:0] xhist [0:K-1];   // xhist[k] = x[n-k]
    logic signed [AW-1:0] yref  [0:NP-1];

    function automatic void calc_ref();
        logic signed [63:0]   prod;
        logic signed [AW-1:0] acc;
        for (int p = 0; p < NP; p++) begin
            acc = '0;
            for (int k = 0; k < K; k++) begin
                prod = 64'(2 * xhist[k]) * 64'(cmem[k / TPP][p * TPP + (k % TPP)]);
                acc  = acc + AW'(prod);
            end
            yref[p] = acc;
        end
    endfunction

    // ---- output capture / compare -------------------------------------------
    int out_cnt  = 0;
    int err_cnt  = 0;
    int samp_idx = 0;

    always @(posedge clk) begin
        if (yv) begin
            if (out_cnt < NP && y !== yref[out_cnt]) begin
                if (err_cnt < 24)
                    $display("MISMATCH samp %0d phase %0d: dut=%0d ref=%0d diff=%0d",
                             samp_idx, out_cnt, y, yref[out_cnt], y - yref[out_cnt]);
                err_cnt++;
            end
            out_cnt++;
        end
    end

    initial begin
        for (int m = 0; m < NM; m++)
            for (int a = 0; a < CD; a++)
                cmem[m][a] = CW'($urandom);
        for (int k = 0; k < K; k++)
            xhist[k] = '0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        for (samp_idx = 0; samp_idx < NSAMP; samp_idx++) begin
            for (int k = K - 1; k > 0; k--)
                xhist[k] = xhist[k-1];
            xhist[0] = DW'($urandom);
            calc_ref();
            out_cnt = 0;

            @(negedge clk);
            nsv = 1'b1;
            nsd = xhist[0];
            @(negedge clk);
            nsv = 1'b0;

            repeat (CD + 150) @(posedge clk);   // shift(4) + sweep(CD) + shadow tail

            if (out_cnt != NP) begin
                $display("FAIL samp %0d: %0d outputs seen, expected %0d",
                         samp_idx, out_cnt, NP);
                err_cnt++;
            end
        end

        if (err_cnt == 0)
            $display("PASS: %0d samples x %0d phases bit-exact (2048-tap small config)",
                     NSAMP, NP);
        else
            $display("FAIL: %0d errors", err_cnt);
        $finish;
    end

endmodule
