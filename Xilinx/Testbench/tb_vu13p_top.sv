`timescale 1ns / 1ps

// =============================================================================
// Integration testbench for vu13p_dac_top ? REFRESHED Round 30 (todo #14)
//
// Matches the current top: differential 200M/mclk inputs, LMK00304 behavioral
// mux, Fig. 4d relay set, led_debug, QSPI1, 80-bit DDR4 stub tie-offs, and the
// Round-29/30 cascode path (dsp_clk -> cell_clk CDC -> IOB regs on cell_clk).
//
// Tests:
//   1. MMCM lock (led_debug[3])
//   2. Reset/mute state: force_zero=1 (led_debug[0]), relays de-energized
//   3. SPI write (40-bit frame: {rw,addr[6:0],data[23:0]} + CRC-8 0x07):
//      volume then unmute -> relay_line_mute asserts (automute FSM, shortened
//      timers via defparam)
//   4. Cascode outputs: no X, and DWA rotation causes toggling on cell_clk
//      (covers the new dsp_clk -> cell_clk CDC end-to-end)
//   5. I2S watchdog: stop BCLK -> i2s_err -> automute drops relay_line_mute
//
// Notes:
//   - I2S input is high-rate (LRCLK 768 kHz, BCLK 64x = 49.152 MHz): the
//     ingress watchdog times out after 512 dsp_clk (~1.8 us) without a frame.
//   - DDR4 stub holds init_calib_complete=0 -> sticky_err[2] -> fpga_irq_n is
//     LOW from the start; the tb expects that (do not test for irq high).
//   - XSim-safe: no fork/join.
// =============================================================================
module tb_vu13p_top;

    localparam real P200 = 5.0;      // 200 MHz
    localparam real P49  = 20.345;   // 49.152 MHz
    localparam real P45  = 22.151;   // 45.1584 MHz

    // Clocks / reset
    logic clk_200m = 0;
    logic clk_45m  = 0;
    logic clk_49m  = 0;
    logic mclk;
    wire  clk_sel;
    logic ext_rst_n = 0;

    // I2S (768 kHz frame: BCLK = 64 x LRCLK = 49.152 MHz)
    logic       i2s_en   = 1;
    logic       i2s_bclk = 0;
    logic [4:0] bclk_div = 0;   // 5-bit: LRCLK toggles every 32 BCLK -> 64-BCLK frame = 768 kHz
    logic       i2s_lrclk = 0;
    logic       i2s_data  = 0;

    // SPI
    logic spi_sclk = 0;
    logic spi_cs_n = 1;
    logic spi_mosi = 0;
    wire  spi_miso;

    // Outputs
    wire        fpga_irq_n;
    wire        relay_line_mute;
    wire        relay_hp_mute;
    wire        relay_hp_rails;
    wire [1:0]  relay_level;
    wire        led_status;
    wire [3:0]  led_debug;   // [3]=clk_locked [2]=ddr4_calib [1]=i2s_err [0]=force_zero
    wire        qspi1_cs_n;
    wire [3:0]  qspi1_dq;
    wire        cf_sck;              // carrier coef flash (bom 18a) - not populated here
    wire [3:0]  cf_cs_n;
    wire [3:0]  cf_dq;
    pullup (cf_dq[1]);               // absent device reads 0xFF -> SoM Flash 1 fallback
    wire [63:0] cascode_l;
    wire [63:0] cascode_r;

    // DDR4 (stubbed inside dac_ddr4_if; pins float / tie off)
    wire [79:0] ddr4_dq;
    wire [9:0]  ddr4_dqs_c, ddr4_dqs_t, ddr4_dm_dbi_n;
    wire [13:0] ddr4_addr;
    wire [1:0]  ddr4_ba;
    wire [0:0]  ddr4_bg, ddr4_cs_n, ddr4_cke, ddr4_odt, ddr4_ck_t, ddr4_ck_c;
    wire        ddr4_act_n, ddr4_reset_n;

    // ------------------------------------------------------------------
    // Clock generation
    // ------------------------------------------------------------------
    always #(P200/2) clk_200m = ~clk_200m;
    always #(P49/2)  clk_49m  = ~clk_49m;
    always #(P45/2)  clk_45m  = ~clk_45m;

    // Behavioral LMK00304 2:1 mux (real part is not glitch-free; the DUT
    // holds its MMCM in reset across switches, so zero-delay mux is fine)
    assign mclk = clk_sel ? clk_49m : clk_45m;

    // I2S source: BCLK 49.152 MHz gated by i2s_en; LRCLK = BCLK/64 (768 kHz)
    always #(P49/2) i2s_bclk = i2s_en ? ~i2s_bclk : i2s_bclk;

    always @(negedge i2s_bclk) begin
        bclk_div <= bclk_div + 1;
        if (bclk_div == 5'd31) i2s_lrclk <= ~i2s_lrclk;
    end

    // ------------------------------------------------------------------
    // DUT (automute timers shortened for simulation)
    // ------------------------------------------------------------------
    defparam u_dut.u_automute.FLUSH_CYCLES       = 26'd400;
    defparam u_dut.u_automute.SETTLE_CYCLES      = 26'd200;
    defparam u_dut.u_automute.SWITCH_CYCLES      = 26'd200;
    defparam u_dut.u_automute.RAIL_SETTLE_CYCLES = 26'd600;

    vu13p_dac_top #(
        .NUM_MACS          (4),     // sim-size FIR (production: 1024)
        .MUTE_DELAY_CYCLES (2000)   // 10 us relay-release wait (production: 20 ms)
    ) u_dut (
        .clk_200m_p     (clk_200m),
        .clk_200m_n     (~clk_200m),
        .mclk_p         (mclk),
        .mclk_n         (~mclk),
        .clk_sel        (clk_sel),
        .ext_rst_n      (ext_rst_n),
        .test_select_n  (1'b1), .test_step_n(1'b1), .pg_all(1'b1), .test_led(),
        .i2s_bclk       (i2s_bclk),
        .i2s_lrclk      (i2s_lrclk),
        .i2s_data       (i2s_data),
        .spi_sclk       (spi_sclk),
        .spi_cs_n       (spi_cs_n),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .fpga_irq_n     (fpga_irq_n),
        .relay_line_mute(relay_line_mute),
        .relay_hp_mute  (relay_hp_mute),
        .relay_hp_rails (relay_hp_rails),
        .relay_level    (relay_level),
        .led_status     (led_status),
        .led_debug      (led_debug),
        .qspi1_cs_n     (qspi1_cs_n),
        .qspi1_dq       (qspi1_dq),
        .cf_sck         (cf_sck),
        .cf_cs_n        (cf_cs_n),
        .cf_dq          (cf_dq),
        .cascode_l      (cascode_l),
        .cascode_r      (cascode_r),
        .ddr4_dq        (ddr4_dq),
        .ddr4_dqs_c     (ddr4_dqs_c),
        .ddr4_dqs_t     (ddr4_dqs_t),
        .ddr4_dm_dbi_n  (ddr4_dm_dbi_n),
        .ddr4_addr      (ddr4_addr),
        .ddr4_ba        (ddr4_ba),
        .ddr4_bg        (ddr4_bg),
        .ddr4_cs_n      (ddr4_cs_n),
        .ddr4_cke       (ddr4_cke),
        .ddr4_odt       (ddr4_odt),
        .ddr4_act_n     (ddr4_act_n),
        .ddr4_ck_t      (ddr4_ck_t),
        .ddr4_ck_c      (ddr4_ck_c),
        .ddr4_reset_n   (ddr4_reset_n)
    );

    // ------------------------------------------------------------------
    // SPI master model: 40-bit frame = {rw, addr[6:0], data[23:0]} + CRC-8
    // Polynomial x^8+x^2+x+1 (0x07), init 0x00, MSB-first over the payload.
    // ------------------------------------------------------------------
    function automatic [7:0] crc8_word(input [31:0] w);
        logic [7:0] c;
        c = 8'h00;
        for (int i = 31; i >= 0; i--) begin
            if ((w[i] ^ c[7]) == 1'b1) c = {c[6:0], 1'b0} ^ 8'h07;
            else                       c = {c[6:0], 1'b0};
        end
        return c;
    endfunction

    task automatic spi_write(input [6:0] addr, input [23:0] data);
        logic [31:0] payload;
        logic [39:0] frame;
        begin
            payload = {1'b0, addr, data};
            frame   = {payload, crc8_word(payload)};
            spi_cs_n = 0; spi_sclk = 0; spi_mosi = 0;
            repeat (8) @(posedge clk_200m);
            for (int i = 39; i >= 0; i--) begin
                spi_mosi = frame[i];
                repeat (4) @(posedge clk_200m);   // ~10 MHz SPI vs 200 MHz sync
                spi_sclk = 1;
                repeat (4) @(posedge clk_200m);
                spi_sclk = 0;
            end
            repeat (4) @(posedge clk_200m);
            spi_cs_n = 1; spi_mosi = 0;
            repeat (8) @(posedge clk_200m);
        end
    endtask

    // ------------------------------------------------------------------
    // Debug: automute FSM transition monitor (first 40 events)
    // ------------------------------------------------------------------
    logic [2:0] st_q = 0;
    int dbg_events = 0;

    always @(posedge u_dut.dsp_clk) begin
        st_q <= u_dut.u_automute.state;
        if (u_dut.u_automute.state !== st_q && dbg_events < 40) begin
            dbg_events++;
            $display("[%0t] DBG-FSM: %0d->%0d (i2s_err=%b rate_chg=%b unmute=%b rst=%b)",
                     $time, st_q, u_dut.u_automute.state, u_dut.i2s_err,
                     u_dut.u_automute.rate_changed, u_dut.spi_unmute_sync,
                     u_dut.sys_rst_n);
        end
    end

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    int pass_count = 0;
    int fail_count = 0;
    int wdog;
    logic [63:0] cas_snap_l, cas_snap_r;
    int cas_toggles;

    initial begin
        $display("==========================================================");
        $display("TB_VU13P_TOP - full-top integration (Round 30 refresh)");
        $display("==========================================================");
        ext_rst_n = 0;
        repeat (50) @(posedge clk_200m);
        ext_rst_n = 1;

        // --- TEST 1: MMCM lock -------------------------------------------
        wdog = 0;
        while (led_debug[3] !== 1'b1 && wdog < 50000) begin
            @(posedge clk_49m); wdog++;
        end
        if (led_debug[3] === 1'b1) begin
            $display("[%0t] PASS: MMCM locked (led_debug[3])", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: MMCM never locked", $time);
            fail_count++;
            $display("ABORT: cannot continue without clocks");
            $finish;
        end

        // --- TEST 2: reset/mute state ------------------------------------
        repeat (200) @(posedge clk_49m);
        if (led_debug[0] === 1'b1 && relay_line_mute === 1'b0 &&
            relay_hp_mute === 1'b0 && relay_hp_rails === 1'b0) begin
            $display("[%0t] PASS: muted state after reset (force_zero=1, relays off)", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: bad mute state: fz=%b line=%b hp=%b rails=%b",
                     $time, led_debug[0], relay_line_mute, relay_hp_mute, relay_hp_rails);
            fail_count++;
        end
        if (fpga_irq_n === 1'b0)
            $display("[%0t] INFO: fpga_irq_n low as expected (DDR4 stub calib=0 sticky)", $time);

        // --- TEST 3: SPI volume + unmute -> line relay --------------------
        spi_write(7'h01, 24'h123456);            // volume (smoke: CRC path)
        spi_write(7'h04, 24'h000001);            // unmute
        repeat (100) @(posedge clk_200m);
        $display("[%0t] DBG: spi_unmute=%b sticky_err=%b sys_volume=%h automute_state=%0d",
                 $time, u_dut.spi_unmute, u_dut.u_ctrl_plane.sticky_err,
                 u_dut.u_ctrl_plane.sys_volume, u_dut.u_automute.state);
        wdog = 0;
        while (relay_line_mute !== 1'b1 && wdog < 200000) begin
            @(posedge clk_49m); wdog++;
            if (wdog % 40000 == 0)
                $display("[%0t] DBG: automute state=%0d timer=%0d i2s_err=%b unmute_sync=%b",
                         $time, u_dut.u_automute.state, u_dut.u_automute.timer,
                         u_dut.i2s_err, u_dut.spi_unmute_sync);
        end
        if (relay_line_mute === 1'b1) begin
            $display("[%0t] PASS: relay_line_mute asserted after SPI unmute", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: relay_line_mute never asserted (CRC or automute path)", $time);
            fail_count++;
        end
        if (relay_hp_mute === 1'b0 && relay_hp_rails === 1'b0) begin
            $display("[%0t] PASS: HP relays stay off (outsel=line default)", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: HP relay energized on line output (hp=%b rails=%b)",
                     $time, relay_hp_mute, relay_hp_rails);
            fail_count++;
        end

        // --- TEST 4: cascode outputs valid + toggling (cell_clk CDC) ------
        repeat (2000) @(posedge clk_49m);        // let NS/DEM run
        if ($isunknown(cascode_l) || $isunknown(cascode_r)) begin
            $display("[%0t] FAIL: X in cascode outputs (l=%h r=%h)", $time, cascode_l, cascode_r);
            fail_count++;
        end else begin
            $display("[%0t] PASS: cascode outputs fully resolved (no X)", $time);
            pass_count++;
        end
        cas_snap_l  = cascode_l;
        cas_snap_r  = cascode_r;
        cas_toggles = 0;
        repeat (4000) begin                      // ~80 us: many 6.144 MHz DEM updates
            @(posedge clk_49m); #0.1;
            if (cascode_l !== cas_snap_l || cascode_r !== cas_snap_r) begin
                cas_toggles++;
                cas_snap_l = cascode_l;
                cas_snap_r = cascode_r;
            end
        end
        if (cas_toggles > 10) begin
            $display("[%0t] PASS: cascode outputs toggling via cell_clk CDC (%0d updates)",
                     $time, cas_toggles);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: cascode outputs static (%0d updates) - CDC dead?",
                     $time, cas_toggles);
            fail_count++;
        end

        // --- TEST 5: single-register clock switch (0x03) ------------------
        // One write must: mute (automute rate_changed), wait relay release,
        // flip clk_sel while MMCM in reset, relock, then auto-re-unmute
        // (cmd_unmute is still 1 in the clk_200m domain).
        spi_write(7'h03, 24'h000001);            // 44.1k family -> 48k family
        wdog = 0;                                // a) automute drops the relay
        while (relay_line_mute !== 1'b0 && wdog < 20000) begin
            @(posedge clk_200m); wdog++;
        end
        if (relay_line_mute === 1'b0 && clk_sel === 1'b0) begin
            $display("[%0t] PASS: rate write muted BEFORE mux flip (relay=0, clk_sel still 0)", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: mute-before-switch order: relay=%b clk_sel=%b",
                     $time, relay_line_mute, clk_sel);
            fail_count++;
        end
        wdog = 0;                                // b) mux flips after mute delay
        while (clk_sel !== 1'b1 && wdog < 20000) begin
            @(posedge clk_200m); wdog++;
        end
        if (clk_sel === 1'b1 && led_debug[3] === 1'b0) begin
            $display("[%0t] PASS: clk_sel flipped with MMCM in reset (locked=0)", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: mux flip: clk_sel=%b locked=%b", $time, clk_sel, led_debug[3]);
            fail_count++;
        end
        wdog = 0;                                // c) relock on 49.152 MHz
        while (led_debug[3] !== 1'b1 && wdog < 100000) begin
            @(posedge clk_200m); wdog++;
        end
        wdog = 0;                                // d) automute re-unmutes by itself
        while (relay_line_mute !== 1'b1 && wdog < 400000) begin
            @(posedge clk_49m); wdog++;
        end
        if (led_debug[3] === 1'b1 && relay_line_mute === 1'b1) begin
            $display("[%0t] PASS: relocked on new OCXO and auto-re-unmuted", $time);
            pass_count++;
        end else begin
            $display("[%0t] FAIL: post-switch recovery: locked=%b relay=%b",
                     $time, led_debug[3], relay_line_mute);
            fail_count++;
        end

        // --- TEST 6: I2S watchdog -> automute drop ------------------------
        i2s_en = 0;                              // stop BCLK -> no frames
        wdog = 0;                                // first: watchdog must fire
        while (led_debug[1] !== 1'b1 && wdog < 20000) begin
            @(posedge clk_49m); wdog++;
        end
        wdog = 0;                                // then: relay must drop
        while (relay_line_mute !== 1'b0 && wdog < 20000) begin
            @(posedge clk_49m); wdog++;
        end
        if (relay_line_mute === 1'b0 && led_debug[1] === 1'b1) begin
            $display("[%0t] PASS: I2S stop -> i2s_err -> relay dropped", $time);   // TEST 6
            pass_count++;
        end else begin
            $display("[%0t] FAIL: watchdog/automute: relay=%b i2s_err=%b",
                     $time, relay_line_mute, led_debug[1]);
            fail_count++;
        end

        // --- Summary -------------------------------------------------------
        $display("==========================================================");
        if (fail_count == 0)
            $display("ALL TESTS PASSED (%0d) - vu13p_dac_top integration OK", pass_count);
        else
            $display("FAILURES: %0d passed, %0d FAILED", pass_count, fail_count);
        $display("==========================================================");
        $finish;
    end

endmodule

