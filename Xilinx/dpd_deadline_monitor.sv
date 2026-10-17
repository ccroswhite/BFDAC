`timescale 1ns / 1ps

// Tracks one outstanding error-feedback correction through its actual
// consumption boundary: the next Stage-A sample enable.
module dpd_deadline_monitor (
    input  logic clk,
    input  logic rst_n,
    input  logic dpd_enabled,
    input  logic sample_advance,
    input  logic result_started,
    input  logic correction_applied,
    output logic deadline_miss
);
    logic correction_pending;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            correction_pending <= 1'b0;
            deadline_miss <= 1'b0;
        end else if (!dpd_enabled) begin
            correction_pending <= 1'b0;
        end else begin
            if (sample_advance && correction_pending)
                deadline_miss <= 1'b1;
            if (correction_applied)
                correction_pending <= 1'b0;
            if (result_started)
                correction_pending <= 1'b1;
        end
    end
endmodule
