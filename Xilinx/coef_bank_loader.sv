`timescale 1ns / 1ps

// =============================================================================
//  COEF_BANK_LOADER
//
//  AXI4 read master that fetches a coefficient bank from DDR4 and writes it
//  into the 256 per-MAC coefficient BRAMs of one fir_polyphase_interpolator
//  instance. Driven by the coef_bank_manager FSM.
//
//  ----------------------------------------------------------------------------
//  DDR4 BANK LAYOUT (per channel)
//  ----------------------------------------------------------------------------
//
//    Address                         | Contents
//    --------------------------------+--------------------------------------
//    DDR4_BASE_ADDR + bank_id * BS   | Start of bank `bank_id`
//      offset 0                      | MAC 0  coef[0]   ... coef[2047]
//      offset 8 KB                   | MAC 1  coef[0]   ... coef[2047]
//      offset 16 KB                  | MAC 2  ...
//      ...                           |
//      offset (255 * 8 KB)           | MAC 255 coef[0]  ... coef[2047]
//    DDR4_BASE_ADDR + (bank_id+1)*BS | Start of next bank
//
//    BS (BANK_SIZE_BYTES) = 256 MACs * 2048 coefs * 4 bytes = 2 MB per bank
//
//  Each coefficient is stored as a 32-bit signed word in DDR4 (sign-extended
//  from the underlying 18-bit value). This wastes ~44% of bank storage but
//  keeps DDR4 addressing trivially aligned and lets us pack 4 coefs per
//  128-bit AXI beat without bit-fiddling.
//
//  ----------------------------------------------------------------------------
//  TIMING BUDGET
//  ----------------------------------------------------------------------------
//
//    Per MAC:        2048 coefs / 4 per beat = 512 beats = 2 bursts of 256
//    Per bank:       256 MACs * 2 bursts = 512 bursts
//    Per burst:      ~256 cycles AXI + ~1024 cycles drain (sequential FSM)
//    Total per bank: ~660K cycles = 1.85 ms at 357 MHz
//
//  Comfortably inside the 5.3 ms fade-out window from coef_mute_envelope.
//
//  ----------------------------------------------------------------------------
//  CONCURRENCY
//  ----------------------------------------------------------------------------
//
//  This first implementation runs SEQUENTIALLY: issue burst -> drain FIFO ->
//  issue next burst. A future optimization would pipeline by issuing the
//  next AR while draining the current R FIFO; that would roughly halve
//  the total time but adds AXI ordering complexity. Not needed for the
//  current 5.3 ms fade budget.
// =============================================================================
module coef_bank_loader #(
    parameter int            NUM_MACS         = 256,
    parameter int            COEF_WIDTH       = 18,
    parameter int            COEF_DEPTH       = 2048,
    parameter int            BANK_BITS        = 4,                // up to 16 banks
    parameter int            AXI_DATA_WIDTH   = 128,
    parameter int            AXI_ADDR_WIDTH   = 32,
    parameter logic [31:0]   DDR4_BASE_ADDR   = 32'h0000_0000,
    parameter logic [31:0]   BANK_SIZE_BYTES  = 32'h0020_0000     // 2 MB
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // -- Control interface (from coef_bank_manager) ----------------------
    input  logic                          load_start,
    input  logic [BANK_BITS-1:0]          load_bank_id,
    output logic                          load_done,

    // -- AXI4 Read Master (to DDR4 hard controller) ----------------------
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,    // beats - 1
    output logic [2:0]                    m_axi_arsize,   // log2(bytes per beat)
    output logic [1:0]                    m_axi_arburst,  // 2'b01 = INCR
    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,

    input  logic [AXI_DATA_WIDTH-1:0]     m_axi_rdata,
    input  logic [1:0]                    m_axi_rresp,
    input  logic                          m_axi_rlast,
    input  logic                          m_axi_rvalid,
    output logic                          m_axi_rready,

    // -- Coefficient write broadcast bus (to fir_polyphase_interpolator) -
    output logic                          coef_we,
    output logic [10:0]                   coef_waddr,
    output logic signed [COEF_WIDTH-1:0]  coef_wdata,
    output logic [7:0]                    coef_wmac
);

    // -------------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------------
    localparam int COEFS_PER_BEAT  = AXI_DATA_WIDTH / 32;          // 4 @128b
    localparam int BEATS_PER_BURST = 256;                          // max AXI burst
    localparam int COEFS_PER_BURST = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC  = COEF_DEPTH / COEFS_PER_BURST;     // 2
    localparam int MAC_BYTES       = COEF_DEPTH * 4;                   // 8 KB

    // -------------------------------------------------------------------------
    //  R-channel FIFO. Holds one full burst (256 x 128b = 4 KB) so the AXI
    //  read can complete without backpressure even if the write FSM is busy.
    //  Implemented as a small dual-port BRAM-backed FIFO.
    // -------------------------------------------------------------------------
    localparam int FIFO_DEPTH      = 256;
    localparam int FIFO_AW         = 8;

    logic [AXI_DATA_WIDTH-1:0]  fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_AW-1:0]         fifo_wptr, fifo_rptr;
    logic [FIFO_AW:0]           fifo_count;
    wire                        fifo_empty = (fifo_count == 0);
    wire                        fifo_full  = (fifo_count == FIFO_DEPTH);
    logic                       fifo_we, fifo_re;
    logic [AXI_DATA_WIDTH-1:0]  fifo_rdata;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_wptr  <= '0;
            fifo_rptr  <= '0;
            fifo_count <= '0;
        end else begin
            if (fifo_we) begin
                fifo_mem[fifo_wptr] <= m_axi_rdata;
                fifo_wptr           <= fifo_wptr + 1'b1;
            end
            if (fifo_re) begin
                fifo_rdata <= fifo_mem[fifo_rptr];
                fifo_rptr  <= fifo_rptr + 1'b1;
            end
            case ({fifo_we, fifo_re})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: ;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    //  Top-level FSM
    //
    //  ST_IDLE       : waiting for load_start
    //  ST_ISSUE_AR   : drive AR for the current burst (one MAC handles 2 bursts)
    //  ST_RECV_R     : capture all 256 beats into the FIFO
    //  ST_DRAIN      : pop FIFO, broadcast 4 coefs per beat to MACs
    //  ST_NEXT       : advance MAC / burst counters
    //  ST_DONE       : pulse load_done -> back to ST_IDLE
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE      = 3'd0,
        ST_ISSUE_AR  = 3'd1,
        ST_RECV_R    = 3'd2,
        ST_DRAIN     = 3'd3,
        ST_NEXT      = 3'd4,
        ST_DONE      = 3'd5
    } state_t;

    state_t                      state;
    logic [BANK_BITS-1:0]        bank_id;
    logic [7:0]                  mac_idx;       // 0..255
    logic                        burst_half;    // 0 = first 1024 coefs, 1 = second
    logic [9:0]                  beat_count;    // 0..255 (one extra bit for safety)
    logic [9:0]                  drain_count;   // 0..1023 within a burst (4 per beat)

    // Bank base address: DDR4_BASE + bank_id * BANK_SIZE_BYTES + mac*8KB + half*4KB
    wire [AXI_ADDR_WIDTH-1:0] burst_addr =
        DDR4_BASE_ADDR
        + (AXI_ADDR_WIDTH'(bank_id) * BANK_SIZE_BYTES)
        + (AXI_ADDR_WIDTH'(mac_idx) * MAC_BYTES)
        + (burst_half ? AXI_ADDR_WIDTH'(COEFS_PER_BURST * 4) : '0);

    // -------------------------------------------------------------------------
    //  Drain-side: each FIFO beat carries 4 coefs. We slice them out one at
    //  a time and pulse coef_we for each.
    // -------------------------------------------------------------------------
    logic [1:0]                  beat_slice;     // which of the 4 coefs in current beat
    logic                        beat_loaded;    // current fifo_rdata is valid
    wire signed [COEF_WIDTH-1:0] slice_coef =
        signed'(fifo_rdata[(beat_slice * 32) +: COEF_WIDTH]);

    // -------------------------------------------------------------------------
    //  Sequential FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            bank_id        <= '0;
            mac_idx        <= '0;
            burst_half     <= 1'b0;
            beat_count     <= '0;
            drain_count    <= '0;
            beat_slice     <= '0;
            beat_loaded    <= 1'b0;
            m_axi_arvalid  <= 1'b0;
            m_axi_rready   <= 1'b0;
            coef_we        <= 1'b0;
            coef_waddr     <= '0;
            coef_wdata     <= '0;
            coef_wmac      <= '0;
            fifo_we        <= 1'b0;
            fifo_re        <= 1'b0;
            load_done      <= 1'b0;
        end else begin
            // Default deasserts
            fifo_we   <= 1'b0;
            fifo_re   <= 1'b0;
            coef_we   <= 1'b0;
            load_done <= 1'b0;

            unique case (state)

                // ----- IDLE -----
                ST_IDLE: begin
                    if (load_start) begin
                        bank_id    <= load_bank_id;
                        mac_idx    <= '0;
                        burst_half <= 1'b0;
                        state      <= ST_ISSUE_AR;
                    end
                end

                // ----- ISSUE AR -----
                ST_ISSUE_AR: begin
                    m_axi_araddr  <= burst_addr;
                    m_axi_arlen   <= 8'(BEATS_PER_BURST - 1);   // 255 -> 256 beats
                    m_axi_arsize  <= 3'd4;                       // 16 bytes/beat (128b)
                    m_axi_arburst <= 2'b01;                      // INCR
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        beat_count    <= '0;
                        state         <= ST_RECV_R;
                    end
                end

                // ----- RECV R into FIFO -----
                ST_RECV_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        fifo_we    <= 1'b1;
                        beat_count <= beat_count + 1'b1;
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            // Kick off the drain pipeline by reading first beat
                            fifo_re      <= 1'b1;
                            beat_loaded  <= 1'b0;
                            beat_slice   <= '0;
                            drain_count  <= '0;
                            state        <= ST_DRAIN;
                        end
                    end
                end

                // ----- DRAIN FIFO into MAC BRAMs -----
                //
                // Each FIFO read latches a 128-bit beat. We unpack it as 4
                // coefs over 4 cycles, pulsing coef_we each cycle. After the
                // 4th slice we read the next beat (if any).
                ST_DRAIN: begin
                    if (!beat_loaded) begin
                        // First-time: initial fifo_re fired in prior state,
                        // fifo_rdata now has beat 0.
                        beat_loaded <= 1'b1;
                        beat_slice  <= '0;
                    end

                    if (beat_loaded) begin
                        // Drive write to current MAC at the current depth address
                        coef_we    <= 1'b1;
                        coef_wmac  <= mac_idx;
                        coef_waddr <= 11'((burst_half ? COEFS_PER_BURST : 0) +
                                          drain_count);
                        coef_wdata <= slice_coef;

                        if (beat_slice == 2'd3) begin
                            // Done with this beat -- fetch the next, unless
                            // we just emitted the last coef of the burst.
                            if (drain_count == 10'(COEFS_PER_BURST - 1)) begin
                                state       <= ST_NEXT;
                                beat_loaded <= 1'b0;
                            end else begin
                                fifo_re     <= 1'b1;
                                beat_slice  <= '0;
                                drain_count <= drain_count + 1'b1;
                                beat_loaded <= 1'b0;   // reload on next cycle
                            end
                        end else begin
                            beat_slice  <= beat_slice + 1'b1;
                            drain_count <= drain_count + 1'b1;
                        end
                    end
                end

                // ----- ADVANCE MAC / BURST counters -----
                ST_NEXT: begin
                    if (!burst_half) begin
                        burst_half <= 1'b1;
                        state      <= ST_ISSUE_AR;
                    end else begin
                        burst_half <= 1'b0;
                        if (mac_idx == 8'(NUM_MACS - 1)) begin
                            state <= ST_DONE;
                        end else begin
                            mac_idx <= mac_idx + 1'b1;
                            state   <= ST_ISSUE_AR;
                        end
                    end
                end

                // ----- DONE -----
                ST_DONE: begin
                    load_done <= 1'b1;
                    state     <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
