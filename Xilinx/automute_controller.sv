`timescale 1ns / 1ps

// Relay sequencer per schematic Fig. 4d:
//   mute -> switch select + rails -> settle -> unmute
// De-energized = muted everywhere (line mute open+shunt, HP jack shorted).
// Level taps (2/4/6 Vrms) and output select (line XLR / headphone) are only
// ever switched while both mute relays are open and audio is force-zeroed,
// so contacts never make/break current.
module automute_controller #(
    // Timings at 90MHz (overridable for simulation)
    parameter logic [25:0] FLUSH_CYCLES       = 26'd4_500_000,  // 50ms pipeline drain
    parameter logic [25:0] SETTLE_CYCLES      = 26'd900_000,    // 10ms contact settle
    parameter logic [25:0] SWITCH_CYCLES      = 26'd900_000,    // 10ms select/level relays
    parameter logic [25:0] RAIL_SETTLE_CYCLES = 26'd45_000_000  // 500ms HP rails + bias settle
)(
    input  logic clk,           // 90MHz DSP Clock
    input  logic rst_n,
    
    // Control Plane
    input  logic spi_unmute,
    input  logic base_rate_sel,
    input  logic i2s_err,
    input  logic level_switch_req,   // Pulse: request level tap relay switch
    input  logic [1:0] level_target, // 00 = 2 Vrms, 01 = 4 Vrms, 10 = 6 Vrms
    input  logic outsel_switch_req,  // Pulse: request output select switch
    input  logic outsel_target,      // 0 = line XLR (rear), 1 = headphone (front)

    // Hardware Plane
    output logic line_mute_drive,    // Line XLR mute relay (energized = unmuted)
    output logic hp_mute_drive,      // HP jack mute relay (energized = jack live)
    output logic hp_rails_drive,     // HP stage rail relay (energized = HP powered)
    output logic [1:0] level_relay_drive, // 00 = 2V tap, 01 = 4V tap, 10 = 6V tap
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

    logic [25:0] timer;
    logic        rate_sel_q;
    logic        rate_changed;
    logic        level_switch_pending;
    logic [1:0]  level_target_q;
    logic        outsel_switch_pending;
    logic        outsel_target_q;
    logic        outsel_active;          // Currently selected output
    logic        rails_changed;          // HP rails toggled this pass -> long settle
    logic [1:0]  level_relay_int;

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
            level_switch_pending  <= 1'b0;
            level_target_q        <= 2'b00;
            outsel_switch_pending <= 1'b0;
            outsel_target_q       <= 1'b0;
            outsel_active         <= 1'b0;   // line output is the cold-start default
            rails_changed         <= 1'b0;
            level_relay_int       <= 2'b00;
        end else begin
            if (level_switch_req) begin
                level_switch_pending <= 1'b1;
                level_target_q       <= level_target;
            end
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
                    // Apply level taps + output select + HP rails while everything
                    // is muted. This is the only place these relays ever move.
                    if (level_switch_pending) begin
                        level_relay_int      <= level_target_q;
                        level_switch_pending <= 1'b0;
                    end
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
    assign switch_busy       = (state != ST_PLAYING);

endmodule