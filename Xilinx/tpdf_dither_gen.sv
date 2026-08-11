`timescale 1ns / 1ps

// =============================================================================
// Round 30 REWRITE. The original implementation advanced two 32-bit LFSRs by
// ONE bit per sample: consecutive outputs shared 31 of 32 bits, so the
// "dither" was massively sample-to-sample correlated — measured ~50 % of its
// power INSIDE the audio band (white = 0.65 %), which injected an unshaped
// in-band noise floor at the noise-shaper quantizer (found by the Round 30
// e2e sine FFT: 84 dB in-system vs 136 dB reference).
//
// New generator: two independent 64-bit xorshift states, FULL-state scramble
// per enable (three shift-XOR passes each), uniform slices u1, u2 of
// DITHER_WIDTH-1 bits -> TPDF = u1 - u2, range +-0.5 quantizer level at
// FRAC_WIDTH=DITHER_WIDTH scaling. Spectrally white to the LFSR period
// (2^64-1). Matches the ns_ef3_gen.py golden convention.
// =============================================================================
module tpdf_dither_gen #(
    parameter int DITHER_WIDTH = 42
)(
    input  logic clk,
    input  logic rst_n,
    input  logic enable,
    output logic signed [DITHER_WIDTH-1:0] dither_out
);

    localparam int UW = DITHER_WIDTH - 1;   // uniform width (41 for 42-bit TPDF)

    logic [63:0] s1, s2;

    // xorshift64 full-state advance (Marsaglia 13/7/17)
    function automatic logic [63:0] xs64(input logic [63:0] s);
        logic [63:0] x;
        x = s ^ (s << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        return x;
    endfunction

    // Next-state nets: IEEE 1800 forbids a part-select directly on a
    // function call (Synth 8-12513), so materialize xs64() once per state.
    logic [63:0] s1_next, s2_next;
    assign s1_next = xs64(s1);
    assign s2_next = xs64(s2);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1 <= 64'hACE1_1001_DEAD_BEEF;
            s2 <= 64'h1337_BEEF_CAFE_F00D;
            dither_out <= '0;
        end else if (enable) begin
            s1 <= s1_next;
            s2 <= s2_next;
            dither_out <= DITHER_WIDTH'($signed({1'b0, s1_next[UW-1:0]}) -
                                        $signed({1'b0, s2_next[UW-1:0]}));
        end
    end

endmodule