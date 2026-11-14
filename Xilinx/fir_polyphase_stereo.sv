`timescale 1ns / 1ps

// =============================================================================
//  FIR_POLYPHASE_STEREO — Milestone 5 Two-Stage (x2 Stage 1A -> x8 Stage 1B)
//
//  Drop-in stereo Stage 1 subsystem for XCVU13P:
//    - Stage 1A (u_l_fir, u_r_fir): NUM_PHASES = 2, S1A_TPP = 8 * TAPS_PER_PHASE
//      (2 phases x 2048 taps/phase = 4096 URAM depth at TAPS_PER_PHASE = 256),
//      Option B 2x symmetric half-curve fold, per-lane SDP BRAM windows (DOB_REG=1).
//    - Stage 1B (u_stage1b): 48-bit stereo rate-selectable Kaiser-Bessel half-band
//      cascade (63t -> 63t -> 31t; rate_shift = 0..3 -> x8 / x4 / x2 / x1 DXD bypass)
//      paced at 16 dsp_clk cycles for downstream halfband_x2.
//
//  Resource footprint at 8.39M effective taps (NUM_MACS = 128, TAPS_PER_PHASE = 256):
//    - DSP48E2: ~540 total stereo (~4.4% of XCVU13P)
//    - URAM288: 64 dual-bank (5.0%) with QUAD_URAM_EN=0, or 32 (2.5%) with QUAD_URAM_EN=1
//    - RAMB36 : 768 SDP window BRAMs (28.6%), 0 LUTRAM
// =============================================================================
module fir_polyphase_stereo #(
    parameter int NUM_MACS       = 128,   // multiple of MACS_PER_U; 80 -> 5.24M, 128 -> 8.39M, 256 -> 16.78M effective taps
    parameter int TAPS_PER_PHASE = 256,   // 16x-normalized TPP: COEF_DEPTH = 16 * TAPS_PER_PHASE
    parameter int DATA_WIDTH     = 24,
    parameter int COEF_WIDTH     = 18,
    parameter int ACC_WIDTH      = 48,
    parameter bit SYM_FOLD_EN    = 1'b1,  // 1: Option B 2x symmetric half-curve fold
    parameter bit QUAD_URAM_EN   = 1'b0,  // 0: Dual-bank live swap (64 URAMs @ 128 MACs); 1: 4 MACs/URAM (32 URAMs)
    parameter bit TWO_STAGE_EN   = 1'b1,  // 1: Milestone 5 x2->x8 cascade; 0: Legacy single-stage x16
    parameter bit WIN_BRAM_EN    = 1'b1   // 1: Per-lane SDP Block RAM (DOB_REG=1) in Stage 1A
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  tri0 [1:0]                     rate_shift,
    output logic                          input_overrun,

    // Baseband inputs (one per channel)
    input  logic                          new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_l,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_r,

    // Interpolated outputs (705.6 / 768 kHz)
    output logic signed [ACC_WIDTH-1:0]   interpolated_l,
    output logic                          interpolated_l_valid,
    output logic signed [ACC_WIDTH-1:0]   interpolated_r,
    output logic                          interpolated_r_valid,
    output logic                          input_frame_done,

    // Coefficient write bus (from coef_bank_loader, dsp_clk domain)
    input  logic                                 coef_we,
    input  logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,
    input  logic signed [COEF_WIDTH-1:0]         coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]          coef_wmac,

    // Dual-bank gapless switching control
    input  logic                          bank_select,
    input  logic                          bank_load_target
);

    // -------------------------------------------------------------------------
    //  Parameters and local constants
    // -------------------------------------------------------------------------
    localparam int COEF_DEPTH  = 16 * TAPS_PER_PHASE;
    localparam int S1A_PHASES  = TWO_STAGE_EN ? 2 : 16;
    localparam int S1A_TPP     = TWO_STAGE_EN ? (8 * TAPS_PER_PHASE) : TAPS_PER_PHASE;

    localparam int MACS_PER_U  = QUAD_URAM_EN ? 4 : 2;
    localparam int NUM_URAMS   = NUM_MACS / MACS_PER_U;
    localparam int URAM_AW     = 12;   // URAM288 address is always 12-bit (4096 deep)
    localparam int URAM_DW     = 72;   // URAM288 data width in SDP mode

    // -------------------------------------------------------------------------
    //  Write-bus broadcast tree
    // -------------------------------------------------------------------------
    logic [URAM_AW-1:0]              coef_waddr_r;
    logic signed [COEF_WIDTH-1:0]    coef_wdata_r;
    logic                            bank_load_target_r;
    logic [$clog2(NUM_MACS)-1:0]     coef_wmac_r;
    logic                            coef_we_r;

    always_ff @(posedge clk) begin
        coef_waddr_r       <= URAM_AW'(coef_waddr);
        coef_wdata_r       <= coef_wdata;
        bank_load_target_r <= bank_load_target;
        coef_wmac_r        <= coef_wmac;
        coef_we_r          <= coef_we;
    end

    // -------------------------------------------------------------------------
    //  Read/Write super-group -> group broadcast tree (64 MACs per URAM group)
    // -------------------------------------------------------------------------
    // Per-channel read-address roots: each FIR drives its own URAM bank so the
    // 2,304-wire coef_out bus never leaves its channel's SLR.  Only the small
    // registered write bus crosses the SLR boundary.
    logic [$clog2(COEF_DEPTH)-1:0] coef_addr_l;
    logic [$clog2(COEF_DEPTH)-1:0] coef_addr_r;

    localparam int TARGET_GRP_U = QUAD_URAM_EN ? 16 : 32;

    // Largest divisor of NUM_URAMS no larger than TARGET_GRP_U — keeps the
    // broadcast tree legal for any NUM_URAMS (e.g. 20 -> 2 groups of 10).
    function automatic int pick_grp_sz(input int n, input int tgt);
        pick_grp_sz = 1;
        for (int s = 2; s <= tgt; s++)
            if (n % s == 0) pick_grp_sz = s;
    endfunction

    localparam int URAM_GRP_SZ  = pick_grp_sz(NUM_URAMS, TARGET_GRP_U);
    localparam int NUM_UGROUPS  = NUM_URAMS / URAM_GRP_SZ;
    localparam int NUM_USUPER   = ((NUM_UGROUPS >= 4) && (NUM_UGROUPS % 4 == 0)) ? 4 : 1;
    localparam int UGRP_PER_SUP = NUM_UGROUPS / NUM_USUPER;

    initial begin
        assert (NUM_MACS % MACS_PER_U == 0)
            else $fatal(1, "NUM_MACS (%0d) must be a multiple of %0d", NUM_MACS, MACS_PER_U);
        assert (NUM_URAMS % URAM_GRP_SZ == 0)
            else $fatal(1, "NUM_URAMS (%0d) not divisible by URAM_GRP_SZ (%0d)", NUM_URAMS, URAM_GRP_SZ);
        assert (COEF_DEPTH <= 4096)
            else $fatal(1, "COEF_DEPTH (%0d) exceeds URAM288 depth 4096", COEF_DEPTH);
    end

    // -------------------------------------------------------------------------
    //  Coefficient output to Stage 1A FIR engines: [channel][MAC]
    // -------------------------------------------------------------------------
    logic                            bank_select_r1;
    logic signed [COEF_WIDTH-1:0]    coef_out [0:1][0:NUM_MACS-1];

    always_ff @(posedge clk)
        bank_select_r1 <= bank_select;

    // -------------------------------------------------------------------------
    //  Per-channel broadcast trees + URAM288 coefficient storage.
    //  gen_ch[0] serves u_l_fir, gen_ch[1] serves u_r_fir; each bank is placed
    //  inside its channel's pblock SLR so all URAM -> DSP_B routes stay local.
    //  Latency is identical to the old shared bank (s2 -> s3 -> OREG_B).
    // -------------------------------------------------------------------------
    genvar ch;
    generate
    for (ch = 0; ch < 2; ch++) begin : gen_ch
        wire [$clog2(COEF_DEPTH)-1:0] coef_addr =
                                       (ch == 0) ? coef_addr_l : coef_addr_r;

        (* dont_touch = "true" *) logic [$clog2(COEF_DEPTH)-1:0] coef_addr_s2 [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic [$clog2(COEF_DEPTH)-1:0] coef_addr_s3 [0:NUM_UGROUPS-1];

        always_ff @(posedge clk) begin
            for (int s = 0; s < NUM_USUPER; s++)
                coef_addr_s2[s] <= coef_addr;
            for (int g = 0; g < NUM_UGROUPS; g++)
                coef_addr_s3[g] <= coef_addr_s2[g / UGRP_PER_SUP];
        end

        (* dont_touch = "true" *) logic [URAM_AW-1:0]           coef_waddr_s2       [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic [URAM_AW-1:0]           coef_waddr_s3       [0:NUM_UGROUPS-1];
        (* dont_touch = "true" *) logic signed [COEF_WIDTH-1:0] coef_wdata_s2       [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic signed [COEF_WIDTH-1:0] coef_wdata_s3       [0:NUM_UGROUPS-1];
        (* dont_touch = "true" *) logic                         bank_load_target_s2 [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic                         bank_load_target_s3 [0:NUM_UGROUPS-1];
        (* dont_touch = "true" *) logic [$clog2(NUM_MACS)-1:0]  coef_wmac_s2        [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic [$clog2(NUM_MACS)-1:0]  coef_wmac_s3        [0:NUM_UGROUPS-1];
        (* dont_touch = "true" *) logic                         coef_we_s2          [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic                         coef_we_s3          [0:NUM_UGROUPS-1];
        (* dont_touch = "true" *) logic                         bank_select_s2      [0:NUM_USUPER-1];
        (* dont_touch = "true" *) logic                         bank_select_s3      [0:NUM_UGROUPS-1];

        always_ff @(posedge clk) begin
            for (int s = 0; s < NUM_USUPER; s++) begin
                coef_waddr_s2[s]       <= coef_waddr_r;
                coef_wdata_s2[s]       <= coef_wdata_r;
                bank_load_target_s2[s] <= bank_load_target_r;
                coef_wmac_s2[s]        <= coef_wmac_r;
                coef_we_s2[s]          <= coef_we_r;
                bank_select_s2[s]      <= bank_select_r1;
            end
            for (int g = 0; g < NUM_UGROUPS; g++) begin
                coef_waddr_s3[g]       <= coef_waddr_s2[g / UGRP_PER_SUP];
                coef_wdata_s3[g]       <= coef_wdata_s2[g / UGRP_PER_SUP];
                bank_load_target_s3[g] <= bank_load_target_s2[g / UGRP_PER_SUP];
                coef_wmac_s3[g]        <= coef_wmac_s2[g / UGRP_PER_SUP];
                coef_we_s3[g]          <= coef_we_s2[g / UGRP_PER_SUP];
                bank_select_s3[g]      <= bank_select_s2[g / UGRP_PER_SUP];
            end
        end

        // URAM288 coefficient storage (PARITY_INTERLEAVED byte+parity mapping)
        for (genvar u = 0; u < NUM_URAMS; u++) begin : gen_uram_coef
            localparam int UGRP = u / URAM_GRP_SZ;

            wire uram_sel = QUAD_URAM_EN
                            ? ((int'(coef_wmac_s3[UGRP]) >> 2) == u)
                            : ((int'(coef_wmac_s3[UGRP]) >> 1) == u);
            wire uram_we  = coef_we_s3[UGRP] && uram_sel;

            wire [1:0] lane_k = QUAD_URAM_EN
                                ? coef_wmac_s3[UGRP][1:0]
                                : {coef_wmac_s3[UGRP][0], bank_load_target_s3[UGRP]};

            wire [7:0] uram_wen = !uram_we ? 8'h00 :
                                  (lane_k == 2'd0) ? 8'h03 :
                                  (lane_k == 2'd1) ? 8'h0C :
                                  (lane_k == 2'd2) ? 8'h30 : 8'hC0;

            wire [URAM_DW-1:0] uram_din;
            assign uram_din = {{4{coef_wdata_s3[UGRP][17:16]}},
                               {4{coef_wdata_s3[UGRP][15:0]}}};

            wire [URAM_DW-1:0] uram_dout;

`ifdef SIM
            (* ram_style = "ultra" *) logic [URAM_DW-1:0] uram_mem [0:4095];
            logic [URAM_DW-1:0] uram_rd_s1, uram_rd_s2;

            initial begin
                for (int i = 0; i < 4096; i++) uram_mem[i] = '0;
            end

            always_ff @(posedge clk) begin
                if (uram_we) begin
                    for (int b = 0; b < 8; b++) begin
                        if (uram_wen[b]) begin
                            uram_mem[coef_waddr_s3[UGRP]][b*8 +: 8] <= uram_din[b*8 +: 8];
                            uram_mem[coef_waddr_s3[UGRP]][64 + b]   <= uram_din[64 + b];
                        end
                    end
                end
                uram_rd_s1 <= uram_mem[URAM_AW'(coef_addr_s3[UGRP])];
                uram_rd_s2 <= uram_rd_s1;
            end

            assign uram_dout = uram_rd_s2;
`else
            URAM288 #(
                .OREG_A                  ("FALSE"),
                .OREG_B                  ("TRUE"),
                .IREG_PRE_A              ("FALSE"),
                .IREG_PRE_B              ("TRUE"),
                .AUTO_SLEEP_LATENCY      (8),
                .AVG_CONS_INACTIVE_CYCLES(10),
                .BWE_MODE_A              ("PARITY_INTERLEAVED"),
                .BWE_MODE_B              ("PARITY_INTERLEAVED"),
                .EN_AUTO_SLEEP_MODE      ("FALSE"),
                .EN_ECC_RD_A             ("FALSE"),
                .EN_ECC_RD_B             ("FALSE"),
                .EN_ECC_WR_A             ("FALSE"),
                .EN_ECC_WR_B             ("FALSE")
            ) u_uram (
                .ADDR_A     (23'(coef_waddr_s3[UGRP])),
                .DIN_A      (uram_din),
                .BWE_A      ({1'b0, uram_wen}),
                .EN_A       (uram_we),
                .RDB_WR_A   (1'b1),
                .DOUT_A     (),
                .RST_A      (1'b0),

                .ADDR_B     (23'(coef_addr_s3[UGRP])),
                .DIN_B      ('0),
                .BWE_B      (9'h1FF),
                .EN_B       (1'b1),
                .RDB_WR_B   (1'b0),
                .DOUT_B     (uram_dout),
                .RST_B      (!rst_n),

                .CAS_IN_ADDR_A    (23'h0),
                .CAS_IN_ADDR_B    (23'h0),
                .CAS_IN_BWE_A     (9'h0),
                .CAS_IN_BWE_B     (9'h0),
                .CAS_IN_DBITERR_A (1'b0),
                .CAS_IN_DBITERR_B (1'b0),
                .CAS_IN_DIN_A     (72'h0),
                .CAS_IN_DIN_B     (72'h0),
                .CAS_IN_DOUT_A    (72'h0),
                .CAS_IN_DOUT_B    (72'h0),
                .CAS_IN_EN_A      (1'b0),
                .CAS_IN_EN_B      (1'b0),
                .CAS_IN_RDACCESS_A(1'b0),
                .CAS_IN_RDACCESS_B(1'b0),
                .CAS_IN_RDB_WR_A  (1'b0),
                .CAS_IN_RDB_WR_B  (1'b0),
                .CAS_IN_SBITERR_A (1'b0),
                .CAS_IN_SBITERR_B (1'b0),

                .OREG_CE_A        (1'b1),
                .OREG_CE_B        (1'b1),
                .OREG_ECC_CE_A    (1'b0),
                .OREG_ECC_CE_B    (1'b0),
                .INJECT_DBITERR_A (1'b0),
                .INJECT_DBITERR_B (1'b0),
                .INJECT_SBITERR_A (1'b0),
                .INJECT_SBITERR_B (1'b0),
                .SLEEP            (1'b0),
                .CLK              (clk)
            );
`endif

            if (QUAD_URAM_EN) begin : gen_quad_dout
                assign coef_out[ch][4*u + 0] = signed'({uram_dout[65:64], uram_dout[15: 0]});
                assign coef_out[ch][4*u + 1] = signed'({uram_dout[67:66], uram_dout[31:16]});
                assign coef_out[ch][4*u + 2] = signed'({uram_dout[69:68], uram_dout[47:32]});
                assign coef_out[ch][4*u + 3] = signed'({uram_dout[71:70], uram_dout[63:48]});
            end else begin : gen_dual_dout
                assign coef_out[ch][2*u]   = bank_select_s3[UGRP]
                                         ? signed'({uram_dout[67:66], uram_dout[31:16]})
                                         : signed'({uram_dout[65:64], uram_dout[15: 0]});
                assign coef_out[ch][2*u+1] = bank_select_s3[UGRP]
                                         ? signed'({uram_dout[71:70], uram_dout[63:48]})
                                         : signed'({uram_dout[69:68], uram_dout[47:32]});
            end
        end
    end
    endgenerate

    // -------------------------------------------------------------------------
    //  Stage 1A: Left & Right Brickwall Polyphase FIR Engines
    // -------------------------------------------------------------------------
    logic                        overrun_l, overrun_r;
    logic                        s1a_frame_done_l, s1a_frame_done_r;
    logic signed [ACC_WIDTH-1:0] s1a_out_l, s1a_out_r;
    logic                        s1a_valid_l, s1a_valid_r;

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .NUM_PHASES     (S1A_PHASES),
        .TAPS_PER_PHASE (S1A_TPP),
        .SYM_FOLD_EN    (SYM_FOLD_EN),
        .WIN_BRAM_EN    (WIN_BRAM_EN),
        .RATE_SCALE_TPP (TWO_STAGE_EN),
        .EMIT_SPACING   (TWO_STAGE_EN ? 4 : 16)
    ) u_l_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .rate_shift         (rate_shift),
        .input_overrun      (overrun_l),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_l),
        .interpolated_out   (s1a_out_l),
        .interpolated_valid (s1a_valid_l),
        .input_frame_done   (s1a_frame_done_l),
        .coef_in            (coef_out[0]),
        .coef_addr_out      (coef_addr_l)
    );

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .NUM_PHASES     (S1A_PHASES),
        .TAPS_PER_PHASE (S1A_TPP),
        .SYM_FOLD_EN    (SYM_FOLD_EN),
        .WIN_BRAM_EN    (WIN_BRAM_EN),
        .RATE_SCALE_TPP (TWO_STAGE_EN),
        .EMIT_SPACING   (TWO_STAGE_EN ? 4 : 16)
    ) u_r_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .rate_shift         (rate_shift),
        .input_overrun      (overrun_r),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_r),
        .interpolated_out   (s1a_out_r),
        .interpolated_valid (s1a_valid_r),
        .input_frame_done   (s1a_frame_done_r),
        .coef_in            (coef_out[1]),
        .coef_addr_out      (coef_addr_r)
    );

    // -------------------------------------------------------------------------
    //  Stage 1B: Stereo 48-Bit x8/x4/x2/x1 Kaiser Half-Band Cascade
    // -------------------------------------------------------------------------
    generate
        if (TWO_STAGE_EN) begin : gen_stage1b
            logic s1b_in_ready;
            logic overrun_s1b;
            logic s1b_out_valid;

            // synthesis translate_off
            always_ff @(posedge clk) begin
                if (rst_n && (s1a_valid_l != s1a_valid_r))
                    $error("fir_polyphase_stereo: Stage 1A L/R valid skew detected");
            end
            // synthesis translate_on

            fir_stage1b_interp8 #(
                .DATA_WIDTH    (ACC_WIDTH),
                .OUT_SPACING   (16),
                .IN_FIFO_DEPTH (16),
                .OUT_FIFO_DEPTH(32)
            ) u_stage1b (
                .clk           (clk),
                .rst_n         (rst_n),
                .rate_shift    (rate_shift),
                .in_valid      (s1a_valid_l),
                .in_ready      (s1b_in_ready),
                .in_l          (s1a_out_l),
                .in_r          (s1a_out_r),
                .input_overrun (overrun_s1b),
                .out_valid     (s1b_out_valid),
                .out_l         (interpolated_l),
                .out_r         (interpolated_r),
                .out_frame_done(input_frame_done)
            );

            assign interpolated_l_valid = s1b_out_valid;
            assign interpolated_r_valid = s1b_out_valid;
            assign input_overrun        = overrun_l || overrun_r || overrun_s1b;
        end else begin : gen_single_stage
            assign interpolated_l       = s1a_out_l;
            assign interpolated_l_valid = s1a_valid_l;
            assign interpolated_r       = s1a_out_r;
            assign interpolated_r_valid = s1a_valid_r;
            assign input_frame_done     = s1a_frame_done_l;
            assign input_overrun        = overrun_l || overrun_r;
        end
    endgenerate

endmodule
