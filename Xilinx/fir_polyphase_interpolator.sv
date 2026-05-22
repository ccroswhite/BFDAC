`timescale 1ns / 1ps

// Mono polyphase FIR interpolator.
//
// Audio history depth is 2K (2048 samples), exactly matching the
// master_coef_addr sweep range (0..2047). Every BRAM slot is read exactly
// once per FIR sweep, with no starvation.
//
// Coefficient BRAMs are NOT owned here -- they are shared between L and R
// channels at the fir_polyphase_stereo wrapper level. Each MAC receives its
// coefficient value each cycle via the coef_in[] array input.
module fir_polyphase_interpolator #(
    parameter int NUM_MACS   = 256,
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48 // STRICTLY 48 BITS to guarantee DSP PCIN/PCOUT routing
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // Baseband Input
    input  logic                                 new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]         new_sample_data,

    // Oversampled Output
    output logic signed [ACC_WIDTH-1:0]          interpolated_out,
    output logic                                 interpolated_valid,

    // -- Coefficient input from shared BRAMs (one value per MAC per cycle) --
    input  logic signed [COEF_WIDTH-1:0]         coef_in [0:NUM_MACS-1],

    // -- Coefficient address output (to drive shared BRAM read port) --------
    output logic [10:0]                          coef_addr_out
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
            interpolated_valid <= 1'b0;
        end else begin
            interpolated_valid <= 1'b0;
            phase_sync         <= 1'b0;

            if (new_sample_valid) begin
                master_coef_addr <= '0;
                phase_counter    <= '0;
                tap_counter      <= '0;
            end else begin
                master_coef_addr <= master_coef_addr + 11'b1;
                tap_counter      <= tap_counter + 7'b1;

                if (tap_counter == 7'd127) begin
                    phase_sync         <= 1'b1;
                    phase_counter      <= phase_counter + 4'b1;
                    interpolated_valid <= 1'b1;
                end
            end
        end
    end

    // =================================---------------------------------------
    // 2. The Baseband Audio Memory -- 2K depth (matches master_coef_addr range)
    // =================================---------------------------------------
    logic [10:0] write_ptr;
    logic signed [DATA_WIDTH-1:0] fwd_seed, rev_seed;

    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_fwd [0:2047];
    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram_rev [0:2047];

    // Master Write Pointer (11-bit, wraps modulo 2048 naturally)
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            write_ptr <= '0;
        end else if (new_sample_valid) begin
            write_ptr <= write_ptr + 11'b1;
        end
    end

    // --- Write-Path Fanout Distribution ---
    // Cloned registers kill the write routing delay
    (* max_fanout = 4 *)  logic [10:0] write_ptr_reg;
    (* max_fanout = 16 *) logic        write_en_reg;
    (* max_fanout = 16 *) logic signed [DATA_WIDTH-1:0] write_data_reg;

    always_ff @(posedge clk) begin
        write_ptr_reg  <= write_ptr;
        write_en_reg   <= new_sample_valid;
        write_data_reg <= new_sample_data;
    end

    // --- Read-Path Fanout Distribution ---
    // Cloned registers kill the read routing delay
    (* max_fanout = 16 *) logic [10:0] fwd_addr_reg;
    (* max_fanout = 16 *) logic [10:0] rev_addr_reg;

    // Pipeline Stage 1: Address math (isolated from BRAM array)
    // 11-bit arithmetic wraps modulo 2048, giving us a circular buffer.
    always_ff @(posedge clk) begin
        fwd_addr_reg <= write_ptr - 11'b1 - master_coef_addr;
        rev_addr_reg <= write_ptr + master_coef_addr;
    end

    // Pipeline Stage 2: BRAM Read/Write
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
    logic                         cascade_phase_sync [0:NUM_MACS];

    // Export coef address for the shared BRAM in the wrapper.
    // Delay by 1 cycle to match audio BRAM read latency.
    logic [10:0] master_coef_addr_d1;
    logic        phase_sync_d1;

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
    end

    assign coef_addr_out         = master_coef_addr_d1;
    assign cascade_fwd[0]        = fwd_seed;
    assign cascade_rev[0]        = rev_seed;
    assign cascade_acc[0]        = '0;
    assign cascade_phase_sync[0] = phase_sync_d1;

    // =================================---------------------------------------
    // 4. The 256-Engine Polyphase Instantiation
    // =================================---------------------------------------
    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac

            // Per-MAC chain pipelining: 2 cycles/hop on coef_addr and
            // phase_sync to match the 2-cycle/hop audio (fwd_reg_2 output)
            // and cascade accumulator (CREG-enabled) latencies. All four
            // chain signals advance at the same per-hop rate so the relative
            // timing inside each MAC is identical to the pre-CREG design.
            logic phase_sync_mid;

            always_ff @(posedge clk) begin
                phase_sync_mid          <= cascade_phase_sync[i];
                cascade_phase_sync[i+1] <= phase_sync_mid;
            end

            if (i == 0) begin : mac_first
                polyphase_mac_engine #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .COEF_WIDTH(COEF_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH),
                    .MAC_ID    (i)
                ) u_mac (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .phase_sync   (cascade_phase_sync[i]),
                    .coef_in      (coef_in[i]),
                    .audio_fwd_in (cascade_fwd[i]),
                    .audio_rev_in (cascade_rev[i]),
                    .audio_fwd_out(cascade_fwd[i+1]),
                    .audio_rev_out(cascade_rev[i+1]),
                    .pcin         (48'sd0),
                    .pcout        (cascade_acc[i+1])
                );
            end else begin : mac_chain
                polyphase_mac_engine #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .COEF_WIDTH(COEF_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH),
                    .MAC_ID    (i)
                ) u_mac (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .phase_sync   (cascade_phase_sync[i]),
                    .coef_in      (coef_in[i]),
                    .audio_fwd_in (cascade_fwd[i]),
                    .audio_rev_in (cascade_rev[i]),
                    .audio_fwd_out(cascade_fwd[i+1]),
                    .audio_rev_out(cascade_rev[i+1]),
                    .pcin         (cascade_acc[i]),
                    .pcout        (cascade_acc[i+1])
                );
            end
        end
    endgenerate

    assign interpolated_out = cascade_acc[NUM_MACS];

    // DEBUG: log every interpolated_valid pulse unconditionally
    int dbg_fir_cnt;
    initial dbg_fir_cnt = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_fir_cnt <= 0;
        end else begin
            if (interpolated_valid) begin
                dbg_fir_cnt <= dbg_fir_cnt + 1;
                if (dbg_fir_cnt < 10) begin
                    $display("[FIR_DBG @%0t] valid_cnt=%0d rst_n=%0b out=%0h c0=%0h c1=%0h c255=%0h c256=%0h",
                        $time, dbg_fir_cnt, rst_n, interpolated_out,
                        cascade_acc[0], cascade_acc[1], cascade_acc[255], cascade_acc[256]);
                end
            end
        end
    end

endmodule
