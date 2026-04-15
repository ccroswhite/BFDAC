`timescale 1ns / 1ps

module sys_clock_gen (
    // Dual Differential Master Clocks
    input  logic clk_45m_p,
    input  logic clk_45m_n,
    input  logic clk_49m_p,
    input  logic clk_49m_n,
    
    // System Reset & Control
    input  logic rst_n,
    input  logic base_rate_sel, // 0 = 45.1584 MHz, 1 = 49.152 MHz
    
    // Generated Output Clocks
    output logic dsp_clk,       // 2x Base Rate (~90.3 MHz / 98.3 MHz)
    output logic lvds_bit_clk,  // 8x Base Rate (~361.2 MHz / 393.2 MHz)
    output logic locked
);

    // =========================================================================
    // 1. Input Differential Buffers (IBUFDS)
    // =========================================================================
    logic clk_45m_ibuf;
    logic clk_49m_ibuf;

    IBUFDS u_ibufds_45m (
        .I  (clk_45m_p),
        .IB (clk_45m_n),
        .O  (clk_45m_ibuf)
    );

    IBUFDS u_ibufds_49m (
        .I  (clk_49m_p),
        .IB (clk_49m_n),
        .O  (clk_49m_ibuf)
    );

    // =========================================================================
    // 2. Glitch-Free Clock Mux (BUFGMUX)
    // =========================================================================
    logic clk_in_buffered;

    BUFGMUX u_bufgmux_base (
        .O  (clk_in_buffered),
        .I0 (clk_45m_ibuf),
        .I1 (clk_49m_ibuf),
        .S  (base_rate_sel)
    );

    // =========================================================================
    // 3. The MMCM Core (MMCME2_ADV)
    // =========================================================================
    logic clkfb_out, clkfb_buf;
    logic dsp_clk_unbuf;
    logic lvds_clk_unbuf;

    MMCME2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .CLKOUT4_CASCADE      ("FALSE"),
        .COMPENSATION         ("ZHOLD"),
        .STARTUP_WAIT         ("FALSE"),
        .DIVCLK_DIVIDE        (1),
        
        // Multiply by 16 to put the VCO inside the 600-1200 MHz safe zone
        .CLKFBOUT_MULT_F      (16.000), 
        .CLKFBOUT_PHASE       (0.000),
        
        // Output 0: LVDS Bit Clock (VCO / 2 = 8x Base Rate)
        .CLKOUT0_DIVIDE_F     (16.000), 
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        
        // Output 1: DSP Clock (VCO / 8 = 2x Base Rate)
        .CLKOUT1_DIVIDE       (8),     
        .CLKOUT1_PHASE        (0.000),
        .CLKOUT1_DUTY_CYCLE   (0.500)
    ) u_mmcm_adv (
        // --- PHYSICAL CLOCKS & RESETS ---
        .CLKIN1               (clk_in_buffered),
        .CLKIN2               (1'b0),
        .CLKINSEL             (1'b1),
        .RST                  (~rst_n),
        .PWRDWN               (1'b0),
        
        // --- OUTPUT CLOCKS ---
        .CLKFBOUT             (clkfb_out),
        .CLKFBOUTB            (),
        .CLKOUT0              (lvds_clk_unbuf),
        .CLKOUT0B             (),
        .CLKOUT1              (dsp_clk_unbuf),
        .CLKOUT1B             (),
        .CLKOUT2              (),
        .CLKOUT2B             (),
        .CLKOUT3              (),
        .CLKOUT3B             (),
        .CLKOUT4              (),
        .CLKOUT5              (),
        .CLKOUT6              (),
        
        // --- FEEDBACK ---
        .CLKFBIN              (clkfb_buf),
        
        // --- STATUS ---
        .LOCKED               (locked),
        
        .CLKFBSTOPPED         (),
        .CLKINSTOPPED         (),
        
        // --- FIXED: DRP PORTS MOVED OUT OF PARAMETERS AND TIED TO GROUND ---
        .DADDR                (7'h0),
        .DCLK                 (1'b0),
        .DEN                  (1'b0),
        .DI                   (16'h0),
        .DWE                  (1'b0),
        .DRDY                 (),
        .DO                   (),
        
        // --- DYNAMIC PHASE SHIFT PORTS (UNUSED) ---
        .PSCLK                (1'b0),
        .PSEN                 (1'b0),
        .PSINCDEC             (1'b0),
        .PSDONE               ()
    );

    // =========================================================================
    // 4. Output Global Buffers (BUFG)
    // =========================================================================
    BUFG u_bufg_fb (
        .I (clkfb_out),
        .O (clkfb_buf)
    );

    BUFG u_bufg_dsp (
        .I (dsp_clk_unbuf),
        .O (dsp_clk)
    );

    BUFG u_bufg_lvds (
        .I (lvds_clk_unbuf),
        .O (lvds_bit_clk)
    );

endmodule