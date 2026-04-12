`timescale 1ns / 1ps

module fir_polyphase_interpolator #(
    parameter int NUM_MACS   = 256,
    parameter int DATA_WIDTH = 32,
    parameter int COEF_WIDTH = 18, 
    parameter int ACC_WIDTH  = 64
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // 44.1kHz Input
    input  logic                                 new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]         new_sample_data,

    // 705.6kHz Output (16x Oversampled)
    output logic signed [ACC_WIDTH-1:0]          interpolated_out,
    output logic                                 interpolated_valid
);

    // =================================---------------------------------------
    // 1. The 2048-Cycle State Machine (The Time Lord)
    // =================================---------------------------------------
    logic [10:0] master_coef_addr; // 0 to 2047
    logic [3:0]  phase_counter;    // 0 to 15
    logic [6:0]  tap_counter;      // 0 to 127
    logic        phase_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            master_coef_addr <= '0;
            phase_counter    <= '0;
            tap_counter      <= '0;
            phase_sync       <= 1'b0;
            interpolated_valid <= 1'b0;
        end else begin
            interpolated_valid <= 1'b0;
            phase_sync         <= 1'b0;

            if (new_sample_valid) begin
                // Reset the engine precisely when a new 44.1kHz baseband sample arrives
                master_coef_addr <= '0;
                phase_counter    <= '0;
                tap_counter      <= '0;
            end else begin
                master_coef_addr <= master_coef_addr + 11'b1;
                tap_counter      <= tap_counter + 7'b1;
                
                // Every 128 cycles, a phase finishes
                if (tap_counter == 7'd127) begin
                    phase_sync <= 1'b1;
                    phase_counter <= phase_counter + 4'b1;
                    
                    // The systolic chain drops the final 64-bit word out of MAC 255
                    interpolated_valid <= 1'b1;
                end
            end
        end
    end

    // =================================---------------------------------------
    // 2. The Baseband Audio Memory (The Folded U-Shape)
    // =================================---------------------------------------
    // We need 65,536 audio samples. 
    // We use a dual-port BRAM configured as a circular buffer.
    logic [15:0] write_ptr;
    logic [15:0] read_fwd_ptr;
    logic [15:0] read_rev_ptr;
    
    logic signed [DATA_WIDTH-1:0] audio_bram [0:65535];
    logic signed [DATA_WIDTH-1:0] fwd_seed, rev_seed;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_ptr <= '0;
        end else if (new_sample_valid) begin
            audio_bram[write_ptr] <= new_sample_data;
            write_ptr <= write_ptr + 16'b1;
        end
    end

    // The Forward line reads from the "New" end, walking backward in time.
    // The Reverse line reads from the "Old" end, walking forward in time.
    always_ff @(posedge clk) begin
        // Pointer logic requires wrapping bounds handling in production
        read_fwd_ptr <= write_ptr - 16'b1 - master_coef_addr;
        read_rev_ptr <= write_ptr - 16'd65536 + master_coef_addr;
        
        fwd_seed <= audio_bram[read_fwd_ptr];
        rev_seed <= audio_bram[read_rev_ptr];
    end

    // =================================---------------------------------------
    // 3. Array Interconnect Routing
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] cascade_fwd [0:NUM_MACS];
    logic signed [DATA_WIDTH-1:0] cascade_rev [0:NUM_MACS];
    logic signed [ACC_WIDTH-1:0]  cascade_acc [0:NUM_MACS];

    assign cascade_fwd[0] = fwd_seed;
    assign cascade_rev[0] = rev_seed;
    assign cascade_acc[0] = '0;

    // =================================---------------------------------------
    // 4. The 256-Engine Polyphase Instantiation
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac
            polyphase_mac_engine #(
                .DATA_WIDTH(DATA_WIDTH),
                .COEF_WIDTH(COEF_WIDTH),
                .ACC_WIDTH (ACC_WIDTH),
                .MAC_ID    (i)
            ) u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                
                .phase_sync   (phase_sync),
                .coef_addr    (master_coef_addr),
                
                .audio_fwd_in (cascade_fwd[i]),
                .audio_rev_in (cascade_rev[i]),
                .audio_fwd_out(cascade_fwd[i+1]),
                .audio_rev_out(cascade_rev[i+1]),
                
                .acc_in       (cascade_acc[i]),
                .acc_out      (cascade_acc[i+1])
            );
        end
    endgenerate

    assign interpolated_out = cascade_acc[NUM_MACS];

endmodule