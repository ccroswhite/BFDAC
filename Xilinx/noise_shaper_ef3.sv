`timescale 1ns / 1ps

// =============================================================================
// 3rd-Order Error-Feedback Noise Shaper with IIR NTF (Round 30)
//
// REPLACES noise_shaper_7th_order, whose placeholder FIR coefficients
// {7,6,5,4,3,2,1} had NTF(DC) = -3 — NO zero at DC, i.e. quantization noise
// was AMPLIFIED in-band (-16 dB SNDR, found by the Round 30 e2e sine FFT).
// A pure FIR error-feedback NTF is fundamentally capped at 2nd order here:
// with the +-28-level signal plan, quantizer headroom is ~6 levels and a
// binomial L=3 FIR feeds back up to ||h||1*1.5 = 10.5 levels -> overload
// (ns_coef_check.py sweeps). Higher order requires NTF poles.
//
//   NTF = (1 - z^-1)^3 / (1 - z^-1/2)^3      ||NTF||inf = 2.37
//
//   f[n] = 1.5 e1 - 2.25 e2 + 0.875 e3 + 1.5 f1 - 0.75 f2 + 0.125 f3
//   w    = u + 32.0 + f ;  y = clamp(floor(w + dither)) ;  e = w - y
//
// All coefficients dyadic (shift-add only). Verified integer-exact against
// ns_ef3_gen.py: 136.0 dB in-band SNDR at -1 dBFS / OSR 154 (code budget
// line: 133.5 dB). e is clamped to +-63 levels for overload recovery.
//
// Pipeline (4 stages, one result per enable; enable period is 56-65 dsp_clk):
//   Stage A : capture u/dither, form the six shift-add partial products
//   Stage B : f = sum of partials; w = u_off + f
//   Stage C : d = w + dither; quantize + range select
//   Stage D : commit y, e (clamped), shift e/f delay lines
// =============================================================================
module noise_shaper_ef3 #(
    parameter int INPUT_WIDTH = 48,
    parameter int FRAC_WIDTH  = 42,
    parameter int OUT_WIDTH   = 7    // 0..63 for the 64-cell DEM
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          enable,
    input  logic signed [INPUT_WIDTH-1:0] data_in,
    input  logic signed [FRAC_WIDTH-1:0]  dither_in,
    output logic [OUT_WIDTH-1:0]          dem_drive_out
);

    localparam int IW = INPUT_WIDTH + 8;   // 56-bit internal

    localparam logic signed [IW-1:0] CENTER_OFFSET_SCALED = 56'sd32 <<< FRAC_WIDTH;
    localparam logic signed [IW-1:0] E_CLAMP              = 56'sd63 <<< FRAC_WIDTH;

    // delay lines
    logic signed [IW-1:0] e1, e2, e3;
    logic signed [IW-1:0] f1, f2, f3;

    logic [3:0] en_pipe;

    // Stage A registers: six dyadic partial products + input snapshot
    logic signed [IW-1:0] pe1_r, pe2_r, pe3_r, pf1_r, pf2_r, pf3_r;
    logic signed [IW-1:0] u_off_r;
    logic signed [FRAC_WIDTH-1:0] dith_a;

    // Stage B registers
    logic signed [IW-1:0] f_r, w_r;
    logic signed [FRAC_WIDTH-1:0] dith_b;

    // Stage C registers
    logic signed [IW-1:0] w_c;
    logic [OUT_WIDTH-1:0] code_c;
    logic [1:0]           range_c;
    logic signed [IW-1:0] d_comb;
    assign d_comb = w_r + IW'($signed(dith_b));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            e1 <= '0; e2 <= '0; e3 <= '0;
            f1 <= '0; f2 <= '0; f3 <= '0;
            en_pipe <= '0;
            pe1_r <= '0; pe2_r <= '0; pe3_r <= '0;
            pf1_r <= '0; pf2_r <= '0; pf3_r <= '0;
            u_off_r <= '0; dith_a <= '0;
            f_r <= '0; w_r <= '0; dith_b <= '0;
            w_c <= '0; code_c <= '0; range_c <= 2'b00;
            dem_drive_out <= 7'd32;
        end else begin
            en_pipe <= {en_pipe[2:0], enable};

            // --- Stage A: dyadic partial products --------------------------
            if (enable) begin
                pe1_r  <= e1 + (e1 >>> 1);                 //  1.5   e1
                pe2_r  <= (e2 <<< 1) + (e2 >>> 2);         //  2.25  e2 (subtracted)
                pe3_r  <= e3 - (e3 >>> 3);                 //  0.875 e3
                pf1_r  <= f1 + (f1 >>> 1);                 //  1.5   f1
                pf2_r  <= (f2 >>> 1) + (f2 >>> 2);         //  0.75  f2 (subtracted)
                pf3_r  <= f3 >>> 3;                        //  0.125 f3
                u_off_r <= IW'($signed(data_in)) + CENTER_OFFSET_SCALED;
                dith_a <= dither_in;
            end

            // --- Stage B: f and quantizer input ----------------------------
            if (en_pipe[0]) begin
                f_r    <= ((pe1_r - pe2_r) + (pe3_r + pf1_r)) - (pf2_r - pf3_r);
                w_r    <= u_off_r + (((pe1_r - pe2_r) + (pe3_r + pf1_r)) - (pf2_r - pf3_r));
                dith_b <= dith_a;
            end

            // --- Stage C: dither + quantize + range select -----------------
            if (en_pipe[1]) begin
                w_c    <= w_r;
                code_c <= d_comb[FRAC_WIDTH +: OUT_WIDTH];
                if (!d_comb[IW-1] && (|d_comb[IW-2 : FRAC_WIDTH+OUT_WIDTH-1]))
                    range_c <= 2'b01;                      // > 63: clamp high
                else if (d_comb[IW-1])
                    range_c <= 2'b10;                      // < 0: clamp low
                else
                    range_c <= 2'b00;
            end

            // --- Stage D: commit output + error, shift delay lines ---------
            if (en_pipe[2]) begin
                automatic logic [OUT_WIDTH-1:0] y;
                automatic logic signed [IW-1:0] e_raw;
                case (range_c)
                    2'b01:   y = 7'd63;
                    2'b10:   y = 7'd0;
                    default: y = code_c;
                endcase
                dem_drive_out <= y;
                e_raw = w_c - (IW'($signed({1'b0, y})) <<< FRAC_WIDTH);
                if (e_raw > E_CLAMP)
                    e1 <= E_CLAMP;
                else if (e_raw < -E_CLAMP)
                    e1 <= -E_CLAMP;
                else
                    e1 <= e_raw;
                e2 <= e1;
                e3 <= e2;
                f1 <= f_r;
                f2 <= f1;
                f3 <= f2;
            end
        end
    end

endmodule
