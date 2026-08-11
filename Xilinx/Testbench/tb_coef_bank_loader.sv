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

    localparam int COEFS_PER_BEAT    = AXI_DATA_WIDTH / 32;       // 4
    localparam int BEATS_PER_BURST   = 256;
    localparam int COEFS_PER_BURST   = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC    = COEF_DEPTH / COEFS_PER_BURST;     // 1
    localparam int MAC_BYTES         = COEF_DEPTH * 4;                   // 4 KB
    localparam int BURST_BYTES       = BEATS_PER_BURST * (AXI_DATA_WIDTH/8); // 4 KB

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
    logic [BANK_BITS-1:0]         load_bank_id;
    logic                         load_done;

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
        .BANK_SIZE_BYTES(BANK_SZ)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .load_start      (load_start),
        .load_bank_id    (load_bank_id),
        .load_done       (load_done),
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
        offset     = base_addr - BASE - AXI_ADDR_WIDTH'(load_bank_id) * BANK_SZ;
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
        if (rst_n && m_axi_arvalid && m_axi_arready) begin
            ar_chk_mac_n    = ar_burst_num / BURSTS_PER_MAC;
            ar_chk_half_n   = ar_burst_num % BURSTS_PER_MAC;
            ar_chk_exp_addr = BASE
                + AXI_ADDR_WIDTH'(load_bank_id) * BANK_SZ
                + AXI_ADDR_WIDTH'(ar_chk_mac_n)  * MAC_BYTES
                + AXI_ADDR_WIDTH'(ar_chk_half_n) * BURST_BYTES;

            if (m_axi_araddr !== ar_chk_exp_addr) begin
                $display("AR ERROR burst=%0d : araddr=%08h  expected=%08h",
                         ar_burst_num, m_axi_araddr, ar_chk_exp_addr);
                error_count = error_count + 1;
            end
            if (m_axi_arlen !== 8'(BEATS_PER_BURST - 1)) begin
                $display("AR ERROR burst=%0d : arlen=%0d  expected=%0d",
                         ar_burst_num, m_axi_arlen, BEATS_PER_BURST - 1);
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
        rst_n        = 1'b0;
        load_start   = 1'b0;
        load_bank_id = '0;
        repeat(8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        @(posedge clk);
    endtask

    task pulse_load_start;
        input logic [BANK_BITS-1:0] bank;
        @(negedge clk); load_bank_id = bank;
        @(posedge clk);
        @(negedge clk); load_start = 1'b1;
        @(posedge clk);
        @(negedge clk); load_start = 1'b0;
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
