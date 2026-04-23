`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic clk_45m,        // 45.1584 MHz (44.1kHz family)
    input  logic clk_49m,        // 49.152 MHz  (48kHz family)
    input  logic rst_n,          // Async reset (active low)
    input  logic base_rate_sel,  // 0 = 44.1k family, 1 = 48k family
    
    output logic dsp_clk,        // Main processing clock (~24 MHz)
    output logic lvds_bit_clk,   // LVDS transmission clock (~24 MHz)
    output logic locked          // MMCM lock status
);

    // ==============================================================
    // 1. Glitchless Master Clock MUX (Dedicated Silicon)
    // ==============================================================
    logic master_clk_in;
    
    BUFGMUX u_bufgmux (
        .O(master_clk_in),
        .I0(clk_45m),
        .I1(clk_49m),
        .S(base_rate_sel)
    );

    // ==============================================================
    // 2. The Mixed-Mode Clock Manager (MMCM) 
    // ==============================================================
    logic feedback_clk;
    logic dsp_clk_unbuf;
    logic lvds_clk_unbuf;

    // The VCO math:
    // Input * 20.0 = 903.168 MHz (if 45M) or 983.04 MHz (if 49M).
    // Both VCO frequencies are safely within the Artix-7 limits (600 - 1200 MHz).
    // VCO / 40.0 = 22.5792 MHz (if 45M) or 24.576 MHz (if 49M).

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(20.0),    
        .CLKFBOUT_PHASE(0.0),
        .CLKIN1_PERIOD(20.345),    // Base nominal period for Vivado estimates
        .CLKOUT0_DIVIDE_F(40.0),   // LVDS Clock Divider
        .CLKOUT1_DIVIDE(40),       // DSP Clock Divider
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_PHASE(0.0),
        .DIVCLK_DIVIDE(1)          
    ) u_mmcm (
        .CLKIN1(master_clk_in),
        .CLKFBIN(feedback_clk),
        .CLKFBOUT(feedback_clk),
        .CLKOUT0(lvds_clk_unbuf),
        .CLKOUT1(dsp_clk_unbuf),
        .LOCKED(locked),
        .PWRDWN(1'b0),
        .RST(~rst_n)
    );

    // ==============================================================
    // 3. Global Clock Buffers (BUFG)
    // ==============================================================
    // These force the clock out of the MMCM and onto the dedicated 
    // low-skew clock trees spanning the FPGA die.
    
    BUFG u_bufg_lvds (
        .I(lvds_clk_unbuf),
        .O(lvds_bit_clk)
    );

    BUFG u_bufg_dsp (
        .I(dsp_clk_unbuf),
        .O(dsp_clk)
    );

endmodule