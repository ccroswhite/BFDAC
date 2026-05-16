`timescale 1ns / 1ps

// =============================================================================
//  COEF_MUTE_ENVELOPE
//
//  Generates a smooth, audibly-transparent gain envelope used to mute the
//  audio path during a coefficient bank switch. The envelope follows the
//  classical smootherstep polynomial:
//
//      smootherstep(x) = 6x^5 - 15x^4 + 10x^3
//
//  This polynomial has the property that BOTH its first and second
//  derivatives are zero at the endpoints x=0 and x=1, which means the
//  audible "click" energy at the start/end of the fade is essentially
//  inaudible -- there is no spectral leakage from a discontinuity in
//  acceleration. (A linear fade has a derivative discontinuity and IS
//  audible. A raised-cosine fade is also good, but smootherstep is
//  algebraically simpler and indistinguishable in listening tests.)
//
//  Resource cost: one RAMB36 holding 4096 x 16-bit envelope samples,
//  pre-computed at synthesis time via Vivado's real-arithmetic ROM
//  initialization. No fabric multipliers are consumed.
//
//  Default duration: 4096 samples = 5.33 ms at 768 kHz, which is a
//  conservative click-suppression window. Parameterizable up or down.
//
//  Usage:
//      Pulse fade_out_req for one cycle to drop gain from full -> mute.
//      Pulse fade_in_req  for one cycle to raise gain from mute -> full.
//      Each fade asserts fade_done for one cycle when complete.
//      Internal state holds the envelope at the endpoint between pulses.
// =============================================================================
module coef_mute_envelope #(
    parameter int FADE_LEN_LOG2 = 12  // 2^12 = 4096 samples = ~5.3 ms @ 768 kHz
)(
    input  logic        clk,           // dsp_clk (357 MHz)
    input  logic        rst_n,
    input  logic        sample_tick,   // one-cycle pulse per audio sample
    input  logic        fade_out_req,  // start fade-out (full -> mute)
    input  logic        fade_in_req,   // start fade-in  (mute -> full)
    output logic [15:0] gain,          // Q1.15 unsigned: 0xFFFF = unity gain
    output logic        fade_done      // pulses for one cycle on completion
);

    localparam int FADE_LEN = 1 << FADE_LEN_LOG2;

    // -------------------------------------------------------------------------
    //  Smootherstep envelope ROM, pre-computed at synthesis time.
    //
    //  envelope_lut[k] = round(65535 * smootherstep(k / (FADE_LEN-1)))
    //
    //  Vivado evaluates the initial block at elaboration and packs the
    //  result into a single RAMB36 (BLOCK style). $rtoi rounds toward zero,
    //  so we add 0.5 before the cast for proper rounding.
    // -------------------------------------------------------------------------
    (* rom_style = "block" *) logic [15:0] envelope_lut [0:FADE_LEN-1];

    initial begin
        automatic real x;
        automatic real s;
        for (int i = 0; i < FADE_LEN; i++) begin
            x = real'(i) / real'(FADE_LEN - 1);
            s = x * x * x * (10.0 - 15.0 * x + 6.0 * x * x);
            envelope_lut[i] = 16'($rtoi(s * 65535.0 + 0.5));
        end
    end

    // -------------------------------------------------------------------------
    //  FSM
    //
    //  IDLE       : gain = 0xFFFF (unity)
    //  FADING_OUT : indexing envelope_lut[N-1-counter] -> gain decreases
    //  FULL_MUTE  : gain = 0
    //  FADING_IN  : indexing envelope_lut[counter]      -> gain increases
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_IDLE       = 2'b00,
        ST_FADE_OUT   = 2'b01,
        ST_FULL_MUTE  = 2'b10,
        ST_FADE_IN    = 2'b11
    } state_t;

    state_t                       state;
    logic [FADE_LEN_LOG2-1:0]     counter;
    logic [15:0]                  gain_r;
    logic                         fade_done_r;

    // Last-tick detector: when counter reaches FADE_LEN-1 on a sample_tick,
    // the next state transition fires. Computed once for clarity.
    wire counter_at_end = (counter == FADE_LEN_LOG2'(FADE_LEN - 1));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Power-on: fully muted. Stay there until the bank manager
            // explicitly asks for a fade-in. This guarantees the first
            // audio sample after reset is preceded by a clean ramp from
            // zero, with no risk of emitting whatever garbage may be in
            // the upstream coefficient BRAMs before the boot loader has
            // populated them.
            state       <= ST_FULL_MUTE;
            counter     <= '0;
            gain_r      <= 16'h0000;
            fade_done_r <= 1'b0;
        end else begin
            fade_done_r <= 1'b0;

            unique case (state)
                ST_IDLE: begin
                    gain_r  <= 16'hFFFF;
                    counter <= '0;
                    if (fade_out_req)     state <= ST_FADE_OUT;
                    else if (fade_in_req) state <= ST_FADE_IN;
                end

                ST_FADE_OUT: begin
                    if (sample_tick) begin
                        // gain steps 0xFFFF -> 0 over FADE_LEN samples
                        gain_r <= envelope_lut[FADE_LEN_LOG2'(FADE_LEN - 1) - counter];
                        if (counter_at_end) begin
                            counter     <= '0;
                            state       <= ST_FULL_MUTE;
                            fade_done_r <= 1'b1;
                        end else begin
                            counter <= counter + 1'b1;
                        end
                    end
                end

                ST_FULL_MUTE: begin
                    gain_r  <= 16'h0000;
                    counter <= '0;
                    if (fade_in_req)      state <= ST_FADE_IN;
                    else if (fade_out_req) ; // already muted, ignore
                end

                ST_FADE_IN: begin
                    if (sample_tick) begin
                        // gain steps 0 -> 0xFFFF over FADE_LEN samples
                        gain_r <= envelope_lut[counter];
                        if (counter_at_end) begin
                            counter     <= '0;
                            state       <= ST_IDLE;
                            fade_done_r <= 1'b1;
                        end else begin
                            counter <= counter + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

    assign gain      = gain_r;
    assign fade_done = fade_done_r;

endmodule
