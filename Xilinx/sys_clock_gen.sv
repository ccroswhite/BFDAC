`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic clk_45m,
    input  logic clk_49m,
    input  logic rst_n,
    input  logic base_rate_sel,
    output logic dsp_clk,
    output logic lvds_bit_clk,
    output logic locked
);

    // Synthesis-safe pass-through for I/O planning. 
    // To be replaced with MMCME2_ADV / PLLE2_ADV for implementation.
    assign dsp_clk      = base_rate_sel ? clk_49m : clk_45m;
    assign lvds_bit_clk = dsp_clk;
    assign locked       = rst_n;

endmodule