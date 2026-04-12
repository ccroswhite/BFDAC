`timescale 1ns / 1ps

module sys_clock_gen #(
    // Assuming a 49.152 MHz VCXO Master Clock
    parameter real CLKIN_PERIOD    = 20.345, // 1 / 49.152MHz in ns
    parameter real VCO_MULTIPLIER  = 20.000, // VCO = 49.152 * 20 = 983.04 MHz
    parameter real BIT_CLK_DIVIDE  = 2.500,  // 983.04 / 2.5 = 393.216 MHz (LVDS Bit Clock)
    parameter integer FRAME_DIVIDE = 10      // 983.04 / 10 = 98.304 MHz (DSP / Frame Clock)
)(
    input  logic clk_in_p,
    input  logic clk_in_n,
    input  logic rst_n,

    output logic dsp_clk,         // Master DSP / OSERDES Frame Clock
    output logic lvds_bit_clk,    // High-Speed OSERDES Bit Clock
    output logic locked           // MMCM Locked Indicator
);

    // Internal nets
    logic clk_in_single;
    logic vco_feedback_out, vco_feedback_in;
    logic clk_out_bit_unbuf, clk_out_frame_unbuf;
    logic mmcm_locked;

    // =========================================================================
    // 1. Differential Input Buffer
    // Converts the off-chip LVDS/PECL VCXO into a single-ended internal route
    // =========================================================================
    IBUFGDS #(
        .DIFF_TERM("TRUE"),  // Enable internal 100-ohm termination
        .IBUF_LOW_PWR("FALSE") // Optimize for jitter over power
    ) u_ibufgds_sys (
        .I  (clk_in_p),
        .IB (clk_in_n),
        .O  (clk_in_single)
    );

    // =========================================================================
    // 2. The Mixed-Mode Clock Manager (MMCM)
    // Guarantees zero-delay phase alignment between the bit and frame clocks
    // =========================================================================
    MMCME2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .COMPENSATION         ("ZHOLD"),
        .DIVCLK_DIVIDE        (1),
        .CLKFBOUT_MULT_F      (VCO_MULTIPLIER),
        .CLKFBOUT_PHASE       (0.000),
        .CLKIN1_PERIOD        (CLKIN_PERIOD),
        
        // CLKOUT0: High-Speed LVDS Bit Clock (e.g., 393.216 MHz)
        .CLKOUT0_DIVIDE_F     (BIT_CLK_DIVIDE),
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        
        // CLKOUT1: DSP & OSERDES Frame Clock (e.g., 98.304 MHz)
        .CLKOUT1_DIVIDE       (FRAME_DIVIDE),
        .CLKOUT1_PHASE        (0.000),
        .CLKOUT1_DUTY_CYCLE   (0.500)
    ) u_mmcm_master (
        // Input Clock & Reset
        .CLKIN1      (clk_in_single),
        .CLKIN2      (1'b0),
        .CLKINSEL    (1'b1),
        .RST         (~rst_n),
        .PWRDWN      (1'b0),

        // Feedback Loop (Zero-delay phase alignment)
        .CLKFBOUT    (vco_feedback_out),
        .CLKFBOUTB   (),
        .CLKFBIN     (vco_feedback_in),

        // Output Clocks
        .CLKOUT0     (clk_out_bit_unbuf),
        .CLKOUT0B    (),
        .CLKOUT1     (clk_out_frame_unbuf),
        .CLKOUT1B    (),
        .CLKOUT2     (),
        .CLKOUT2B    (),
        .CLKOUT3     (),
        .CLKOUT3B    (),
        .CLKOUT4     (),
        .CLKOUT5     (),
        .CLKOUT6     (),

        // Status
        .LOCKED      (mmcm_locked)
    );

    // =========================================================================
    // 3. Global Clock Buffers (BUFG)
    // Routes the generated clocks onto the low-skew global clock trees
    // =========================================================================
    
    // Feedback buffer (required for ZHOLD compensation)
    BUFG u_bufg_fb (
        .I (vco_feedback_out),
        .O (vco_feedback_in)
    );

    // High-speed Bit Clock buffer
    BUFG u_bufg_bit (
        .I (clk_out_bit_unbuf),
        .O (lvds_bit_clk)
    );

    // DSP/Frame Clock buffer
    BUFG u_bufg_frame (
        .I (clk_out_frame_unbuf),
        .O (dsp_clk)
    );

    // =========================================================================
    // 4. Lock Synchronization
    // Ensures downstream logic doesn't exit reset until the clock is stable
    // =========================================================================
    always_ff @(posedge dsp_clk or negedge rst_n) begin
        if (!rst_n) begin
            locked <= 1'b0;
        end else begin
            locked <= mmcm_locked;
        end
    end

endmodule