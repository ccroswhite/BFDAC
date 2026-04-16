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

    // Dedicated Clock Mux Primitive (Fixes TIMING-14)
    BUFGMUX u_clock_mux (
        .O(dsp_clk),
        .I0(clk_45m),   // Base rate 0 (e.g., 44.1k family)
        .I1(clk_49m),   // Base rate 1 (e.g., 48k family)
        .S(base_rate_sel)
    );

    assign lvds_bit_clk = dsp_clk;
    assign locked       = rst_n;

endmodule