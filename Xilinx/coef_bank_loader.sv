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
//    DDR4_BASE_ADDR + bank_id * BS   | Start of bank `bank_id` (legacy slot path)
//      offset 0                      | MAC 0  coef[0] ... coef[COEF_DEPTH-1]
//      offset MAC_BYTES              | MAC 1  ...
//      ...                           |
//      offset (NUM_MACS-1)*MAC_BYTES | MAC NUM_MACS-1
//    DDR4_BASE_ADDR + (bank_id+1)*BS | Start of next bank
//
//    COEF_DEPTH = 16 phases * TAPS_PER_PHASE;  MAC_BYTES = COEF_DEPTH * 4
//    BS (BANK_SIZE_BYTES) = NUM_MACS * MAC_BYTES
//      1M taps  (release, 256 MACs x TPP 256):  256 x 16 KB =  4 MB per bank
//      5.24M    (proven,  1280 MACs x TPP 256): 1280 x 16 KB = 21 MB per bank
//    Directory-resolved loads (load_by_id) use the entry's ddr4_offset
//    instead of bank_id * BS; payload_bytes must equal BS exactly.
//
//  Each coefficient is stored as a 32-bit signed word in DDR4 (sign-extended
//  from the underlying 18-bit value). This wastes ~44% of bank storage but
//  keeps DDR4 addressing trivially aligned and lets us pack 4 coefs per
//  128-bit AXI beat without bit-fiddling.
//
//  ----------------------------------------------------------------------------
//  PACKED 18-BIT PAYLOAD (packing = 1, 2026-10-05, bom item 18 (a))
//  ----------------------------------------------------------------------------
//
//  Selected per directory entry (beat 1 byte 0x14 = packing; 0 = 32-bit v1,
//  1 = packed). The payload is ONE continuous stream of NUM_MACS*COEF_DEPTH
//  18-bit coefficients in the same MAC-major order, 7 per 128-bit beat
//  (bits [17:0], [35:18], ... [125:108]; [127:126] are padding), with no
//  per-MAC or per-burst alignment: coefficient g = mac*COEF_DEPTH + addr
//  sits in beat g/7 slot g%7. The last beat is zero-padded. Expected
//  payload_bytes = ceil(N/7)*16 (11,983,728 B at 1280x256 vs 21.0 MB v1;
//  0.570x). The loader fetches it as 256-beat bursts (last one short) and
//  the drain walks (mac, addr) counters independently of beat boundaries.
//  Only the directory path supports packing; the legacy slot path is v1.
//  The flash image for a packed filter is this payload verbatim, so the
//  QSPI boot loader stays a plain copier.
//
//  ----------------------------------------------------------------------------
//  TIMING BUDGET
//  ----------------------------------------------------------------------------
//
//    Per burst:      1024 coefs = 256 beats; ~256 cycles AXI receive +
//                    1024 cycles drain (ST_DRAIN writes ONE coef per cycle
//                    onto the single URAM write bus) ~= 1300 cycles, run
//                    sequentially (no AR/R overlap).
//    Per MAC:        COEF_DEPTH / 1024 bursts (4 at TPP=256)
//    Per bank @ ui_clk 300 MHz:
//      1M taps  (256 x 256):   1024 bursts ~= 1.3M cycles ~=  4.4 ms
//      5.24M    (1280 x 256):  5120 bursts ~= 6.7M cycles ~= 22 ms
//    DDR4 bandwidth is not the limit (~1 ms for 21 MB); the drain bus is.
//
//  There is NO fade around a filter change (dac_coef_subsys ties fade_out_req
//  low): the shadow bank fills while audio plays from the active bank and
//  the swap is atomic, so these figures are selection-to-effect latency, not
//  a mute. AR/R pipelining would save ~20%; a 4-coef-wide write bus ~4x.
//
//  ----------------------------------------------------------------------------
//  FILTER DIRECTORY LOOKUP (load_by_id = 1, docs/coef_format_v2.md)
//  ----------------------------------------------------------------------------
//
//  The host stages a directory at DIR_BASE_ADDR: 32-byte entries, terminated
//  by an all-zero entry. Beat 0 of each entry (little-endian byte offsets):
//
//    [15:0]   filter_id        (0x00, 2 B)
//    [23:16]  phase_type       (0x02)
//    [31:24]  rate_family      (0x03)
//    [63:32]  tap_count        (0x04)
//    [95:64]  ddr4_offset      (0x08, in 16-byte units)
//    [127:96] payload_bytes    (0x0C)
//
//  Beat 1 (latency_us + reserved) is not used by the loader. The loader
//  walks entries one AXI burst (2 beats) at a time until filter_id matches,
//  the terminator is reached, or DIR_MAX_ENTRIES have been scanned. On a
//  match, payload_bytes must equal BANK_SIZE_BYTES (a filter built for a
//  different NUM_MACS/TAPS_PER_PHASE is rejected rather than loaded as
//  garbage) and the bank is fetched from ddr4_offset*16.
//
//  load_done pulses at the end of EVERY attempt; load_err is a level, set
//  before load_done on failure and cleared on the next load_start, so the
//  bank manager can decide whether to swap banks.
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
    parameter logic [31:0]   BANK_SIZE_BYTES  = 32'(NUM_MACS * COEF_DEPTH * 4), // e.g. 4 MB for 1024x1024
    parameter logic [31:0]   DIR_BASE_ADDR    = 32'h3FFF_0000,  // top 64 KB of the 1 GB AXI window
    parameter int            DIR_MAX_ENTRIES  = 256             // scan cap (32 B each = 8 KB)
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  tri0                           enforce_stream_rate,
    input  tri0 [2:0]                     stream_rate,

    // -- Control interface (from coef_bank_manager) ----------------------
    input  logic                          load_start,
    input  logic                          load_by_id,      // 1: directory lookup of load_filter_id
    input  logic [BANK_BITS-1:0]          load_bank_id,    // 0: legacy fixed slot
    input  logic [15:0]                   load_filter_id,
    output logic                          load_done,       // pulse: attempt finished (see load_err)
    output logic                          load_err,        // level: last attempt failed
    output logic [1:0]                    load_err_code,   // 1 = ID not found, 2 = size mismatch

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
    input  logic                          coef_stall,      // CDC FIFO almost full: hold coef_we
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

    // Packed-mode geometry (7 x 18-bit per beat, continuous stream)
    localparam int          PK_PER_BEAT    = 7;
    localparam longint      PK_TOTAL_COEFS = longint'(NUM_MACS) * COEF_DEPTH;
    localparam longint      PK_TOTAL_BEATS = (PK_TOTAL_COEFS + PK_PER_BEAT - 1) / PK_PER_BEAT;
    localparam logic [31:0] PK_BYTES       = 32'(PK_TOTAL_BEATS * (AXI_DATA_WIDTH / 8));
    localparam longint      PK_BURSTS      = (PK_TOTAL_BEATS + BEATS_PER_BURST - 1) / BEATS_PER_BURST;
    localparam int          PK_LAST_BEATS  = int'(PK_TOTAL_BEATS - (PK_BURSTS - 1) * BEATS_PER_BURST);

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
    typedef enum logic [3:0] {
        ST_IDLE      = 4'd0,
        ST_ISSUE_AR  = 4'd1,
        ST_RECV_R    = 4'd2,
        ST_DRAIN     = 4'd3,
        ST_NEXT      = 4'd4,
        ST_DONE      = 4'd5,
        ST_DIR_AR    = 4'd6,   // directory: issue 2-beat read of entry dir_idx
        ST_DIR_R     = 4'd7,   // directory: capture beat 0
        ST_DIR_CHECK = 4'd8,   // directory: match / terminator / advance
        ST_ERR       = 4'd9    // lookup failed: flag and finish
    } state_t;

    localparam int DIR_ENTRY_BYTES = 32;
    localparam int DIDX_W          = $clog2(DIR_MAX_ENTRIES);

    state_t                      state;
    logic [BANK_BITS-1:0]        bank_id;
    logic [AXI_ADDR_WIDTH-1:0]   bank_base;     // resolved start of the bank image in DDR4
    logic [15:0]                 filter_id_r;
    logic [DIDX_W-1:0]           dir_idx;
    logic [AXI_DATA_WIDTH-1:0]   dir_beat0;
    logic [AXI_DATA_WIDTH-1:0]   dir_beat1;
    logic [2:0] rate_r;
    logic enforce_rate_r;
    logic                        packed_r;      // current load uses the packed payload
    logic [31:0]                 pk_burst;      // packed: burst number (0..PK_BURSTS-1)
    logic [8:0]                  pk_burst_beats;// packed: beats in the current burst
    logic [8:0]                  pk_beat;       // packed: beats drained in this burst
    logic [$clog2(COEF_DEPTH)-1:0] pk_waddr;    // packed: running coef address within MAC
    logic [31:0]                 pk_left;       // packed: coefficients still to write
    logic [$clog2(NUM_MACS)-1:0] mac_idx;
    logic [BIDX_W-1:0]           burst_idx;     // burst within MAC (0..BURSTS_PER_MAC-1)
    logic [9:0]                  beat_count;    // 0..255 (one extra bit for safety)
    logic [9:0]                  drain_count;   // 0..1023 within a burst (4 per beat)

    // Burst address: bank_base + mac * MAC_BYTES + burst_idx * BURST_BYTES.
    // bank_base = DDR4_BASE + bank_id * BANK_SIZE_BYTES (legacy slot mode) or
    // directory ddr4_offset * 16 (ID mode).
    // Each AXI burst = 256 beats x 16 bytes = 4 KB = COEFS_PER_BURST coefs;
    // BURSTS_PER_MAC bursts cover all COEF_DEPTH coefs of one MAC.
    wire [AXI_ADDR_WIDTH-1:0] burst_addr =
        bank_base
        + (AXI_ADDR_WIDTH'(mac_idx) * MAC_BYTES)
        + (AXI_ADDR_WIDTH'(burst_idx) * BURST_BYTES);

    wire [AXI_ADDR_WIDTH-1:0] dir_entry_addr =
        DIR_BASE_ADDR + (AXI_ADDR_WIDTH'(dir_idx) * DIR_ENTRY_BYTES);

    // Directory field slices (beat 0 + the packing byte at entry offset 0x14)
    wire [15:0] dir_filter_id     = dir_beat0[15:0];
    wire [31:0] dir_ddr4_offset   = dir_beat0[95:64];
    wire [31:0] dir_payload_bytes = dir_beat0[127:96];
    wire        dir_terminator    = (dir_beat0 == '0);
    wire [7:0]  dir_packing       = dir_beat1[39:32];
    wire        dir_packing_ok    = (dir_packing == 8'd0) || (dir_packing == 8'd1);
    wire [31:0] dir_expect_bytes  = (dir_packing == 8'd1) ? PK_BYTES : BANK_SIZE_BYTES;
    wire [7:0] dir_rate_code = dir_beat0[31:24];
    wire [1:0] dir_rate_shift = dir_rate_code[2:1];
    wire [7:0] dir_rate_schema = dir_beat1[55:48];
    wire [7:0] dir_rate_shift_mirror = dir_beat1[47:40];
    wire dir_rate_version_ok =
        ((dir_rate_schema == 8'd0) && (rate_r[2:1] == 0) &&
         (dir_rate_shift == 0) && (dir_rate_shift_mirror == 0)) ||
        ((dir_rate_schema == 8'd3) &&
         (dir_rate_shift == rate_r[2:1]) &&
         (dir_rate_shift_mirror == {6'd0, rate_r[2:1]}));
    wire dir_rate_ok = dir_rate_version_ok &&
                       (dir_rate_code[0] == ~rate_r[0]) &&
                       (dir_rate_code[7:3] == 0) &&
                       dir_beat0[63:32] == (32'(NUM_MACS * COEF_DEPTH) >> rate_r[2:1]);

    // Packed burst address: beats issued so far x 16 B
    wire [AXI_ADDR_WIDTH-1:0] pk_burst_addr =
        bank_base + AXI_ADDR_WIDTH'(pk_burst * BEATS_PER_BURST * (AXI_DATA_WIDTH / 8));
    wire        pk_last_burst = (pk_burst == 32'(PK_BURSTS - 1));
    wire [8:0]  pk_this_beats = pk_last_burst ? 9'(PK_LAST_BEATS) : 9'(BEATS_PER_BURST);

    // -------------------------------------------------------------------------
    //  Drain-side: each FIFO beat carries 4 coefs. We slice them out one at
    //  a time and pulse coef_we for each.
    // -------------------------------------------------------------------------
    logic [2:0]                  beat_slice;     // coef within the beat (0..3 v1, 0..6 packed)
    logic                        beat_loaded;    // current beat_buf is valid
    logic [AXI_DATA_WIDTH-1:0]   beat_buf;       // registered copy of fifo_rdata, immune to NBA races
    wire signed [COEF_WIDTH-1:0] slice_coef = packed_r
        ? signed'(beat_buf[(beat_slice * COEF_WIDTH) +: COEF_WIDTH])
        : signed'(beat_buf[(beat_slice * 32)         +: COEF_WIDTH]);
    // packed: this slice completes the beat (7th slot or the final coefficient)
    wire pk_beat_last_slice = (beat_slice == 3'd6) || (pk_left == 32'd1);

    // -------------------------------------------------------------------------
    //  Sequential FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            bank_id        <= '0;
            bank_base      <= '0;
            filter_id_r    <= '0;
            dir_idx        <= '0;
            dir_beat0      <= '0;
            dir_beat1      <= '0;
            rate_r         <= 0;
            enforce_rate_r <= 0;
            packed_r       <= 1'b0;
            pk_burst       <= '0;
            pk_burst_beats <= '0;
            pk_beat        <= '0;
            pk_waddr       <= '0;
            pk_left        <= '0;
            load_err       <= 1'b0;
            load_err_code  <= 2'd0;
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
                        bank_id       <= load_bank_id;
                        filter_id_r   <= load_filter_id;
                        mac_idx       <= '0;
                        burst_idx     <= '0;
                        packed_r      <= 1'b0;          // legacy slot path is always v1
                        pk_burst      <= '0;
                        pk_waddr      <= '0;
                        pk_left       <= 32'(PK_TOTAL_COEFS);
                        load_err      <= 1'b0;
                        load_err_code <= 2'd0;
                        rate_r <= stream_rate;
                        enforce_rate_r <= enforce_stream_rate;
                        if (load_by_id) begin
                            dir_idx <= '0;
                            state   <= ST_DIR_AR;
                        end else if (enforce_stream_rate) begin
                            load_err_code <= 2'd3;
                            state <= ST_ERR;
                        end else begin
                            bank_base <= DDR4_BASE_ADDR
                                       + (AXI_ADDR_WIDTH'(load_bank_id) * BANK_SIZE_BYTES);
                            state     <= ST_ISSUE_AR;
                        end
                    end
                end

                // ----- DIRECTORY: issue a 2-beat read of one entry -----
                ST_DIR_AR: begin
                    m_axi_araddr  <= dir_entry_addr;
                    m_axi_arlen   <= 8'd1;             // 2 beats = 32 B entry
                    m_axi_arsize  <= 3'd4;
                    m_axi_arburst <= 2'b01;
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        beat_count    <= '0;
                        state         <= ST_DIR_R;
                    end
                end

                // ----- DIRECTORY: capture beat 0, wait for rlast -----
                ST_DIR_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        if (beat_count == 0)
                            dir_beat0 <= m_axi_rdata;
                        else
                            dir_beat1 <= m_axi_rdata;
                        beat_count <= beat_count + 1'b1;
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            state        <= ST_DIR_CHECK;
                        end
                    end
                end

                // ----- DIRECTORY: terminator / match / advance -----
                ST_DIR_CHECK: begin
                    if (dir_terminator) begin
                        load_err_code <= 2'd1;
                        state         <= ST_ERR;
                    end else if (dir_filter_id == filter_id_r) begin
                        if (enforce_rate_r && !dir_rate_ok) begin
                            load_err_code <= 2'd3;
                            state <= ST_ERR;
                        end else if (!dir_packing_ok || dir_payload_bytes != dir_expect_bytes) begin
                            load_err_code <= 2'd2;
                            state         <= ST_ERR;
                        end else begin
                            bank_base <= AXI_ADDR_WIDTH'({dir_ddr4_offset, 4'b0000});
                            packed_r  <= (dir_packing == 8'd1);
                            state     <= ST_ISSUE_AR;
                        end
                    end else if (32'(dir_idx) == DIR_MAX_ENTRIES - 1) begin
                        load_err_code <= 2'd1;
                        state         <= ST_ERR;
                    end else begin
                        dir_idx <= dir_idx + 1'b1;
                        state   <= ST_DIR_AR;
                    end
                end

                // ----- LOOKUP FAILED -----
                ST_ERR: begin
                    load_err <= 1'b1;
                    state    <= ST_DONE;
                end

                // ----- ISSUE AR -----
                // Drive arvalid=1 and hold until slave asserts arready
                // while arvalid is already high (proper AXI handshake).
                ST_ISSUE_AR: begin
                    m_axi_araddr  <= packed_r ? pk_burst_addr : burst_addr;
                    m_axi_arlen   <= packed_r ? 8'(pk_this_beats - 9'd1) : 8'(BEATS_PER_BURST - 1);
                    m_axi_arsize  <= 3'd4;
                    m_axi_arburst <= 2'b01;
                    m_axi_arvalid <= 1'b1;
                    pk_burst_beats <= pk_this_beats;
                    pk_beat        <= '0;
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

                    if (beat_loaded && !coef_stall && packed_r) begin
                        // Packed: (mac_idx, pk_waddr) walk the whole bank; beat
                        // boundaries are independent of MAC boundaries.
                        coef_we    <= 1'b1;
                        coef_wmac  <= mac_idx;
                        coef_waddr <= pk_waddr;
                        coef_wdata <= slice_coef;
                        pk_left    <= pk_left - 32'd1;
                        if (pk_waddr == $clog2(COEF_DEPTH)'(COEF_DEPTH - 1)) begin
                            pk_waddr <= '0;
                            mac_idx  <= mac_idx + 1'b1;
                        end else begin
                            pk_waddr <= pk_waddr + 1'b1;
                        end
                        if (pk_beat_last_slice) begin
                            beat_loaded <= 1'b0;
                            beat_slice  <= '0;
                            pk_beat     <= pk_beat + 9'd1;
                            if (pk_beat == pk_burst_beats - 9'd1 || pk_left == 32'd1)
                                state   <= ST_NEXT;
                            else
                                fifo_re <= 1'b1;
                        end else begin
                            beat_slice  <= beat_slice + 1'b1;
                        end
                    end else if (beat_loaded && !coef_stall) begin
                        // Drive write to current MAC at the current depth address
                        coef_we    <= 1'b1;
                        coef_wmac  <= mac_idx;
                        coef_waddr <= $clog2(COEF_DEPTH)'(32'(burst_idx) * COEFS_PER_BURST + 32'(drain_count));
                        coef_wdata <= slice_coef;
                        if (mac_idx == $clog2(NUM_MACS)'(NUM_MACS-1) && drain_count < 4)
                            $display("[DRAIN255 @%0t] burst=%0d drain=%0d wdata=%0h",
                                $time, burst_idx, drain_count, slice_coef);

                        drain_count <= drain_count + 1'b1;
                        if (beat_slice == 3'd3) begin
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
                    if (packed_r) begin
                        if (pk_last_burst || pk_left == 32'd0) begin
                            state <= ST_DONE;
                        end else begin
                            pk_burst <= pk_burst + 32'd1;
                            state    <= ST_ISSUE_AR;
                        end
                    end else if (BURSTS_PER_MAC > 1 && 32'(burst_idx) != BURSTS_PER_MAC - 1) begin
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
