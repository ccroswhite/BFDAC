`timescale 1ns / 1ps

// =============================================================================
//  TB_COEF_BANK_LOADER
//
//  Self-checking simulation testbench for coef_bank_loader.
//
//  What is checked:
//    1. AXI AR channel: correct araddr, arlen (255), arsize (4), arburst (INCR)
//       for every burst (256 total across 256 MACs x 1 burst each).
//    2. Coefficient write broadcast: correct coef_wmac, coef_waddr, and
//       coef_wdata for every coef within the first two MACs (MAC 0 and MAC 1)
//       and spot-checks the last MAC (MAC 255).
//    3. load_done asserts exactly once at the end, one cycle after ST_DONE.
//    4. load_done de-asserts on the cycle after it asserted.
//
//  AXI slave model:
//    - AR channel: accepts immediately (arready always 1, but one test case
//      inserts a 3-cycle stall to verify the FSM waits).
//    - R channel: returns data after a configurable READ_LATENCY, one beat per
//      cycle, with rlast on the 256th beat.
//
//  Coefficient data:
//    Each 128-bit beat is packed with 4 x 32-bit words.  The testbench fills
//    DDR4 memory with a deterministic pattern:
//        word[mac][coef_idx] = (mac * COEF_DEPTH + coef_idx) & 18'h3FFFF
//    This is what the checker expects to receive on the coef write bus.
// =============================================================================

module tb_coef_bank_loader;

    // -------------------------------------------------------------------------
    //  Parameters matching the DUT (keep in sync with coef_bank_loader.sv)
    // -------------------------------------------------------------------------
    localparam int NUM_MACS          = 256;   // Scaled down for simulation (production=1024)
    localparam int COEF_WIDTH        = 18;
`ifdef TB_TPP256
    localparam int COEF_DEPTH        = 4096;  // 16 phases * 256 taps/phase (KU15P config)
