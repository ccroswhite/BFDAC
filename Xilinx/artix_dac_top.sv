`timescale 1ns / 1ps

// artix_dac_top - Wire-only top level
// All logic lives in dedicated sub-modules:
//   dac_ddr4_if      : DDR4 MIG wrapper
//   dac_coef_subsys  : Coefficient loading + bank management + CDC
//   dac_ctrl_plane   : SPI register file + relays
//   dac_i2s_ingress  : I2S receiver + stereo FIFO
//   dac_dsp_core     : FIR + volume + dither + noise shape + DEM + LVDS

module artix_dac_top (
    // Base Clocks & Reset (Hybrid OCXO + Studio Reference Clocking)
    input  logic        clk_45m,       // OCXO: 45.1584 MHz = 1024x44.1 kHz
    input  logic        clk_49m,       // OCXO: 49.152 MHz  = 1024x48 kHz
    input  logic        clk_ref_ext,   // External 10 MHz or word clock input

    // DDR4 Reference Clock (XEM8320 AD20/AE20, 100 MHz differential LVDS)
    input  logic        ddr4_refclkp,
    input  logic        ddr4_refclkn,

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

    // Hardware Control Plane
    output logic        relay_gain_6v,
    output logic        relay_audio_out,

    // High-Speed Serial LVDS (To MAX10 Tubs)
    output logic        lvds_bclk_p,
    output logic        lvds_bclk_n,
    output logic        lvds_sync_p,
    output logic        lvds_sync_n,
    output logic        lvds_data_l_p,
    output logic        lvds_data_l_n,
    output logic        lvds_data_r_p,
    output logic        lvds_data_r_n,

    // DDR4 Interface (XEM8320 - Bank 64, pin assignments in XDC)
    inout  wire  [15:0] ddr4_dq,
    inout  wire  [1:0]  ddr4_dqs_c,
    inout  wire  [1:0]  ddr4_dqs_t,
    inout  wire  [1:0]  ddr4_dm_dbi_n,
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
    logic dsp_clk;
    logic lvds_bit_clk;
    logic clk_locked;
    logic sys_rst_n;
    logic base_rate_sel;
    logic clk_source_sel;
    logic clk_49m_muxed;
    logic clk_49m_clean;

    assign sys_rst_n     = ext_rst_n & clk_locked;
    assign clk_49m_muxed = clk_source_sel ? clk_49m_clean : clk_49m;
    assign clk_49m_clean = clk_49m; // TODO: jitter attenuator output

    sys_clock_gen u_clk_gen (
        .clk_45m        (clk_45m),
        .clk_49m        (clk_49m_muxed),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
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
    logic [11:0] coef_waddr;
    logic signed [17:0] coef_wdata;
    logic [6:0]  coef_wmac;

    // Bank switching (dsp_clk domain)
    logic        bank_select;
    logic        bank_load_target;

    // Boot envelope (dsp_clk domain)
    logic [15:0] boot_envelope_gain;

    // Coef subsystem status (dsp_clk domain)
    logic [3:0]  current_bank_id;
    logic        mgr_busy;
    logic        coef_load_done;

    // SPI control outputs (clk_49m domain)
    logic [31:0] sys_volume;
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;

    // I2S audio (dsp_clk domain)
    logic [23:0] audio_l;
    logic [23:0] audio_r;
    logic        new_sample;

    // Sample tick (dsp_clk domain)
    logic        sample_768k_tick;

    // ==============================================================
    // 1. DDR4 Memory Interface
    // ==============================================================
    dac_ddr4_if u_ddr4_if (
        .sys_rst_n              (sys_rst_n),
        .ddr4_refclkp           (ddr4_refclkp),
        .ddr4_refclkn           (ddr4_refclkn),
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
    dac_coef_subsys u_coef_subsys (
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
        .clk_49m                (clk_49m),
        .ext_rst_n              (ext_rst_n),
        .spi_sclk               (spi_sclk),
        .spi_cs_n               (spi_cs_n),
        .spi_mosi               (spi_mosi),
        .spi_miso               (spi_miso),
        .relay_gain_6v          (relay_gain_6v),
        .relay_audio_out        (relay_audio_out),
        .mgr_busy               (mgr_busy),
        .coef_load_done         (coef_load_done),
        .current_bank_id        (current_bank_id),
        .sys_volume             (sys_volume),
        .base_rate_sel          (base_rate_sel),
        .clk_source_sel         (clk_source_sel),
        .coef_bank_id           (coef_bank_id),
        .coef_load_start        (coef_load_start)
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
        .new_sample             (new_sample)
    );

    // ==============================================================
    // 5. DSP Core (FIR + volume + dither + noise shape + DEM + LVDS)
    // ==============================================================
    dac_dsp_core u_dsp_core (
        .dsp_clk                (dsp_clk),
        .lvds_bit_clk           (lvds_bit_clk),
        .sys_rst_n              (sys_rst_n),
        .audio_l                (audio_l),
        .audio_r                (audio_r),
        .new_sample             (new_sample),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target),
        .sys_volume             (sys_volume),
        .boot_envelope_gain     (boot_envelope_gain),
        .sample_768k_tick       (sample_768k_tick),
        .lvds_bclk_p            (lvds_bclk_p),
        .lvds_bclk_n            (lvds_bclk_n),
        .lvds_sync_p            (lvds_sync_p),
        .lvds_sync_n            (lvds_sync_n),
        .lvds_data_l_p          (lvds_data_l_p),
        .lvds_data_l_n          (lvds_data_l_n),
        .lvds_data_r_p          (lvds_data_r_p),
        .lvds_data_r_n          (lvds_data_r_n)
    );

endmodule
