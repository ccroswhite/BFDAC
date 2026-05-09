`timescale 1ns / 1ps

module fir_polyphase_interpolator #(
    parameter int NUM_MACS   = 256,
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 64 // 64 BITS
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // Baseband Input
    input  logic                                 new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]         new_sample_data,

    // Oversampled Output
    output logic signed [ACC_WIDTH-1:0]          interpolated_out,
    output logic                                 interpolated_valid
);

    // =================================---------------------------------------
    // 1. The 2048-Cycle State Machine 
    // =================================---------------------------------------
    logic [10:0] master_coef_addr;  
    logic [3:0]  phase_counter;    
    logic [6:0]  tap_counter;      
    logic        phase_sync;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            master_coef_addr   <= '0;
            phase_counter      <= '0;
            tap_counter        <= '0;
            phase_sync         <= 1'b0;
        end else begin
            phase_sync <= 1'b0;

            if (new_sample_valid) begin
                master_coef_addr <= '0;
                phase_counter    <= '0;
                tap_counter      <= '0;
            end else begin
                master_coef_addr <= master_coef_addr + 11'b1;
                tap_counter      <= tap_counter + 7'b1;
                
                if (tap_counter == 7'd127) begin
                    phase_sync <= 1'b1;
                    phase_counter <= phase_counter + 4'b1;
                end
            end
        end
    end

    // =================================---------------------------------------
    // 2. The Baseband Audio Memory (With Read/Write Fanout Distribution)
    // =================================---------------------------------------
    logic [15:0] write_ptr;
    logic signed [DATA_WIDTH-1:0] fwd_seed, rev_seed;
    
    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_fwd [0:65535];
    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_rev [0:65535];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= '0;
        end else if (new_sample_valid) begin
            write_ptr <= write_ptr + 16'b1;
        end
    end

    // --- Write-Path Fanout Distribution ---
    (* max_fanout = 4 *)  logic [15:0] write_ptr_reg;
    (* max_fanout = 16 *) logic        write_en_reg;
    (* max_fanout = 16 *) logic signed [DATA_WIDTH-1:0] write_data_reg;

    always_ff @(posedge clk) begin
        write_ptr_reg  <= write_ptr;
        write_en_reg   <= new_sample_valid;
        write_data_reg <= new_sample_data;
    end

    // --- Read-Path Fanout Distribution ---
    (* max_fanout = 16 *) logic [15:0] fwd_addr_reg;
    (* max_fanout = 16 *) logic [15:0] rev_addr_reg;
    
    always_ff @(posedge clk) begin
        fwd_addr_reg <= write_ptr - 16'b1 - master_coef_addr;
        rev_addr_reg <= write_ptr + master_coef_addr;
    end

    always_ff @(posedge clk) begin
        if (write_en_reg) begin
            audio_bram_fwd[write_ptr_reg] <= write_data_reg;
            audio_bram_rev[write_ptr_reg] <= write_data_reg;
        end
        fwd_seed <= audio_bram_fwd[fwd_addr_reg];       
        rev_seed <= audio_bram_rev[rev_addr_reg];       
    end

    // =================================---------------------------------------
    // 3. Array Interconnect Routing
    // =================================---------------------------------------
    logic signed [DATA_WIDTH-1:0] cascade_fwd [0:NUM_MACS];
    logic signed [DATA_WIDTH-1:0] cascade_rev [0:NUM_MACS];
    logic signed [ACC_WIDTH-1:0]  cascade_acc [0:NUM_MACS];
    logic [10:0]                  cascade_coef_addr  [0:NUM_MACS];
    logic                         cascade_phase_sync [0:NUM_MACS];
    logic                         mac_valid_out      [0:NUM_MACS-1];

    logic [10:0] master_coef_addr_d1;
    logic        phase_sync_d1;

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
    end

    assign cascade_fwd[0] = fwd_seed;
    assign cascade_rev[0] = rev_seed;
    assign cascade_acc[0] = '0;  
    assign cascade_coef_addr[0]  = master_coef_addr_d1; 
    assign cascade_phase_sync[0] = phase_sync_d1;       

    // =================================---------------------------------------
    // 4. The 256-Engine Polyphase Instantiation
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac
            
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
                .phase_sync   (cascade_phase_sync[i]),
                .coef_addr    (cascade_coef_addr[i]),
                .audio_fwd_in (cascade_fwd[i]),
                .audio_rev_in (cascade_rev[i]),
                .audio_fwd_out(cascade_fwd[i+1]),
                .audio_rev_out(cascade_rev[i+1]),
                .acc_in       (cascade_acc[i]),
                .acc_out      (cascade_acc[i+1]),
                .valid_out    (mac_valid_out[i])
            );
        end
    endgenerate

    // =================================---------------------------------------
    // 5. Output Assignment
    // =================================---------------------------------------
    assign interpolated_out   = cascade_acc[NUM_MACS];
    // Tap the valid flag specifically from the final MAC engine in the array
    assign interpolated_valid = mac_valid_out[NUM_MACS-1];

endmodule