`else
    localparam int COEF_DEPTH        = 1024;  // 16 phases * 64 taps/phase
`endif
    localparam int BANK_BITS         = 4;
    localparam int AXI_DATA_WIDTH    = 128;
    localparam int AXI_ADDR_WIDTH    = 32;
    localparam logic [31:0] BASE     = 32'h0000_0000;
    localparam logic [31:0] BANK_SZ  = 32'(1024 * COEF_DEPTH * 4);  // 4 MB @1024 / 16 MB @4096
    localparam logic [31:0] DIR_BASE = 32'h3FFF_0000;              // filter directory
    localparam int          DIR_MAX  = 256;

    localparam int COEFS_PER_BEAT    = AXI_DATA_WIDTH / 32;       // 4
    localparam int BEATS_PER_BURST   = 256;
    localparam int COEFS_PER_BURST   = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC    = COEF_DEPTH / COEFS_PER_BURST;     // 1
    localparam int MAC_BYTES         = COEF_DEPTH * 4;                   // 4 KB
    localparam int BURST_BYTES       = BEATS_PER_BURST * (AXI_DATA_WIDTH/8); // 4 KB

    // Packed 18-bit payload geometry (7 coefs / beat, continuous stream) — mirrors the DUT
    localparam int          PK_PER_BEAT  = 7;
    localparam int          PK_COEFS     = NUM_MACS * COEF_DEPTH;
    localparam int          PK_BEATS     = (PK_COEFS + PK_PER_BEAT - 1) / PK_PER_BEAT;
    localparam logic [31:0] PK_BYTES     = 32'(PK_BEATS * (AXI_DATA_WIDTH / 8));
    localparam int          PK_BURSTS    = (PK_BEATS + BEATS_PER_BURST - 1) / BEATS_PER_BURST;
    localparam int          PK_LAST      = PK_BEATS - (PK_BURSTS - 1) * BEATS_PER_BURST;

    localparam real CLK_PERIOD       = 2.8;   // ~357 MHz

    // -------------------------------------------------------------------------
    //  Slave model knobs
    // -------------------------------------------------------------------------
    int AR_STALL_CYCLES = 0;    // extra cycles before arready (set per test)
    int READ_LATENCY    = 2;    // cycles from AR handshake to first rvalid

    // -------------------------------------------------------------------------
    //  DUT port signals
    // -------------------------------------------------------------------------
    logic                         clk;
    logic                         rst_n;

    logic                         load_start;
    logic                         load_by_id;
    logic [BANK_BITS-1:0]         load_bank_id;
    logic [15:0]                  load_filter_id;
    logic                         load_done;
    logic                         load_err;
    logic [1:0]                   load_err_code;

    // Expected bank base for the slave model / AR checker (legacy: slot*BANK_SZ;
    // ID mode: the directory entry's ddr4_offset*16)
    logic [AXI_ADDR_WIDTH-1:0]    exp_bank_base;
    logic                         exp_packed;     // image at exp_bank_base is the packed stream

    // Directory model: both beats of each 32-byte entry.
    // beat 0 = {payload_bytes[31:0], ddr4_offset[31:0], tap_count[31:0],
    //           rate_family[7:0], phase_type[7:0], filter_id[15:0]}
    // beat 1 = {reserved, packing[39:32], latency_us[31:0]}
    logic [AXI_DATA_WIDTH-1:0]    dir_beat0 [0:7];
    logic [AXI_DATA_WIDTH-1:0]    dir_beat1 [0:7];
    int                           dir_reads;

    function automatic logic [AXI_DATA_WIDTH-1:0] mk_dir_entry(
        input logic [15:0] fid, input logic [31:0] offset_bytes, input logic [31:0] payload);
        return {payload, offset_bytes >> 4, 32'd0, 8'd0, 8'd0, fid};
    endfunction
    function automatic logic [AXI_DATA_WIDTH-1:0] mk_dir_beat1(input logic [7:0] packing);
        return {88'd0, packing, 32'd0};
    endfunction

    // Packed beat b of the stream: slot s holds coefficient g = 7b+s, value
    // (g & 0x3FFFF) == ((mac*COEF_DEPTH + addr) & 0x3FFFF) — same pattern the
    // write checker expects, so one checker serves both layouts.
    function automatic logic [AXI_DATA_WIDTH-1:0] gen_packed_beat(input int b);
        logic [AXI_DATA_WIDTH-1:0] beat;
        int g;
        beat = '0;
        for (int s = 0; s < PK_PER_BEAT; s++) begin
            g = b * PK_PER_BEAT + s;
            if (g < PK_COEFS)
                beat[s*18 +: 18] = 18'(g & 32'h3FFFF);
        end
        return beat;
    endfunction

    logic [AXI_ADDR_WIDTH-1:0]    m_axi_araddr;
    logic [7:0]                   m_axi_arlen;
    logic [2:0]                   m_axi_arsize;
    logic [1:0]                   m_axi_arburst;
    logic                         m_axi_arvalid;
    logic                         m_axi_arready;

    logic [AXI_DATA_WIDTH-1:0]    m_axi_rdata;
    logic [1:0]                   m_axi_rresp;
    logic                         m_axi_rlast;
    logic                         m_axi_rvalid;
    logic                         m_axi_rready;

    logic                         coef_we;
    logic [$clog2(COEF_DEPTH)-1:0] coef_waddr;  // matches DUT port width
    logic signed [COEF_WIDTH-1:0] coef_wdata;
    logic [7:0]                   coef_wmac;

    // -------------------------------------------------------------------------
    //  DUT instantiation
    // -------------------------------------------------------------------------
    coef_bank_loader #(
        .NUM_MACS       (NUM_MACS),
        .COEF_WIDTH     (COEF_WIDTH),
        .COEF_DEPTH     (COEF_DEPTH),
        .BANK_BITS      (BANK_BITS),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .DDR4_BASE_ADDR (BASE),
        .BANK_SIZE_BYTES(BANK_SZ),
        .DIR_BASE_ADDR  (DIR_BASE),
        .DIR_MAX_ENTRIES(DIR_MAX)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .load_start      (load_start),
        .load_by_id      (load_by_id),
        .load_bank_id    (load_bank_id),
        .load_filter_id  (load_filter_id),
        .load_done       (load_done),
        .load_err        (load_err),
        .load_err_code   (load_err_code),
        .m_axi_araddr    (m_axi_araddr),
        .m_axi_arlen     (m_axi_arlen),
        .m_axi_arsize    (m_axi_arsize),
        .m_axi_arburst   (m_axi_arburst),
        .m_axi_arvalid   (m_axi_arvalid),
        .m_axi_arready   (m_axi_arready),
        .m_axi_rdata     (m_axi_rdata),
        .m_axi_rresp     (m_axi_rresp),
        .m_axi_rlast     (m_axi_rlast),
        .m_axi_rvalid    (m_axi_rvalid),
        .m_axi_rready    (m_axi_rready),
        .coef_stall      (1'b0),
        .coef_we         (coef_we),
        .coef_waddr      (coef_waddr),
        .coef_wdata      (coef_wdata),
        .coef_wmac       (coef_wmac)
    );

    // -------------------------------------------------------------------------
    //  Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2.0) clk = ~clk;

    // -------------------------------------------------------------------------
    //  AXI slave model state
    // -------------------------------------------------------------------------
    // AR channel
    logic [AXI_ADDR_WIDTH-1:0] slave_araddr;
    logic [7:0]                slave_arlen;
    logic                      ar_accepted;

    // R channel pipeline
    // Per-beat data generation: deterministic from address
    // Returns 128-bit beat with 4 x 32-bit coef words packed.
    // coef word s = (mac_num * COEF_DEPTH + coef_idx) & 18'h3FFFF
    function automatic logic [AXI_DATA_WIDTH-1:0] gen_beat (
        input logic [AXI_ADDR_WIDTH-1:0] base_addr,
        input int                        beat_idx
    );
        logic [AXI_ADDR_WIDTH-1:0] offset;
        int mac_num, coef_base, coef_idx, s;
        logic [AXI_DATA_WIDTH-1:0] beat;
        // Directory region: entry index from address
        if (base_addr >= DIR_BASE) begin
            if (beat_idx == 0)
                return dir_beat0[int'((base_addr - DIR_BASE) / 32)];
            else
                return dir_beat1[int'((base_addr - DIR_BASE) / 32)];
        end
        offset     = base_addr - exp_bank_base;
        if (exp_packed)
            return gen_packed_beat(int'(offset) / (AXI_DATA_WIDTH / 8) + beat_idx);
        mac_num    = int'(offset) / MAC_BYTES;
        // Intra-MAC burst offset (multi-burst per MAC when COEF_DEPTH > 1024)
        coef_base  = (int'(offset) % MAC_BYTES) / 4 + beat_idx * COEFS_PER_BEAT;
        beat       = '0;
        for (s = 0; s < COEFS_PER_BEAT; s++) begin
            coef_idx       = coef_base + s;
            beat[s*32 +: 32] = 32'((mac_num * COEF_DEPTH + coef_idx) & 32'h3FFFF);
        end
        return beat;
    endfunction

    // -------------------------------------------------------------------------
    //  AR-channel slave: accept with configurable stall
    // -------------------------------------------------------------------------
    int  ar_stall_cnt;
    logic ar_txn_pending;   // sticky: set when accepted, cleared when arvalid deasserts

    always_ff @(posedge clk) begin
        m_axi_arready <= 1'b0;
        ar_accepted   <= 1'b0;
        if (!rst_n) begin
            ar_stall_cnt   <= 0;
            ar_txn_pending <= 1'b0;
        end else begin
            if (!m_axi_arvalid)
                ar_txn_pending <= 1'b0;

            if (m_axi_arvalid && !ar_txn_pending) begin
                if (ar_stall_cnt < AR_STALL_CYCLES) begin
                    ar_stall_cnt <= ar_stall_cnt + 1;
                end else begin
                    ar_stall_cnt   <= 0;
                    ar_txn_pending <= 1'b1;
                    m_axi_arready  <= 1'b1;
                    ar_accepted    <= 1'b1;
                    slave_araddr   <= m_axi_araddr;
                    slave_arlen    <= m_axi_arlen;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    //  R-channel slave: flat-register implementation (XSim compatible).
    //  Supports one outstanding transaction at a time (sequential FSM matches DUT).
    //  States: R_IDLE -> R_DELAY -> R_PRESENT -> R_BUBBLE -> R_PRESENT ...
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        R_IDLE    = 2'd0,
        R_DELAY   = 2'd1,
        R_PRESENT = 2'd2,
        R_BUBBLE  = 2'd3
    } r_state_t;

    r_state_t                    r_state;
    logic [AXI_ADDR_WIDTH-1:0]   r_araddr;          // captured AR address
    int                          r_beats_remaining;  // beats left in burst
    int                          r_beat_index;       // current beat number
    int                          r_delay_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_state          <= R_IDLE;
            r_araddr         <= '0;
            r_beats_remaining <= 0;
            r_beat_index     <= 0;
            r_delay_cnt      <= 0;
            m_axi_rvalid     <= 1'b0;
            m_axi_rlast      <= 1'b0;
            m_axi_rdata      <= '0;
            m_axi_rresp      <= 2'b00;
        end else begin
            m_axi_rvalid <= 1'b0;
            m_axi_rlast  <= 1'b0;

            unique case (r_state)

                R_IDLE: begin
                    if (ar_accepted) begin
                        r_araddr          <= slave_araddr;
                        r_beats_remaining <= int'(slave_arlen) + 1;
                        r_beat_index      <= 0;
                        r_delay_cnt       <= 0;
                        r_state           <= R_DELAY;
                    end
                end

                R_DELAY: begin
                    if (r_delay_cnt == READ_LATENCY - 1) begin
                        m_axi_rdata  <= gen_beat(r_araddr, 0);
                        r_state      <= R_PRESENT;
                    end
                    r_delay_cnt <= r_delay_cnt + 1;
                end

                R_PRESENT: begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= (r_beats_remaining == 1);
                    if (m_axi_rready) begin
                        r_beats_remaining <= r_beats_remaining - 1;
                        r_beat_index      <= r_beat_index + 1;
                        if (r_beats_remaining == 1) begin
                            // Last beat consumed — go idle or accept next AR
                            if (ar_accepted) begin
                                r_araddr          <= slave_araddr;
                                r_beats_remaining <= int'(slave_arlen) + 1;
                                r_beat_index      <= 0;
                                r_delay_cnt       <= 0;
                                r_state           <= R_DELAY;
                            end else begin
                                r_state <= R_IDLE;
                            end
                        end else begin
                            // More beats: bubble to load next beat into rdata
                            r_state <= R_BUBBLE;
                        end
                    end else begin
                        m_axi_rvalid <= 1'b1;  // hold
                        m_axi_rlast  <= (r_beats_remaining == 1);
                    end
                end

                R_BUBBLE: begin
                    // Load next beat, then go back to PRESENT
                    m_axi_rdata <= gen_beat(r_araddr, r_beat_index);
                    r_state     <= R_PRESENT;
                end

            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Checker: capture every coef write and verify against expected pattern
    // -------------------------------------------------------------------------
    int  total_writes;
    int  error_count;
    // Module-scope temporaries for coef checker (XSim: no automatic vars in always)
    int                          chk_mac_n;
    int                          chk_cidx;
    int                          chk_expected_raw;
    logic signed [COEF_WIDTH-1:0] chk_expected;

    // Load timeout scales with bursts per MAC (4x cycles at COEF_DEPTH=4096)
    localparam int LOAD_TIMEOUT   = 1_500_000 * BURSTS_PER_MAC;

    // Which MACs to check exhaustively (first two and last one)
    localparam int CHECK_MAC_LO   = 0;
    localparam int CHECK_MAC_HI   = 1;
    localparam int CHECK_MAC_LAST = NUM_MACS - 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            total_writes = 0;
            error_count  = 0;
        end else if (coef_we) begin
            total_writes = total_writes + 1;

            // Check exhaustively for MAC 0, MAC 1, and MAC 255
            if (coef_wmac == CHECK_MAC_LO  ||
                coef_wmac == CHECK_MAC_HI  ||
                coef_wmac == CHECK_MAC_LAST) begin

                chk_mac_n        = int'(coef_wmac);
                chk_cidx         = int'(coef_waddr);
                chk_expected_raw = (chk_mac_n * COEF_DEPTH + chk_cidx) & 32'h3FFFF;
                chk_expected     = signed'(COEF_WIDTH'(chk_expected_raw));

                if (coef_wdata !== chk_expected) begin
                    $display("ERROR @ %0t : mac=%0d addr=%0d  got=%0h  exp=%0h",
                             $time, coef_wmac, coef_waddr,
                             coef_wdata, chk_expected);
                    error_count = error_count + 1;
                end
            end

            // Address must always be in [0 .. COEF_DEPTH-1]
            if (int'(coef_waddr) >= COEF_DEPTH) begin
                $display("ERROR @ %0t : coef_waddr=%0d out of range (mac=%0d)",
                         $time, coef_waddr, coef_wmac);
                error_count = error_count + 1;
            end

            // MAC index must always be in [0 .. NUM_MACS-1]
            if (int'(coef_wmac) >= NUM_MACS) begin
                $display("ERROR @ %0t : coef_wmac=%0d out of range", $time, coef_wmac);
                error_count = error_count + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AR-channel checker: runs on every arvalid/arready handshake
    // -------------------------------------------------------------------------
    int   ar_burst_num;  // global burst number 0..NUM_MACS-1 (one burst per MAC)
    // Module-scope temporaries for AR checker (XSim: no automatic vars in always)
    int                        ar_chk_mac_n;
    int                        ar_chk_half_n;
    logic [AXI_ADDR_WIDTH-1:0] ar_chk_exp_addr;

    always @(posedge clk) begin
        if (rst_n && m_axi_arvalid && m_axi_arready && m_axi_araddr >= DIR_BASE) begin
            // Directory entry read: 2 beats, 32-byte aligned
            dir_reads = dir_reads + 1;
            if (m_axi_arlen !== 8'd1 || m_axi_araddr[4:0] !== 5'd0) begin
                $display("DIR AR ERROR: araddr=%08h arlen=%0d (expected 32B-aligned, arlen=1)",
                         m_axi_araddr, m_axi_arlen);
                error_count = error_count + 1;
            end
        end else if (rst_n && m_axi_arvalid && m_axi_arready) begin
            if (exp_packed) begin
                ar_chk_exp_addr = exp_bank_base + AXI_ADDR_WIDTH'(ar_burst_num) * BURST_BYTES;
                ar_chk_half_n   = (ar_burst_num == PK_BURSTS - 1) ? PK_LAST - 1 : BEATS_PER_BURST - 1;
            end else begin
                ar_chk_mac_n    = ar_burst_num / BURSTS_PER_MAC;
                ar_chk_half_n   = ar_burst_num % BURSTS_PER_MAC;
                ar_chk_exp_addr = exp_bank_base
                    + AXI_ADDR_WIDTH'(ar_chk_mac_n)  * MAC_BYTES
                    + AXI_ADDR_WIDTH'(ar_chk_half_n) * BURST_BYTES;
                ar_chk_half_n   = BEATS_PER_BURST - 1;
            end

            if (m_axi_araddr !== ar_chk_exp_addr) begin
                $display("AR ERROR burst=%0d : araddr=%08h  expected=%08h",
                         ar_burst_num, m_axi_araddr, ar_chk_exp_addr);
                error_count = error_count + 1;
            end
            if (int'(m_axi_arlen) !== ar_chk_half_n) begin
                $display("AR ERROR burst=%0d : arlen=%0d  expected=%0d",
                         ar_burst_num, m_axi_arlen, ar_chk_half_n);
                error_count = error_count + 1;
            end
            if (m_axi_arsize !== 3'd4) begin
                $display("AR ERROR burst=%0d : arsize=%0d  expected=4", ar_burst_num, m_axi_arsize);
                error_count = error_count + 1;
            end
            if (m_axi_arburst !== 2'b01) begin
                $display("AR ERROR burst=%0d : arburst=%0b  expected=01", ar_burst_num, m_axi_arburst);
                error_count = error_count + 1;
            end

            ar_burst_num = ar_burst_num + 1;
        end
    end

    // -------------------------------------------------------------------------
    //  Helper tasks (plain, not automatic — XSim compatible)
    // -------------------------------------------------------------------------
    task apply_reset;
        rst_n          = 1'b0;
        load_start     = 1'b0;
        load_by_id     = 1'b0;
        load_bank_id   = '0;
        load_filter_id = '0;
        exp_bank_base  = BASE;
        exp_packed     = 1'b0;
        dir_reads      = 0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk);
    endtask

    task pulse_load_start;
        input logic [BANK_BITS-1:0] bank;
        @(negedge clk);
        load_by_id    = 1'b0;
        load_bank_id  = bank;
        exp_bank_base = BASE + AXI_ADDR_WIDTH'(bank) * BANK_SZ;
        @(posedge clk);
        @(negedge clk); load_start = 1'b1;
        @(posedge clk);
        @(negedge clk); load_start = 1'b0;
    endtask

    task pulse_load_by_id;
        input logic [15:0] fid;
        input logic [AXI_ADDR_WIDTH-1:0] expected_base;
        @(negedge clk);
        load_by_id     = 1'b1;
        load_filter_id = fid;
        exp_bank_base  = expected_base;
        @(posedge clk);
        @(negedge clk); load_start = 1'b1;
        @(posedge clk);
        @(negedge clk); load_start = 1'b0;
    endtask

    // Default 3-entry directory + terminator. Entry payload sizes match the
    // DUT's BANK_SIZE_BYTES so the size check passes.
    localparam logic [31:0] DIR_IMG_A = 32'h0100_0000;
    localparam logic [31:0] DIR_IMG_B = 32'h0200_0000;
    localparam logic [31:0] DIR_IMG_C = 32'h0300_0000;
    task setup_directory;
        for (int i = 0; i < 8; i++) begin dir_beat0[i] = '0; dir_beat1[i] = '0; end
        dir_beat0[0] = mk_dir_entry(16'h0101, DIR_IMG_A, BANK_SZ);
        dir_beat0[1] = mk_dir_entry(16'h0202, DIR_IMG_B, BANK_SZ);
        dir_beat0[2] = mk_dir_entry(16'h0303, DIR_IMG_C, BANK_SZ);
        // dir_beat0[3] stays all-zero = terminator
    endtask

    // wait_for_load_done: poll posedge until load_done or timeout.
    // No fork/join or iff guard (XSim incompatible).
    int wfld_cyc;
    task wait_for_load_done;
        input int timeout_cycles;
        wfld_cyc = 0;
        while (!load_done && wfld_cyc < timeout_cycles) begin
            @(posedge clk); #0.1;
            wfld_cyc = wfld_cyc + 1;
        end
        if (!load_done) begin
            $display("TIMEOUT: load_done never asserted within %0d cycles", timeout_cycles);
            error_count = error_count + 1;
        end
    endtask

    // -------------------------------------------------------------------------
    //  Test cases
    // -------------------------------------------------------------------------

    // ---- TEST 1: Normal load, arready immediate, bank 0 --------------------
    task test_normal_load;
        $display("\n=== TEST 1: Normal load (bank 0, arready immediate) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        pulse_load_start(4'd0);
        wait_for_load_done(LOAD_TIMEOUT);

        // Verify load_done was a 1-cycle pulse
        @(posedge clk); #0.1;
        if (load_done) begin
            $display("ERROR: load_done did not de-assert after one cycle");
            error_count = error_count + 1;
        end

        // Total writes must equal NUM_MACS * COEF_DEPTH
        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count = error_count + 1;
        end

        if (ar_burst_num !== NUM_MACS * BURSTS_PER_MAC) begin
            $display("ERROR: total AR bursts = %0d, expected %0d",
                     ar_burst_num, NUM_MACS * BURSTS_PER_MAC);
            error_count = error_count + 1;
        end

        $display("TEST 1 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 2: AR channel stall (3 extra cycles per burst) ---------------
    task test_ar_stall;
        $display("\n=== TEST 2: AR stall (3 cycles, bank 1) ===");
        AR_STALL_CYCLES = 3;
        READ_LATENCY    = 1;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        pulse_load_start(4'd1);
        wait_for_load_done(2 * LOAD_TIMEOUT);

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count = error_count + 1;
        end

        $display("TEST 2 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 3: load_start held for multiple cycles (should only trigger once)
    task test_long_start_pulse;
        $display("\n=== TEST 3: load_start held 8 cycles (bank 2) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;

        @(negedge clk); load_bank_id = 4'd2;
        exp_bank_base = BASE + AXI_ADDR_WIDTH'(2) * BANK_SZ;
        @(posedge clk);
        @(negedge clk); load_start = 1'b1;
        repeat(8) @(posedge clk);
        @(negedge clk); load_start = 1'b0;

        wait_for_load_done(LOAD_TIMEOUT);

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count = error_count + 1;
        end

        $display("TEST 3 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 4: Back-to-back loads on different banks ---------------------
    task test_back_to_back;
        $display("\n=== TEST 4: Back-to-back loads (bank 3 then bank 4) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;

        pulse_load_start(4'd3);
        wait_for_load_done(LOAD_TIMEOUT);

        @(posedge clk);

        ar_burst_num = 0;
        total_writes = 0;
        pulse_load_start(4'd4);
        wait_for_load_done(LOAD_TIMEOUT);

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count = error_count + 1;
        end

        $display("TEST 4 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 5: Directory lookup hit (3rd entry) --------------------------
    task test_dir_hit;
        $display("\n=== TEST 5: Directory lookup hit (id 0x0303 -> entry 2) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        setup_directory;
        pulse_load_by_id(16'h0303, DIR_IMG_C);
        wait_for_load_done(LOAD_TIMEOUT);

        repeat(4) @(posedge clk);
        if (load_err !== 1'b0) begin
            $display("ERROR: load_err asserted on a valid lookup (code=%0d)", load_err_code);
            error_count = error_count + 1;
        end
        if (dir_reads !== 3) begin
            $display("ERROR: directory reads = %0d, expected 3 (entries 0..2)", dir_reads);
            error_count = error_count + 1;
        end
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count = error_count + 1;
        end
        if (ar_burst_num !== NUM_MACS * BURSTS_PER_MAC) begin
            $display("ERROR: bank AR bursts = %0d, expected %0d",
                     ar_burst_num, NUM_MACS * BURSTS_PER_MAC);
            error_count = error_count + 1;
        end
        $display("TEST 5 done. errors=%0d  writes=%0d  dir_reads=%0d",
                 error_count, total_writes, dir_reads);
    endtask

    // ---- TEST 6: Directory lookup miss (terminator reached) ----------------
    task test_dir_not_found;
        $display("\n=== TEST 6: Directory miss (id 0x0404) -> load_err code 1 ===");
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        setup_directory;
        pulse_load_by_id(16'h0404, DIR_IMG_C);
        wait_for_load_done(200_000);

        repeat(4) @(posedge clk);
        if (load_err !== 1'b1 || load_err_code !== 2'd1) begin
            $display("ERROR: expected load_err=1 code=1, got err=%0b code=%0d",
                     load_err, load_err_code);
            error_count = error_count + 1;
        end
        if (dir_reads !== 4) begin
            $display("ERROR: directory reads = %0d, expected 4 (3 entries + terminator)", dir_reads);
            error_count = error_count + 1;
        end
        if (total_writes !== 0 || ar_burst_num !== 0) begin
            $display("ERROR: miss must not load: writes=%0d bursts=%0d", total_writes, ar_burst_num);
            error_count = error_count + 1;
        end
        $display("TEST 6 done. errors=%0d  err=%0b code=%0d dir_reads=%0d",
                 error_count, load_err, load_err_code, dir_reads);
    endtask

    // ---- TEST 7: Payload size mismatch -------------------------------------
    task test_dir_size_mismatch;
        $display("\n=== TEST 7: Size mismatch (id 0x0202 built for another scale) -> code 2 ===");
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        setup_directory;
        dir_beat0[1] = mk_dir_entry(16'h0202, DIR_IMG_B, BANK_SZ / 2);
        pulse_load_by_id(16'h0202, DIR_IMG_B);
        wait_for_load_done(200_000);

        repeat(4) @(posedge clk);
        if (load_err !== 1'b1 || load_err_code !== 2'd2) begin
            $display("ERROR: expected load_err=1 code=2, got err=%0b code=%0d",
                     load_err, load_err_code);
            error_count = error_count + 1;
        end
        if (dir_reads !== 2) begin
            $display("ERROR: directory reads = %0d, expected 2", dir_reads);
            error_count = error_count + 1;
        end
        if (total_writes !== 0) begin
            $display("ERROR: size mismatch must not load: writes=%0d", total_writes);
            error_count = error_count + 1;
        end

        // Error must clear on the next (legacy) load and that load must succeed
        $display("   ... follow-up legacy load (bank 0) clears load_err");
        ar_burst_num = 0;
        total_writes = 0;
        dir_reads    = 0;
        pulse_load_start(4'd0);
        @(posedge clk); #0.1;
        if (load_err !== 1'b0) begin
            $display("ERROR: load_err not cleared at load_start");
            error_count = error_count + 1;
        end
        wait_for_load_done(LOAD_TIMEOUT);
        repeat(4) @(posedge clk);
        if (load_err !== 1'b0 || total_writes !== NUM_MACS * COEF_DEPTH || dir_reads !== 0) begin
            $display("ERROR: follow-up load err=%0b writes=%0d dir_reads=%0d",
                     load_err, total_writes, dir_reads);
            error_count = error_count + 1;
        end
        $display("TEST 7 done. errors=%0d", error_count);
    endtask

    // ---- TEST 8: Packed 18-bit payload via directory (packing = 1) ----------
    task test_dir_packed;
        $display("\n=== TEST 8: Packed payload (id 0x0505, 7 coefs/beat, %0d beats / %0d bursts, last %0d) ===",
                 PK_BEATS, PK_BURSTS, PK_LAST);
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        setup_directory;
        dir_beat0[3] = mk_dir_entry(16'h0505, DIR_IMG_B, PK_BYTES);
        dir_beat1[3] = mk_dir_beat1(8'd1);
        // dir_beat0[4] = terminator
        exp_packed = 1'b1;
        pulse_load_by_id(16'h0505, DIR_IMG_B);
        wait_for_load_done(LOAD_TIMEOUT);

        repeat(4) @(posedge clk);
        if (load_err !== 1'b0) begin
            $display("ERROR: load_err asserted on a valid packed lookup (code=%0d)", load_err_code);
            error_count = error_count + 1;
        end
        if (total_writes !== PK_COEFS) begin
            $display("ERROR: total coef writes = %0d, expected %0d", total_writes, PK_COEFS);
            error_count = error_count + 1;
        end
        if (ar_burst_num !== PK_BURSTS) begin
            $display("ERROR: packed AR bursts = %0d, expected %0d", ar_burst_num, PK_BURSTS);
            error_count = error_count + 1;
        end
        exp_packed = 1'b0;
        $display("TEST 8 done. errors=%0d  writes=%0d  bursts=%0d", error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 9: Packed entry with a v1-sized payload -> code 2 --------------
    task test_dir_packed_size;
        $display("\n=== TEST 9: Packed entry declaring the v1 size -> code 2; unknown packing -> code 2 ===");
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset;
        setup_directory;
        dir_beat0[3] = mk_dir_entry(16'h0505, DIR_IMG_B, BANK_SZ);   // wrong size for packing=1
        dir_beat1[3] = mk_dir_beat1(8'd1);
        pulse_load_by_id(16'h0505, DIR_IMG_B);
        wait_for_load_done(200_000);
        repeat(4) @(posedge clk);
        if (load_err !== 1'b1 || load_err_code !== 2'd2 || total_writes !== 0) begin
            $display("ERROR: expected err=1 code=2 writes=0, got err=%0b code=%0d writes=%0d",
                     load_err, load_err_code, total_writes);
            error_count = error_count + 1;
        end

        dir_beat0[3] = mk_dir_entry(16'h0505, DIR_IMG_B, PK_BYTES);
        dir_beat1[3] = mk_dir_beat1(8'd7);                             // unknown packing value
        pulse_load_by_id(16'h0505, DIR_IMG_B);
        wait_for_load_done(200_000);
        repeat(4) @(posedge clk);
        if (load_err !== 1'b1 || load_err_code !== 2'd2 || total_writes !== 0) begin
            $display("ERROR: unknown packing: expected err=1 code=2 writes=0, got err=%0b code=%0d writes=%0d",
                     load_err, load_err_code, total_writes);
            error_count = error_count + 1;
        end
        $display("TEST 9 done. errors=%0d", error_count);
    endtask

    // -------------------------------------------------------------------------
    //  Main stimulus
    // -------------------------------------------------------------------------
    int final_errors;
    initial begin
        $timeformat(-9, 1, " ns", 10);
        final_errors = 0;

        test_normal_load();
        final_errors += error_count;

        test_ar_stall();
        final_errors += error_count;

        test_long_start_pulse();
        final_errors += error_count;

        test_back_to_back();
        final_errors += error_count;

        test_dir_hit();
        final_errors += error_count;

        test_dir_not_found();
        final_errors += error_count;

        test_dir_size_mismatch();
        final_errors += error_count;

        test_dir_packed();
        final_errors += error_count;

        test_dir_packed_size();
        final_errors += error_count;

        repeat(20) @(posedge clk);

        if (final_errors == 0)
            $display("\n*** ALL TESTS PASSED ***\n");
        else
            $display("\n*** %0d ERROR(s) DETECTED ***\n", final_errors);

        $finish;
    end

    // -------------------------------------------------------------------------
    //  Watchdog: absolute simulation time limit
    // -------------------------------------------------------------------------
    initial begin
        #(20_000_000 * BURSTS_PER_MAC);  // 20 ms sim time (80 ms @ COEF_DEPTH=4096)
        $display("WATCHDOG: simulation exceeded time limit");
        $finish;
    end

endmodule
