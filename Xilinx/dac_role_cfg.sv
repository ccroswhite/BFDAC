`timescale 1ns / 1ps

// dac_role_cfg — FPGA role configuration register.
//
// Written by the SPI control plane (clk_49m domain) via CMD_SET_ROLE (opcode 0x07).
// Outputs are used in the dsp_clk domain. Because these are static configuration
// values written once at boot and then held stable, a set_false_path is used
// rather than a synchroniser (see XDC).
//
// SPI payload for CMD_SET_ROLE (ctrl_bus_data[31]=0, [30:24]=7'h07):
//   ctrl_bus_data[0]  : channel_sel  — 0=Left, 1=Right
//   ctrl_bus_data[1]  : frame_master — 1=drive frame_sync, 0=receive frame_sync
//
// Default at reset: channel_sel=0 (Left), frame_master=1 (master).
// This makes a single FPGA in standalone mode behave as master/left — correct
// for mono bench testing without any inter-FPGA connection.
//
// XDC required:
//   set_false_path -from [get_cells -hierarchical *channel_sel_reg*]
//   set_false_path -from [get_cells -hierarchical *frame_master_reg*]

module dac_role_cfg (
    input  logic       clk,          // clk_49m (SPI control plane clock)
    input  logic       rst_n,

    // From SPI decoder
    input  logic       write_en,     // pulse when CMD_SET_ROLE received
    input  logic [1:0] role_data,    // [0]=channel_sel, [1]=frame_master

    // Outputs (static after boot — false-path to dsp_clk domain)
    output logic       channel_sel,  // 0=Left, 1=Right
    output logic       frame_master  // 1=TX master, 0=RX slave
);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            channel_sel  <= 1'b0;   // Default: Left
            frame_master <= 1'b1;   // Default: Master
        end else if (write_en) begin
            channel_sel  <= role_data[0];
            frame_master <= role_data[1];
        end
    end

endmodule
