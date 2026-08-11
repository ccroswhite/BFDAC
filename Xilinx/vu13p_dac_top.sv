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
    parameter int NUM_MACS = 1024,  // Production: 1024 (1M taps) or 2048 (2M taps)
    parameter int TAPS_PER_PHASE = 64,  // Coefs per MAC per phase; taps = 16*NUM_MACS*TAPS_PER_PHASE
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
    output logic [1:0]  relay_level,          // 00 = 2V tap, 01 = 4V, 10 = 6V

    // Debug / Status LED (BC33) + board-level debug LEDs (J1)
    output logic        led_status,
    output logic [3:0]  led_debug,     // [3]=clk_locked [2]=ddr4_calib [1]=i2s_err [0]=force_zero

    // QSPI Flash 1 — coefficient storage (bank 65, directly accessible)
    // Flash 0 accessed via STARTUPE3 (config pins, bitstreams)
    output logic        qspi1_cs_n,
    inout  wire  [3:0]  qspi1_dq,

    // Direct cascode cell outputs — IOB-registered on cell_clk, < 50 ps
    // inter-cell skew. 1 pin per cell, 64 per channel, 128 total (pins: XDC §8,
    // banks 64+65 = L, 67+69 = R); external MC100EP52 reclock FFs generate the
    // complementary base-drive pair (Fig. 1b)
    output logic [63:0] cascode_l,
    output logic [63:0] cascode_r,

    // DDR4 Interface — C0 controller, 5× MT40A1G16KD-062E, banks 61/62/63
    // 80-bit data bus (5 chips × 16 bits), 10 byte lanes
    inout  wire  [79:0] ddr4_dq,
    inout  wire  [9:0]  ddr4_dqs_c,
    inout  wire  [9:0]  ddr4_dqs_t,
    inout  wire  [9:0]  ddr4_dm_dbi_n,
    output wire  [13:0] ddr4_addr,
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
    logic [1:0] level_target;
    logic [1:0] level_target_sync;
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
    (* ASYNC_REG = "TRUE" *) logic [3:0] level_target_sync_chain;  // 2 bits x 2 stages
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
            level_target_sync_chain  <= {level_target_sync_chain[1:0], level_target};
            outsel_req_sync_chain    <= {outsel_req_sync_chain[0], outsel_switch_req};
            outsel_target_sync_chain <= {outsel_target_sync_chain[0], outsel_target};
        end
    end
    assign spi_unmute_sync       = unmute_sync_chain[1];
    assign base_rate_sel_sync    = rate_sel_sync_chain[1];
    assign level_switch_req_sync  = level_req_sync_chain[1] && !level_req_sync_chain[0]; // edge pulse
    assign level_target_sync      = level_target_sync_chain[3:2];
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

    // Coef subsystem status (dsp_clk domain)
    logic [3:0]  current_bank_id;
    logic        mgr_busy;
    logic        coef_load_done;

    // SPI control outputs (clk_200m domain)
    logic [31:0] sys_volume;
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;

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
    logic [1:0]                    level_relay_drive;
    logic                          switch_busy;

    // Sample tick (dsp_clk domain)
    logic        sample_768k_tick;

    // ==============================================================
    // 1. DDR4 Memory Interface
    // ==============================================================
    dac_ddr4_if u_ddr4_if (
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
        .m_axi_rready           (axi_rready)
    );

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
        .coef_load_done         (coef_load_done)
    );

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
        .coef_load_done         (coef_load_done),
        .current_bank_id        (current_bank_id),
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
        .spi_unmute             (spi_unmute)
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
    assign relay_level     = level_relay_drive;

    assign led_debug = {clk_locked, ddr4_init_calib_complete, i2s_err, force_zero};

    // Debug ILA (control-plane clock, captures SPI/automute/I2C status)
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
        .sys_volume             (sys_volume),
        .boot_envelope_gain     (boot_envelope_gain),
        .sample_768k_tick       (sample_768k_tick),
        .cascode_l              (cascode_l),
        .cascode_r              (cascode_r)
    );

endmodule
