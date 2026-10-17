`timescale 1ns / 1ps

// Control-domain transaction: rate_code={log2(native/base), family48}.
// The command bus remains stable until ack_toggle matches req_toggle.
module stream_rate_controller #(
    parameter int MUTE_CYCLES = 4000000,
    parameter int SETTLE_CYCLES = 2048,
    parameter int STARTUP_CYCLES = 4096
) (
    input logic clk, rst_n, clk_locked,
    input logic [2:0] requested_rate,
    input logic req_toggle,
    output logic ack_toggle,
    output logic [2:0] applied_rate,
    output logic busy, ready, mmcm_rst, path_reset, clk_sel, serial_enable
);
    typedef enum logic [2:0] {MUTE_WAIT, RESET_CLOCK, SETTLE, LOCK_WAIT, STARTUP, RUN} state_t;
    state_t state;
    logic [31:0] timer;
    logic [2:0] target;
    logic request_epoch;
    (* ASYNC_REG = "TRUE" *) logic [1:0] lock_sync;

    assign busy = state != RUN || req_toggle != ack_toggle;
    assign ready = state == RUN && lock_sync[1] && !busy;
    // Carrier hardware: low enables 49.152MHz, high enables 45.1584MHz.
    assign clk_sel = ~applied_rate[0];
    assign mmcm_rst = state == RESET_CLOCK || state == SETTLE;
    assign path_reset = state == RESET_CLOCK || state == SETTLE || state == LOCK_WAIT;
    assign serial_enable = state == RUN || state == MUTE_WAIT;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= RESET_CLOCK;
            timer <= 0;
            target <= 0;
            applied_rate <= 0;
            request_epoch <= 0;
            ack_toggle <= 0;
            lock_sync <= 0;
        end else begin
            lock_sync <= {lock_sync[0], clk_locked};
            case (state)
                RUN: begin
                    if (req_toggle != ack_toggle) begin
                        target <= requested_rate;
                        request_epoch <= req_toggle;
                        timer <= MUTE_CYCLES - 1;
                        state <= MUTE_WAIT;
                    end else if (!lock_sync[1]) begin
                        target <= applied_rate;
                        timer <= MUTE_CYCLES - 1;
                        state <= MUTE_WAIT;
                    end
                end
                MUTE_WAIT: if (timer == 0) state <= RESET_CLOCK;
                           else timer <= timer - 1;
                RESET_CLOCK: begin
                    applied_rate <= target;
                    timer <= SETTLE_CYCLES - 1;
                    state <= SETTLE;
                end
                SETTLE: if (timer == 0) state <= LOCK_WAIT;
                        else timer <= timer - 1;
                LOCK_WAIT: if (lock_sync[1]) begin
                    timer <= STARTUP_CYCLES - 1;
                    state <= STARTUP;
                end
                STARTUP: begin
                    if (!lock_sync[1]) state <= LOCK_WAIT;
                    else if (timer == 0) begin
                        ack_toggle <= request_epoch;
                        state <= RUN;
                    end else timer <= timer - 1;
                end
                default: state <= RESET_CLOCK;
            endcase
        end
    end
endmodule
