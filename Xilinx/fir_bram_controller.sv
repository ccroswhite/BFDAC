`timescale 1ns / 1ps

module fir_bram_controller (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start_processing,
    output logic        enable_systolic,
    output logic [12:0] addr_A,
    output logic [12:0] addr_B
);

    logic [12:0] local_idx;
    logic        running;
    logic        enable_pipe [0:4]; // 5-stage pipeline

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            local_idx <= '0;
            running   <= 1'b0;
            addr_A    <= '0;
            addr_B    <= '0;
            enable_systolic <= 1'b0;
            for (int i=0; i<5; i++) enable_pipe[i] <= 1'b0;
        end else begin
            
            // Trigger the state machine
            if (start_processing) running <= 1'b1;

            // =================================-------------------------------
            // STAGE 0: The 8,100 Linear Counter
            // =================================-------------------------------
            // 100 cycles * 81 phases perfectly maps to a linear 0 -> 8099 sequence
            if (running) begin
                if (local_idx == 13'd8099) local_idx <= '0;
                else local_idx <= local_idx + 1'b1;
            end

            // =================================-------------------------------
            // STAGE 1: Dual-Port Address Assignment
            // =================================-------------------------------
            addr_A <= local_idx;
            addr_B <= 13'd8099 - local_idx; // Port B reads the mirror image
            
            enable_pipe[0] <= running;

            // =================================-------------------------------
            // STAGE 2 to 4: Match 2-stage Address Fanout + 2-cycle BRAM Latency
            // =================================-------------------------------
            enable_pipe[1] <= enable_pipe[0];
            enable_pipe[2] <= enable_pipe[1];
            enable_pipe[3] <= enable_pipe[2];
            enable_pipe[4] <= enable_pipe[3];
            
            enable_systolic <= enable_pipe[4];
        end
    end
endmodule