`timescale 1ns / 1ps

module automute_controller (
    input  logic clk,           // 90MHz DSP Clock
    input  logic rst_n,
    
    // Control Plane
    input  logic spi_unmute,    
    input  logic base_rate_sel, 
    input  logic i2s_err,       

    // Hardware Plane
    output logic relay_drive,   
    output logic force_zero     // 1 = Clamp audio to 0, 0 = Allow live audio
);

    // Timings at 90MHz
    localparam logic [22:0] FLUSH_CYCLES  = 23'd4_500_000; // 50ms
    localparam logic [19:0] SETTLE_CYCLES = 20'd900_000;   // 10ms

    typedef enum logic [1:0] {
        ST_MUTED,
        ST_FLUSHING,
        ST_SETTLING,
        ST_PLAYING
    } state_t;
    state_t state;

    logic [22:0] timer;
    logic        rate_sel_q;
    logic        rate_changed;

    always_ff @(posedge clk) begin
        if (!rst_n) rate_sel_q <= 1'b0;
        else        rate_sel_q <= base_rate_sel;
    end
    assign rate_changed = (base_rate_sel ^ rate_sel_q);

    always_ff @(posedge clk) begin
        if (!rst_n || i2s_err || rate_changed || !spi_unmute) begin
            state       <= ST_MUTED;
            timer       <= '0;
            relay_drive <= 1'b0; 
            force_zero  <= 1'b1; 
        end else begin
            case (state)
                ST_MUTED: begin
                    state <= ST_FLUSHING;
                    timer <= '0;
                end

                ST_FLUSHING: begin
                    relay_drive <= 1'b0;
                    force_zero  <= 1'b1;
                    if (timer < FLUSH_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_SETTLING;
                        timer <= '0;
                    end
                end

                ST_SETTLING: begin
                    relay_drive <= 1'b1; // Energize relay coil
                    force_zero  <= 1'b1; // Keep audio clamped while contacts bounce
                    if (timer < SETTLE_CYCLES) begin
                        timer <= timer + 1'b1;
                    end else begin
                        state <= ST_PLAYING;
                    end
                end

                ST_PLAYING: begin
                    relay_drive <= 1'b1;
                    force_zero  <= 1'b0; // Audio flows
                end
            endcase
        end
    end

endmodule