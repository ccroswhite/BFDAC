`timescale 1ns / 1ps

// Mute/output relay controller — three-tier mute model (ruling 2026-11-15):
//
//   (a) no stream / stream stops  -> digital clamp (force_zero) + volume 0
//   (b) user mute                 -> same digital path
//   (c) system not ready / unsafe -> line XLR relay physically disconnects
//
// Relay transitions are AUDIBLE (mechanical click), so the relay must not
// cycle during normal operation. It energizes exactly once at power-up when
// sys_ready (clocks locked + pg_all) and stays closed for the session. Mid-
// session it opens ONLY on:
//   - !sys_ready  (extreme power/clock error — pg_all loss or unlock)
//   - test_active (cell-test / bench mode — factory/calibration path; the
//                  test requires the XLR output isolated from the amplifier)
// Every other mute event (i2s_err, rate change, unmute=0, stream stop) is
// handled by the digital clamp — no clicks on dropped USB connections,
// format changes, or level changes.
//
// LEVEL (bom 7 ruling 2026-10-07: DIGITAL, K1/K2 relays struck): the level
// code is a digital gain cap applied in the DSP volume stage (top:
// level_gain LUT x boot_envelope_gain). It may only change while clamped
// (ST_SWITCHING below), so a 10-30 dB gain step never reaches the output.
// The 'relay' naming is kept for the port map; relay_level pins are
// no-connects on the board.
//   level code: 000 = 2 Vrms, 001 = 4 Vrms, 010 = 6 Vrms, 011 = 0.6 Vrms,
//               100 = 0.2 Vrms (others reserved -> treated as 2 V in top)
// Pending is derived from (target != applied) rather than from the req
// pulse: the target is quasi-static, so no single-cycle pulse has to
// survive the clk_200m -> dsp_clk crossing, and a LEVEL write made while
// muted is not lost. The level registers reset only on rst_n (NOT on mute /
// i2s_err / rate change) so the applied level is never silently reverted.
module automute_controller #(
    // Defaults provide at least the requested wall time at 302.474 MHz, the
    // faster family DSP clock. Simulation may override these parameters.
    parameter logic [27:0] FLUSH_CYCLES  = 28'd15_125_000,  // ~50ms pipeline drain
    parameter logic [27:0] SETTLE_CYCLES = 28'd3_025_000,   // ~10ms contact settle
    parameter logic [27:0] SWITCH_CYCLES = 28'd3_025_000    // ~10ms level-apply window
)(
    input  logic clk,           // audio-family DSP clock (277.898/302.474 MHz)
    input  logic rst_n,

    // Control Plane
    input  logic sys_ready,     // 1 = clocks locked + pg_all (safe to expose XLR)
    input  logic test_active,   // 1 = cell-test/bench active -> open relay (isolation)
    input  logic unmute_req,    // digital unmute request (stream-gated in top)
    input  logic base_rate_sel,
    input  logic i2s_err,
    input  logic level_switch_req,   // legacy pulse, unused (pending = target != applied)
    input  logic [2:0] level_target, // level code, see header (quasi-static, 2-FF synced)

    // Hardware Plane
    output logic line_mute_drive,    // Line XLR mute relay (energized = connected)
    output logic [2:0] level_relay_drive, // applied level code (digital gain cap select)
    output logic force_zero,         // 1 = Clamp audio to 0, 0 = Allow live audio
    output logic switch_busy         // 1 while a transition sequence is in progress
);

    typedef enum logic [2:0] {
        ST_OPEN,        // relay open (startup / hard fault / test isolation)
        ST_SETTLING,    // relay energizing, contacts bouncing
        ST_ARMED,       // relay closed, output digitally muted (armed)
        ST_FLUSHING,    // unmute requested: pipeline drains while clamped
        ST_PLAYING,     // audio flows
        ST_SWITCHING,   // level cap applies here while clamped
        ST_LVL_SETTLE   // analog settle after level change
    } state_t;
    state_t state;

    logic [27:0] timer;
    logic        rate_sel_q;
    logic        rate_changed;
    logic        level_switch_pending;
    logic [2:0]  level_target_q1, level_target_q2;
    logic [2:0]  level_relay_int;

    // Level state: reset only on rst_n. The synced target must be stable for
    // two cycles before it counts (multi-bit CDC: bits may land a cycle apart).
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            level_target_q1 <= 3'b000;
            level_target_q2 <= 3'b000;
            level_relay_int <= 3'b000;
        end else begin
            level_target_q1 <= level_target;
            level_target_q2 <= level_target_q1;
            if (state == ST_SWITCHING && level_switch_pending)
                level_relay_int <= level_target_q2;
        end
    end
    assign level_switch_pending = (level_target_q1 == level_target_q2) &&
                                  (level_target_q2 != level_relay_int);

    always_ff @(posedge clk) begin
        if (!rst_n) rate_sel_q <= 1'b0;
        else        rate_sel_q <= base_rate_sel;
    end
    assign rate_changed = (base_rate_sel ^ rate_sel_q);

    always_ff @(posedge clk) begin
        if (!rst_n || !sys_ready || test_active) begin
            // Hard path: output physically disconnected. Relay drops on power/
            // clock loss and on factory test entry — the ONLY mid-session
            // relay opens (ruling 2026-11-15).
            state           <= ST_OPEN;
            timer           <= '0;
            line_mute_drive <= 1'b0;
            force_zero      <= 1'b1;
        end else if (state != ST_OPEN && state != ST_SETTLING &&
                     (i2s_err || rate_changed || !unmute_req)) begin
            // Digital mute ONLY — the relay stays closed (no click). Every
            // runtime mute event lands here.
            state           <= ST_ARMED;
            timer           <= '0;
            line_mute_drive <= 1'b1;
            force_zero      <= 1'b1;
        end else begin
            case (state)
                ST_OPEN: begin
                    // sys_ready && !test_active already true past the outer gate:
                    // energize the relay once — the single startup click.
                    line_mute_drive <= 1'b0;
                    force_zero      <= 1'b1;
                    state <= ST_SETTLING;
                    timer <= '0;
                end

                ST_SETTLING: begin
                    // Relay energized, contacts bouncing; audio still clamped.
                    line_mute_drive <= 1'b1;
                    force_zero      <= 1'b1;
                    if (timer < SETTLE_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_ARMED;
                        timer <= '0;
                    end
                end

                ST_ARMED: begin
                    // Armed: XLR connected but output digitally muted.
                    line_mute_drive <= 1'b1;
                    force_zero      <= 1'b1;
                    if (level_switch_pending) begin
                        state <= ST_SWITCHING;
                        timer <= '0;
                    end else if (unmute_req) begin
                        state <= ST_FLUSHING;
                        timer <= '0;
                    end
                end

                ST_FLUSHING: begin
                    // Unmute requested: let the pipeline drain while clamped.
                    if (timer < FLUSH_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_PLAYING;
                        timer <= '0;
                    end
                end

                ST_PLAYING: begin
                    line_mute_drive <= 1'b1;
                    force_zero      <= 1'b0; // Audio flows
                    if (level_switch_pending) begin
                        state <= ST_SWITCHING;
                        timer <= '0;
                    end
                end

                ST_SWITCHING: begin
                    // Level cap applies here (level block above) while clamped
                    // — the only place it ever changes.
                    force_zero <= 1'b1;
                    if (timer < SWITCH_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_LVL_SETTLE;
                        timer <= '0;
                    end
                end

                ST_LVL_SETTLE: begin
                    // Analog settle after the gain-cap step, then resume.
                    force_zero <= 1'b1;
                    if (timer < SETTLE_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= unmute_req ? ST_PLAYING : ST_ARMED;
                        timer <= '0;
                    end
                end
            endcase
        end
    end

    assign level_relay_drive = level_relay_int;
    assign switch_busy       = (state == ST_SETTLING)   ||
                               (state == ST_FLUSHING)   ||
                               (state == ST_SWITCHING)  ||
                               (state == ST_LVL_SETTLE);

endmodule
