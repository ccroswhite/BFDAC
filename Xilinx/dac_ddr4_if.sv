`timescale 1ns / 1ps

// DDR4 Memory Interface Subsystem
// Wraps the MIG-generated ddr4_0 IP core.
// Platform: Alinx ACVU13 SOM — C0 controller, banks 61/62/63.
//   TOPOLOGY (2026-08-11): 64-bit data (4× MT40A1G16, 8 GB; DDR4 MIG
//   controller maxes at 72-bit so the SOM's 5th chip is unused).
//   DDR4 reference clock: C0_DDR4_CLKREF (AD33/AE33) on-module 200 MHz
// Exposes AXI4 slave ports: read side for coef_bank_loader, write side for
// qspi_boot_loader (added 2026-08-22); ui_clk for the coefficient subsystem.
// NOTE: this is the SIMULATION STUB. The real MIG wrapper is
// dac_ddr4_if_mig.sv (+ ip/ddr4_0, ip/axi_dwc_coef) — include exactly one
// of the two files per fileset.

module dac_ddr4_if (
    // System reset (active-low, from ext_rst_n)
    input  logic        sys_rst_n,

    // DDR4 reference clock — on-module 200 MHz differential (unused in stub)
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
    input  logic         m_axi_rready,

    // AXI4 Write Channels (driven by qspi_boot_loader)
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

    // =========================================================================
    // MIG IP STUB
    // =========================================================================
    // The real ddr4_0 MIG IP must be regenerated in Vivado 2026.1 once the
    // ACVU13 SOM DDR4 topology is confirmed (ranks, speed, bus width, on-module
    // reference clock routing). This stub ties off all outputs to safe defaults
    // so elaboration and simulation of the rest of the design can proceed.
    //
    // To replace: delete this section, instantiate the Vivado-generated ddr4_0
    // IP, connect c0_sys_clk_p/n to the on-module clock (from SOM, not a top
    // port), and update DDR4 PHY port widths to match the SOM topology.
    // =========================================================================

    // PHY outputs (driven low while stub active)
    assign ddr4_addr    = '0;
    assign ddr4_ba      = '0;
    assign ddr4_bg      = '0;
    assign ddr4_cs_n    = '1;  // deselect
    assign ddr4_cke     = '0;
    assign ddr4_odt     = '0;
    assign ddr4_act_n   = 1'b1;
    assign ddr4_ck_t    = '0;
    assign ddr4_ck_c    = '1;
    assign ddr4_reset_n = 1'b0;  // DDR4 held in reset

    // Bidirectional DDR4 data bus — stub drives high-Z
    assign ddr4_dq      = 'z;
    assign ddr4_dqs_c   = 'z;
    assign ddr4_dqs_t   = 'z;
    assign ddr4_dm_dbi_n = 'z;

    // User interface — stub provides a free-running ui_clk from sys_rst_n
    // so coef_subsys CDC logic can simulate without the real MIG.
    // ui_clk frequency: driven by simulation only (no FPGA primitive here).
    assign ui_clk            = 1'b0;  // Replaced by real MIG ui_clk output
    assign ui_clk_sync_rst   = ~sys_rst_n;
    assign init_calib_complete = 1'b0;  // Held low until real MIG present

    // AXI4 read channel — stub stalls all transactions (arready=0, rvalid=0)
    assign m_axi_arready = 1'b0;
    assign m_axi_rdata   = '0;
    assign m_axi_rresp   = 2'b00;
    assign m_axi_rlast   = 1'b0;
    assign m_axi_rvalid  = 1'b0;

    // AXI4 write channels — stub stalls all transactions
    assign s_axi_awready = 1'b0;
    assign s_axi_wready  = 1'b0;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = 1'b0;

endmodule
