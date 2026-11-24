`timescale 1ns / 1ps

module bench_test_stimulus (
    input logic clk, rst_n, tick, allowed,
    input logic [10:0] cmd,
    input logic req,
    output logic ack,
    output logic [10:0] applied,
    output logic signed [47:0] sample_l, sample_r
);
    (* ASYNC_REG = "TRUE" *) logic req_meta, req_sync;
    logic [31:0] phase, phase_increment;
    logic signed [15:0] sine_rom [1024];
    logic signed [15:0] sine_q;
    logic signed [47:0] sample_value;
    localparam logic [31:0] INC_48 = (64'd4294967296000 + 3072000) / 6144000;
    localparam logic [31:0] INC_44 = (64'd4294967296000 + 2822400) / 5644800;

    initial begin
        for (int i = 0; i < 1024; i++)
            sine_rom[i] = $rtoi(32767.0 * $sin(6.283185307179586 * i / 1024.0));
    end

    always_comb begin
        sample_value = 0;
        if (applied[1:0] == 2) begin
            case (applied[9:3])
                1: sample_value = 48'sd1 <<< 42;
                2: sample_value = -(48'sd1 <<< 42);
                3: sample_value = 48'sd4 <<< 42;
                4: sample_value = -(48'sd4 <<< 42);
                default: sample_value = 0;
            endcase
        end else if (applied[1:0] == 3)
            sample_value = 48'($signed(sine_q)) <<< 29;
        sample_l = applied[2] ? 48'sd0 : sample_value;
        sample_r = applied[2] ? sample_value : 48'sd0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_meta <= 0;
            req_sync <= 0;
            ack <= 0;
            applied <= 0;
            phase <= 0;
            phase_increment <= 0;
            sine_q <= 0;
        end else begin
            req_meta <= req;
            req_sync <= req_meta;
            sine_q <= sine_rom[phase[31:22]];
            if (!allowed) applied <= 0;
            // Acknowledge on dsp_clk, not pace_tick: a req arriving while the
            // audio pace domain is stopped (stream teardown / clock fault)
            // must still complete the 4-phase handshake, or u_bench_ctrl
            // wedges in SEND and its bench_busy blocks stream restart.
            if (!req_sync) begin
                ack <= 0;
            end else if (!ack) begin
                if (allowed && ((cmd[1:0] == 1) ||
                    (cmd[1:0] == 2 && cmd[9:3] <= 4) ||
                    (cmd[1:0] == 3 && cmd[9:3] <= 19)))
                    applied <= cmd;
                else applied <= 0;
                phase <= 0;
                // INC_* < 2^20 and valid cmds have cmd[9:3] <= 19, so a
                // 20x6 product suffices — avoids a wide DSP48E2 multiplier.
                phase_increment <= (cmd[10] ? INC_48 : INC_44) * (6'(cmd[7:3]) + 6'd1);
                ack <= 1;
            end
            if (tick && !(req_sync && !ack))
                phase <= phase + phase_increment;
        end
    end
endmodule
