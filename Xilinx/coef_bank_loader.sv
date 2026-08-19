`timescale 1ns / 1ps

// =============================================================================
//  COEF_BANK_LOADER
//
//  AXI4 read master that fetches a coefficient bank from DDR4 and writes it
//  into the URAM288 coefficient storage of fir_polyphase_stereo.
//  Driven by the coef_bank_manager FSM.
//
//  ----------------------------------------------------------------------------
//  DDR4 BANK LAYOUT (per channel)
//  ----------------------------------------------------------------------------
//
//    Address                         | Contents
//    --------------------------------+--------------------------------------
//    DDR4_BASE_ADDR + bank_id * BS   | Start of bank `bank_id`
//      offset 0                      | MAC 0  coef[0]   ... coef[1023]
//      offset 4 KB                   | MAC 1  coef[0]   ... coef[1023]
//      offset 8 KB                   | MAC 2  ...
//      ...                           |
//      offset (1023 * 4 KB)          | MAC 1023 coef[0] ... coef[1023]
//    DDR4_BASE_ADDR + (bank_id+1)*BS | Start of next bank
//
//    BS (BANK_SIZE_BYTES) = 1024 MACs * 1024 coefs * 4 bytes = 4 MB per bank
//    (2M taps: 2048 MACs * 1024 coefs * 4 bytes = 8 MB per bank)
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
//    Per MAC:        1024 coefs / 4 per beat = 256 beats = 1 burst of 256
//    Per bank:       1024 MACs * 1 burst = 1024 bursts
//    Per burst:      ~256 cycles AXI + ~1024 cycles drain (sequential FSM)
//    Total per bank: ~1.3M cycles = 3.6 ms at 357 MHz
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
    parameter int            NUM_MACS         = 1024,  // Any multiple of 64; taps = 16*NUM_MACS*TAPS_PER_PHASE
    parameter int            COEF_WIDTH       = 18,
    parameter int            COEF_DEPTH       = 1024,  // 16 phases * 64 taps/phase
    parameter int            BANK_BITS        = 4,                // up to 16 banks
    parameter int            AXI_DATA_WIDTH   = 128,
    parameter int            AXI_ADDR_WIDTH   = 32,
    parameter logic [31:0]   DDR4_BASE_ADDR   = 32'h0000_0000,
    parameter logic [31:0]   BANK_SIZE_BYTES  = 32'(NUM_MACS * COEF_DEPTH * 4) // e.g. 4 MB for 1024x1024
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
    output logic [$clog2(COEF_DEPTH)-1:0]    coef_waddr,
    output logic signed [COEF_WIDTH-1:0]     coef_wdata,
    output logic [$clog2(NUM_MACS)-1:0]      coef_wmac
);

    // -------------------------------------------------------------------------
    //  Constants
    // -------------------------------------------------------------------------
    localparam int COEFS_PER_BEAT  = AXI_DATA_WIDTH / 32;          // 4 @128b
    localparam int BEATS_PER_BURST = 256;                          // max AXI burst
    localparam int COEFS_PER_BURST = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC  = COEF_DEPTH / COEFS_PER_BURST;     // 1 (TPP=64) .. 4 (TPP=256)
    localparam int MAC_BYTES       = COEF_DEPTH * 4;                   // 4 KB (TPP=64) .. 16 KB (TPP=256)
    localparam int BURST_BYTES     = COEFS_PER_BURST * 4;              // 4 KB per AXI burst
    localparam int BIDX_W          = (BURSTS_PER_MAC > 1) ? $clog2(BURSTS_PER_MAC) : 1;

    initial begin
        assert (COEF_DEPTH % COEFS_PER_BURST == 0)
            else $fatal(1, "COEF_DEPTH must be a multiple of COEFS_PER_BURST");
    end

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
    logic                       fifo_re, fifo_re_d1;
    logic                       fifo_we_d1;           // registered write-enable
    logic [AXI_DATA_WIDTH-1:0]  fifo_din;             // data latched on handshake cycle
    logic [AXI_DATA_WIDTH-1:0]  fifo_rdata;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fifo_wptr  <= '0;
            fifo_rptr  <= '0;
            fifo_count <= '0;
            fifo_rdata <= '0;
        end else begin
            if (fifo_we_d1) begin
                fifo_mem[fifo_wptr] <= fifo_din;
                fifo_wptr           <= fifo_wptr + 1'b1;
            end
            if (fifo_re) begin
                fifo_rdata <= fifo_mem[fifo_rptr];
                fifo_rptr  <= fifo_rptr + 1'b1;
            end
            case ({fifo_we_d1, fifo_re})
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
    logic [$clog2(NUM_MACS)-1:0] mac_idx;
    logic [BIDX_W-1:0]           burst_idx;     // burst within MAC (0..BURSTS_PER_MAC-1)
    logic [9:0]                  beat_count;    // 0..255 (one extra bit for safety)
    logic [9:0]                  drain_count;   // 0..1023 within a burst (4 per beat)

    // Bank base address: DDR4_BASE + bank_id * BANK_SIZE_BYTES + mac * MAC_BYTES
    //                    + burst_idx * BURST_BYTES
    // Each AXI burst = 256 beats x 16 bytes = 4 KB = COEFS_PER_BURST coefs;
    // BURSTS_PER_MAC bursts cover all COEF_DEPTH coefs of one MAC.
    wire [AXI_ADDR_WIDTH-1:0] burst_addr =
        DDR4_BASE_ADDR
        + (AXI_ADDR_WIDTH'(bank_id) * BANK_SIZE_BYTES)
        + (AXI_ADDR_WIDTH'(mac_idx) * MAC_BYTES)
        + (AXI_ADDR_WIDTH'(burst_idx) * BURST_BYTES);

    // -------------------------------------------------------------------------
    //  Drain-side: each FIFO beat carries 4 coefs. We slice them out one at
    //  a time and pulse coef_we for each.
    // -------------------------------------------------------------------------
    logic [1:0]                  beat_slice;     // which of the 4 coefs in current beat
    logic                        beat_loaded;    // current beat_buf is valid
    logic [AXI_DATA_WIDTH-1:0]   beat_buf;       // registered copy of fifo_rdata, immune to NBA races
    wire signed [COEF_WIDTH-1:0] slice_coef =
        signed'(beat_buf[(beat_slice * 32) +: COEF_WIDTH]);

    // -------------------------------------------------------------------------
    //  Sequential FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            bank_id        <= '0;
            mac_idx        <= '0;
            burst_idx      <= '0;
            beat_count     <= '0;
            drain_count    <= '0;
            beat_slice     <= '0;
            beat_loaded    <= 1'b0;
            beat_buf       <= '0;
            m_axi_arvalid  <= 1'b0;
            m_axi_rready   <= 1'b0;
            coef_we        <= 1'b0;
            coef_waddr     <= '0;
            coef_wdata     <= '0;
            coef_wmac      <= '0;
            fifo_re        <= 1'b0;
            fifo_re_d1     <= 1'b0;
            fifo_we_d1     <= 1'b0;
            fifo_din       <= '0;
            load_done      <= 1'b0;
        end else begin
            // Default deasserts
            fifo_re    <= 1'b0;
            fifo_re_d1 <= fifo_re;
            fifo_we_d1 <= 1'b0;
            coef_we   <= 1'b0;
            load_done <= 1'b0;

            unique case (state)

                // ----- IDLE -----
                ST_IDLE: begin
                    if (load_start) begin
                        bank_id    <= load_bank_id;
                        mac_idx    <= '0;
                        burst_idx  <= '0;
                        state      <= ST_ISSUE_AR;
                    end
                end

                // ----- ISSUE AR -----
                // Drive arvalid=1 and hold until slave asserts arready
                // while arvalid is already high (proper AXI handshake).
                ST_ISSUE_AR: begin
                    m_axi_araddr  <= burst_addr;
                    m_axi_arlen   <= 8'(BEATS_PER_BURST - 1);
                    m_axi_arsize  <= 3'd4;
                    m_axi_arburst <= 2'b01;
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        beat_count    <= '0;
                        state         <= ST_RECV_R;
                        $display("[AR_HS @%0t] mac=%0d burst=%0d beat_count_now=%0d (resetting to 0)",
                            $time, mac_idx, burst_idx, beat_count);
                    end
                end

                // ----- RECV R into FIFO -----
                ST_RECV_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (beat_count == 0)
                            $display("[BEAT0 @%0t] mac=%0d burst=%0d first beat rvalid+rready", $time, mac_idx, burst_idx);
                        // Latch rdata now; fifo_we_d1 fires next cycle to write it.
                        // This breaks any same-cycle dependency on m_axi_rdata.
                        fifo_din   <= m_axi_rdata;
                        fifo_we_d1 <= 1'b1;
                        if (beat_count == 0)
                            $display("[DIN_HS0 @%0t] beat0 handshake m_axi_rdata=%0h", $time, m_axi_rdata);
                        beat_count <= beat_count + 1'b1;
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            fifo_re      <= 1'b1;
                            beat_loaded  <= 1'b0;
                            beat_slice   <= '0;
                            drain_count  <= '0;
                            state        <= ST_DRAIN;
                            $display("[RLAST @%0t] mac=%0d burst=%0d beat_cnt=%0d fifo_wptr=%0d fifo_rptr=%0d fifo_cnt=%0d",
                                $time, mac_idx, burst_idx, beat_count+1, fifo_wptr, fifo_rptr, fifo_count+1);
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
                        // fifo_re_d1 indicates fifo_rdata NBA has committed.
                        // Only latch beat_buf and assert beat_loaded once
                        // fifo_rdata is guaranteed stable.
                        if (fifo_re_d1) begin
                            beat_buf    <= fifo_rdata;
                            beat_loaded <= 1'b1;
                            beat_slice  <= '0;
                            if (drain_count == 0)
                                $display("[BEATBUF0 @%0t] fifo_rdata=%0h (beat0 coef0 expected=%0h)",
                                    $time, fifo_rdata, mac_idx * COEF_DEPTH + burst_idx * COEFS_PER_BURST);
                        end
                    end

                    if (beat_loaded) begin
                        // Drive write to current MAC at the current depth address
                        coef_we    <= 1'b1;
                        coef_wmac  <= mac_idx;
                        coef_waddr <= $clog2(COEF_DEPTH)'(32'(burst_idx) * COEFS_PER_BURST + 32'(drain_count));
                        coef_wdata <= slice_coef;
                        if (mac_idx == $clog2(NUM_MACS)'(NUM_MACS-1) && drain_count < 4)
                            $display("[DRAIN255 @%0t] burst=%0d drain=%0d wdata=%0h",
                                $time, burst_idx, drain_count, slice_coef);

                        drain_count <= drain_count + 1'b1;
                        if (beat_slice == 2'd3) begin
                            // Done with this beat -- fetch the next, unless
                            // we just emitted the last coef of the burst.
                            if (drain_count == 10'(COEFS_PER_BURST - 1)) begin
                                state       <= ST_NEXT;
                                beat_loaded <= 1'b0;
                            end else begin
                                fifo_re     <= 1'b1;
                                beat_slice  <= '0;
                                beat_loaded <= 1'b0;   // reload on next cycle
                            end
                        end else begin
                            beat_slice  <= beat_slice + 1'b1;
                        end
                    end
                end

                // ----- ADVANCE MAC / BURST counters -----
                // BURSTS_PER_MAC bursts per MAC (1 @ TPP=64, 4 @ TPP=256);
                // advance burst_idx first, then the MAC.
                ST_NEXT: begin
                    if (BURSTS_PER_MAC > 1 && 32'(burst_idx) != BURSTS_PER_MAC - 1) begin
                        burst_idx <= burst_idx + 1'b1;
                        state     <= ST_ISSUE_AR;
                    end else if (mac_idx == $clog2(NUM_MACS)'(NUM_MACS - 1)) begin
                        state <= ST_DONE;
                    end else begin
                        burst_idx <= '0;
                        mac_idx   <= mac_idx + 1'b1;
                        state     <= ST_ISSUE_AR;
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
