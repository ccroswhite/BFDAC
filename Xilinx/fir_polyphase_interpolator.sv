`timescale 1ns / 1ps

module fir_polyphase_interpolator #(
    parameter int NUM_MACS   = 256,
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18, 
    parameter int ACC_WIDTH  = 48
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

    always_ff @(posedge clk) begin
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
                // Reset the engine precisely when a new baseband sample arrives
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
                    
                    // The systolic chain drops the final 48-bit word out of MAC 255
                    interpolated_valid <= 1'b1;
                end
            end
        end
    end

    // =================================---------------------------------------
    // 2. The Baseband Audio Memory (The Folded U-Shape)
    // =================================---------------------------------------
    logic [15:0] write_ptr;
    logic signed [DATA_WIDTH-1:0] fwd_seed, rev_seed;
    
    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_fwd [0:65535];
    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_rev [0:65535];

    // --- A. The Pointer Logic ---
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= '0;
        end else if (new_sample_valid) begin
            write_ptr <= write_ptr + 16'b1;
        end
    end

    // Calculate addresses combinationally outside the clocked block
    logic [15:0] fwd_addr_comb;
    logic [15:0] rev_addr_comb;
    assign fwd_addr_comb = write_ptr - 16'b1 - master_coef_addr;
    assign rev_addr_comb = write_ptr + master_coef_addr;
    // assign rev_addr_comb = write_ptr - 16'd65536 + master_coef_addr;

    // --- B & C. The RAM Logic (Dual-Port Template) ---
    always_ff @(posedge clk) begin
        if (new_sample_valid) begin
            audio_bram_fwd[write_ptr] <= new_sample_data; 
        end
        fwd_seed <= audio_bram_fwd[fwd_addr_comb];        
    end

    always_ff @(posedge clk) begin
        if (new_sample_valid) begin
            audio_bram_rev[write_ptr] <= new_sample_data; 
        end
        rev_seed <= audio_bram_rev[rev_addr_comb];        
    end

    // =================================---------------------------------------
    // 3. Array Interconnect Routing
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] cascade_fwd [0:NUM_MACS];
    logic signed [DATA_WIDTH-1:0] cascade_rev [0:NUM_MACS];
    logic signed [ACC_WIDTH-1:0]  cascade_acc [0:NUM_MACS];

    // NEW: Pipelined Control Signals (The Bucket Brigade)
    logic [10:0] cascade_coef_addr  [0:NUM_MACS];
    logic        cascade_phase_sync [0:NUM_MACS];

    assign cascade_fwd[0] = fwd_seed;
    assign cascade_rev[0] = rev_seed;
    assign cascade_acc[0] = '0;
    
    // Seed the start of the control pipeline
    assign cascade_coef_addr[0]  = master_coef_addr;
    assign cascade_phase_sync[0] = phase_sync;

    // =================================---------------------------------------
    // 4. The 256-Engine Polyphase Instantiation
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac
            
            // The Systolic Shift Register for Control Signals
            // This drops fanout to 1 and perfectly staggers the accumulator chain
            always_ff @(posedge clk) begin
                cascade_coef_addr[i+1]  <= cascade_coef_addr[i];
                cascade_phase_sync[i+1] <= cascade_phase_sync[i];
            end

            polyphase_mac_engine #(
                .DATA_WIDTH(DATA_WIDTH),
                .COEF_WIDTH(COEF_WIDTH),
                .ACC_WIDTH (ACC_WIDTH),
                .MAC_ID    (i)
            ) u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                
                // Feed the PIPELINED control signals into the MAC
                .phase_sync   (cascade_phase_sync[i]),
                .coef_addr    (cascade_coef_addr[i]),
                
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