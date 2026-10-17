`timescale 1ns / 1ps

// DDR4 Memory Interface Subsystem — REAL MIG (f9 fitment configuration)
// Wraps the Vivado-generated ddr4_0 IP + axi_dwc_coef width converter.
// Platform: Alinx ACVU13 SOM — C0 controller, banks 61/62/63.
//   TOPOLOGY NOTE (2026-08-11): SOM carries 5x MT40A1G16KD-062E (80 DQ),
//   but the DDR4 MIG controller maxes at 72-bit. Configured 64-bit data
//   (4 devices, 8 GB addressable); 5th device unused. MIG part is
//   MT40A1G16RC-062E (KD not in the 2026.1 part list; config-compatible).
//   2400 MT/s, on-module 200 MHz reference clock (C0_DDR4_CLKREF).
// Exposes AXI4 slave ports (128-bit, upsized to the MIG's native 512-bit
// slave via axi_dwc_coef): read side serves coef_bank_loader; write side
// serves qspi_boot_loader (QSPI → DDR4 coefficient staging, added 2026-08-22
// — previously tied off read-only).
//
// This file REPLACES the dac_ddr4_if stub for synthesis/implementation
// runs (exclude dac_ddr4_if.sv, include this + ip/*.xci). The stub remains
// the simulation default until a DDR4 sim flow exists.

module dac_ddr4_if (
    // System reset (active-low, from ext_rst_n)
    input  logic        sys_rst_n,

    // DDR4 reference clock — on-module 200 MHz differential
    input  wire         ddr4_clkref_p,
    input  wire         ddr4_clkref_n,

    // DDR4 PHY Interface — C0, 64-bit, banks 61/62/63
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
    output wire         ddr4_reset_n,

    // MIG User Interface outputs
    output logic        ui_clk,             // MIG ui_clk (DDR4 clk/4 = 300 MHz)
    output logic        ui_clk_sync_rst,    // Active-high sync reset in ui_clk domain
    output logic        init_calib_complete,

    // AXI4 Read Address Channel (driven by coef_bank_loader, 128-bit domain)
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
    input  logic         m_axi_rready,

    // AXI4 Write Channels (driven by qspi_boot_loader, 128-bit, ui_clk domain)
    input  logic [29:0]  s_axi_awaddr,
    input  logic [7:0]   s_axi_awlen,
    input  logic [2:0]   s_axi_awsize,
    input  logic [1:0]   s_axi_awburst,
    input  logic         s_axi_awvalid,
    output logic         s_axi_awready,
    input  logic [127:0] s_axi_wdata,
    input  logic [15:0]  s_axi_wstrb,
    input  logic         s_axi_wlast,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,
    output logic [1:0]   s_axi_bresp,
    output logic         s_axi_bvalid,
    input  logic         s_axi_bready
);

    // AXI between width converter (master, 512b) and MIG slave
    logic [32:0]  mig_araddr;
    logic [7:0]   mig_arlen;
    logic [2:0]   mig_arsize;
    logic [1:0]   mig_arburst;
    logic         mig_arvalid, mig_arready;
    logic [2:0]   mig_arprot;
    logic [3:0]   mig_arqos, mig_arcache, mig_arregion;
    logic [0:0]   mig_arlock;
    logic [511:0] mig_rdata;
    logic [1:0]   mig_rresp;
    logic         mig_rlast, mig_rvalid, mig_rready;

    logic [32:0]  mig_awaddr;
    logic [7:0]   mig_awlen;
    logic [2:0]   mig_awsize;
    logic [1:0]   mig_awburst;
    logic         mig_awvalid, mig_awready;
    logic [2:0]   mig_awprot;
    logic [3:0]   mig_awqos, mig_awcache, mig_awregion;
    logic [0:0]   mig_awlock;
    logic [511:0] mig_wdata;
    logic [63:0]  mig_wstrb;
    logic         mig_wlast, mig_wvalid, mig_wready;
    logic [1:0]   mig_bresp;
    logic         mig_bvalid, mig_bready;

    logic aresetn;
    assign aresetn = ~ui_clk_sync_rst;

    // ------------------------------------------------------------------
    // AXI width converter: 128-bit SI (loader) -> 512-bit MI (MIG)
    // Single-clock (FIFO_MODE=0): everything in ui_clk domain.
    // Write path: qspi_boot_loader (128b SI) upsized to the 512b MIG slave.
    // ------------------------------------------------------------------
    axi_dwc_coef u_axi_dwc (
        .s_axi_aclk     (ui_clk),
        .s_axi_aresetn  (aresetn),
        // SI write (qspi_boot_loader)
        .s_axi_awid     (1'b0),
        .s_axi_awaddr   ({3'd0, s_axi_awaddr}),
        .s_axi_awlen    (s_axi_awlen),
        .s_axi_awsize   (s_axi_awsize),
        .s_axi_awburst  (s_axi_awburst),
        .s_axi_awlock   (1'b0),
        // AxCACHE[1] (Modifiable) MUST be set: with it clear the upsizer
        // forwards each 128-bit beat as a narrow 16 B beat on the 512-bit
        // bus (len unchanged, rotating strobes) and ddr4_0 (AxiNarrowBurst
        // = false) writes every beat at a 64 B stride -> scrambled image
        // (tb_vu13p_mig, 2026-09-04). 0011 = normal non-cacheable bufferable.
        .s_axi_awcache  (4'b0011),
        .s_axi_awprot   (3'd0),
        .s_axi_awregion (4'd0),
        .s_axi_awqos    (4'd0),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wlast    (s_axi_wlast),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bid      (),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        // SI read (loader)
        .s_axi_arid     (1'b0),
        .s_axi_araddr   ({3'd0, m_axi_araddr}),
        .s_axi_arlen    (m_axi_arlen),
        .s_axi_arsize   (m_axi_arsize),
        .s_axi_arburst  (m_axi_arburst),
        .s_axi_arlock   (1'b0),
        .s_axi_arcache  (4'b0011),
        .s_axi_arprot   (3'd0),
        .s_axi_arregion (4'd0),
        .s_axi_arqos    (4'd0),
        .s_axi_arvalid  (m_axi_arvalid),
        .s_axi_arready  (m_axi_arready),
        .s_axi_rid      (),
        .s_axi_rdata    (m_axi_rdata),
        .s_axi_rresp    (m_axi_rresp),
        .s_axi_rlast    (m_axi_rlast),
        .s_axi_rvalid   (m_axi_rvalid),
        .s_axi_rready   (m_axi_rready),
        // MI write -> MIG
        .m_axi_awaddr   (mig_awaddr),
        .m_axi_awlen    (mig_awlen),
        .m_axi_awsize   (mig_awsize),
        .m_axi_awburst  (mig_awburst),
        .m_axi_awlock   (mig_awlock),
        .m_axi_awcache  (mig_awcache),
        .m_axi_awprot   (mig_awprot),
        .m_axi_awregion (mig_awregion),
        .m_axi_awqos    (mig_awqos),
        .m_axi_awvalid  (mig_awvalid),
        .m_axi_awready  (mig_awready),
        .m_axi_wdata    (mig_wdata),
        .m_axi_wstrb    (mig_wstrb),
        .m_axi_wlast    (mig_wlast),
        .m_axi_wvalid   (mig_wvalid),
        .m_axi_wready   (mig_wready),
        .m_axi_bresp    (mig_bresp),
        .m_axi_bvalid   (mig_bvalid),
        .m_axi_bready   (mig_bready),
        // MI read -> MIG
        .m_axi_araddr   (mig_araddr),
        .m_axi_arlen    (mig_arlen),
        .m_axi_arsize   (mig_arsize),
        .m_axi_arburst  (mig_arburst),
        .m_axi_arlock   (mig_arlock),
        .m_axi_arcache  (mig_arcache),
        .m_axi_arprot   (mig_arprot),
        .m_axi_arregion (mig_arregion),
        .m_axi_arqos    (mig_arqos),
        .m_axi_arvalid  (mig_arvalid),
        .m_axi_arready  (mig_arready),
        .m_axi_rdata    (mig_rdata),
        .m_axi_rresp    (mig_rresp),
        .m_axi_rlast    (mig_rlast),
        .m_axi_rvalid   (mig_rvalid),
        .m_axi_rready   (mig_rready)
    );

    // ------------------------------------------------------------------
    // DDR4 MIG
    // ------------------------------------------------------------------
    ddr4_0 u_ddr4_0 (
        .sys_rst                   (~sys_rst_n),
        .c0_sys_clk_p              (ddr4_clkref_p),
        .c0_sys_clk_n              (ddr4_clkref_n),
        .c0_ddr4_act_n             (ddr4_act_n),
        .c0_ddr4_adr               (ddr4_addr),
        .c0_ddr4_ba                (ddr4_ba),
        .c0_ddr4_bg                (ddr4_bg),
        .c0_ddr4_cke               (ddr4_cke),
        .c0_ddr4_odt               (ddr4_odt),
        .c0_ddr4_cs_n              (ddr4_cs_n),
        .c0_ddr4_ck_t              (ddr4_ck_t),
        .c0_ddr4_ck_c              (ddr4_ck_c),
        .c0_ddr4_reset_n           (ddr4_reset_n),
        .c0_ddr4_dm_dbi_n          (ddr4_dm_dbi_n),
        .c0_ddr4_dq                (ddr4_dq),
        .c0_ddr4_dqs_c             (ddr4_dqs_c),
        .c0_ddr4_dqs_t             (ddr4_dqs_t),
        .c0_init_calib_complete    (init_calib_complete),
        .c0_ddr4_ui_clk            (ui_clk),
        .c0_ddr4_ui_clk_sync_rst   (ui_clk_sync_rst),
        .dbg_clk                   (),
        .dbg_bus                   (),
        .c0_ddr4_aresetn           (aresetn),
        // AXI slave — write channels from width converter
        .c0_ddr4_s_axi_awid        (1'b0),
        .c0_ddr4_s_axi_awaddr      (mig_awaddr),
        .c0_ddr4_s_axi_awlen       (mig_awlen),
        .c0_ddr4_s_axi_awsize      (mig_awsize),
        .c0_ddr4_s_axi_awburst     (mig_awburst),
        .c0_ddr4_s_axi_awlock      (mig_awlock),
        .c0_ddr4_s_axi_awcache     (mig_awcache),
        .c0_ddr4_s_axi_awprot      (mig_awprot),
        .c0_ddr4_s_axi_awqos       (mig_awqos),
        .c0_ddr4_s_axi_awvalid     (mig_awvalid),
        .c0_ddr4_s_axi_awready     (mig_awready),
        .c0_ddr4_s_axi_wdata       (mig_wdata),
        .c0_ddr4_s_axi_wstrb       (mig_wstrb),
        .c0_ddr4_s_axi_wlast       (mig_wlast),
        .c0_ddr4_s_axi_wvalid      (mig_wvalid),
        .c0_ddr4_s_axi_wready      (mig_wready),
        .c0_ddr4_s_axi_bid         (),
        .c0_ddr4_s_axi_bresp       (mig_bresp),
        .c0_ddr4_s_axi_bvalid      (mig_bvalid),
        .c0_ddr4_s_axi_bready      (mig_bready),
        // AXI slave — read channels from width converter
        .c0_ddr4_s_axi_arid        (1'b0),
        .c0_ddr4_s_axi_araddr      (mig_araddr),
        .c0_ddr4_s_axi_arlen       (mig_arlen),
        .c0_ddr4_s_axi_arsize      (mig_arsize),
        .c0_ddr4_s_axi_arburst     (mig_arburst),
        .c0_ddr4_s_axi_arlock      (mig_arlock),
        .c0_ddr4_s_axi_arcache     (mig_arcache),
        .c0_ddr4_s_axi_arprot      (mig_arprot),
        .c0_ddr4_s_axi_arqos       (mig_arqos),
        .c0_ddr4_s_axi_arvalid     (mig_arvalid),
        .c0_ddr4_s_axi_arready     (mig_arready),
        .c0_ddr4_s_axi_rid         (),
        .c0_ddr4_s_axi_rdata       (mig_rdata),
        .c0_ddr4_s_axi_rresp       (mig_rresp),
        .c0_ddr4_s_axi_rlast       (mig_rlast),
        .c0_ddr4_s_axi_rvalid      (mig_rvalid),
        .c0_ddr4_s_axi_rready      (mig_rready)
    );

endmodule
