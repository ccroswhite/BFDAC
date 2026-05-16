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
//      3. Wait for load_done (coefficients now in shadow BRAMs).
//      4. Toggle bank_select to swap active/shadow banks (atomic, gapless).
//      5. Back to IDLE, audio continues uninterrupted with new coefficients.
//
//  Boot behavior:
//
//      At power-on, the default bank should be loaded into Bank A before
//      audio begins. Boot loader asserts boot_load_done when complete.
//
//  Request handling:
//
//      A bank_select_pulse received while loading is captured in a single-entry
//      queue (req_pending). Most-recent-wins semantics for queued requests.
// =============================================================================
module coef_bank_manager #(
    parameter int NUM_BANKS  = 12,
    parameter int BANK_BITS  = 4   // ceil(log2(NUM_BANKS)) -- 4 bits = up to 16
)(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       sample_tick,       // 768 kHz tick (unused in gapless)

    // -- Host request interface (from SPI control plane) -------------------
    input  logic [BANK_BITS-1:0]       bank_select_req,
    input  logic                       bank_select_pulse,

    // -- Boot loader handshake ---------------------------------------------
    input  logic                       boot_load_done,

    // -- Dual-bank control -------------------------------------------------
    output logic                       bank_select,       // 0=Bank A active, 1=Bank B active
    output logic                       bank_load_target,  // Which bank to load into (async to bank_select)

    // -- coef_bank_loader handshake ----------------------------------------
    output logic                       load_start,
    output logic [BANK_BITS-1:0]       load_bank_id,
    input  logic                       load_done,

    // -- Status outputs ----------------------------------------------------
    output logic [BANK_BITS-1:0]       current_bank_id,
    output logic                       busy
);

    // -------------------------------------------------------------------------
    //  FSM - Gapless dual-bank switching
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        ST_BOOT_WAIT = 2'd0,
        ST_IDLE      = 2'd1,
        ST_LOADING   = 2'd2,
        ST_SWITCHING = 2'd3    // One-cycle atomic bank swap
    } state_t;

    state_t                  state;
    logic [BANK_BITS-1:0]    target_bank;       // bank to load into shadow
    logic [BANK_BITS-1:0]    queued_bank;       // most recent request, if any
    logic                    queued_valid;      // queued_bank holds a pending request
    logic [BANK_BITS-1:0]    current_bank_r;
    logic                    bank_select_r;      // Current active bank (0=A, 1=B)
    logic                    bank_load_target_r; // Which bank loader should write to
    logic                    load_start_r;

    // Reject out-of-range bank requests by clamping to NUM_BANKS-1.
    // (Cheaper than reporting an error and equally safe.)
    wire [BANK_BITS-1:0] req_clamped =
        (bank_select_req >= NUM_BANKS[BANK_BITS-1:0])
            ? BANK_BITS'(NUM_BANKS - 1)
            : bank_select_req;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_BOOT_WAIT;
            target_bank        <= '0;
            queued_bank        <= '0;
            queued_valid       <= 1'b0;
            current_bank_r     <= '0;
            bank_select_r      <= 1'b0;      // Start with Bank A active
            bank_load_target_r <= 1'b1;      // Load first bank into Bank B
            load_start_r       <= 1'b0;
        end else begin
            // Default: pulses deassert each cycle
            load_start_r <= 1'b0;

            // Always-on request queue. Most-recent-wins.
            if (bank_select_pulse) begin
                queued_bank  <= req_clamped;
                queued_valid <= 1'b1;
            end

            unique case (state)

                // -------------------------------------------------------------
                //  ST_BOOT_WAIT: Waiting for boot loader to populate initial bank.
                //  Boot loader loads into Bank B (bank_load_target=1).
                //  When done, we atomically switch to Bank B and move to IDLE.
                // -------------------------------------------------------------
                ST_BOOT_WAIT: begin
                    if (boot_load_done) begin
                        bank_select_r      <= 1'b1;      // Switch to Bank B
                        bank_load_target_r <= 1'b0;      // Next load goes to Bank A
                        current_bank_r     <= '0;         // Bank 0 now active
                        state              <= ST_IDLE;
                    end
                end

                // -------------------------------------------------------------
                //  ST_IDLE: Ready to accept a bank-switch request.
                //  Load into the inactive bank (opposite of bank_select).
                // -------------------------------------------------------------
                ST_IDLE: begin
                    if (queued_valid && (queued_bank != current_bank_r)) begin
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
                        state <= ST_SWITCHING;
                    end
                end

                // -------------------------------------------------------------
                //  ST_SWITCHING: Atomic bank swap (single cycle, gapless).
                //  Toggle bank_select to make shadow bank active.
                // -------------------------------------------------------------
                ST_SWITCHING: begin
                    bank_select_r      <= ~bank_select_r;    // Swap active bank
                    bank_load_target_r <= bank_select_r;     // Next load to old active
                    current_bank_r     <= target_bank;
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
    assign busy            = (state != ST_IDLE);

endmodule
