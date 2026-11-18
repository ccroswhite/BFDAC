`timescale 1ns / 1ps
// =============================================================================
// dac_voicing_shaper.sv  --  Layer-2 bypassable harmonic voicing stage
//
// Inserted at the 768/705.6 kHz node between fir_polyphase_stereo (interp_l/r)
// and halfband_x2 HB1.  One instance per channel.
//
//   voicing_en=1 :  y[n] = x[n] + k2*(u^2 - dc_est) + k3*u^3   (u = x/2^41)
//   voicing_en=0 :  y[n] = x[n]               (0-LSB bit-exact bypass)
//
//   dc_est tracks E[u^2] with a 1-pole tracker updated per input sample:
//       dc_est += (u_sq - dc_est) / 2^DC_SHIFT   (~1.8-1.9 Hz corner)
//   This strips the k2*A^2/2 DC shift so voiced content cannot inject DC
//   into the downstream noise shaper / DEM headroom.
//
// Harmonic targets (A = 1 FS sine):
//   H2 = k2/2   ->  k2 = +2.0e-3  ->  H2 = -60 dBc
//   H3 = k3/4   ->  k3 = -8.0e-5  ->  H3 = -94 dBc
//
// Formats:
//   data_in/data_out : signed 48-bit, full scale = 2^FS_SHIFT
//   u                : Q2.25 (27b), data_in[FS_SHIFT+1 -: 27] clamped to
//                      (-2.0, +2.0)  ->  2x FS headroom, no wrap on overshoot
//   u_sq, u_cu       : Q3.15 signed (18b); u_cu clamped to (-4.0, +4.0)
//   k2, k3           : Q2.25 signed (27b, DSP48E2 A-port)
//                      k2=+2.0e-3 -> 27'sd67109 ; k3=-8.0e-5 -> -27'sd2684
//
// Architecture:
//   Sample-domain boundary regs are in_valid-gated (per-sample semantics,
//   esp. for the dc tracker).  All multiplies are 27x18 single-DSP48E2 ops
//   (u^2 uses u * u[26:9]; the 2^-16 truncation costs <-130 dBc post-k).
//   Product paths are clk-clocked 2-3 stage pipelines so Vivado absorbs
//   AREG/BREG+MREG+PREG inside the DSP slices: inputs only change at
//   in_valid strobes (>=8 dsp_clk spacing), so products settle long before
//   the next strobe and add ZERO sample latency.
//   Net sample-domain latency = 2 input samples.
//   DSP48E2 estimate: 4/channel (u^2, u^3, k2, k3) = 8 stereo.
// =============================================================================

module dac_voicing_shaper #(
    parameter int DATA_WIDTH = 48,
    parameter int FS_SHIFT   = 41,   // full scale = 2^FS_SHIFT
    parameter int DC_SHIFT   = 16    // tracker corner = Fs/2^DC_SHIFT (~1.8Hz @768k)
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          in_valid,
    input  logic signed [DATA_WIDTH-1:0]  data_in,

    input  logic                          voicing_en,
    input  logic signed [26:0]            k2,   // Q2.25
    input  logic signed [26:0]            k3,   // Q2.25

    output logic                          out_valid,
    output logic signed [DATA_WIDTH-1:0]  data_out
);

    // ---- Sample-domain registers (in_valid gated) --------------------------
    logic signed [26:0] u1;                        // Q2.25
    logic signed [47:0] x_d1, x_d2;
    logic signed [17+DC_SHIFT:0] dc_acc;           // dc_est + sub-LSB frac
    logic signed [17:0] usq_ac, ucu_q;             // Q3.15

    // ---- Clk-clocked DSP product pipelines --------------------------------
    // Inputs change only at in_valid strobes, so these converge a few clks
    // after each strobe and hold until the next one.
    logic signed [26:0] u1_c1, u1_c2;              // u1 delayed 2 clks
    (* use_dsp = "yes" *) logic signed [44:0] usq_p1;  // Q4.41 (DSP48E2)
    logic signed [44:0] usq_full;
    (* use_dsp = "yes" *) logic signed [44:0] ucu_p1;  // Q5.40 (DSP48E2)
    logic signed [44:0] ucu_full;
    (* use_dsp = "yes" *) logic signed [44:0] hp2;     // Q5.40 (DSP48E2)
    (* use_dsp = "yes" *) logic signed [44:0] hp3;     // Q5.40 (DSP48E2)
    logic signed [45:0] harm_sum;                  // Q5.40

    // ---- Combinational helpers (signed everywhere: bare part-selects are
    //      unsigned under IEEE 1800-2017 11.8.1 and would corrupt the math) --
    wire  signed [26:0] u_slice = data_in[FS_SHIFT+1 -: 27];
    // Overflow detect uses sign-extension mismatch vs data_in[FS_SHIFT+1];
    // clamp POLARITY must use the true sign data_in[DATA_WIDTH-1] (data_in[42]
    // is wrong for |x| >= 2^(FS_SHIFT+2)).  Exact -2.0 is also clamped: u^2=+4.0
    // would wrap the Q3.15 usq_w slice to -4.0.
    wire                u_ovf   = (data_in[DATA_WIDTH-1:FS_SHIFT+2]
                                   != {(DATA_WIDTH-FS_SHIFT-2){u_slice[26]}})
                                  || (u_slice == 27'sh4000000);
    wire  signed [26:0] u_norm  = u_ovf ? (data_in[DATA_WIDTH-1] ? 27'sh4000001
                                                               : 27'sh3FFFFFF)
                                        : u_slice;    // clamp to (-2.0,+2.0)
    wire  signed [17:0] u_hi    = $signed(u1[26:9]);  // Q2.16 truncated u
    wire  signed [17:0] usq_w   = $signed(usq_full[43:26]); // Q3.15
    wire  signed [17:0] dc_est  = $signed(dc_acc[17+DC_SHIFT:DC_SHIFT]);
    wire  signed [17:0] ucu_w   = $signed(ucu_full[42:25]); // Q3.15
    wire                ucu_ovf = (ucu_full[44:43] != {2{ucu_full[42]}});
    // Clamp polarity uses the true sign ucu_full[44]; symmetric +-131071
    // avoids the exact -4.0 edge (18'sh20000 = -131072 = -4.0).
    wire  signed [17:0] ucu_cl  = ucu_ovf ? (ucu_full[44] ? 18'sh20001
                                                        : 18'sh1FFFF)
                                        : ucu_w;      // clamp to (-4.0,+4.0)
    wire  signed [48:0] x_ext   = {x_d2[47], x_d2};
    wire  signed [48:0] h_ext   = {{3{harm_sum[45]}}, harm_sum};

    function automatic logic signed [47:0] sat48(input logic signed [48:0] s);
        if (s > 49'sh0_7FFF_FFFF_FFFF)
            return 48'sh7FFF_FFFF_FFFF;
        else if (s < -49'sh0_8000_0000_0000)
            return -48'sh8000_0000_0000;
        else
            return s[47:0];
    endfunction

    // ---- DSP product registers (clk domain; see header) --------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            u1_c1    <= '0;  u1_c2    <= '0;
            usq_p1   <= '0;  usq_full <= '0;
            ucu_p1   <= '0;  ucu_full <= '0;
            hp2      <= '0;  hp3      <= '0;
            harm_sum <= '0;
        end else begin
            // u1_c2 is u1 delayed 2 clks so it pairs with usq_full (the
            // 2-clk product pipe) -> ucu always cubes ONE consistent sample.
            u1_c1    <= u1;
            u1_c2    <= u1_c1;
            usq_p1   <= u1 * u_hi;                 // 27x18 -> 1 DSP48E2
            usq_full <= usq_p1;
            ucu_p1   <= usq_w * u1_c2;             // 18x27 -> 1 DSP48E2
            ucu_full <= ucu_p1;
            hp2      <= k2 * usq_ac;               // 27x18 -> 1 DSP48E2
            hp3      <= k3 * ucu_q;                // 27x18 -> 1 DSP48E2
            harm_sum <= hp2 + hp3;
        end
    end

    // synthesis translate_off
    // Products need ~4 clks to settle after each strobe; in_valid spacing
    // must be >= 5 clks (HW: >>8).  Catch back-to-back strobes in unit TBs.
    int last_strobe = -100;
    always @(posedge clk) if (rst_n && in_valid) begin
        if (last_strobe >= 0 && ($time - last_strobe) < 50)
            $error("[voicing_shaper] in_valid spacing < 5 clk at %0t", $time);
        last_strobe = $time;
    end
    // synthesis translate_on

    // ---- Sample-domain pipeline (per-strobe) -------------------------------
    //  n   : u1 <= u_norm(x_n), x_d1 <= x_n
    //        (during interval n..n+1 the clk pipes settle: usq_full=u_n^2,
    //         ucu_full=u_n^3, harm_sum=harm_{n-1})
    //  n+1 : usq_ac(u_n^2 - dc_est), dc tracker update, ucu_q(u_n^3), x_d2
    //  n+2 : data_out(x_n) = sat(x_d2 + harm_sum<<1) | x_d2   (bypass)
    //  -> 2-sample latency; all products consumed reflect ONE sample index.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            u1        <= '0;
            x_d1      <= '0;  x_d2 <= '0;
            dc_acc    <= '0;
            usq_ac    <= '0;
            ucu_q     <= '0;
            out_valid <= 1'b0;
            data_out  <= '0;
        end else if (in_valid) begin
            // ---- S1: normalize + clamp -----------------------------------
            u1   <= u_norm;
            x_d1 <= data_in;

            // ---- S2: DC tracker + capture u^2-ac / u^3 (sample n) ---------
            dc_acc   <= dc_acc + (usq_w - dc_est);
            usq_ac   <= usq_w - dc_est;
            ucu_q    <= ucu_cl;
            x_d2     <= x_d1;

            // ---- S3: scale harm <<1, sum, saturate, bypass -----------------
            data_out  <= voicing_en ? sat48(x_ext + (h_ext <<< 1))
                                    : x_d2;          // 0-LSB bypass
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
