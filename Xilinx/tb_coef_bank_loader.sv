`timescale 1ns / 1ps

// =============================================================================
//  TB_COEF_BANK_LOADER
//
//  Self-checking simulation testbench for coef_bank_loader.
//
//  What is checked:
//    1. AXI AR channel: correct araddr, arlen (255), arsize (4), arburst (INCR)
//       for every burst (512 total across 256 MACs x 2 halves).
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
    localparam int NUM_MACS          = 256;
    localparam int COEF_WIDTH        = 18;
    localparam int COEF_DEPTH        = 2048;
    localparam int BANK_BITS         = 4;
    localparam int AXI_DATA_WIDTH    = 128;
    localparam int AXI_ADDR_WIDTH    = 32;
    localparam logic [31:0] BASE     = 32'h0000_0000;
    localparam logic [31:0] BANK_SZ  = 32'h0020_0000;   // 2 MB

    localparam int COEFS_PER_BEAT    = AXI_DATA_WIDTH / 32;       // 4
    localparam int BEATS_PER_BURST   = 256;
    localparam int COEFS_PER_BURST   = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC    = COEF_DEPTH / COEFS_PER_BURST;     // 2
    localparam int MAC_BYTES         = COEF_DEPTH * 4;                   // 8 KB
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
    logic [10:0]                  coef_waddr;
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
    typedef struct {
        logic [AXI_ADDR_WIDTH-1:0] araddr;
        int                        beats_remaining;
        int                        beat_index;
    } r_txn_t;

    r_txn_t r_queue [$];

    // Per-beat data generation: deterministic from address
    function automatic logic [AXI_DATA_WIDTH-1:0] gen_beat (
        input logic [AXI_ADDR_WIDTH-1:0] base_addr,
        input int                        beat_index
    );
        // Recover mac and coef_base from address
        // Address = BASE + bank*BANK_SZ + mac*MAC_BYTES + half*BURST_BYTES + beat*16
        // We encode: word value = (mac * COEF_DEPTH + coef_idx) trimmed to COEF_WIDTH
        logic [AXI_ADDR_WIDTH-1:0] offset;
        int mac_num, half_offset, coef_base, coef_idx;
        logic [AXI_DATA_WIDTH-1:0] beat;

        offset      = base_addr - BASE;                     // strip bank (bank=0 for test)
        mac_num     = int'(offset / MAC_BYTES);
        half_offset = int'((offset % MAC_BYTES) / BURST_BYTES); // 0 or 1
        coef_base   = half_offset * COEFS_PER_BURST + beat_index * COEFS_PER_BEAT;

        for (int s = 0; s < COEFS_PER_BEAT; s++) begin
            coef_idx = coef_base + s;
            beat[s*32 +: 32] = 32'((mac_num * COEF_DEPTH + coef_idx) & 32'h3FFFF);
        end
        return beat;
    endfunction

    // -------------------------------------------------------------------------
    //  AR-channel slave: accept with configurable stall
    // -------------------------------------------------------------------------
    int ar_stall_cnt;
    initial ar_stall_cnt = 0;

    always_ff @(posedge clk) begin
        m_axi_arready <= 1'b0;
        ar_accepted   <= 1'b0;

        if (m_axi_arvalid) begin
            if (ar_stall_cnt < AR_STALL_CYCLES) begin
                ar_stall_cnt <= ar_stall_cnt + 1;
            end else begin
                ar_stall_cnt  <= 0;
                m_axi_arready <= 1'b1;
                ar_accepted   <= 1'b1;
                slave_araddr  <= m_axi_araddr;
                slave_arlen   <= m_axi_arlen;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  R-channel slave: push accepted ARs into a queue, drain with latency
    // -------------------------------------------------------------------------
    int r_delay_cnt;
    initial begin
        m_axi_rvalid = 1'b0;
        m_axi_rdata  = '0;
        m_axi_rlast  = 1'b0;
        m_axi_rresp  = 2'b00;
        r_delay_cnt  = 0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_axi_rvalid <= 1'b0;
            m_axi_rlast  <= 1'b0;
            r_delay_cnt  <= 0;
            r_queue       = {};
        end else begin
            // Enqueue newly accepted AR
            if (ar_accepted) begin
                r_txn_t txn;
                txn.araddr          = slave_araddr;
                txn.beats_remaining = int'(slave_arlen) + 1;
                txn.beat_index      = 0;
                r_queue.push_back(txn);
            end

            // Drive R channel
            if (r_queue.size() > 0) begin
                if (r_delay_cnt < READ_LATENCY) begin
                    r_delay_cnt  <= r_delay_cnt + 1;
                    m_axi_rvalid <= 1'b0;
                end else begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rdata  <= gen_beat(r_queue[0].araddr, r_queue[0].beat_index);
                    m_axi_rlast  <= (r_queue[0].beats_remaining == 1);
                    m_axi_rresp  <= 2'b00;

                    if (m_axi_rready) begin
                        r_queue[0].beats_remaining--;
                        r_queue[0].beat_index++;
                        if (r_queue[0].beats_remaining == 0) begin
                            void'(r_queue.pop_front());
                            r_delay_cnt  <= 0;
                            m_axi_rvalid <= 1'b0;
                            m_axi_rlast  <= 1'b0;
                        end
                    end
                end
            end else begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
                r_delay_cnt  <= 0;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  Checker: capture every coef write and verify against expected pattern
    // -------------------------------------------------------------------------
    int  total_writes;
    int  error_count;

    // Which MACs to check exhaustively (first two and last one)
    localparam int CHECK_MAC_LO = 0;
    localparam int CHECK_MAC_HI = 1;
    localparam int CHECK_MAC_LAST = NUM_MACS - 1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            total_writes <= 0;
            error_count  <= 0;
        end else if (coef_we) begin
            total_writes <= total_writes + 1;

            // Check exhaustively for MAC 0, MAC 1, and MAC 255
            if (coef_wmac == CHECK_MAC_LO  ||
                coef_wmac == CHECK_MAC_HI  ||
                coef_wmac == CHECK_MAC_LAST) begin

                automatic int   mac_n    = int'(coef_wmac);
                automatic int   cidx     = int'(coef_waddr);
                automatic int   expected_raw = (mac_n * COEF_DEPTH + cidx) & 32'h3FFFF;
                // Sign-extend from COEF_WIDTH
                automatic logic signed [COEF_WIDTH-1:0] expected =
                    signed'(COEF_WIDTH'(expected_raw));

                if (coef_wdata !== expected) begin
                    $display("ERROR @ %0t : mac=%0d addr=%0d  got=%0h  exp=%0h",
                             $time, coef_wmac, coef_waddr,
                             coef_wdata, expected);
                    error_count <= error_count + 1;
                end
            end

            // Address must always be in [0 .. COEF_DEPTH-1]
            if (int'(coef_waddr) >= COEF_DEPTH) begin
                $display("ERROR @ %0t : coef_waddr=%0d out of range (mac=%0d)",
                         $time, coef_waddr, coef_wmac);
                error_count <= error_count + 1;
            end

            // MAC index must always be in [0 .. NUM_MACS-1]
            if (int'(coef_wmac) >= NUM_MACS) begin
                $display("ERROR @ %0t : coef_wmac=%0d out of range", $time, coef_wmac);
                error_count <= error_count + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    //  AR-channel checker: runs on every arvalid/arready handshake
    // -------------------------------------------------------------------------
    int   ar_burst_num;  // global burst number 0..511
    initial ar_burst_num = 0;

    always_ff @(posedge clk) begin
        if (rst_n && m_axi_arvalid && m_axi_arready) begin
            automatic int    mac_n       = ar_burst_num / BURSTS_PER_MAC;
            automatic int    half_n      = ar_burst_num % BURSTS_PER_MAC;
            automatic logic [AXI_ADDR_WIDTH-1:0] exp_addr =
                BASE
                + AXI_ADDR_WIDTH'(load_bank_id) * BANK_SZ
                + AXI_ADDR_WIDTH'(mac_n)   * MAC_BYTES
                + AXI_ADDR_WIDTH'(half_n)  * BURST_BYTES;

            if (m_axi_araddr !== exp_addr) begin
                $display("AR ERROR burst=%0d : araddr=%08h  expected=%08h",
                         ar_burst_num, m_axi_araddr, exp_addr);
                error_count <= error_count + 1;
            end
            if (m_axi_arlen !== 8'(BEATS_PER_BURST - 1)) begin
                $display("AR ERROR burst=%0d : arlen=%0d  expected=%0d",
                         ar_burst_num, m_axi_arlen, BEATS_PER_BURST - 1);
                error_count <= error_count + 1;
            end
            if (m_axi_arsize !== 3'd4) begin
                $display("AR ERROR burst=%0d : arsize=%0d  expected=4", ar_burst_num, m_axi_arsize);
                error_count <= error_count + 1;
            end
            if (m_axi_arburst !== 2'b01) begin
                $display("AR ERROR burst=%0d : arburst=%0b  expected=01", ar_burst_num, m_axi_arburst);
                error_count <= error_count + 1;
            end

            ar_burst_num <= ar_burst_num + 1;
        end
    end

    // -------------------------------------------------------------------------
    //  Helper tasks
    // -------------------------------------------------------------------------
    task automatic apply_reset();
        rst_n        <= 1'b0;
        load_start   <= 1'b0;
        load_bank_id <= '0;
        m_axi_arready = 1'b0;
        repeat(8) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);
    endtask

    task automatic pulse_load_start(input logic [BANK_BITS-1:0] bank);
        load_bank_id <= bank;
        @(posedge clk);
        load_start   <= 1'b1;
        @(posedge clk);
        load_start   <= 1'b0;
    endtask

    task automatic wait_for_load_done(input int timeout_cycles = 1_500_000);
        fork
            begin : wait_done
                @(posedge clk iff load_done);
                disable wait_timeout;
            end
            begin : wait_timeout
                repeat (timeout_cycles) @(posedge clk);
                $display("TIMEOUT: load_done never asserted within %0d cycles",
                         timeout_cycles);
                error_count <= error_count + 1;
                disable wait_done;
            end
        join
    endtask

    // -------------------------------------------------------------------------
    //  Test cases
    // -------------------------------------------------------------------------

    // ---- TEST 1: Normal load, arready immediate, bank 0 --------------------
    task automatic test_normal_load();
        $display("\n=== TEST 1: Normal load (bank 0, arready immediate) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset();
        pulse_load_start(4'd0);
        wait_for_load_done();

        // Verify load_done was a 1-cycle pulse
        @(posedge clk);
        if (load_done) begin
            $display("ERROR: load_done did not de-assert after one cycle");
            error_count <= error_count + 1;
        end

        // Total writes must equal NUM_MACS * COEF_DEPTH
        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count <= error_count + 1;
        end

        if (ar_burst_num !== NUM_MACS * BURSTS_PER_MAC) begin
            $display("ERROR: total AR bursts = %0d, expected %0d",
                     ar_burst_num, NUM_MACS * BURSTS_PER_MAC);
            error_count <= error_count + 1;
        end

        $display("TEST 1 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 2: AR channel stall (3 extra cycles per burst) ---------------
    task automatic test_ar_stall();
        $display("\n=== TEST 2: AR stall (3 cycles, bank 1) ===");
        AR_STALL_CYCLES = 3;
        READ_LATENCY    = 1;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset();
        pulse_load_start(4'd1);
        wait_for_load_done(3_000_000);

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count <= error_count + 1;
        end

        $display("TEST 2 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 3: load_start held for multiple cycles (should only trigger once)
    task automatic test_long_start_pulse();
        $display("\n=== TEST 3: load_start held 8 cycles (bank 2) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset();

        load_bank_id <= 4'd2;
        @(posedge clk);
        load_start   <= 1'b1;
        repeat(8) @(posedge clk);
        load_start   <= 1'b0;

        wait_for_load_done();

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count <= error_count + 1;
        end

        $display("TEST 3 done. errors=%0d  writes=%0d  bursts=%0d",
                 error_count, total_writes, ar_burst_num);
    endtask

    // ---- TEST 4: Back-to-back loads on different banks ---------------------
    task automatic test_back_to_back();
        $display("\n=== TEST 4: Back-to-back loads (bank 3 then bank 4) ===");
        AR_STALL_CYCLES = 0;
        READ_LATENCY    = 2;
        ar_burst_num    = 0;
        total_writes    = 0;
        error_count     = 0;

        apply_reset();

        pulse_load_start(4'd3);
        wait_for_load_done();

        @(posedge clk);  // one idle cycle between loads

        ar_burst_num = 0;
        total_writes = 0;
        pulse_load_start(4'd4);
        wait_for_load_done();

        repeat(4) @(posedge clk);
        if (total_writes !== NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: total coef writes = %0d, expected %0d",
                     total_writes, NUM_MACS * COEF_DEPTH);
            error_count <= error_count + 1;
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
        #(20_000_000);  // 20 ms wall-clock sim time
        $display("WATCHDOG: simulation exceeded 20 ms limit");
        $finish;
    end

endmodule
