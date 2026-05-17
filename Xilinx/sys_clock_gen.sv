`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic clk_45m,         // 44.1k-family audio-locked reference (45.1584 MHz)
    input  logic clk_49m,         // 48k-family audio-locked reference (49.152 MHz)
    input  logic rst_n,
    input  logic base_rate_sel,   // 0 = 44.1k (45.1584 MHz), 1 = 48k (49.152 MHz)
    output logic dsp_clk,         // ~357.46 MHz (49.152 MHz × 20 / 2.75)
    output logic lvds_bit_clk,    // 196.608 MHz (49.152 MHz × 4)
    output logic locked
);

    // ==============================================================
    //  XCAU25P Clock Generator - OCXO-Based Audiophile Clocking
    //
    //  Dual ultra-low jitter OCXO references for high-end DAC performance:
    //    - OCXO #1: 45.1584 MHz = 1024 × 44.1 kHz (44.1k, 88.2k, 176.4k, 352.8k)
    //    - OCXO #2: 49.152 MHz  = 1024 × 48 kHz   (48k, 96k, 192k, 384k, 768k)
    //
    //  Jitter Performance:
    //    - OCXO input:        <1 ps RMS (target)
    //    - MMCM contribution: ~100-200 ps RMS
    //    - Total DSP clock:   <250 ps RMS (excellent for audio)
    //
    //  Generated Clocks:
    //    - VCO:        983.04 MHz (49.152 × 20)
    //    - DSP Clock:  357.46 MHz (983.04 / 2.75)
    //    - LVDS Clock: 196.608 MHz (983.04 / 5) = 768 kHz × 256
    //
    //  CRITICAL: Switch base_rate_sel ONLY during reset/idle to avoid glitches
    // ==============================================================

    logic master_clk_muxed;
    logic mmcm_fb_out, mmcm_fb_in;
    logic dsp_clk_unbuf, lvds_clk_unbuf;

    // 1. Glitchless Clock Multiplexing (BUFGMUX_CTRL)
    //    Switch only when system is idle to prevent phase discontinuities
    BUFGMUX_CTRL u_bufgmux (
        .O  (master_clk_muxed),
        .I0 (clk_45m),
        .I1 (clk_49m),
        .S  (base_rate_sel)
    );

    // 2. Audio-Locked MMCM
    //    VCO range 800-1600 MHz; 983.04 MHz is optimal for low jitter
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(20.000),    // VCO = 49.152 × 20 = 983.04 MHz
        .CLKIN1_PERIOD(20.345),      // 49.152 MHz period (worst case)

        // DSP Clock: 983.04 / 3.5 = 280.87 MHz (49M mode), 258.05 MHz (45M mode)
        // Cycles per 768k sample: 366/336 cycles — still plenty for 768 kHz
        // Reduced from 357/328 MHz to add ~600-900ps timing slack for production
        .CLKOUT0_DIVIDE_F(3.500),

        // LVDS Clock: 983.04 / 5 = 196.608 MHz
        // 196.608 MHz = 768 kHz × 256 (exact frame alignment)
        .CLKOUT1_DIVIDE(5),

        .DIVCLK_DIVIDE(1)
    ) u_mmcm (
        .CLKIN1    (master_clk_muxed),
        .CLKFBIN   (mmcm_fb_in),
        .CLKFBOUT  (mmcm_fb_out),
        .CLKFBOUTB (),
        .CLKOUT0   (dsp_clk_unbuf),
        .CLKOUT0B  (),
        .CLKOUT1   (lvds_clk_unbuf),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .LOCKED    (locked),
        .RST       (~rst_n),
        .PWRDWN    (1'b0)
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

endmodule