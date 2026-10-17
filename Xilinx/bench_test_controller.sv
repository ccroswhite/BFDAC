`timescale 1ns / 1ps

module bench_test_controller #(
    parameter int CLK_HZ = 200000000,
    parameter int DEBOUNCE_CYCLES = CLK_HZ / 100,
    parameter int SELECT_CYCLES = CLK_HZ * 3,
    parameter int CANCEL_CYCLES = CLK_HZ * 2
)(
    input logic clk, rst_n,
    input logic select_n, step_n,
    input logic available, ready, healthy, rate_48,
    input logic cmd_ack,
    output logic cmd_req,
    output logic [10:0] cmd,
    output logic busy, led,
    output logic [31:0] status
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] button_meta, button_sync;
    (* ASYNC_REG = "TRUE" *) logic ack_meta, ack_sync;
    logic [1:0] button_level, armed, press;
    logic [31:0] debounce_count [2], release_count [2];
    logic [31:0] hold_count;
    logic long_press, hold_reported;
    typedef enum logic [2:0] {IDLE, SELECTING, ARM, SEND, RELEASE_ACK, HOLD} state_t;
    state_t state;
    logic [2:0] selection;
    logic [31:0] selection_count, blink_count;
    logic cancel_pending, restart_pending;
    logic fault;
    logic [6:0] last_step;
    logic [31:0] half_period;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            button_meta <= 2'b11;
            button_sync <= 2'b11;
            button_level <= 2'b11;
            armed <= 0;
            press <= 0;
            debounce_count[0] <= 0;
            debounce_count[1] <= 0;
            release_count[0] <= 0;
            release_count[1] <= 0;
            hold_count <= 0;
            long_press <= 0;
            hold_reported <= 0;
            ack_meta <= 0;
            ack_sync <= 0;
        end else begin
            button_meta <= {step_n, select_n};
            button_sync <= button_meta;
            ack_meta <= cmd_ack;
            ack_sync <= ack_meta;
            press <= 0;
            long_press <= 0;
            for (int b = 0; b < 2; b++) begin
                if (!button_sync[b]) release_count[b] <= 0;
                else if (release_count[b] < DEBOUNCE_CYCLES) release_count[b] <= release_count[b] + 1;
                else armed[b] <= 1;
                if (button_sync[b] == button_level[b]) begin
                    debounce_count[b] <= 0;
                end else if (debounce_count[b] == DEBOUNCE_CYCLES - 1) begin
                    button_level[b] <= button_sync[b];
                    debounce_count[b] <= 0;
                    if (!button_sync[b] && armed[b]) press[b] <= 1;
                end else begin
                    debounce_count[b] <= debounce_count[b] + 1;
                end
            end
            if (button_level[0]) begin
                hold_count <= 0;
                hold_reported <= 0;
            end else if (!hold_reported) begin
                if (hold_count == CANCEL_CYCLES - 1) begin
                    long_press <= 1;
                    hold_reported <= 1;
                end else hold_count <= hold_count + 1;
            end
        end
    end

    always_comb begin
        case (cmd[1:0])
            1: begin last_step = 127; half_period = CLK_HZ / 2; end
            2: begin last_step = 4; half_period = CLK_HZ / 4; end
            3: begin last_step = 19; half_period = CLK_HZ / 6; end
            default: begin last_step = 0; half_period = CLK_HZ / 2; end
        endcase
        busy = state != IDLE;
        cmd_req = state == SEND;
        status = {11'd0, fault, cancel_pending, selection, state, cmd, led, busy};
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            cmd <= 0;
            selection <= 0;
            selection_count <= 0;
            cancel_pending <= 0;
            restart_pending <= 0;
            blink_count <= 0;
            led <= 0;
            fault <= 0;
        end else begin
            if (state != HOLD || !healthy || cancel_pending) begin
                blink_count <= 0;
                led <= 0;
            end else if (blink_count == half_period - 1) begin
                blink_count <= 0;
                led <= ~led;
            end else blink_count <= blink_count + 1;

            if (long_press && busy) begin
                cancel_pending <= 1;
                restart_pending <= 0;
            end
            if (busy && !available) begin
                cancel_pending <= 1;
                restart_pending <= 0;
                fault <= 1;
            end
            if ((state == HOLD || state == SEND || state == RELEASE_ACK) && !healthy) begin
                cancel_pending <= 1;
                restart_pending <= 0;
                fault <= 1;
            end
            case (state)
                IDLE: begin
                    cancel_pending <= 0;
                    restart_pending <= 0;
                    if (press[0] && available) begin
                        selection <= 1;
                        selection_count <= 0;
                        fault <= 0;
                        state <= SELECTING;
                    end
                end
                SELECTING: begin
                    if (cancel_pending || long_press) begin
                        cmd <= 0;
                        state <= SEND;
                    end else if (selection_count == SELECT_CYCLES - 1) begin
                        if (selection >= 1 && selection <= 3 && !press[0]) begin
                            cmd <= {rate_48, 7'd0, 1'b0, selection[1:0]};
                            state <= ARM;
                        end else begin
                            fault <= 1;
                            state <= IDLE;
                        end
                    end else begin
                        selection_count <= selection_count + 1;
                        if (press[0] && selection < 4) selection <= selection + 1;
                    end
                end
                ARM: begin
                    if (cancel_pending || long_press) begin
                        cmd <= 0;
                        state <= SEND;
                    end else if (ready && healthy) state <= SEND;
                end
                SEND: if (ack_sync) state <= RELEASE_ACK;
                RELEASE_ACK: if (!ack_sync) begin
                    if (cmd[1:0] != 0 && (cancel_pending || long_press || !healthy)) begin
                        cmd <= 0;
                        state <= SEND;
                    end else if (cmd[1:0] == 0) begin
                        cancel_pending <= 0;
                        if (restart_pending && !long_press && healthy) begin
                            restart_pending <= 0;
                            selection <= 1;
                            selection_count <= 0;
                            state <= SELECTING;
                        end else state <= IDLE;
                    end else begin
                        state <= HOLD;
                        led <= 1;
                        blink_count <= 0;
                    end
                end
                HOLD: begin
                    if (cancel_pending || long_press || !healthy || press[0]) begin
                        cmd <= 0;
                        restart_pending <= press[0] && !long_press && healthy && !cancel_pending;
                        state <= SEND;
                    end else if (press[1]) begin
                        if (cmd[9:3] == last_step) begin
                            if (cmd[2]) cmd <= 0;
                            else begin cmd[2] <= 1; cmd[9:3] <= 0; end
                        end else cmd[9:3] <= cmd[9:3] + 1;
                        state <= SEND;
                    end
                end
                default: begin cmd <= 0; state <= SEND; end
            endcase
        end
    end
endmodule
