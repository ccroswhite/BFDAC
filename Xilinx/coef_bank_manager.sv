`timescale 1ns / 1ps

// =============================================================================
//  COEF_BANK_MANAGER - Gapless Dual-Bank Edition
//
//  Manages coefficient bank switching using dual-bank BRAM architecture.
//  Loads new coefficients into the inactive (shadow) bank while audio plays
//  from the active bank, then performs an atomic switch.
//
//  Sequence on a bank-switch request:
//
//      1. Identify inactive bank (bank_select ^ 1).
//      2. Pulse load_start to coef_bank_loader, target = inactive bank.
//      3. Wait for load_done (coefficients now in shadow URAMs).
//      4. Wait for the complete native input frame (all active interpolation
//         phases) to finish before swapping active/shadow banks.
//      5. Propagate bank_select through the read mux before the next FIR sweep.
//
//  Boot behavior (revised 2026-09-03, TODO-16):
//
//      The QSPI boot loader stages coefficient records into DDR4, NOT into a
//      FIR bank. The manager therefore holds in ST_BOOT_WAIT until ddr4_ready
//      (boot_ok, synced) and then goes IDLE with NO bank swap: both FIR banks
//      are unwritten, bank_valid=0, and the boot mute envelope keeps the
//      output at zero. The first request (ARM policy: FILTER_SELECT index 0
//      after reading BOOT_STATUS.boot_ok) loads the shadow bank and swaps;
//      bank_valid then goes high and the subsystem starts the boot fade-in.
//      Requests that arrive before ddr4_ready are queued (most-recent-wins).
//
//  Request handling:
//
//      A bank_select_pulse received while loading is captured in a single-entry
//      queue (req_pending). Most-recent-wins semantics for queued requests.
//
//  Request encoding (REQ_BITS = 17, 2026-09-02):
//
//      bank_select_req = {by_id, id[15:0]}
//        by_id = 0 : legacy fixed slot, id[3:0] = bank_id (SPI reg 0x05)
//        by_id = 1 : filter_id resolved through the DDR4 directory by the
//                    loader (SPI regs 0x08-0x0A, docs/coef_format_v2.md)
//      The two spaces never compare equal, so a legacy slot and a filter ID
//      that happen to share low bits are distinct requests.
//
//  Failed loads (load_failed=1 when load_done pulses: ID not found or size
//  mismatch) return to IDLE WITHOUT swapping banks; audio continues on the
//  current bank and the ctrl plane reports the error.
// =============================================================================
module coef_bank_manager #(
    parameter int REQ_BITS   = 17
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       sample_tick,       // pulse after all FIR phases for one input frame

    // -- Host request interface (from SPI control plane) -------------------
    input  logic [REQ_BITS-1:0]        bank_select_req,
    input  logic                       bank_select_pulse,

    // -- Boot handshake -----------------------------------------------------
    input  logic                       ddr4_ready,        // boot_ok level, dsp_clk-synced

    // -- Dual-bank control -------------------------------------------------
    output logic                       bank_select,       // 0=Bank A active, 1=Bank B active
    output logic                       bank_load_target,  // Which bank to load into (async to bank_select)

    // -- coef_bank_loader handshake ----------------------------------------
    output logic                       load_start,
    output logic [REQ_BITS-1:0]        load_bank_id,      // latched request, stable LOADING..done
    input  logic                       load_done,
    input  logic                       load_failed,       // sampled with load_done

    // -- Status outputs ----------------------------------------------------
    output logic [REQ_BITS-1:0]        current_bank_id,
    output logic                       bank_valid,        // active bank holds a successful load
    output logic                       busy
);

    // -------------------------------------------------------------------------
    //  FSM - swap only between complete FIR input-frame calculations
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_BOOT_WAIT    = 3'd0,
        ST_IDLE         = 3'd1,
        ST_LOADING      = 3'd2,
        ST_WAIT_BOUNDARY= 3'd3,
        ST_SWITCHING    = 3'd4    // One-cycle bank swap after the frame boundary
    } state_t;

    state_t                  state;
    logic [REQ_BITS-1:0]     target_bank;       // bank to load into shadow
    logic [REQ_BITS-1:0]     queued_bank;       // most recent request, if any
    logic                    queued_valid;      // queued_bank holds a pending request
    logic [REQ_BITS-1:0]     current_bank_r;
    logic                    bank_select_r;      // Current active bank (0=A, 1=B)
    logic                    bank_load_target_r; // Which bank loader should write to
    logic                    load_start_r;
    logic                    bank_valid_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_BOOT_WAIT;
            target_bank        <= '0;
            queued_bank        <= '0;
            queued_valid       <= 1'b0;
            current_bank_r     <= '0;
            bank_select_r      <= 1'b0;      // Start with Bank A active (unwritten)
            bank_load_target_r <= 1'b1;      // First load goes into Bank B
            load_start_r       <= 1'b0;
            bank_valid_r       <= 1'b0;
        end else begin
            // Default: pulses deassert each cycle
            load_start_r <= 1'b0;

            // Always-on request queue. Most-recent-wins.
            if (bank_select_pulse) begin
                queued_bank  <= bank_select_req;
                queued_valid <= 1'b1;
            end

            unique case (state)

                // -------------------------------------------------------------
                //  ST_BOOT_WAIT: DDR4 not yet staged by the QSPI boot loader.
                //  Hold (queue) requests; no bank swap here.
                // -------------------------------------------------------------
                ST_BOOT_WAIT: begin
                    if (ddr4_ready)
                        state <= ST_IDLE;
                end

                // -------------------------------------------------------------
                //  ST_IDLE: Ready to accept a bank-switch request.
                //  Load into the inactive bank (opposite of bank_select).
                //  The same-bank shortcut only applies once a bank is valid.
                // -------------------------------------------------------------
                ST_IDLE: begin
                    if (queued_valid && (!bank_valid_r || queued_bank != current_bank_r)) begin
                        target_bank        <= queued_bank;
                        queued_valid       <= 1'b0;
                        bank_load_target_r <= ~bank_select_r;  // Load into inactive bank
                        load_start_r       <= 1'b1;
                        state              <= ST_LOADING;
                    end else if (queued_valid) begin
                        // Same bank requested -- silently consume.
                        queued_valid <= 1'b0;
                    end
                end

                // -------------------------------------------------------------
                //  ST_LOADING: Waiting for loader to fill the shadow bank.
                // -------------------------------------------------------------
                ST_LOADING: begin
                    if (load_done) begin
                        // Failed lookup: keep the active bank, report via ctrl plane
                        state <= load_failed ? ST_IDLE : ST_WAIT_BOUNDARY;
                    end
                end

                // The shadow image is ready, but the current input's FIR
                // convolution may still be using the active bank.
                ST_WAIT_BOUNDARY: begin
                    if (sample_tick)
                        state <= ST_SWITCHING;
                end

                // -------------------------------------------------------------
                //  ST_SWITCHING: Atomic bank swap (single cycle, gapless).
                //  Toggle bank_select to make shadow bank active.
                // -------------------------------------------------------------
                ST_SWITCHING: begin
                    bank_select_r      <= ~bank_select_r;    // Swap active bank
                    bank_load_target_r <= bank_select_r;     // Next load to old active
                    current_bank_r     <= target_bank;
                    bank_valid_r       <= 1'b1;
                    state              <= ST_IDLE;
                end

            endcase
        end
    end

    assign load_bank_id    = target_bank;
    assign bank_select     = bank_select_r;
    assign bank_load_target= bank_load_target_r;
    assign load_start      = load_start_r;
    assign current_bank_id = current_bank_r;
    assign bank_valid      = bank_valid_r;
    assign busy            = (state != ST_IDLE);

endmodule
