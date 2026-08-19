`timescale 1ns / 1ps

module sys_clock_gen (
    input  logic mclk,            // Externally-muxed OCXO master clock (45.1584 or 49.152 MHz)
    input  logic rst_n,
    input  logic mmcm_rst,        // Held high across external clock-mux switches (top level)
    output logic dsp_clk,         // 258 MHz (44.1k) / 281 MHz (48k) at DIVIDE_F=3.5; up to ~357 MHz
    output logic cell_clk,        // mclk-rate (45.1584/49.152 MHz), MMCM phase-aligned to mclk;
                                  // launches the cascode IOB registers so the external MC100EP52
                                  // reclock FFs (clocked by the same LMK tree) get a full mclk
                                  // period of setup (Round 29 / todo #13)
    output logic locked
);

    // ==============================================================
    //  XCVU13P Clock Generator - OCXO-Based Audiophile Clocking
    //  Platform: Alinx ACVU13 SOM (on-module DDR4 ref clk — no external DDR4 clk pin)
    //
    //  Clock selection is now EXTERNAL (LMK00304 2:1 mux on the baseboard).
    //  The FPGA receives a single muxed master clock on mclk and selects the
    //  OCXO via the clk_sel output pin (driven from dac_ctrl_plane at top level).
    //  The same LMK00304 output tree also clocks the external reclock FFs, so
    //  FPGA dsp_clk and the FF clock are frequency-locked by construction.
    //
    //  Dual ultra-low jitter OCXO references (upstream of the external mux):
    //    - OCXO #1: 45.1584 MHz = 1024 × 44.1 kHz  (period = 22.151 ns)
    //    - OCXO #2: 49.152  MHz = 1024 × 48  kHz   (period = 20.345 ns)
    //
    //  CLKIN1_PERIOD must be set to the SLOWER (longer-period) input so that
    //  Vivado timing analysis is never presented a clock faster than declared.
    //  Both clocks share CLKFBOUT_MULT_F=20; VCO stays within 800-1600 MHz:
    //    - 44.1k family: VCO = 45.1584 × 20 = 903.168 MHz
    //    - 48k   family: VCO = 49.152  × 20 = 983.04  MHz
    //
    //  DSP clock (CLKOUT0_DIVIDE_F = 3.500):
    //    - 44.1k family: 903.168 / 3.5 = 258.05 MHz
    //    - 48k   family: 983.04  / 3.5 = 280.87 MHz
    //  Both are within the XCVU13P DSP48E2 Fmax (~450 MHz at -2 speed grade).
    //  Increase CLKOUT0_DIVIDE_F to 2.750 for ~328/357 MHz after P&R validation.
    //
    //  Two output clocks:
    //    dsp_clk  — drives the entire DSP design.
    //    cell_clk — CLKOUT1 = VCO/20 = mclk frequency, phase-aligned to mclk
    //               by the MMCM feedback loop. Launches ONLY the 128 cascode
    //               IOB registers, so the launch edge is phase-locked to the
    //               external reclock-FF clock (same LMK00304 tree) and the
    //               data-valid window at the MC100EP52 D inputs is a full
    //               mclk period minus Tco/flight (see XDC §8 + bom.md §1.4).
    //
    //  Required XDC create_clock entry (single port, constrain at the faster
    //  49.152 MHz rate so both OCXO families are covered):
    //    create_clock -name clk_mclk -period 20.345 [get_ports mclk_p]
    //
    //  CRITICAL: The LMK00304 mux is NOT glitch-free. The top level must:
    //    1. mute (automute FSM) and assert mmcm_rst,
    //    2. flip clk_sel,
    //    3. release mmcm_rst after the mux settles,
    //    4. wait for locked (~100 us) before unmuting.
    // ==============================================================

    logic mmcm_fb_out, mmcm_fb_in;
    logic dsp_clk_unbuf;
    logic cell_clk_unbuf;

    // Audio-Locked MMCM
    //    VCO range 800-1600 MHz; 983.04 MHz is optimal for low jitter
    MMCME4_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(20.000),    // VCO: 903.168 MHz (44.1k) / 983.04 MHz (48k)
        .CLKIN1_PERIOD(22.151),      // Worst-case (slower): 45.1584 MHz = 22.151 ns
                                     // XDC create_clock uses the faster 20.345 ns

        // DSP Clock: 258.05 MHz (44.1k) / 280.87 MHz (48k) at DIVIDE_F=3.500
        // Increase CLKOUT0_DIVIDE_F to 2.750 for ~328/357 MHz after P&R validation
        .CLKOUT0_DIVIDE_F(3.500),

        // CLKOUT1 = VCO/20 = mclk frequency (45.1584/49.152 MHz) — cascode IOB
        // launch clock (cell_clk).
        // CLKOUT1_PHASE = 90° (2026-08-14, f9wb route review): with 0° the MMCM
        // feedback alignment puts the IOB launch edge essentially coincident
        // with the mclk pad edge (fast-corner insertion −0.56 ns), so data could
        // reach the external MC100EP52 D pins with near-zero margin against the
        // SAME ff_clk edge — hold failed by −1.74 ns against the budgeted
        // 1.5 ns pad. Launching a quarter period (5.09 ns) after the ff_clk
        // edge gives real margin on BOTH sides: ~3.5 ns hold, ~11 ns setup
        // (capture on the next ff_clk edge, 15.26 ns away). The RTZ pattern is
        // shifted uniformly by 5.09 ns — pulse widths and the 6-of-8 duty are
        // untouched, and the EP52 resampling erases the shift entirely.
        .CLKOUT1_DIVIDE(20),
        .CLKOUT1_PHASE(90.000),

        .DIVCLK_DIVIDE(1)
    ) u_mmcm (
        .CLKIN1    (mclk),
        .CLKFBIN   (mmcm_fb_in),
        .CLKFBOUT  (mmcm_fb_out),
        .CLKFBOUTB (),
        .CLKOUT0   (dsp_clk_unbuf),
        .CLKOUT0B  (),
        .CLKOUT1   (cell_clk_unbuf),
        .CLKOUT1B  (),
        .CLKOUT2   (),
        .CLKOUT2B  (),
        .CLKOUT3   (),
        .CLKOUT3B  (),
        .CLKOUT4   (),
        .CLKOUT5   (),
        .CLKOUT6   (),
        .LOCKED    (locked),
        .RST       (~rst_n | mmcm_rst),
        .PWRDWN    (1'b0)
        // MMCME4_BASE has a single CLKIN1 (no CLKINSEL port - that is
        // MMCME4_ADV); clock selection is external on the LMK00304.
    );

    // Feedback Buffer
    BUFG u_bufg_fb (
        .I (mmcm_fb_out),
        .O (mmcm_fb_in)
    );

    // Output Buffer — single BUFG for dsp_clk
    BUFG u_bufg_dsp (
        .I (dsp_clk_unbuf),
        .O (dsp_clk)
    );

    // Output Buffer — cell_clk (cascode IOB launch, mclk-phase-aligned)
    BUFG u_bufg_cell (
        .I (cell_clk_unbuf),
        .O (cell_clk)
    );

endmodule