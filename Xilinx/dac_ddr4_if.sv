`timescale 1ns / 1ps

// DDR4 Memory Interface Subsystem
// Wraps the MIG-generated ddr4_0 IP core.
// Exposes AXI4 read-only master for coef_bank_loader and ui_clk for the
// coefficient subsystem. Write channels are tied off (read-only design).

module dac_ddr4_if (
    // System reset (active-low, from ext_rst_n)
    input  logic        sys_rst_n,

    // DDR4 Reference Clock (100 MHz differential LVDS, XEM8320 pins AD20/AE20)
    input  logic        ddr4_refclkp,
    input  logic        ddr4_refclkn,

    // DDR4 PHY Interface (route directly to FPGA pins via XDC)
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
    output wire         ddr4_reset_n,

    // MIG User Interface outputs
    output logic        ui_clk,             // ~200 MHz output clock
    output logic        ui_clk_sync_rst,    // Active-high sync reset in ui_clk domain
    output logic        init_calib_complete,

    // AXI4 Read Address Channel (driven by coef_bank_loader)
    input  logic [29:0] m_axi_araddr,
    input  logic [7:0]  m_axi_arlen,
    input  logic [2:0]  m_axi_arsize,
    input  logic [1:0]  m_axi_arburst,
    input  logic        m_axi_arvalid,
    output logic        m_axi_arready,

    // AXI4 Read Data Channel (to coef_bank_loader)
    output logic [127:0] m_axi_rdata,
    output logic [1:0]   m_axi_rresp,
    output logic         m_axi_rlast,
    output logic         m_axi_rvalid,
    input  logic         m_axi_rready
);

    ddr4_0 u_ddr4 (
        .sys_rst                    (~sys_rst_n),
        .c0_sys_clk_p               (ddr4_refclkp),
        .c0_sys_clk_n               (ddr4_refclkn),

        // DDR4 PHY
        .c0_ddr4_adr                (ddr4_addr),
        .c0_ddr4_ba                 (ddr4_ba),
        .c0_ddr4_cke                (ddr4_cke),
        .c0_ddr4_cs_n               (ddr4_cs_n),
        .c0_ddr4_act_n              (ddr4_act_n),
        .c0_ddr4_odt                (ddr4_odt),
        .c0_ddr4_bg                 (ddr4_bg),
        .c0_ddr4_reset_n            (ddr4_reset_n),
        .c0_ddr4_dm_dbi_n           (ddr4_dm_dbi_n),
        .c0_ddr4_dq                 (ddr4_dq),
        .c0_ddr4_dqs_c              (ddr4_dqs_c),
        .c0_ddr4_dqs_t              (ddr4_dqs_t),
        .c0_ddr4_ck_c               (ddr4_ck_c),
        .c0_ddr4_ck_t               (ddr4_ck_t),

        // User interface
        .c0_ddr4_ui_clk             (ui_clk),
        .c0_ddr4_ui_clk_sync_rst    (ui_clk_sync_rst),
        .c0_init_calib_complete     (init_calib_complete),
        .dbg_clk                    (/* unused */),
        .dbg_bus                    (/* unused */),

        // AXI4 Reset
        .c0_ddr4_aresetn            (sys_rst_n),

        // AXI4 Read Address Channel
        .c0_ddr4_s_axi_araddr       (m_axi_araddr),
        .c0_ddr4_s_axi_arlen        (m_axi_arlen),
        .c0_ddr4_s_axi_arsize       (m_axi_arsize),
        .c0_ddr4_s_axi_arburst      (m_axi_arburst),
        .c0_ddr4_s_axi_arvalid      (m_axi_arvalid),
        .c0_ddr4_s_axi_arready      (m_axi_arready),
        .c0_ddr4_s_axi_arid         (4'h0),
        .c0_ddr4_s_axi_arlock       (1'h0),
        .c0_ddr4_s_axi_arcache      (4'h0),
        .c0_ddr4_s_axi_arprot       (3'h0),
        .c0_ddr4_s_axi_arqos        (4'h0),

        // AXI4 Read Data Channel
        .c0_ddr4_s_axi_rdata        (m_axi_rdata),
        .c0_ddr4_s_axi_rresp        (m_axi_rresp),
        .c0_ddr4_s_axi_rlast        (m_axi_rlast),
        .c0_ddr4_s_axi_rvalid       (m_axi_rvalid),
        .c0_ddr4_s_axi_rready       (m_axi_rready),
        .c0_ddr4_s_axi_rid          (/* unused */),

        // AXI4 Write channels (unused - tie off)
        .c0_ddr4_s_axi_awid         (4'h0),
        .c0_ddr4_s_axi_awaddr       (30'h0),
        .c0_ddr4_s_axi_awlen        (8'h0),
        .c0_ddr4_s_axi_awsize       (3'h0),
        .c0_ddr4_s_axi_awburst      (2'h0),
        .c0_ddr4_s_axi_awlock       (1'h0),
        .c0_ddr4_s_axi_awcache      (4'h0),
        .c0_ddr4_s_axi_awprot       (3'h0),
        .c0_ddr4_s_axi_awqos        (4'h0),
        .c0_ddr4_s_axi_awvalid      (1'b0),
        .c0_ddr4_s_axi_awready      (/* unused */),
        .c0_ddr4_s_axi_wdata        (128'h0),
        .c0_ddr4_s_axi_wstrb        (16'h0),
        .c0_ddr4_s_axi_wlast        (1'b0),
        .c0_ddr4_s_axi_wvalid       (1'b0),
        .c0_ddr4_s_axi_wready       (/* unused */),
        .c0_ddr4_s_axi_bid          (/* unused */),
        .c0_ddr4_s_axi_bresp        (/* unused */),
        .c0_ddr4_s_axi_bvalid       (/* unused */),
        .c0_ddr4_s_axi_bready       (1'b1)
    );

endmodule
