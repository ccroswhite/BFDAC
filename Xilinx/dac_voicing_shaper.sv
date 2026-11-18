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
//       dc_est += (u_sq - dc_est) >>> 16      (~1.9 Hz corner @ 705.6 kHz,
//                                              ~1.8 Hz @ 768 kHz)
//   This strips the k2*A^2/2 DC shift so voiced content cannot inject DC
//   into the downstream noise shaper / DEM headroom.
//
// Harmonic targets (A = 1 FS sine):
//   H2 = k2/2   ->  k2 = +2.0e-3  ->  H2 = -60 dBc
//   H3 = k3/4   ->  k3 = -8.0e-5  ->  H3 = -94 dBc
//
// Formats:
//   data_in/data_out : signed 48-bit, full scale = 2^41
//   u                : Q2.25 (27b), data_in[42:16]  ->  4x FS headroom
//   u_sq, u_cu       : Q3.15 signed (18b)  (u^2 can exceed 1.0 w/ overshoot)
//   k2, k3           : Q2.25 signed (27b, DSP48E2 A-port)
//                      k2=+2.0e-3 -> 27'sd67109 ; k3=-8.0e-5 -> -27'sd2684
//
// Pipeline: 6 in_valid-spaced stages, ~5 sample latency.  All datapath regs
// are in_valid-gated (samples are >>8 dsp_clk apart; saves power and gives
// per-sample recursion semantics for the DC tracker).  out_valid is the
// in_valid strobe delayed one clock; output data changes ON the strobe edge,
// so downstream halfband_x2 sees identical sample spacing.
// DSP48E2 estimate: 5/channel (27x27 u^2 = 2, 18x27 u^3 = 1, 2x k-mults).
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

    // Stage registers
    logic signed [26:0] u1;                     // Q2.25
    logic signed [47:0] x_d1, x_d2, x_d3, x_d4, x_d5;

    logic signed [53:0] usq_full;               // Q4.50
    logic signed [26:0] u1_d;                   // u delayed to S3

    logic signed [17+DC_SHIFT:0] dc_acc;        // dc_est + DC_SHIFT sub-LSB bits
    logic signed [17:0] usq_ac;                 // u_sq - dc_est, Q3.15
    logic signed [44:0] ucu_full;               // Q5.40

    logic signed [17:0] ucu_q;                  // Q3.15 (ucu_full[42:25])
    logic signed [17:0] usq_ac_d;               // Q3.15 to S5

    logic signed [45:0] harm_sum;               // Q5.40 = k2*usq_ac + k3*ucu

    // Saturating 48-bit result
    function automatic logic signed [47:0] sat48(input logic signed [48:0] s);
        if (s > 49'sh0_7FFF_FFFF_FFFF)
            return 48'sh7FFF_FFFF_FFFF;
        else if (s < -49'sh0_8000_0000_0000)
            return -48'sh8000_0000_0000;
        else
            return s[47:0];
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            u1        <= '0;
            x_d1      <= '0;  x_d2 <= '0;  x_d3 <= '0;  x_d4 <= '0;  x_d5 <= '0;
            usq_full  <= '0;
            u1_d      <= '0;
            dc_acc    <= '0;
            usq_ac    <= '0;
            ucu_full  <= '0;
            ucu_q     <= '0;
            usq_ac_d  <= '0;
            harm_sum  <= '0;
            out_valid <= 1'b0;
            data_out  <= '0;
        end else if (in_valid) begin
            // ---- S1: normalize (FS=2^41 -> Q2.25 at bits [42:16]) ---------
            u1   <= data_in[42:16];
            x_d1 <= data_in;

            // ---- S2: u^2 (27x27 -> Q4.50), hold u -------------------------
            usq_full <= u1 * u1;
            u1_d     <= u1;
            x_d2     <= x_d1;

            // ---- S3: DC tracker + u^3 -------------------------------------
            // DC tracker: dc_acc carries DC_SHIFT fractional bits below the
            // Q3.15 LSB, so the 1/2^DC_SHIFT-per-sample update has no dead zone.
            dc_acc   <= dc_acc + ($signed(usq_full[52:35])
                                  - dc_acc[17+DC_SHIFT:DC_SHIFT]);
            usq_ac   <= $signed(usq_full[52:35])
                        - dc_acc[17+DC_SHIFT:DC_SHIFT];            // Q3.15
            ucu_full <= usq_full[52:35] * u1_d;                // Q5.40
            x_d3     <= x_d2;

            // ---- S4: slice u^3, hold AC u^2 -------------------------------
            ucu_q    <= ucu_full[42:25];                       // Q3.15
            usq_ac_d <= usq_ac;
            x_d4     <= x_d3;

            // ---- S5: k-mults + sum (registered into DSP48E2) --------------
            harm_sum <= k2 * usq_ac_d + k3 * ucu_q;            // 46b Q5.40
            x_d5     <= x_d4;

            // ---- S6: scale to data domain (raw<<1), sum, sat, bypass ------
            data_out  <= voicing_en
                         ? sat48(x_d5 + $signed({harm_sum[44:0], 1'b0}))
                         : x_d5;          // 0-LSB bypass
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
