`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic clk_45m,
    input  logic clk_49m,
    input  logic rst_n,
    input  logic base_rate_sel,
    output logic dsp_clk,
    output logic lvds_bit_clk,
    output logic clk_200m,       // ADDED: The Reference Clock for the DDR3L MIG
    output logic locked
);

    logic master_clk_muxed;
    logic mmcm_fb_out, mmcm_fb_in;
    logic dsp_clk_unbuf, lvds_clk_unbuf, clk_200m_unbuf;

    // 1. Safe Clock Multiplexing
    BUFGMUX u_bufgmux (
        .O(master_clk_muxed),
        .I0(clk_45m),
        .I1(clk_49m),
        .S(base_rate_sel)
    );

    // 2. The Core MMCM
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(20.000),    // VCO = 49.152 * 20 = 983.04 MHz
        .CLKIN1_PERIOD(20.345),      // 49.152 MHz period
        
        // DSP Clock: 983.04 / 2.750 = 357.46 MHz
        .CLKOUT0_DIVIDE_F(2.750),    
        
        // LVDS Clock: 983.04 / 5 = 196.608 MHz
        .CLKOUT1_DIVIDE(5),          
        
        // MIG Ref Clock: 983.04 / 5 = 196.608 MHz (Valid for 200MHz IDELAYCTRL)
        .CLKOUT2_DIVIDE(5),          

        .DIVCLK_DIVIDE(1)
    ) u_mmcm (
        .CLKIN1   (master_clk_muxed),
        .CLKFBIN  (mmcm_fb_in),
        .CLKFBOUT (mmcm_fb_out),
        .CLKOUT0  (dsp_clk_unbuf),
        .CLKOUT1  (lvds_clk_unbuf),
        .CLKOUT2  (clk_200m_unbuf),
        .LOCKED   (locked),
        .RST      (~rst_n),
        .PWRDWN   (1'b0)
    );

    // Feedback Buffer
    BUFG u_bufg_fb (
        .I (mmcm_fb_out),
        .O (mmcm_fb_in)
    );

    // Output Buffers
    BUFG u_bufg_dsp (
        .I (dsp_clk_unbuf),
        .O (dsp_clk)
    );

    BUFG u_bufg_lvds (
        .I (lvds_clk_unbuf),
        .O (lvds_bit_clk)
    );

    BUFG u_bufg_200m (
        .I (clk_200m_unbuf),
        .O (clk_200m)
    );

endmodule