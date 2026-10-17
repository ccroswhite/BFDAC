`timescale 1ns / 1ps

// =============================================================================
// vu13p_dac_top — Wire-only top level for XCVU13P stereo DAC
//
// Platform : Xilinx XCVU13P on Alinx ACVU13 SOM
//   - 10 GB DDR4 (C0, banks 61/62/63), C1 unused — its 200 MHz CLKREF used as clk_200m
//   - QSPI Flash on-module
//   - 377 HP IOs exposed via Samtec connectors
// Single-FPGA design
//
// Sub-modules:
//   dac_ddr4_if      : DDR4 MIG wrapper (uses on-module DDR4)
//   dac_coef_subsys  : Coefficient loading + bank management + CDC
//   dac_ctrl_plane   : SPI register file + relays
//   dac_i2s_ingress  : I2S receiver + stereo FIFO
//   dac_dsp_core     : FIR×16 + HB1/2/3 + volume + dither + 7th-order NS
//                      + 64-element DEM + IOB-registered cascode outputs
//                        (1 pin per cell, 128 total; complement generated at
//                        the external reclock stage, Fig. 1b)
//
// Target: XCVU13P-2FHGB2104I, 350-400 MHz DSP clock, 1024 MACs, 1M taps
//
// Clock architecture (external mux, Round 24):
//   Two OCXOs feed an on-board LMK00304 2:1 mux/fanout. One LMK output drives
//   the FPGA mclk_p/n GC pair; the others drive the LMK1C1108 trees that
//   clock the external reclock FF stage: 128x MC100EP52 differential LVPECL
//   D-FFs (Round 29, Fig. 1b). Each FF resamples one LVCMOS18 cascode data
//   pin (resistive shift to its differential D input) and its Q/~Q outputs
//   drive the DMMT5551 steering-cell base pair (Fig. 2) - no CMOS translator.
//   The cascode IOBs launch on cell_clk (mclk-rate MMCM output, phase-aligned
//   to the reclock-FF clock), giving the FF D inputs ~13-16 ns of setup
//   (bom.md 1.4).
//   clk_sel (FPGA output) selects the OCXO on the LMK00304:
//     clk_sel = 0 -> 45.1584 MHz (44.1 kHz family)
//     clk_sel = 1 -> 49.152  MHz (48 kHz family)
//   ONE SPI register (0x03 base_rate_sel) drives BOTH the DSP family select
//   and the OCXO mux (clk_source_sel is an alias in dac_ctrl_plane) - they
//   can never disagree. The LMK mux is NOT glitch-free, so the switch
//   sequencer below enforces the safe order in hardware: the register change
//   first reaches the automute FSM (rate_changed -> ST_MUTED, relay drive
//   drops, force_zero), then after MUTE_DELAY_CYCLES (physical relay release)
//   the MMCM is held in reset, clk_sel flips, and the MMCM relocks (~100 us).
//   sys_rst_n stays low until relock, flushing every dsp_clk/cell_clk-domain
//   pipeline (FIR, halfbands, NS, DEM, staging, cascode IOBs -> pins low).
// =============================================================================

module vu13p_dac_top #(
    // RELEASE geometry (ruling 2026-09-03): 256 x 256 = 1,048,576 taps, 4 MB/bank,
    // 31 filters on the 128 MiB coefficient flash unpacked. 1280 x 256 (5.24M)
    // is the proven upper bound (f15b P&R closed). Synth scripts may override.
    parameter int NUM_MACS = 256,   // Any multiple of 64, <=2560 (URAM limit); taps = 16*NUM_MACS*TAPS_PER_PHASE
    parameter int TAPS_PER_PHASE = 256, // Power of 2, <=256; taps = 16*NUM_MACS*TAPS_PER_PHASE
    parameter int MUTE_DELAY_CYCLES = 4_000_000  // 20 ms @ 200 MHz: automute relay
                                                 // physical release before the mux
                                                 // flips (shorten in simulation)
)(
    // Base Clocks & Reset (all differential)
    input  logic        clk_200m_p,    // SOM 200 MHz system clock (+ side)
    input  logic        clk_200m_n,    // SOM 200 MHz system clock (- side)
    input  logic        mclk_p,        // LMK00304 output: selected OCXO master clock (+ side)
    input  logic        mclk_n,        // LMK00304 output: selected OCXO master clock (- side)
    output logic        clk_sel,       // LMK00304 CLKin_SEL: 0 = 45.1584 MHz, 1 = 49.152 MHz

    input  logic        ext_rst_n,
    input  logic        test_select_n,
    input  logic        test_step_n,
    input  logic        pg_all,
    output logic        test_led,

    // I2S Ingress
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // ARM SPI Interface (Control Plane)
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,
    output logic        fpga_irq_n,    // Active-low IRQ to ARM (sticky errors)

    // Hardware Control Plane (Fig. 4d relay set)
    output logic        relay_line_mute,      // energized = line XLR unmuted
    output logic        relay_hp_mute,        // energized = HP jack live
    output logic        relay_hp_rails,       // energized = HP stage powered
    output logic [1:0]  relay_level,          // IDLE (driven 0): level is a digital gain cap since bom 7 ruling 2026-10-07; pins kept in the XDC, no-connect on J1

    // Debug / Status LED (BC33) + board-level debug LEDs (J1)
    output logic        led_status,
    output logic [3:0]  led_debug,     // [3]=clk_locked [2]=ddr4_calib [1]=i2s_err [0]=force_zero

    // QSPI Flash 1 — coefficient storage (bank 65, directly accessible)
    // Flash 0 accessed via STARTUPE3 (config pins, bitstreams)
    output logic        qspi1_cs_n,
    inout  wire  [3:0]  qspi1_dq,

    // Carrier coefficient flash (bom item 18/18a, 2026-10-05): 1..4 x MT25QU02G
    // on one x1 bus, bank-70 pins (XDC §11b). cf_cs_n[0] = populated device,
    // [3:1] reserved sites. SCK is a user-IO forwarded copy of the engine clock.
    output logic        cf_sck,
    output logic [3:0]  cf_cs_n,
    inout  wire  [3:0]  cf_dq,

    // Direct cascode cell outputs — IOB-registered on cell_clk, < 50 ps
    // inter-cell skew. 1 pin per cell, 64 per channel, 128 total (pins: XDC §8,
    // banks 64+65 = L, 67+69 = R); external MC100EP52 reclock FFs generate the
    // complementary base-drive pair (Fig. 1b)
    output logic [63:0] cascode_l,
    output logic [63:0] cascode_r,

    // DDR4 Interface — C0 controller, banks 61/62/63
    // TOPOLOGY (2026-08-11): SOM has 5× MT40A1G16KD (80 DQ) but the DDR4
    // MIG controller maxes at 72-bit → 64-bit config (4 chips, 8 GB);
    // 5th chip unused. 8 byte lanes.
    input  wire         ddr4_clkref_p,   // on-module 200 MHz C0_DDR4_CLKREF
    input  wire         ddr4_clkref_n,
    inout  wire  [63:0] ddr4_dq,
    inout  wire  [7:0]  ddr4_dqs_c,
    inout  wire  [7:0]  ddr4_dqs_t,
    inout  wire  [7:0]  ddr4_dm_dbi_n,
    output wire  [16:0] ddr4_addr,
    output wire  [1:0]  ddr4_ba,
    output wire  [0:0]  ddr4_bg,
    output wire  [0:0]  ddr4_cs_n,
    output wire  [0:0]  ddr4_cke,
    output wire  [0:0]  ddr4_odt,
    output wire         ddr4_act_n,
    output wire  [0:0]  ddr4_ck_t,
    output wire  [0:0]  ddr4_ck_c,
    output wire         ddr4_reset_n
);

    // ==============================================================
    // Clocks & Reset
    // ==============================================================
    logic clk_200m;       // Single-ended after IBUFDS
    logic mclk;           // Single-ended after IBUFDS (externally-muxed OCXO)
    logic dsp_clk;
    logic clk_locked;
    logic sys_rst_n;
    logic base_rate_sel;
    logic clk_source_sel;

    // Differential-to-single-ended clock buffers
    IBUFDS u_ibufds_200m (
        .I  (clk_200m_p),
        .IB (clk_200m_n),
        .O  (clk_200m)
    );

    IBUFDS u_ibufds_mclk (
        .I  (mclk_p),
        .IB (mclk_n),
        .O  (mclk)
    );

    // --------------------------------------------------------------
    // External clock-mux switch sequencer (clk_200m domain)
    //
    // Single SPI register (0x03) commands the rate-family change; this
    // sequencer enforces the safe order IN HARDWARE (no host protocol
    // dependency). The LMK00304 mux is not glitch-free, so on any
    // clk_source_sel change:
    //   1. MUTE_WAIT: dsp_clk is still running; the automute FSM has
    //      already seen the same register change (rate_changed) and
    //      dropped the relay drives + force_zero. Wait MUTE_DELAY_CYCLES
    //      for the mechanical relay contacts to actually open.
    //   2. Hold the MMCM in reset, flip clk_sel, keep reset asserted
    //      for MUX_SETTLE_CYCLES (mux switch + OCXO output settle).
    //   3. Release; clk_locked reasserts (~100 us) and sys_rst_n
    //      releases the dsp_clk domain through reset (all pipelines -
    //      FIR, halfbands, NS, DEM, staging, cascode IOBs - flush; the
    //      128 cascode pins are held at 0 so the external EP52 FFs
    //      clock in a static all-off pattern while mclk is switching).
    // A new register change during MUTE_WAIT simply retargets (counter
    // restarts); a change during the reset phase is picked up on the
    // next pass because clk_source_sel_q keeps tracking.
    // --------------------------------------------------------------
    localparam int MUX_SETTLE_CYCLES = 2048;   // 10.24 us @ 200 MHz

    logic        clk_source_sel_q;
    logic [25:0] mute_wait_cnt;
    logic [11:0] mux_settle_cnt;
    logic        mmcm_rst;

    always_ff @(posedge clk_200m or negedge ext_rst_n) begin
        if (!ext_rst_n) begin
            clk_source_sel_q <= 1'b0;
            clk_sel          <= 1'b0;
            mute_wait_cnt    <= '0;
            mux_settle_cnt   <= '0;
            mmcm_rst         <= 1'b0;
        end else begin
            if (clk_source_sel != clk_source_sel_q && !mmcm_rst) begin
                // 1. Register changed: automute is muting; arm the relay-
                //    release delay (restart if it changes again mid-wait)
                mute_wait_cnt <= MUTE_DELAY_CYCLES[25:0];
                clk_source_sel_q <= clk_source_sel;
            end else if (mute_wait_cnt != 0) begin
                mute_wait_cnt <= mute_wait_cnt - 1'b1;
                if (mute_wait_cnt == 26'd1) begin
                    mmcm_rst       <= 1'b1;    // 2. reset first, then switch
                    mux_settle_cnt <= MUX_SETTLE_CYCLES[11:0];
                end
            end else if (mmcm_rst) begin
                clk_sel <= clk_source_sel_q;   // flip mux while MMCM held in reset
                if (mux_settle_cnt != 0)
                    mux_settle_cnt <= mux_settle_cnt - 1'b1;
                else
                    mmcm_rst <= 1'b0;          // 3. release -> relock -> flush
            end else begin
                clk_source_sel_q <= clk_source_sel;
            end
        end
    end

    // SPI control signals (clk_200m -> dsp_clk)
    (* MARK_DEBUG = "TRUE" *) logic spi_unmute;
    (* MARK_DEBUG = "TRUE" *) logic level_switch_req;
    logic spi_unmute_sync;
    logic base_rate_sel_sync;
    logic level_switch_req_sync;
    logic [2:0] level_target;
    logic [2:0] level_target_sync;
    logic outsel_switch_req;
    logic outsel_switch_req_sync;
    logic outsel_target;
    logic outsel_target_sync;

    assign sys_rst_n = ext_rst_n & clk_locked;

    // CDC: SPI control signals from clk_200m to dsp_clk domain.
    // level_target / outsel_target are quasi-static: they are written by SPI
    // strictly before their req pulse and only sampled by the sequencer many
    // cycles later (while muted), so 2-FF chains per bit are sufficient.
    (* ASYNC_REG = "TRUE" *) logic [1:0] unmute_sync_chain;
    (* ASYNC_REG = "TRUE" *) logic [1:0] rate_sel_sync_chain;
    (* ASYNC_REG = "TRUE" *) logic [1:0] level_req_sync_chain;
    (* ASYNC_REG = "TRUE" *) logic [5:0] level_target_sync_chain;  // 3 bits x 2 stages
    (* ASYNC_REG = "TRUE" *) logic [1:0] outsel_req_sync_chain;
    (* ASYNC_REG = "TRUE" *) logic [1:0] outsel_target_sync_chain;
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            unmute_sync_chain        <= '0;
            rate_sel_sync_chain      <= '0;
            level_req_sync_chain     <= '0;
            level_target_sync_chain  <= '0;
            outsel_req_sync_chain    <= '0;
            outsel_target_sync_chain <= '0;
        end else begin
            unmute_sync_chain        <= {unmute_sync_chain[0], spi_unmute};
            rate_sel_sync_chain      <= {rate_sel_sync_chain[0], base_rate_sel};
            level_req_sync_chain     <= {level_req_sync_chain[0], level_switch_req};
            level_target_sync_chain  <= {level_target_sync_chain[2:0], level_target};
            outsel_req_sync_chain    <= {outsel_req_sync_chain[0], outsel_switch_req};
            outsel_target_sync_chain <= {outsel_target_sync_chain[0], outsel_target};
        end
    end
    assign spi_unmute_sync       = unmute_sync_chain[1];
    assign base_rate_sel_sync    = rate_sel_sync_chain[1];
    assign level_switch_req_sync  = level_req_sync_chain[1] && !level_req_sync_chain[0]; // edge pulse
    assign level_target_sync      = level_target_sync_chain[5:3];
    assign outsel_switch_req_sync = outsel_req_sync_chain[1] && !outsel_req_sync_chain[0]; // edge pulse
    assign outsel_target_sync     = outsel_target_sync_chain[1];

    logic cell_clk;

    sys_clock_gen u_clk_gen (
        .mclk           (mclk),
        .rst_n          (ext_rst_n),
        .mmcm_rst       (mmcm_rst),
        .dsp_clk        (dsp_clk),
        .cell_clk       (cell_clk),
        .locked         (clk_locked)
    );

    // ==============================================================
    // Inter-module wires
    // ==============================================================

    // DDR4 ui_clk domain
    logic        ddr4_ui_clk;
    logic        ddr4_ui_clk_sync_rst;
    logic        ddr4_init_calib_complete;

    // AXI4 Read (coef_bank_loader <-> ddr4_if)
    logic [29:0] axi_araddr;
    logic [7:0]  axi_arlen;
    logic [2:0]  axi_arsize;
    logic [1:0]  axi_arburst;
    logic        axi_arvalid;
    logic        axi_arready;
    logic [127:0] axi_rdata;
    logic [1:0]  axi_rresp;
    logic        axi_rlast;
    logic        axi_rvalid;
    logic        axi_rready;

    // Coefficient write bus (dsp_clk domain)
    logic        coef_we;
    logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr;  // coef index within MAC (16 phases * TAPS_PER_PHASE)
    logic signed [17:0]          coef_wdata;
    logic [$clog2(NUM_MACS)-1:0] coef_wmac;    // 12 bits for 4096 MACs

    // Bank switching (dsp_clk domain)
    logic        bank_select;
    logic        bank_load_target;

    // Boot envelope (dsp_clk domain)
    logic [15:0] boot_envelope_gain;

    // Coef subsystem status (dsp_clk domain; load_err is a ui_clk level)
    logic [3:0]  current_bank_id;
    logic        mgr_busy;
    logic        bank_valid;        // dsp_clk level: FIR active bank holds a good load
    logic        coef_load_done;
    logic        coef_load_err;
    logic [1:0]  coef_load_err_code;

    // SPI control outputs (clk_200m domain)
    logic [31:0] sys_volume;
    logic [31:0] sys_volume_dsp;   // dsp_clk copy (toggle-handshake CDC below)
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;

    // Named-filter toggle list (docs/coef_format_v2.md): filter_id is
    // resolved to a DDR4 bank image by coef_bank_loader's directory walk.
    // filter_next_id is readback-only (0x17) until shadow-bank preload lands.
    logic [15:0] filter_id;
    logic [15:0] filter_next_id;
    logic        filter_load_req;
    logic        video_mode;

    // I2S audio (dsp_clk domain)
    logic [23:0] audio_l;
    logic [23:0] audio_r;
    logic        new_sample;
    (* MARK_DEBUG = "TRUE" *) logic i2s_err;

    // Mute / relay control (dsp_clk domain)
    (* MARK_DEBUG = "TRUE" *) logic force_zero;
    (* MARK_DEBUG = "TRUE" *) logic line_mute_drive;
    (* MARK_DEBUG = "TRUE" *) logic hp_mute_drive;
    logic                          hp_rails_drive;
    logic [2:0]                    level_relay_drive;
    logic                          switch_busy;

    // CDC: sys_volume (clk_200m) -> dsp_clk. The AP slews volume live over
    // SPI (user 2026-10-09: AP manages the slew), so the word must land in
    // dsp_clk atomically; a torn capture across a carry boundary would put a
    // wrong operand into the volume multiplier for one sample. Toggle
    // handshake: clk_200m flips vol_tog when the word changes, dsp_clk syncs
    // the toggle and captures the (now stable) word. Consecutive SPI frames
    // are >= 40 SCLK apart, far longer than the 3-cycle capture latency.
    logic        vol_tog;
    logic [31:0] sys_volume_q;
    (* ASYNC_REG = "TRUE" *) logic [2:0] vol_tog_sync;
    always_ff @(posedge clk_200m) begin
        if (!ext_rst_n) begin
            vol_tog      <= 1'b0;
            sys_volume_q <= 32'h0;
        end else begin
            sys_volume_q <= sys_volume;
            if (sys_volume != sys_volume_q) vol_tog <= ~vol_tog;
        end
    end
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_tog_sync   <= 3'b0;
            sys_volume_dsp <= 32'h0;
        end else begin
            vol_tog_sync <= {vol_tog_sync[1:0], vol_tog};
            if (vol_tog_sync[2] ^ vol_tog_sync[1]) sys_volume_dsp <= sys_volume;
        end
    end

    // Output LEVEL as a digital gain cap (bom 7 ruling 2026-10-07; dsp_clk).
    // The applied level code comes from the automute sequencer, which only
    // changes it while muted + force-zeroed, so the gain step is click-free.
    // Q0.16 gain relative to 6 Vrms full scale (0xFFFF = x1):
    //   6 V x1 | 4 V x2/3 | 2 V x1/3 | 0.6 V x1/10 | 0.2 V x1/30
    // Folded into the boot-envelope word the DSP volume stage already
    // multiplies by, so dac_dsp_core is untouched: env_level_gain =
    // boot_envelope_gain * level_gain >> 16 (one 16x16 DSP, slow control).
    // SNR at the XLR follows the signal (analog floor ~1.4 uV rms is fixed):
    // 132.8 / 129.3 / 123.3 / 112.8 / 103.3 dB0 for 6 / 4 / 2 / 0.6 / 0.2 V.
    logic [15:0] level_gain;
    (* use_dsp = "yes" *) logic [15:0] env_level_gain;
    always_ff @(posedge dsp_clk) begin
        case (level_relay_drive)
            3'b000:  level_gain <= 16'd21845;  // 2 Vrms   (x1/3,  -9.54 dB)
            3'b001:  level_gain <= 16'd43691;  // 4 Vrms   (x2/3,  -3.52 dB)
            3'b010:  level_gain <= 16'hFFFF;   // 6 Vrms   (x1,     0 dB)
            3'b011:  level_gain <= 16'd6554;   // 0.6 Vrms (x1/10, -20.0 dB)
            3'b100:  level_gain <= 16'd2185;   // 0.2 Vrms (x1/30, -29.5 dB)
            default: level_gain <= 16'd21845;  // reserved codes -> 2 V (safe)
        endcase
        env_level_gain <= 16'((32'(boot_envelope_gain) * 32'(level_gain)) >> 16);
    end

    // Sample tick (dsp_clk domain)
    logic        sample_768k_tick;

    // QSPI flash subsystem (clk_200m domain unless noted — 2026-08-22)
    logic [7:0]  flash_cmd_opcode, flash_buf_wdata, flash_buf_waddr;
    logic [7:0]  flash_buf_raddr, flash_buf_rdata;
    logic [1:0]  flash_cmd_target;
    logic        flash_cmd_trigger, flash_cmd_busy, flash_buf_we;
    logic        flash_cmd_err;
    logic [31:0] flash_cmd_addr;
    logic        qspi_rd_req, qspi_rd_active, qspi_rd_byte_valid, qspi_rd_done;
    logic        qspi_rd_stall, qspi_rd_target, boot_src;
    logic [1:0]  qspi_sel_target, qspi_cf_cs_sel;
    logic [31:0] qspi_rd_addr;
    logic [23:0] qspi_rd_len;
    logic [7:0]  qspi_rd_byte;
    logic        qspi_sck, qspi_cs_n, qspi_mosi, qspi_sel_flash0, qspi_miso;
    logic        startup_eos;
    logic        boot_start;
    logic        boot_done, boot_ok, boot_crc_fail, boot_axi_fail;
    logic [7:0]  boot_record_count;
    logic [29:0] axi_awaddr;
    logic [7:0]  axi_awlen;
    logic [2:0]  axi_awsize;
    logic [1:0]  axi_awburst;
    logic        axi_awvalid, axi_awready;
    logic [127:0] axi_wdata;
    logic [15:0]  axi_wstrb;
    logic         axi_wlast, axi_wvalid, axi_wready;
    logic [1:0]   axi_bresp;
    logic         axi_bvalid, axi_bready;

    // ==============================================================
    // 1. DDR4 Memory Interface
    // ==============================================================
    dac_ddr4_if u_ddr4_if (
        .ddr4_clkref_p          (ddr4_clkref_p),
        .ddr4_clkref_n          (ddr4_clkref_n),
        .sys_rst_n              (sys_rst_n),
        .ddr4_dq                (ddr4_dq),
        .ddr4_dqs_c             (ddr4_dqs_c),
        .ddr4_dqs_t             (ddr4_dqs_t),
        .ddr4_dm_dbi_n          (ddr4_dm_dbi_n),
        .ddr4_addr              (ddr4_addr),
        .ddr4_ba                (ddr4_ba),
        .ddr4_bg                (ddr4_bg),
        .ddr4_cs_n              (ddr4_cs_n),
        .ddr4_cke               (ddr4_cke),
        .ddr4_odt               (ddr4_odt),
        .ddr4_act_n             (ddr4_act_n),
        .ddr4_ck_t              (ddr4_ck_t),
        .ddr4_ck_c              (ddr4_ck_c),
        .ddr4_reset_n           (ddr4_reset_n),
        .ui_clk                 (ddr4_ui_clk),
        .ui_clk_sync_rst        (ddr4_ui_clk_sync_rst),
        .init_calib_complete    (ddr4_init_calib_complete),
        .m_axi_araddr           (axi_araddr),
        .m_axi_arlen            (axi_arlen),
        .m_axi_arsize           (axi_arsize),
        .m_axi_arburst          (axi_arburst),
        .m_axi_arvalid          (axi_arvalid),
        .m_axi_arready          (axi_arready),
        .m_axi_rdata            (axi_rdata),
        .m_axi_rresp            (axi_rresp),
        .m_axi_rlast            (axi_rlast),
        .m_axi_rvalid           (axi_rvalid),
        .m_axi_rready           (axi_rready),
        .s_axi_awaddr           (axi_awaddr),
        .s_axi_awlen            (axi_awlen),
        .s_axi_awsize           (axi_awsize),
        .s_axi_awburst          (axi_awburst),
        .s_axi_awvalid          (axi_awvalid),
        .s_axi_awready          (axi_awready),
        .s_axi_wdata            (axi_wdata),
        .s_axi_wstrb            (axi_wstrb),
        .s_axi_wlast            (axi_wlast),
        .s_axi_wvalid           (axi_wvalid),
        .s_axi_wready           (axi_wready),
        .s_axi_bresp            (axi_bresp),
        .s_axi_bvalid           (axi_bvalid),
        .s_axi_bready           (axi_bready)
    );

    // ==============================================================
    // 1b. QSPI Flash Subsystem (2026-08-22 — Steps 2+3 of flash/DDR4 wiring)
    //   - qspi_flash_ctrl: shared x1-SPI engine, three targets
    //       target 0 = SoM Flash 1 (coefficients, bank-65 pins)
    //       target 1 = SoM Flash 0 (bitstream, via STARTUPE3 — ARM bin updates)
    //       target 2 = carrier coefficient flash (bank-70 pins, 25 MHz)
    //   - qspi_boot_loader: autonomous at EOS+calib — stages coefficient
    //     records QSPI → CRC32 → DDR4; no ARM involvement (user ruling).
    //     Tries the carrier flash first, falls back to SoM Flash 1 (18a).
    //   - ARM update path: ctrl-plane regs 0x10-0x14 / 0x1A-0x1B
    // ==============================================================
    qspi_flash_ctrl u_flash_ctrl (
        .clk            (clk_200m),
        .rst_n          (ext_rst_n),
        .cmd_opcode     (flash_cmd_opcode),
        .cmd_target     (flash_cmd_target),
        .cmd_addr       (flash_cmd_addr),
        .cmd_trigger    (flash_cmd_trigger),
        .cmd_busy       (flash_cmd_busy),
        .cmd_err        (flash_cmd_err),
        .buf_wdata      (flash_buf_wdata),
        .buf_we         (flash_buf_we),
        .buf_waddr      (flash_buf_waddr),
        .buf_raddr      (flash_buf_raddr),
        .buf_rdata      (flash_buf_rdata),
        .rd_req         (qspi_rd_req),
        .rd_target      (qspi_rd_target),
        .rd_addr        (qspi_rd_addr),
        .rd_len         (qspi_rd_len),
        .rd_stall       (qspi_rd_stall),
        .rd_active      (qspi_rd_active),
        .rd_byte        (qspi_rd_byte),
        .rd_byte_valid  (qspi_rd_byte_valid),
        .rd_done        (qspi_rd_done),
        .spi_sck        (qspi_sck),
        .spi_cs_n       (qspi_cs_n),
        .spi_mosi       (qspi_mosi),
        .sel_target     (qspi_sel_target),
        .sel_flash0     (qspi_sel_flash0),
        .cf_cs_sel      (qspi_cf_cs_sel),
        .spi_miso       (qspi_miso)
    );

    // Boot gate: end-of-startup AND DDR4 calibrated (both synced to clk_200m)
    (* ASYNC_REG = "TRUE" *) logic [1:0] calib_sync_boot, eos_sync_boot;
    always_ff @(posedge clk_200m) begin
        calib_sync_boot <= {calib_sync_boot[0], ddr4_init_calib_complete};
        eos_sync_boot   <= {eos_sync_boot[0],   startup_eos};
    end
    assign boot_start = calib_sync_boot[1] && eos_sync_boot[1];

    qspi_boot_loader u_boot_loader (
        .clk            (clk_200m),
        .rst_n          (ext_rst_n),
        .start          (boot_start),
        .rd_req         (qspi_rd_req),
        .rd_target      (qspi_rd_target),
        .rd_addr        (qspi_rd_addr),
        .rd_len         (qspi_rd_len),
        .rd_stall       (qspi_rd_stall),
        .rd_active      (qspi_rd_active),
        .rd_byte        (qspi_rd_byte),
        .rd_byte_valid  (qspi_rd_byte_valid),
        .rd_done        (qspi_rd_done),
        .boot_done      (boot_done),
        .boot_ok        (boot_ok),
        .crc_fail       (boot_crc_fail),
        .axi_fail       (boot_axi_fail),
        .record_count   (boot_record_count),
        .boot_src       (boot_src),
        .ui_clk         (ddr4_ui_clk),
        .ui_rst         (ddr4_ui_clk_sync_rst),
        .m_axi_awaddr   (axi_awaddr),
        .m_axi_awlen    (axi_awlen),
        .m_axi_awsize   (axi_awsize),
        .m_axi_awburst  (axi_awburst),
        .m_axi_awvalid  (axi_awvalid),
        .m_axi_awready  (axi_awready),
        .m_axi_wdata    (axi_wdata),
        .m_axi_wstrb    (axi_wstrb),
        .m_axi_wlast    (axi_wlast),
        .m_axi_wvalid   (axi_wvalid),
        .m_axi_wready   (axi_wready),
        .m_axi_bresp    (axi_bresp),
        .m_axi_bvalid   (axi_bvalid),
        .m_axi_bready   (axi_bready)
    );

    // STARTUPE3: CCLK for both flashes (USRCCLKO) + Flash 0 (config) access.
    //   DO[0] = Flash 0 MOSI, DI[1] = Flash 0 MISO, DO[3:2] = WP/HOLD high,
    //   FCSBO = Flash 0 CS (driven only when sel_flash0)
    logic [3:0] startup_di;
    STARTUPE3 #(
        .PROG_USR      ("FALSE"),
        .SIM_CCLK_FREQ (0.0)
    ) u_startupe3 (
        .CFGCLK    (),
        .CFGMCLK   (),
        .EOS       (startup_eos),
        .PREQ      (),
        .DI        (startup_di),
        .DO        ({2'b11, 1'b0, qspi_mosi}),
        .DTS       (4'b0110),                    // D1 (MISO) + D2 inputs
        .FCSBO     (qspi_sel_flash0 ? qspi_cs_n : 1'b1),
        .FCSBTS    (1'b0),
        .GSR       (1'b0),
        .GTS       (1'b0),
        .KEYCLEARB (1'b1),
        .PACK      (1'b0),
        .USRCCLKO  (qspi_sck),
        .USRCCLKTS (1'b0),
        .USRDONEO  (1'b1),
        .USRDONETS (1'b1)
    );

    // Flash 1 (coefficients) — dedicated bank-65 pins, x1 mode:
    //   dq[0] = MOSI, dq[1] = MISO, dq[2]/dq[3] = WP/HOLD held high
    assign qspi1_cs_n  = (qspi_sel_target == 2'd0) ? qspi_cs_n : 1'b1;
    assign qspi1_dq[0] = qspi_mosi;
    assign qspi1_dq[1] = 1'bz;                   // MISO input
    assign qspi1_dq[2] = 1'b1;
    assign qspi1_dq[3] = 1'b1;

    // Carrier coefficient flash — bank-70 pins, x1 mode (bom 18a). All outputs
    // re-registered on clk_200m so SCK / CS / MOSI leave the IOBs together
    // (one clk of common latency; the engine's SCK-low MOSI setup is unchanged).
    // MISO is taken combinationally: at 25 MHz the engine samples 20 ns after
    // the falling edge it launched; flash t_CLQV (<= 7 ns) + IOB latency +
    // trace fit inside that. Reserved sites cf_cs_n[3:1] follow cf_cs_sel.
    (* IOB = "TRUE" *) logic       cf_sck_q;
    (* IOB = "TRUE" *) logic [3:0] cf_cs_n_q;
    (* IOB = "TRUE" *) logic       cf_mosi_q;
    always_ff @(posedge clk_200m) begin
        cf_sck_q  <= (qspi_sel_target == 2'd2) ? qspi_sck : 1'b0;
        cf_mosi_q <= qspi_mosi;
        for (int i = 0; i < 4; i++)
            cf_cs_n_q[i] <= !((qspi_sel_target == 2'd2) && !qspi_cs_n &&
                              (qspi_cf_cs_sel == 2'(i)));
    end
    assign cf_sck   = cf_sck_q;
    assign cf_cs_n  = cf_cs_n_q;
    assign cf_dq[0] = cf_mosi_q;
    assign cf_dq[1] = 1'bz;                      // MISO input
    assign cf_dq[2] = 1'b1;                      // WP#
    assign cf_dq[3] = 1'b1;                      // HOLD# / RESET#

    always_comb begin
        case (qspi_sel_target)
            2'd1:    qspi_miso = startup_di[1];  // SoM Flash 0 via STARTUPE3
            2'd2:    qspi_miso = cf_dq[1];       // carrier
            default: qspi_miso = qspi1_dq[1];    // SoM Flash 1
        endcase
    end

    // ==============================================================
    // 2. Coefficient Subsystem
    // ==============================================================
    dac_coef_subsys #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE)
    ) u_coef_subsys (
        .ui_clk                 (ddr4_ui_clk),
        .ui_clk_sync_rst        (ddr4_ui_clk_sync_rst),
        .dsp_clk                (dsp_clk),
        .sys_rst_n              (sys_rst_n),
        .sample_768k_tick       (sample_768k_tick),
        .coef_bank_id           (coef_bank_id),
        .coef_load_start        (coef_load_start),
        .filter_id              (filter_id),
        .filter_load_req        (filter_load_req),
        .boot_ok                (boot_ok),
        .m_axi_araddr           (axi_araddr),
        .m_axi_arlen            (axi_arlen),
        .m_axi_arsize           (axi_arsize),
        .m_axi_arburst          (axi_arburst),
        .m_axi_arvalid          (axi_arvalid),
        .m_axi_arready          (axi_arready),
        .m_axi_rdata            (axi_rdata),
        .m_axi_rresp            (axi_rresp),
        .m_axi_rlast            (axi_rlast),
        .m_axi_rvalid           (axi_rvalid),
        .m_axi_rready           (axi_rready),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target),
        .boot_envelope_gain     (boot_envelope_gain),
        .current_bank_id        (current_bank_id),
        .mgr_busy               (mgr_busy),
        .bank_valid             (bank_valid),
        .coef_load_done         (coef_load_done),
        .coef_load_err          (coef_load_err),
        .coef_load_err_code     (coef_load_err_code)
    );

    // Calibration coefficient store wiring (see section 3b)
    logic        cal_wr_toggle, cal_commit_toggle;
    logic [8:0]  cal_wr_addr, cal_rd_addr;
    logic [23:0] cal_wr_data, cal_rd_data;
    logic        cal_active_bank, cal_commit_pending;
    // DPD engines (dsp_clk): cal-store read buses + enable
    logic [3:0][8:0]  dpd_cal_addr;
    logic [3:0][23:0] dpd_cal_data;
    logic             dpd_enable;        // ctrl plane, clk_200m
    logic             dpd_enable_sync;
    logic [1:0][7:0]   cell_test_cfg;
    logic [1:0]        cell_test_req, cell_test_ack;
    logic [10:0] bench_cmd;
    logic bench_req, bench_ack, bench_ready, bench_busy, bench_available;
    logic [31:0] bench_status;
    (* ASYNC_REG = "TRUE" *) logic [2:0] bench_ctrl_meta, bench_ctrl_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] pg_all_sync;
    always_ff @(posedge clk_200m) begin
        if (!ext_rst_n) begin bench_ctrl_meta <= 0; bench_ctrl_sync <= 0; end
        else begin
            bench_ctrl_meta <= {pg_all, sys_rst_n, bench_ready};
            bench_ctrl_sync <= bench_ctrl_meta;
        end
    end
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) pg_all_sync <= 0;
        else pg_all_sync <= {pg_all_sync[0], pg_all};
    end
    bench_test_controller u_bench_ctrl (
        .clk(clk_200m), .rst_n(ext_rst_n), .select_n(test_select_n), .step_n(test_step_n),
        .available(bench_available), .ready(&bench_ctrl_sync),
        .healthy(bench_ctrl_sync[2] && bench_ctrl_sync[1]), .rate_48(base_rate_sel),
        .cmd_ack(bench_ack), .cmd_req(bench_req), .cmd(bench_cmd),
        .busy(bench_busy), .led(test_led), .status(bench_status)
    );
    (* ASYNC_REG = "TRUE" *) logic [1:0] dpd_en_sync_ff;
    always_ff @(posedge dsp_clk)
        dpd_en_sync_ff <= {dpd_en_sync_ff[0], dpd_enable};
    assign dpd_enable_sync = dpd_en_sync_ff[1];

    // ==============================================================
    // 3. Control Plane (SPI + relays)
    // ==============================================================
    dac_ctrl_plane u_ctrl_plane (
        .clk                    (clk_200m),
        .ext_rst_n              (ext_rst_n),
        .spi_sclk               (spi_sclk),
        .spi_cs_n               (spi_cs_n),
        .spi_mosi               (spi_mosi),
        .spi_miso               (spi_miso),
        .fpga_irq_n             (fpga_irq_n),
        .level_switch_req       (level_switch_req),
        .level_target           (level_target),
        .outsel_switch_req      (outsel_switch_req),
        .outsel_target          (outsel_target),
        .mgr_busy               (mgr_busy),
        .bank_valid             (bank_valid),
        .coef_load_done         (coef_load_done),
        .current_bank_id        (current_bank_id),
        .coef_load_err          (coef_load_err),
        .coef_load_err_code     (coef_load_err_code),
        .i2s_err                (i2s_err),
        .switch_busy            (switch_busy),
        .clk_locked             (clk_locked),
        .ddr4_init_calib_complete (ddr4_init_calib_complete),
        .line_mute_status       (line_mute_drive),
        .hp_mute_status         (hp_mute_drive),
        .sys_volume             (sys_volume),
        .base_rate_sel          (base_rate_sel),
        .clk_source_sel         (clk_source_sel),
        .coef_bank_id           (coef_bank_id),
        .coef_load_start        (coef_load_start),
        .filter_id              (filter_id),
        .filter_next_id         (filter_next_id),
        .filter_load_req        (filter_load_req),
        .video_mode             (video_mode),
        .spi_unmute             (spi_unmute),
        .cal_wr_toggle          (cal_wr_toggle),
        .cal_wr_addr            (cal_wr_addr),
        .cal_wr_data            (cal_wr_data),
        .cal_commit_toggle      (cal_commit_toggle),
        .cal_rd_addr            (cal_rd_addr),
        .cal_rd_data            (cal_rd_data),
        .cal_active_bank        (cal_active_bank),
        .cal_commit_pending     (cal_commit_pending),
        .flash_cmd_opcode       (flash_cmd_opcode),
        .flash_cmd_target       (flash_cmd_target),
        .flash_cmd_addr         (flash_cmd_addr),
        .flash_cmd_trigger      (flash_cmd_trigger),
        .flash_cmd_busy         (flash_cmd_busy),
        .flash_cmd_err          (flash_cmd_err),
        .flash_buf_wdata        (flash_buf_wdata),
        .flash_buf_we           (flash_buf_we),
        .flash_buf_waddr        (flash_buf_waddr),
        .flash_buf_raddr        (flash_buf_raddr),
        .flash_buf_rdata        (flash_buf_rdata),
        .boot_done              (boot_done),
        .boot_ok                (boot_ok),
        .boot_crc_fail          (boot_crc_fail),
        .boot_axi_fail          (boot_axi_fail),
        .boot_record_count      (boot_record_count),
        .boot_src               (boot_src),
        .dpd_enable             (dpd_enable),
        .cell_test_cfg          (cell_test_cfg),
        .cell_test_req          (cell_test_req),
        .cell_test_ack          (cell_test_ack),
        .bench_busy             (bench_busy),
        .bench_status           (bench_status),
        .bench_available        (bench_available)
    );

    // ==============================================================
    // 3b. Calibration Coefficient Store (Step 6.3/6.7, DECIDED Aug 2026)
    // ARM computes temperature-corrected cal values and writes them here over
    // SPI; the store swaps banks atomically at a sample boundary. The active
    // bank feeds the dpd_engine pair in dac_dsp_core (4 read ports, Step 4D.1).
    // ==============================================================
    cal_coef_store u_cal_store (
        .dsp_clk        (dsp_clk),
        .dsp_rst_n      (sys_rst_n),
        .sample_tick    (sample_768k_tick),
        .dpd_rd_addr    (dpd_cal_addr),
        .dpd_rd_data    (dpd_cal_data),
        .ctrl_clk       (clk_200m),
        .ctrl_rst_n     (ext_rst_n),
        .wr_toggle      (cal_wr_toggle),
        .wr_addr        (cal_wr_addr),
        .wr_data        (cal_wr_data),
        .commit_toggle  (cal_commit_toggle),
        .rd_addr        (cal_rd_addr),
        .rd_data        (cal_rd_data),
        .active_bank    (cal_active_bank),
        .commit_pending (cal_commit_pending)
    );

    // ==============================================================
    // 4. I2S Ingress
    // ==============================================================
    dac_i2s_ingress u_i2s_ingress (
        .dsp_clk                (dsp_clk),
        .sys_rst_n              (sys_rst_n),
        .i2s_bclk               (i2s_bclk),
        .i2s_lrclk              (i2s_lrclk),
        .i2s_data               (i2s_data),
        .audio_l                (audio_l),
        .audio_r                (audio_r),
        .new_sample             (new_sample),
        .i2s_err                (i2s_err)
    );

    // ==============================================================
    // 3a. Mute / Output Relay Controller
    // ==============================================================
    automute_controller u_automute (
        .clk              (dsp_clk),
        .rst_n            (sys_rst_n),
        .spi_unmute       (spi_unmute_sync),
        .base_rate_sel    (base_rate_sel_sync),
        .i2s_err          (i2s_err),
        .level_switch_req (level_switch_req_sync),
        .level_target     (level_target_sync),
        .outsel_switch_req(outsel_switch_req_sync),
        .outsel_target    (outsel_target_sync),
        .line_mute_drive  (line_mute_drive),
        .hp_mute_drive    (hp_mute_drive),
        .hp_rails_drive   (hp_rails_drive),
        .level_relay_drive(level_relay_drive),
        .force_zero       (force_zero),
        .switch_busy      (switch_busy)
    );

    assign relay_line_mute = line_mute_drive;
    assign relay_hp_mute   = hp_mute_drive;
    assign relay_hp_rails  = hp_rails_drive;
    assign relay_level     = 2'b00;   // no level relays on the board (bom 7, 2026-10-07)

    assign led_debug = {clk_locked, ddr4_init_calib_complete, i2s_err, force_zero};

    // Debug ILA (control-plane clock, captures SPI/automute status)
    // Enable with +define+ILA_EN during synthesis
    ila_wrapper #(
        .PROBE_WIDTH (16)
    ) u_ila_ctrl (
        .clk   (clk_200m),
        .probe ({spi_unmute, level_switch_req, outsel_switch_req, fpga_irq_n,
                 line_mute_drive, hp_mute_drive, hp_rails_drive,
                 force_zero, i2s_err, 7'b0})
    );

    // ==============================================================
    // 5. DSP Core (FIR×16 + HB1/2/3 + volume + dither + 7th-NS + DEM + cascode)
    // ==============================================================
    dac_dsp_core #(
        .NUM_MACS               (NUM_MACS),
        .TAPS_PER_PHASE         (TAPS_PER_PHASE)
    ) u_dsp_core (
        .dsp_clk                (dsp_clk),
        .cell_clk               (cell_clk),
        .sys_rst_n              (sys_rst_n),
        .audio_l                (audio_l),
        .audio_r                (audio_r),
        .new_sample             (new_sample),
        .force_zero             (force_zero),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target),
        .sys_volume             (sys_volume_dsp),
        .boot_envelope_gain     (env_level_gain),   // boot envelope x LEVEL cap (see level_gain above)
        .cell_test_cfg          (cell_test_cfg),
        .cell_test_req          (cell_test_req),
        .cell_test_ack          (cell_test_ack),
        .cell_test_safe         (force_zero && !line_mute_drive && !hp_mute_drive && pg_all_sync[1]),
        .bench_req              (bench_req),
        .bench_cmd              (bench_cmd),
        .bench_ack              (bench_ack),
        .bench_ready            (bench_ready),
        .dpd_enable             (dpd_enable_sync),
        .dpd_cal_addr           (dpd_cal_addr),
        .dpd_cal_data           (dpd_cal_data),
        .sample_768k_tick       (sample_768k_tick),
        .cascode_l              (cascode_l),
        .cascode_r              (cascode_r)
    );

endmodule
