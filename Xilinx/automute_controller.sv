`timescale 1ns / 1ps

// Relay sequencer per schematic Fig. 4d:
//   mute -> switch select + rails -> settle -> unmute
// De-energized = muted everywhere (line mute open+shunt, HP jack shorted).
// Output select (line XLR / headphone) is only ever switched while both mute
// relays are open and audio is force-zeroed, so contacts never make/break
// current.
// LEVEL (bom 7 ruling 2026-10-07: DIGITAL, K1/K2 relays struck): the level
// code is no longer a relay tap but a digital gain cap applied in the DSP
// volume stage (top: level_gain LUT x boot_envelope_gain). It is still only
// changed here, in ST_SWITCHING, while muted and force-zeroed, so a 10-30 dB
// gain step never reaches the output as a click. The 'relay' naming is kept
// for the port map; relay_level pins are no-connects on the board.
//   level code: 000 = 2 Vrms, 001 = 4 Vrms, 010 = 6 Vrms, 011 = 0.6 Vrms,
//               100 = 0.2 Vrms (others reserved -> treated as 2 V in top)
// Pending is derived from (target != applied) rather than from the req
// pulse: the target is quasi-static, so no single-cycle pulse has to survive
// the clk_200m -> dsp_clk crossing, and a LEVEL write made while muted is
// not lost. The level registers reset only on rst_n (NOT on mute / i2s_err /
// rate change) so the applied level is never silently reverted to 2 V.
module automute_controller #(
    // Defaults provide at least the requested wall time at 302.474 MHz, the
    // faster family DSP clock. Simulation may override these parameters.
    parameter logic [27:0] FLUSH_CYCLES       = 28'd15_125_000,  // ~50ms pipeline drain
    parameter logic [27:0] SETTLE_CYCLES      = 28'd3_025_000,   // ~10ms contact settle
    parameter logic [27:0] SWITCH_CYCLES      = 28'd3_025_000,   // ~10ms relay transition
    parameter logic [27:0] RAIL_SETTLE_CYCLES = 28'd151_250_000  // ~500ms HP rails + bias settle
)(
    input  logic clk,           // audio-family DSP clock (277.898/302.474 MHz)
    input  logic rst_n,
    
    // Control Plane
    input  logic spi_unmute,
    input  logic base_rate_sel,
    input  logic i2s_err,
    input  logic level_switch_req,   // legacy pulse, unused (pending = target != applied)
    input  logic [2:0] level_target, // level code, see header (quasi-static, 2-FF synced)
    input  logic outsel_switch_req,  // Pulse: request output select switch
    input  logic outsel_target,      // 0 = line XLR (rear), 1 = headphone (front)

    // Hardware Plane
    output logic line_mute_drive,    // Line XLR mute relay (energized = unmuted)
    output logic hp_mute_drive,      // HP jack mute relay (energized = jack live)
    output logic hp_rails_drive,     // HP stage rail relay (energized = HP powered)
    output logic [2:0] level_relay_drive, // applied level code (digital gain cap select)
    output logic force_zero,         // 1 = Clamp audio to 0, 0 = Allow live audio
    output logic switch_busy         // 1 while any relay sequence is in progress
);

    typedef enum logic [2:0] {
        ST_MUTED,
        ST_FLUSHING,
        ST_SWITCHING,
        ST_RAIL_SETTLING,
        ST_SETTLING,
        ST_PLAYING
    } state_t;
    state_t state;

    logic [27:0] timer;
    logic        rate_sel_q;
    logic        rate_changed;
    logic        level_switch_pending;
    logic [2:0]  level_target_q1, level_target_q2;
    logic        outsel_switch_pending;
    logic        outsel_target_q;
    logic        outsel_active;          // Currently selected output
    logic        rails_changed;          // HP rails toggled this pass -> long settle
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
        if (!rst_n || i2s_err || rate_changed || !spi_unmute) begin
            state                 <= ST_MUTED;
            timer                 <= '0;
            line_mute_drive       <= 1'b0;   // de-energized = muted (open+shunt)
            hp_mute_drive         <= 1'b0;   // de-energized = jack shorted
            hp_rails_drive        <= 1'b0;   // de-energized = HP stage unpowered
            force_zero            <= 1'b1;
            outsel_switch_pending <= 1'b0;
            outsel_target_q       <= 1'b0;
            outsel_active         <= 1'b0;   // line output is the cold-start default
            rails_changed         <= 1'b0;
        end else begin
            if (outsel_switch_req) begin
                outsel_switch_pending <= 1'b1;
                outsel_target_q       <= outsel_target;
            end

            case (state)
                ST_MUTED: begin
                    line_mute_drive <= 1'b0;
                    hp_mute_drive   <= 1'b0;
                    force_zero      <= 1'b1;
                    state <= ST_FLUSHING;
                    timer <= '0;
                end

                ST_FLUSHING: begin
                    // Both mute relays open, audio clamped, pipeline drains.
                    if (timer < FLUSH_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_SWITCHING;
                        timer <= '0;
                    end
                end

                ST_SWITCHING: begin
                    // Apply output select + HP rails (and, in the level block
                    // above, the digital level cap) while everything is muted.
                    // This is the only place these ever change.
                    if (outsel_switch_pending) begin
                        rails_changed         <= (outsel_active != outsel_target_q);
                        outsel_active         <= outsel_target_q;
                        outsel_switch_pending <= 1'b0;
                    end
                    hp_rails_drive <= outsel_active; // follows select (updated next pass if changed)
                    if (timer < SWITCH_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= rails_changed ? ST_RAIL_SETTLING : ST_SETTLING;
                        timer <= '0;
                    end
                end

                ST_RAIL_SETTLING: begin
                    // HP rails toggled: wait for the stage bias (LED refs, 100uF
                    // bypass, class-A Idq) to reach operating point before the
                    // mute relay exposes the jack.
                    hp_rails_drive <= outsel_active;
                    if (timer < RAIL_SETTLE_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        rails_changed <= 1'b0;
                        state <= ST_SETTLING;
                        timer <= '0;
                    end
                end

                ST_SETTLING: begin
                    // Energize only the active branch's mute relay; audio still
                    // clamped while contacts bounce.
                    line_mute_drive <= ~outsel_active;
                    hp_mute_drive   <=  outsel_active;
                    force_zero      <= 1'b1;
                    if (timer < SETTLE_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_PLAYING;
                    end
                end

                ST_PLAYING: begin
                    line_mute_drive <= ~outsel_active;
                    hp_mute_drive   <=  outsel_active;
                    force_zero      <= 1'b0; // Audio flows
                    if (level_switch_pending || outsel_switch_pending) begin
                        state <= ST_MUTED;
                        timer <= '0;
                    end
                end
            endcase
        end
    end

    assign level_relay_drive = level_relay_int;
    assign switch_busy       = (state == ST_FLUSHING) ||
                               (state == ST_SWITCHING) ||
                               (state == ST_RAIL_SETTLING) ||
                               (state == ST_SETTLING);

endmodule