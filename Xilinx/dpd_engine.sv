`timescale 1ns / 1ps

// =============================================================================
// DPD Engine (Step 4D.1, 2026-08-22) — per-channel serial 2-lane MAC engine
//
// Implements the CERTIFIED fixed-point Volterra predistortion controller
// (utils/dpd_fx_golden.py, W=18 / F=24 ratified 2026-08-03) embedded in the
// EF3 error feedback: after each noise-shaper Stage-D commit (y_valid), the
// engine computes
//
//   acc  = -Sm[y]<<shS + SUM_i Qm[i]*prod_i(hist)<<shQ - SUM_j Fm[j]*h[j+1]<<shF
//   act  = (acc + 1<<(GF-1)) >>> GF                      (2^-24 code-LSB grid)
//   corr = (lut24[y] + act) <<< (FRAC-24)                (FRAC=42 e-domain)
//
// and pulses corr_valid; noise_shaper_ef3 Stage E patches
// e1 = clamp(e_raw - corr) before the next enable. All arithmetic is modulo
// 2^56 (matches the golden model's 56-bit accumulator wrap).
//
//   hist   : code-32 history, 17 deep (kernel max lag 5, FIR taps h[1..16])
//   prod_i : order-2/3 lag products, <=17-bit signed exact
//   mants  : 18-bit signed (one cal-store word each), one 18x17 DSP48 per lane
//   shifts : per-class shared exponents shQ/shS/shF and GF = G-24, 6-bit,
//            stored per channel in the cal store (ARM tooling computes them)
//
// Coefficient source: cal_coef_store active bank, TWO read ports per channel
// (1-cycle registered reads). Word map (per channel):
//   0-63 lut24 | 64-102 Qm[39] | 103-118 Fm[16] | 119-122 shQ/shS/shF/GF |
//   128-191 Sm[64]
//
// Schedule (31 issue slots, II=1 per lane, ~41 dsp_clk total — fits the
// >=52-cycle budget between Stage D and the next enable):
//   step 0   : A meta shQ         B meta shS
//   step 1   : A meta shF         B meta GF
//   step 2   : A Sm[y] (neg)      B lut24[y] (capture)
//   step 3-22: A kernel even i    B kernel odd i (last B slot idle)
//   step23-30: A FIR j=0..7 (neg) B FIR j=8..15 (neg)
// =============================================================================
module dpd_engine #(
    parameter int FRAC = 42,
    parameter int F    = 24,     // action grid
    parameter int ACCW = 56
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               dpd_enable,   // level, dsp_clk-synced
    input  logic               y_valid,      // NS Stage-D commit (1 pulse)
    input  logic [6:0]         y,            // committed code 0..63

    // cal_coef_store active-bank read ports (registered, data next cycle)
    output logic [7:0]         cal_addr_a,
    input  logic [23:0]        cal_data_a,
    output logic [7:0]         cal_addr_b,
    input  logic [23:0]        cal_data_b,

    // correction to noise_shaper_ef3 Stage E
    output logic signed [ACCW-1:0] corr,
    output logic               corr_valid,
    output logic               busy
);

    `include "dpd_lag_rom.svh"

    // Cal store word map
    localparam logic [7:0] A_LUT = 8'd0,   A_Q   = 8'd64,  A_F   = 8'd103;
    localparam logic [7:0] A_SHQ = 8'd119, A_SHS = 8'd120, A_SHF = 8'd121;
    localparam logic [7:0] A_GF  = 8'd122, A_S   = 8'd128;

    // Op kinds through the lane pipelines
    typedef enum logic [3:0] {
        OP_IDLE, OP_META_SHQ, OP_META_SHS, OP_META_SHF, OP_META_GF,
        OP_LUT, OP_MAC_Q, OP_MAC_S, OP_MAC_F
    } op_t;

    // ------------------------------------------------------------------------
    // history: code-32, 17 deep, 6-bit signed
    // ------------------------------------------------------------------------
    logic signed [5:0] hist [0:16];

    // ------------------------------------------------------------------------
    // sequencer
    // ------------------------------------------------------------------------
    logic        running;
    logic [5:0]  step;          // 0..30 issue, then drain
    logic [6:0]  y_r;

    // per-lane issue-stage payloads
    op_t               opA_s0, opB_s0;
    logic signed [5:0] a_h0, a_h1, a_h2, b_h0, b_h1, b_h2;
    logic              a_one2, b_one2;   // lag2 unused -> multiply by 1

    // metadata / LUT registers
    logic [5:0]  shQ, shS, shF, gf;
    logic signed [23:0] lut_r;

    // lane pipelines (issue N -> operands N / p12 N+1 / p17+coef N+2 /
    // mul N+3 / mulr N+4 / shift N+5 / acc N+6; op X is "valid during"
    // cycle N+k+1 at pipe index k)
    op_t  opA_p [1:5];
    op_t  opB_p [1:5];
    logic signed [11:0] a_p12, b_p12;
    logic signed [5:0]  a_h2d, b_h2d;
    logic               a_one2d, b_one2d;
    logic signed [17:0] a_coef, b_coef;
    logic signed [16:0] a_p17, b_p17;
    logic signed [34:0] a_mul, b_mul, a_mulr, b_mulr;
    logic signed [ACCW-1:0] a_shift, b_shift;
    logic signed [ACCW-1:0] accA, accB;

    // finish sequence
    logic signed [ACCW-1:0] sum_r, sumh_r, act_r;
    logic [2:0]  fin;           // one-hot-ish finish pipeline
    assign busy = running || (|fin);

    function automatic logic signed [5:0] hsel(input logic [2:0] lag);
        return hist[lag];
    endfunction

    // schedule decode (combinational on step)
    logic [7:0] adrA_c, adrB_c;
    op_t        opA_c, opB_c;
    logic [8:0] lagsA_c, lagsB_c;
    logic [5:0] tA, tB;

    always_comb begin
        adrA_c = '0; adrB_c = '0;
        opA_c = OP_IDLE; opB_c = OP_IDLE;
        lagsA_c = 9'b111_111_111; lagsB_c = 9'b111_111_111;
        tA = '0; tB = '0;
        unique case (1'b1)
            (step == 6'd0): begin
                adrA_c = A_SHQ; opA_c = OP_META_SHQ;
                adrB_c = A_SHS; opB_c = OP_META_SHS;
            end
            (step == 6'd1): begin
                adrA_c = A_SHF; opA_c = OP_META_SHF;
                adrB_c = A_GF;  opB_c = OP_META_GF;
            end
            (step == 6'd2): begin
                adrA_c = A_S + {2'd0, y_r[5:0]}; opA_c = OP_MAC_S;
                adrB_c = A_LUT + {2'd0, y_r[5:0]}; opB_c = OP_LUT;
            end
            (step >= 6'd3 && step <= 6'd22): begin
                tA = 6'((step - 6'd3) << 1);            // even kernel index
                tB = tA + 6'd1;                          // odd kernel index
                adrA_c  = A_Q + {2'd0, tA};
                opA_c   = OP_MAC_Q;
                lagsA_c = DPD_LAGS[tA];
                if (tB < 6'(DPD_NTERMS)) begin
                    adrB_c  = A_Q + {2'd0, tB};
                    opB_c   = OP_MAC_Q;
                    lagsB_c = DPD_LAGS[tB];
                end
            end
            (step >= 6'd23 && step <= 6'd30): begin
                adrA_c = A_F + {2'd0, step - 6'd23};      // FIR j = 0..7
                opA_c  = OP_MAC_F;
                adrB_c = A_F + {2'd0, step - 6'd23} + 8'd8; // FIR j = 8..15
                opB_c  = OP_MAC_F;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            running    <= 1'b0;
            step       <= '0;
            y_r        <= '0;
            for (int i = 0; i < 17; i++) hist[i] <= '0;
            opA_s0     <= OP_IDLE;  opB_s0 <= OP_IDLE;
            for (int i = 1; i <= 5; i++) begin
                opA_p[i] <= OP_IDLE;
                opB_p[i] <= OP_IDLE;
            end
            cal_addr_a <= '0;  cal_addr_b <= '0;
            a_h0 <= '0; a_h1 <= '0; a_h2 <= '0; a_one2 <= 1'b0;
            b_h0 <= '0; b_h1 <= '0; b_h2 <= '0; b_one2 <= 1'b0;
            shQ <= '0; shS <= '0; shF <= '0; gf <= '0;
            lut_r  <= '0;
            a_p12 <= '0; b_p12 <= '0; a_h2d <= '0; b_h2d <= '0;
            a_one2d <= 1'b0; b_one2d <= 1'b0;
            a_coef <= '0; b_coef <= '0; a_p17 <= '0; b_p17 <= '0;
            a_mul <= '0; b_mul <= '0; a_mulr <= '0; b_mulr <= '0;
            a_shift <= '0; b_shift <= '0;
            accA <= '0; accB <= '0;
            sum_r <= '0; sumh_r <= '0; act_r <= '0;
            fin  <= '0;
            corr <= '0;
            corr_valid <= 1'b0;
        end else begin
            corr_valid <= 1'b0;

            // ---------------- launch --------------------------------------
            if (y_valid && dpd_enable) begin
                // shift history with the fresh code (hist[0] = current)
                hist[0] <= 6'(y - 7'd32);
                for (int i = 1; i < 17; i++) hist[i] <= hist[i-1];
                y_r     <= y;
                running <= 1'b1;
                step    <= '0;
                accA    <= '0;
                accB    <= '0;
                fin     <= '0;
            end else if (running) begin
                if (step <= 6'd30) step <= step + 6'd1;
            end

            // ---------------- issue stage (s0) -----------------------------
            if (running && step <= 6'd30) begin
                cal_addr_a <= adrA_c;
                cal_addr_b <= adrB_c;
                opA_s0     <= opA_c;
                opB_s0     <= opB_c;
                // operand select: kernel lags, FIR single tap, STAT -> 1
                unique case (opA_c)
                    OP_MAC_Q: begin
                        a_h0 <= hsel(lagsA_c[2:0]);
                        a_h1 <= hsel(lagsA_c[5:3]);
                        a_h2 <= hsel(lagsA_c[8:6]);
                        a_one2 <= (lagsA_c[8:6] == 3'd7);
                    end
                    OP_MAC_F: begin
                        a_h0 <= hist[step - 6'd23 + 6'd1];   // h[j+1]
                        a_h1 <= 6'sd1;
                        a_h2 <= 6'sd1;
                        a_one2 <= 1'b1;
                    end
                    default: begin                            // STAT / meta
                        a_h0 <= 6'sd1; a_h1 <= 6'sd1; a_h2 <= 6'sd1;
                        a_one2 <= 1'b1;
                    end
                endcase
                unique case (opB_c)
                    OP_MAC_Q: begin
                        b_h0 <= hsel(lagsB_c[2:0]);
                        b_h1 <= hsel(lagsB_c[5:3]);
                        b_h2 <= hsel(lagsB_c[8:6]);
                        b_one2 <= (lagsB_c[8:6] == 3'd7);
                    end
                    OP_MAC_F: begin
                        b_h0 <= hist[step - 6'd23 + 6'd9];   // h[j+9]
                        b_h1 <= 6'sd1;
                        b_h2 <= 6'sd1;
                        b_one2 <= 1'b1;
                    end
                    default: begin
                        b_h0 <= 6'sd1; b_h1 <= 6'sd1; b_h2 <= 6'sd1;
                        b_one2 <= 1'b1;
                    end
                endcase
            end else begin
                opA_s0 <= OP_IDLE;
                opB_s0 <= OP_IDLE;
            end

            // ---------------- pipeline flags -------------------------------
            opA_p[1] <= opA_s0;  opB_p[1] <= opB_s0;
            for (int i = 2; i <= 5; i++) begin
                opA_p[i] <= opA_p[i-1];
                opB_p[i] <= opB_p[i-1];
            end

            // ---------------- s1: RAM data back; captures; prod12 ----------
            a_p12  <= a_h0 * a_h1;
            b_p12  <= b_h0 * b_h1;
            a_h2d  <= a_h2;   b_h2d  <= b_h2;
            a_one2d<= a_one2; b_one2d<= b_one2;
            a_coef <= signed'(cal_data_a[17:0]);
            b_coef <= signed'(cal_data_b[17:0]);
            case (opA_p[1])
                OP_META_SHQ: shQ <= cal_data_a[5:0];
                OP_META_SHF: shF <= cal_data_a[5:0];
                default: ;
            endcase
            case (opB_p[1])
                OP_META_SHS: shS <= cal_data_b[5:0];
                OP_META_GF:  gf  <= cal_data_b[5:0];
                OP_LUT:      lut_r <= signed'(cal_data_b);
                default: ;
            endcase

            // ---------------- s2: prod17 (coef arrives here too) -----------
            a_p17   <= a_one2d ? 17'(a_p12) : 17'(a_p12 * a_h2d);
            b_p17   <= b_one2d ? 17'(b_p12) : 17'(b_p12 * b_h2d);

            // ---------------- s3/s4: 18x17 multiply (DSP48, 2-stage) -------
            a_mul  <= a_coef * a_p17;
            b_mul  <= b_coef * b_p17;
            a_mulr <= a_mul;
            b_mulr <= b_mul;

            // ---------------- s5: class shift (op valid at p[4]) -----------
            unique case (opA_p[4])
                OP_MAC_Q: a_shift <= ACCW'(a_mulr) <<< shQ;
                OP_MAC_S: a_shift <= ACCW'(a_mulr) <<< shS;
                OP_MAC_F: a_shift <= ACCW'(a_mulr) <<< shF;
                default:  a_shift <= '0;
            endcase
            unique case (opB_p[4])
                OP_MAC_Q: b_shift <= ACCW'(b_mulr) <<< shQ;
                OP_MAC_F: b_shift <= ACCW'(b_mulr) <<< shF;
                default:  b_shift <= '0;
            endcase

            // ---------------- s6: accumulate (STAT/FIR negative) -----------
            case (opA_p[5])
                OP_MAC_Q:          accA <= accA + a_shift;
                OP_MAC_S, OP_MAC_F: accA <= accA - a_shift;
                default: ;
            endcase
            case (opB_p[5])
                OP_MAC_Q:          accB <= accB + b_shift;
                OP_MAC_F:          accB <= accB - b_shift;
                default: ;
            endcase

            // ---------------- finish: sum, round, output -------------------
            // last issue at step 30 -> its acc update lands 6 cycles later
            // (step counter parks at 31; count the drain with fin)
            if (running && step == 6'd31) begin
                // wait for pipes to drain: opA_p[5] returns to IDLE after
                // the last MAC's accumulate. Kick the finish chain then.
                if (opA_p[5] == OP_IDLE && opB_p[5] == OP_IDLE
                    && fin == 3'b000) fin <= 3'b001;
            end
            if (fin[0]) begin
                sum_r  <= accA + accB;
                fin    <= 3'b010;
            end else if (fin[1]) begin
                sumh_r <= sum_r + (ACCW'(1) <<< (gf - 6'd1));
                fin    <= 3'b100;
            end else if (fin[2]) begin
                act_r      <= sumh_r >>> gf;
                corr       <= (ACCW'(lut_r) + (sumh_r >>> gf)) <<< (FRAC - F);
                corr_valid <= 1'b1;
                fin        <= '0;
                running    <= 1'b0;
            end
        end
    end

endmodule
