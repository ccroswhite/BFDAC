`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic clk_45m,       // 45.1584 MHz Master (for 44.1k family)
    input  logic clk_49m,       // 49.1520 MHz Master (for 48k family)
    input  logic rst_n,
    input  logic base_rate_sel, // 0 = 45.1584MHz, 1 = 49.152MHz
    
    output logic dsp_clk,       // ~344.5 MHz (Overclocked DSP Core)
    output logic lvds_bit_clk,  // ~196.6 MHz (Serial Transmission)
    output logic locked
);

    logic master_clk_muxed;
    logic clkfb_out, clkfb_in;
    logic dsp_clk_unbuf, lvds_clk_unbuf;

    // Glitchless clock multiplexer
    BUFGMUX u_bufgmux (
        .O(master_clk_muxed),
        .I0(clk_45m),
        .I1(clk_49m),
        .S(base_rate_sel)
    );

// Hardware MMCM for zero-jitter multiplication/division
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(20.000),    // VCO = ~983 MHz (49.152 * 20)
        .CLKOUT0_DIVIDE_F(2.750),    // CHANGED: Valid 0.125 increment (983 / 2.75 = 357.46 MHz)
        .CLKOUT1_DIVIDE(5),          // CLKOUT1 = ~196.6 MHz (983 / 5)
        .DIVCLK_DIVIDE(1),
        .CLKIN1_PERIOD(20.345)
    ) u_mmcm (
        .CLKIN1  (master_clk_muxed),
        .CLKFBIN (clkfb_in),
        .RST     (~rst_n),
        .PWRDWN  (1'b0),
        
        .CLKFBOUT(clkfb_out),
        .CLKOUT0 (dsp_clk_unbuf),
        .CLKOUT1 (lvds_clk_unbuf),
        .LOCKED  (locked)
    );

    // Route MMCM feedback and outputs onto dedicated low-skew Global Clock buffers
    BUFG u_bufg_fb   (.I(clkfb_out),      .O(clkfb_in));
    BUFG u_bufg_dsp  (.I(dsp_clk_unbuf),  .O(dsp_clk));
    BUFG u_bufg_lvds (.I(lvds_clk_unbuf), .O(lvds_bit_clk));

endmodule