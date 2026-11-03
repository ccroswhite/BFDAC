`timescale 1ns / 1ps

// =============================================================================
//  FIR_POLYPHASE_STEREO — Milestone 2 (Half-Curve Fold) & Milestone 3 (Quad-MAC URAM)
//
//  Stereo wrapper around two fir_polyphase_interpolator instances (L and R).
//
//  Milestone 3 Quad-MAC URAM288 Packing (QUAD_URAM_EN = 1):
//    Packs 4 MACs (4 x 18-bit = 72-bit) per URAM288 using PARITY_INTERLEAVED
//    byte+parity lanes (k = coef_wmac[1:0] = 0..3):
//      Lane k=0 (MAC 4u+0): BWE=8'h03 -> {uram_dout[65:64], uram_dout[15: 0]}
//      Lane k=1 (MAC 4u+1): BWE=8'h0C -> {uram_dout[67:66], uram_dout[31:16]}
//      Lane k=2 (MAC 4u+2): BWE=8'h30 -> {uram_dout[69:68], uram_dout[47:32]}
//      Lane k=3 (MAC 4u+3): BWE=8'hC0 -> {uram_dout[71:70], uram_dout[63:48]}
//    Cuts URAM288 count by 50% (e.g. 1280 MACs = 320 URAMs instead of 640).
//
//  Milestone 2 Bit-Exact Half-Curve Fold (SYM_FOLD_EN = 1):
//    Passed down to u_l_fir and u_r_fir, doubling effective filter taps
//    (2 * 16 * NUM_MACS * TAPS_PER_PHASE) from the shared half-curve URAMs.
// =============================================================================
module fir_polyphase_stereo #(
    parameter int NUM_MACS       = 1024,  // Any multiple of 64 at production scale
    parameter int TAPS_PER_PHASE = 64,    // 16 phases x 64 = 1024 coefs/MAC
    parameter int DATA_WIDTH     = 24,
    parameter int COEF_WIDTH     = 18,
    parameter int ACC_WIDTH      = 48,
    parameter bit SYM_FOLD_EN    = 1'b1,  // 1: Milestone 2 Option B 2x half-curve fold
    parameter bit QUAD_URAM_EN   = 1'b1   // 1: Milestone 3 4-MACs-per-URAM288 packing
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  tri0 [1:0]                     rate_shift,
    output logic                          input_overrun,

    // Baseband inputs (one per channel)
    input  logic                          new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_l,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_r,

    // Interpolated outputs
    output logic signed [ACC_WIDTH-1:0]   interpolated_l,
    output logic                          interpolated_l_valid,
    output logic signed [ACC_WIDTH-1:0]   interpolated_r,
    output logic                          interpolated_r_valid,
    output logic                          input_frame_done,

    // Coefficient write bus (from coef_bank_loader, dsp_clk domain)
    input  logic                               coef_we,
    input  logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,
    input  logic signed [COEF_WIDTH-1:0]       coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]        coef_wmac,

    // Dual-bank control (retained for top-level port compatibility; unused when QUAD_URAM_EN=1)
    input  logic                          bank_select,
    input  logic                          bank_load_target
);

    // -------------------------------------------------------------------------
    //  Parameters and local constants
    // -------------------------------------------------------------------------
    localparam int COEF_DEPTH  = 16 * TAPS_PER_PHASE;
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
    //  Read/Write super-group -> group broadcast tree (64 MACs per URAM group:
    //  16 URAMs/group when QUAD_URAM_EN=1, 32 URAMs/group when QUAD_URAM_EN=0)
    // -------------------------------------------------------------------------
    logic [$clog2(COEF_DEPTH)-1:0] coef_addr;

    localparam int TARGET_GRP_U = QUAD_URAM_EN ? 16 : 32;
    localparam int URAM_GRP_SZ  = (NUM_URAMS < TARGET_GRP_U) ? NUM_URAMS : TARGET_GRP_U;
    localparam int NUM_UGROUPS  = NUM_URAMS / URAM_GRP_SZ;
    localparam int NUM_USUPER   = ((NUM_UGROUPS >= 4) && (NUM_UGROUPS % 4 == 0)) ? 4 : 1;
    localparam int UGRP_PER_SUP = NUM_UGROUPS / NUM_USUPER;

    initial begin
        assert (NUM_MACS % MACS_PER_U == 0)
            else $fatal(1, "NUM_MACS (%0d) must be a multiple of %0d", NUM_MACS, MACS_PER_U);
        assert ((NUM_URAMS < TARGET_GRP_U) || (NUM_URAMS % TARGET_GRP_U == 0))
            else $fatal(1, "NUM_MACS (%0d) must be a multiple of 64 at production scale", NUM_MACS);
        assert (COEF_DEPTH <= 4096)
            else $fatal(1, "COEF_DEPTH (%0d) exceeds URAM288 depth 4096", COEF_DEPTH);
    end

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

    logic                                                   bank_select_r1;
    (* dont_touch = "true" *) logic                         bank_select_s2      [0:NUM_USUPER-1];
    (* dont_touch = "true" *) logic                         bank_select_s3      [0:NUM_UGROUPS-1];

    always_ff @(posedge clk) begin
        bank_select_r1 <= bank_select;
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

    // -------------------------------------------------------------------------
    //  Coefficient output to FIR engines (one 18-bit value per MAC per cycle)
    // -------------------------------------------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_out [0:NUM_MACS-1];

    // -------------------------------------------------------------------------
    //  URAM288 coefficient storage
    //  PARITY_INTERLEAVED lane k (0..3):
    //    coef[15:0]  -> DIN[16k +: 16] (bytes 2k, 2k+1)
    //    coef[17:16] -> DIN[64+2k +: 2] (parity bits 64+2k, 64+2k+1)
    //    gated by uram_wen = 8'h03 << (2*k).
    // -------------------------------------------------------------------------
    genvar u;
    generate
        for (u = 0; u < NUM_URAMS; u++) begin : gen_uram_coef
            localparam int UGRP = u / URAM_GRP_SZ;

            wire uram_sel = QUAD_URAM_EN
                            ? ((int'(coef_wmac_s3[UGRP]) >> 2) == u)
                            : ((int'(coef_wmac_s3[UGRP]) >> 1) == u);
            wire uram_we  = coef_we_s3[UGRP] && uram_sel;

            // Lane index k (0..3):
            //   QUAD_URAM_EN = 1: k = coef_wmac[1:0] (4 MACs per URAM)
            //   QUAD_URAM_EN = 0: k = {coef_wmac[0], bank_load_target} (2 MACs x 2 banks)
            wire [1:0] lane_k = QUAD_URAM_EN
                                ? coef_wmac_s3[UGRP][1:0]
                                : {coef_wmac_s3[UGRP][0], bank_load_target_s3[UGRP]};

            wire [7:0] uram_wen = !uram_we ? 8'h00 :
                                  (lane_k == 2'd0) ? 8'h03 :
                                  (lane_k == 2'd1) ? 8'h0C :
                                  (lane_k == 2'd2) ? 8'h30 : 8'hC0;

            wire [URAM_DW-1:0] uram_din;
            assign uram_din = {{4{coef_wdata_s3[UGRP][17:16]}},   // [71:64] parity bits
                               {4{coef_wdata_s3[UGRP][15:0]}}};   // [63: 0] data bytes

            wire [URAM_DW-1:0] uram_dout;

`ifdef SIM
            // Behavioral model for simulation (XSim does not have URAM288 primitive)
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
                assign coef_out[4*u + 0] = signed'({uram_dout[65:64], uram_dout[15: 0]});
                assign coef_out[4*u + 1] = signed'({uram_dout[67:66], uram_dout[31:16]});
                assign coef_out[4*u + 2] = signed'({uram_dout[69:68], uram_dout[47:32]});
                assign coef_out[4*u + 3] = signed'({uram_dout[71:70], uram_dout[63:48]});
            end else begin : gen_dual_dout
                assign coef_out[2*u]   = bank_select_s3[UGRP]
                                         ? signed'({uram_dout[67:66], uram_dout[31:16]})
                                         : signed'({uram_dout[65:64], uram_dout[15: 0]});
                assign coef_out[2*u+1] = bank_select_s3[UGRP]
                                         ? signed'({uram_dout[71:70], uram_dout[63:48]})
                                         : signed'({uram_dout[69:68], uram_dout[47:32]});
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    //  Left channel interpolator
    // -------------------------------------------------------------------------
    logic overrun_l, overrun_r;
    logic frame_done_l, frame_done_r;
    assign input_overrun    = overrun_l || overrun_r;
    assign input_frame_done = frame_done_l;

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .SYM_FOLD_EN    (SYM_FOLD_EN)
    ) u_l_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_l),
        .rate_shift         (rate_shift),
        .input_overrun      (overrun_l),
        .input_frame_done   (frame_done_l),
        .interpolated_out   (interpolated_l),
        .interpolated_valid (interpolated_l_valid),
        .coef_in            (coef_out),
        .coef_addr_out      (coef_addr)
    );

    // -------------------------------------------------------------------------
    //  Right channel interpolator
    // -------------------------------------------------------------------------
    logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_addr_r_unused;

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .SYM_FOLD_EN    (SYM_FOLD_EN)
    ) u_r_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_r),
        .rate_shift         (rate_shift),
        .input_overrun      (overrun_r),
        .input_frame_done   (frame_done_r),
        .interpolated_out   (interpolated_r),
        .interpolated_valid (interpolated_r_valid),
        .coef_in            (coef_out),
        .coef_addr_out      (coef_addr_r_unused)
    );

endmodule
