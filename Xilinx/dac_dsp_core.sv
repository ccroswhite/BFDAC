`timescale 1ns / 1ps

// =============================================================================
// DAC DSP Core — XCVU13P single-FPGA stereo design (Milestones 1–3 Integrated)
//
// Signal chain (stereo throughout):
//   1.  fir_polyphase_stereo : x16 polyphase FIR (Option B 2x Half-Curve Fold +
//                              Quad-MAC URAM288 packing + Time-Muxed Adder Tree)
//   2.  halfband_x2 HB1      : x2 interpolation, 768k  -> 1.536 MHz, 63 taps
//   3.  halfband_x2 HB2      : x2 interpolation, 1.536 -> 3.072 MHz, 31 taps
//   4.  halfband_x2 HB3      : x2 interpolation, 3.072 -> 6.144 MHz, 15 taps
//   5.  Volume multiplier    : DSP48, 4-stage pipeline, shared combined_volume
//   6.  Sample pacer         : elastic FIFO, one paced sample per 6.144 MHz tick
//   7.  TPDF dither          : 42-bit, independent L+R
//   8.  noise_shaper_ef3     : 3rd-order EF, IIR NTF (1-z)^3/(1-z/2)^3, + DPD
//   9.  dem_sort             : 64-element sort-based 2nd-order vector shaper
//  10.  IOB output registers : staging (dsp_clk) -> CDC -> RTZ pattern gen + IOB
// =============================================================================
module dac_dsp_core #(
    parameter int NUM_MACS = 80,  // production geometry (5x16=80 DQ)
    parameter int TAPS_PER_PHASE = 256,  // production
    parameter int CELL_TEST_MUTE_CYCLES = 4000000,
    parameter bit SYM_FOLD_EN  = 1'b1,
    parameter bit QUAD_URAM_EN = 1'b0
)(
    // Single clock domain — all logic runs on the 278/302 MHz audio-family dsp_clk
    input  logic        dsp_clk,
    input  logic        sys_rst_n,
    input  logic        fir_rst_n,   // dedicated FIR tree (relaxed release; sinks are skew-tolerant)

    // Audio input (from dac_i2s_ingress, dsp_clk domain)
    input  logic [23:0] audio_l,
    input  logic [23:0] audio_r,
    input  logic        new_sample,
    input  logic        force_zero,    // 1: clamp FIR input to 0 (mute / relay sequencing)
    input  tri0 [1:0]   rate_shift,
    output logic        stream_fault,

    // Coefficient write bus (from dac_coef_subsys, dsp_clk domain)
    input  logic                               coef_we,
    input  logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,
    input  logic signed [17:0]                 coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]        coef_wmac,

    // Bank switching (from dac_coef_subsys, dsp_clk domain)
    input  logic        bank_select,
    input  logic        bank_load_target,

    // Layer-2 voicing shaper (dsp_clk domain, frame-synced upstream)
    input  logic              voicing_en,
    input  logic signed [26:0] voicing_k2,   // Q2.25
    input  logic signed [26:0] voicing_k3,   // Q2.25

    // Volume gain in Q16.16 NS code units (from dac_ctrl_plane)
    input  logic [31:0] sys_volume,

    // Boot envelope gain (from dac_coef_subsys, dsp_clk domain)
    input  logic [15:0] boot_envelope_gain,

    // DPD (Step 4D.1): enable level + cal_coef_store active-bank read ports
    input  logic              dpd_enable,
    output logic [3:0][8:0]   dpd_cal_addr,
    input  logic [3:0][23:0]  dpd_cal_data,

    // Sample tick output (768 kHz post-FIR, to dac_coef_subsys)
    output logic        sample_768k_tick,
    output logic        fir_frame_done,
    output logic        dpd_busy,
    output logic        dpd_deadline_miss,

    // Cascode IOB launch clock
    input  logic            cell_clk,
    input  logic [1:0][7:0] cell_test_cfg,
    input  logic [1:0]      cell_test_req,
    output logic [1:0]      cell_test_ack,
    input  logic            cell_test_safe,
    input  tri0             bench_req,
    input  logic [10:0]     bench_cmd,
    output logic            bench_ack,
    output logic            bench_ready,

    // Direct cascode cell outputs — IOB-registered on cell_clk, RTZ-encoded
    output logic [63:0] cascode_l,
    output logic [63:0] cascode_r
);

    // =========================================================================
    // Mute input gating
    // =========================================================================
    logic [23:0] gated_audio_l, gated_audio_r;
    assign gated_audio_l = force_zero ? 24'd0 : audio_l;
    assign gated_audio_r = force_zero ? 24'd0 : audio_r;

    // =========================================================================
    // 1. Polyphase FIR x16 — stereo, URAM288 coefficient storage
    //    Output rate: 768 kHz (48k) / 705.6 kHz (44.1k)
    // =========================================================================
    logic signed [47:0] interp_l,       interp_r;
    logic               interp_l_valid, interp_r_valid;
    logic fir_overrun, pace_fault;
    assign stream_fault = fir_overrun || pace_fault || dpd_deadline_miss;

    assign sample_768k_tick = interp_l_valid;

    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (24),
        .COEF_WIDTH     (18),
        .ACC_WIDTH      (48),
        .SYM_FOLD_EN    (SYM_FOLD_EN),
        .QUAD_URAM_EN   (QUAD_URAM_EN)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (fir_rst_n),
        .rate_shift           (rate_shift),
        .input_overrun        (fir_overrun),
        .new_sample_valid     (new_sample),
        .new_sample_l         (gated_audio_l),
        .new_sample_r         (gated_audio_r),
        .interpolated_l       (interp_l),
        .interpolated_l_valid (interp_l_valid),
        .interpolated_r       (interp_r),
        .interpolated_r_valid (interp_r_valid),
        .input_frame_done     (fir_frame_done),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (bank_select),
        .bank_load_target     (bank_load_target)
    );

    // =========================================================================
    // 1b. Layer-2 voicing shaper — stereo, bypassable k2/k3 polynomial
    //     at the 768/705.6 kHz node.  0-LSB pass-through when !voicing_en.
    // =========================================================================
    logic signed [47:0] vox_l,       vox_r;
    logic               vox_l_valid, vox_r_valid;

    dac_voicing_shaper u_voicing_l (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .in_valid   (interp_l_valid),
        .data_in    (interp_l),
        .voicing_en (voicing_en),
        .k2         (voicing_k2),
        .k3         (voicing_k3),
        .out_valid  (vox_l_valid),
        .data_out   (vox_l)
    );

    dac_voicing_shaper u_voicing_r (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .in_valid   (interp_r_valid),
        .data_in    (interp_r),
        .voicing_en (voicing_en),
        .k2         (voicing_k2),
        .k3         (voicing_k3),
        .out_valid  (vox_r_valid),
        .data_out   (vox_r)
    );

    // =========================================================================
    // 2. Half-band x2 stage HB1 — stereo
    //    63 taps, 768k -> 1.536 MHz
    // =========================================================================
    logic signed [47:0] hb1_l,       hb1_r;
    logic               hb1_l_valid, hb1_r_valid;

    halfband_x2 #(.NUM_TAPS(63), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(4))
    u_hb1_l (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (vox_l_valid),
        .data_in  (vox_l),
        .out_valid(hb1_l_valid),
        .data_out (hb1_l)
    );

    halfband_x2 #(.NUM_TAPS(63), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(4))
    u_hb1_r (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (vox_r_valid),
        .data_in  (vox_r),
        .out_valid(hb1_r_valid),
        .data_out (hb1_r)
    );

    // =========================================================================
    // 3. Half-band x2 stage HB2 — stereo
    //    31 taps, 1.536 -> 3.072 MHz
    // =========================================================================
    logic signed [47:0] hb2_l,       hb2_r;
    logic               hb2_l_valid, hb2_r_valid;

    halfband_x2 #(.NUM_TAPS(31), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(2))
    u_hb2_l (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (hb1_l_valid),
        .data_in  (hb1_l),
        .out_valid(hb2_l_valid),
        .data_out (hb2_l)
    );

    halfband_x2 #(.NUM_TAPS(31), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(2))
    u_hb2_r (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (hb1_r_valid),
        .data_in  (hb1_r),
        .out_valid(hb2_r_valid),
        .data_out (hb2_r)
    );

    // =========================================================================
    // 4. Half-band x2 stage HB3 — stereo
    //    15 taps, 3.072 -> 6.144 MHz
    // =========================================================================
    logic signed [47:0] hb3_l,       hb3_r;
    logic               hb3_l_valid, hb3_r_valid;

    halfband_x2 #(.NUM_TAPS(15), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(1))
    u_hb3_l (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (hb2_l_valid),
        .data_in  (hb2_l),
        .out_valid(hb3_l_valid),
        .data_out (hb3_l)
    );

    halfband_x2 #(.NUM_TAPS(15), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(1))
    u_hb3_r (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (hb2_r_valid),
        .data_in  (hb2_r),
        .out_valid(hb3_r_valid),
        .data_out (hb3_r)
    );

    // =========================================================================
    // 5. Volume multiplier - shared combined_volume, stereo paths
    // =========================================================================
    // sys_volume is Q16.16 with max 28.0 (32'h001C_0000, volume_q24_to_gain_q16)
    // -> 22 active bits. Single 26x17 DSP48E2 with full AREG/BREG/MREG/PREG
    // pipelining + round-to-nearest so 0xFFFF envelope = exact unity gain.
    (* use_dsp = "yes" *) logic [31:0] combined_volume;
    logic [21:0] cvol_a_r;                       // AREG
    logic [16:0] cvol_b_r;                       // BREG (unsigned envelope)
    (* use_dsp = "yes" *) logic [38:0] cvol_m;   // MREG: 22x17 product
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            cvol_a_r         <= '0;
            cvol_b_r         <= '0;
            cvol_m           <= '0;
            combined_volume  <= '0;
        end else begin
            cvol_a_r        <= sys_volume[21:0];
            cvol_b_r        <= {1'b0, boot_envelope_gain};
            cvol_m          <= cvol_a_r * cvol_b_r;
            combined_volume <= 32'((cvol_m + 39'h8000) >> 16);
        end
    end

    logic signed [47:0] vol_a_l_r1;
    logic        [31:0] vol_b_r1;
    (* use_dsp = "yes" *) logic signed [79:0] vol_mlo_l_r2, vol_mhi_l_r2;
    (* use_dsp = "yes" *) logic signed [79:0] vol_mlo_r_r2, vol_mhi_r_r2;
    (* use_dsp = "yes" *) logic signed [79:0] vol_p_l_r3, vol_p_r_r3;
    logic signed [47:0] vol_a_r_r1;
    logic signed [63:0] volumed_l, volumed_r;
    logic        [3:0]  vol_valid_pipe;   // 4-stage data pipe -> 4-deep valid
    logic               volumed_valid;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_a_l_r1     <= '0;  vol_a_r_r1  <= '0;
            vol_b_r1       <= '0;
            vol_mlo_l_r2   <= '0;  vol_mhi_l_r2 <= '0;
            vol_mlo_r_r2   <= '0;  vol_mhi_r_r2 <= '0;
            vol_p_l_r3     <= '0;  vol_p_r_r3  <= '0;
            volumed_l      <= '0;  volumed_r   <= '0;
            vol_valid_pipe <= '0;
        end else begin
            vol_a_l_r1 <= hb3_l;
            vol_a_r_r1 <= hb3_r;
            vol_b_r1   <= combined_volume;
            // 48x32 split into two registered 48x16 partial products — each fits
            // a shallow DSP cascade (~7 levels) instead of one 14-level cone.
            vol_mlo_l_r2 <= vol_a_l_r1 * $signed({1'b0, vol_b_r1[15:0]});
            vol_mhi_l_r2 <= vol_a_l_r1 * $signed({1'b0, vol_b_r1[31:16]});
            vol_mlo_r_r2 <= vol_a_r_r1 * $signed({1'b0, vol_b_r1[15:0]});
            vol_mhi_r_r2 <= vol_a_r_r1 * $signed({1'b0, vol_b_r1[31:16]});
            vol_p_l_r3 <= vol_mlo_l_r2 + (vol_mhi_l_r2 <<< 16);
            vol_p_r_r3 <= vol_mlo_r_r2 + (vol_mhi_r_r2 <<< 16);
            volumed_l  <= vol_p_l_r3[79:16];
            volumed_r  <= vol_p_r_r3[79:16];
            vol_valid_pipe <= {vol_valid_pipe[2:0], hb3_l_valid};
        end
    end

    assign volumed_valid = vol_valid_pipe[3];

    // =========================================================================
    // 6. Sample pacer (Round 30) — elastic FIFO + cell_clk/8 tick.
    // =========================================================================
    logic [95:0] pace_fifo [256];
    logic [95:0] pace_fifo_dout;   // registered read -> BRAM DOA_REG=1
    logic [7:0]  pace_wptr, pace_rptr;
    logic [8:0]  pace_count;
    logic        pace_valid;
    logic signed [47:0] paced_l, paced_r;
    logic pace_started;
    // synthesis translate_off
    logic        pace_ovf_warned = 1'b0;
    // synthesis translate_on

    function automatic logic signed [47:0] ns_feed(input logic signed [63:0] v);
        if (v[63:46] == '0 || v[63:46] == '1)
            return {v[46:0], 1'b0};
        else
            return v[63] ? 48'sh8000_0000_0001 : 48'sh7FFF_FFFF_FFFF;
    endfunction

    logic [2:0] pace_div;
    logic       pace_tgl;

    (* ASYNC_REG = "TRUE" *) logic [1:0] cell_rst_sync;
    logic cell_rst_n;

    // cell_clk-domain reset release: async assert, synchronized deassert.
    always_ff @(posedge cell_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            cell_rst_sync <= 2'b00;
        else
            cell_rst_sync <= {cell_rst_sync[0], 1'b1};
    end
    assign cell_rst_n = cell_rst_sync[1];

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            pace_div <= '0;
            pace_tgl <= 1'b0;
        end else begin
            pace_div <= pace_div + 3'd1;
            if (pace_div == 3'd7)
                pace_tgl <= ~pace_tgl;
        end
    end

    (* ASYNC_REG = "TRUE" *) logic [2:0] pace_sync;
    logic pace_tick;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            pace_sync <= '0;
        else
            pace_sync <= {pace_sync[1:0], pace_tgl};
    end
    assign pace_tick = pace_sync[2] ^ pace_sync[1];

    logic cell_test_ready;
    logic [10:0] bench_applied;
    logic signed [47:0] bench_sample_l, bench_sample_r;
    wire bench_active = bench_applied[1:0] != 0;
    wire bench_audio = bench_applied[1:0] >= 2;
    assign bench_ready = cell_test_ready && cell_test_safe;
    bench_test_stimulus u_bench_stimulus (
        .clk(dsp_clk), .rst_n(sys_rst_n), .tick(pace_tick), .allowed(bench_ready),
        .cmd(bench_cmd), .req(bench_req), .ack(bench_ack), .applied(bench_applied),
        .sample_l(bench_sample_l), .sample_r(bench_sample_r)
    );

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            pace_wptr    <= '0;
            pace_rptr    <= '0;
            pace_count   <= '0;
            pace_valid   <= 1'b0;
            paced_l      <= '0;
            paced_r      <= '0;
            pace_started <= 0;
            pace_fault   <= 0;
        end else begin
            pace_valid <= 1'b0;
            // BRAM-style registered read: rptr is stable between ticks so the
            // dout reg is already settled when pace_tick consumes it. Forward
            // the write data when the write slot IS the read slot (only when
            // the FIFO is empty — writes are blocked when full).
            pace_fifo_dout <= pace_fifo[pace_rptr];
            if (volumed_valid && pace_count != 9'd256) begin
                pace_fifo[pace_wptr] <= {ns_feed(volumed_l), ns_feed(volumed_r)};
                pace_wptr <= pace_wptr + 8'd1;
                if (pace_wptr == pace_rptr)
                    pace_fifo_dout <= {ns_feed(volumed_l), ns_feed(volumed_r)};
            end
            // synthesis translate_off
            if (volumed_valid && pace_count == 9'd256 && !pace_ovf_warned) begin
                $warning("dac_dsp_core: pace FIFO overflow, dropping samples (expected only in accelerated testbenches)");
                pace_ovf_warned <= 1'b1;
            end
            // synthesis translate_on
            if (pace_tick && !pace_started && pace_count >= 128) pace_started <= 1;
            if (pace_tick && pace_started && pace_count == 0) pace_fault <= 1;
            if (volumed_valid && pace_count == 256) pace_fault <= 1;
            if (pace_tick && pace_started && pace_count != 0) begin
                {paced_l, paced_r} <= pace_fifo_dout;
                pace_rptr  <= pace_rptr + 8'd1;
                pace_valid <= 1'b1;
            end
            case ({volumed_valid && pace_count != 9'd256, pace_tick && pace_started && pace_count != 0})
                2'b10:   pace_count <= pace_count + 9'd1;
                2'b01:   pace_count <= pace_count - 9'd1;
                default: pace_count <= pace_count;
            endcase
            if (bench_active) begin
                pace_count   <= 0;
                pace_wptr    <= 0;
                pace_rptr    <= 0;
                pace_started <= 0;
                pace_fault   <= 0;
                pace_valid   <= pace_tick && bench_audio;
                paced_l      <= bench_sample_l;
                paced_r      <= bench_sample_r;
            end
        end
    end

    // =========================================================================
    // 7. TPDF Dither — independent L and R
    // =========================================================================
    logic signed [42:0] dither_l, dither_r;

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_dither_l (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (pace_valid),
        .dither_out (dither_l)
    );

    tpdf_dither_gen #(
        .DITHER_WIDTH(42),
        .SEED1(64'hD1B5_4A32_D192_ED03),
        .SEED2(64'h94D0_49BB_1331_11EB)
    ) u_dither_r (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (pace_valid),
        .dither_out (dither_r)
    );

    // =========================================================================
    // 8. Noise Shaper — independent L and R (Round 30: noise_shaper_ef3)
    // =========================================================================
    logic [6:0] dem_cmd_l, dem_cmd_r;

    logic        ns_y_valid_l, ns_y_valid_r;
    logic        dpd_corr_valid_l, dpd_corr_valid_r;
    logic signed [55:0] dpd_corr_l, dpd_corr_r;

    noise_shaper_ef3 #(
        .INPUT_WIDTH (48),
        .FRAC_WIDTH  (42),
        .OUT_WIDTH   (7)
    ) u_ns_l (
        .clk           (dsp_clk),
        .rst_n         (sys_rst_n),
        .enable        (pace_valid),
        .data_in       (paced_l),
        .dither_in     (dither_l),
        .dem_drive_out (dem_cmd_l),
        .y_valid       (ns_y_valid_l),
        .corr_valid    (dpd_corr_valid_l),
        .corr          (dpd_corr_l)
    );

    noise_shaper_ef3 #(
        .INPUT_WIDTH (48),
        .FRAC_WIDTH  (42),
        .OUT_WIDTH   (7)
    ) u_ns_r (
        .clk           (dsp_clk),
        .rst_n         (sys_rst_n),
        .enable        (pace_valid),
        .data_in       (paced_r),
        .dither_in     (dither_r),
        .dem_drive_out (dem_cmd_r),
        .y_valid       (ns_y_valid_r),
        .corr_valid    (dpd_corr_valid_r),
        .corr          (dpd_corr_r)
    );

    // =========================================================================
    // 8b. DPD Engines (Step 4D.1, 2026-08-22)
    // =========================================================================
    logic [7:0] dpd_addr_l_a, dpd_addr_l_b, dpd_addr_r_a, dpd_addr_r_b;
    logic dpd_busy_l, dpd_busy_r;
    assign dpd_busy = dpd_busy_l || dpd_busy_r;

    dpd_deadline_monitor u_dpd_deadline_monitor (
        .clk(dsp_clk),
        .rst_n(sys_rst_n),
        .dpd_enabled(dpd_enable && !bench_active),
        .sample_advance(pace_valid),
        .result_started(ns_y_valid_l && ns_y_valid_r),
        .correction_applied(dpd_corr_valid_l && dpd_corr_valid_r),
        .deadline_miss(dpd_deadline_miss)
    );

    assign dpd_cal_addr = {{1'b1, dpd_addr_r_b}, {1'b1, dpd_addr_r_a},
                           {1'b0, dpd_addr_l_b}, {1'b0, dpd_addr_l_a}};

    dpd_engine u_dpd_l (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .dpd_enable (dpd_enable && !bench_active),
        .y_valid    (ns_y_valid_l),
        .y          (dem_cmd_l),
        .cal_addr_a (dpd_addr_l_a),
        .cal_data_a (dpd_cal_data[0]),
        .cal_addr_b (dpd_addr_l_b),
        .cal_data_b (dpd_cal_data[1]),
        .corr       (dpd_corr_l),
        .corr_valid (dpd_corr_valid_l),
        .busy       (dpd_busy_l)
    );

    dpd_engine u_dpd_r (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .dpd_enable (dpd_enable && !bench_active),
        .y_valid    (ns_y_valid_r),
        .y          (dem_cmd_r),
        .cal_addr_a (dpd_addr_r_a),
        .cal_data_a (dpd_cal_data[2]),
        .cal_addr_b (dpd_addr_r_b),
        .cal_data_b (dpd_cal_data[3]),
        .corr       (dpd_corr_r),
        .corr_valid (dpd_corr_valid_r),
        .busy       (dpd_busy_r)
    );

    // =========================================================================
    // 9. 64-Element DEM — sort-based 2nd-order vector shaper (Round 30)
    // =========================================================================
    logic [5:0] ns_valid_pipe;
    logic       dem_enable;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            ns_valid_pipe <= '0;
        else
            ns_valid_pipe <= {ns_valid_pipe[4:0], pace_valid};
    end

    assign dem_enable = ns_valid_pipe[5];

    logic [63:0] dem_out_l, dem_out_r;
    logic        dem_valid_l, dem_valid_r;

    dem_sort #(.ARRAY_SIZE(64), .AMP_WIDTH(7)) u_dem_l (
        .clk          (dsp_clk),
        .rst_n        (sys_rst_n),
        .enable       (dem_enable),
        .amplitude_in (dem_cmd_l),
        .resistor_out (dem_out_l),
        .valid_out    (dem_valid_l)
    );

    dem_sort #(.ARRAY_SIZE(64), .AMP_WIDTH(7)) u_dem_r (
        .clk          (dsp_clk),
        .rst_n        (sys_rst_n),
        .enable       (dem_enable),
        .amplitude_in (dem_cmd_r),
        .resistor_out (dem_out_r),
        .valid_out    (dem_valid_r)
    );

    // =========================================================================
    // 10. IOB Output Registers
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic [1:0] cell_test_req_meta, cell_test_req_sync;
    logic [1:0][7:0] cell_test_applied;
    localparam int CELL_TEST_WAIT_W = $clog2(CELL_TEST_MUTE_CYCLES + 1);
    logic [CELL_TEST_WAIT_W-1:0] cell_test_mute_count;
    assign cell_test_ready = cell_test_mute_count == CELL_TEST_WAIT_W'(CELL_TEST_MUTE_CYCLES);
    wire cell_test_active = (cell_test_applied[0][7] || cell_test_applied[1][7]) && cell_test_ready;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            cell_test_req_meta   <= '0;
            cell_test_req_sync   <= '0;
            cell_test_ack        <= '0;
            cell_test_applied    <= '0;
            cell_test_mute_count <= '0;
        end else begin
            cell_test_req_meta <= cell_test_req;
            cell_test_req_sync <= cell_test_req_meta;
            if (!cell_test_safe)
                cell_test_mute_count <= '0;
            else if (!cell_test_ready)
                cell_test_mute_count <= cell_test_mute_count + 1'b1;
            for (int ch = 0; ch < 2; ch++) begin
                if ((cell_test_req_sync[ch] != cell_test_ack[ch]) &&
                    (!cell_test_cfg[ch][7] || (cell_test_safe && cell_test_ready))) begin
                    cell_test_applied[ch] <= cell_test_cfg[ch];
                    cell_test_ack[ch]     <= cell_test_req_sync[ch];
                end
            end
        end
    end

    function automatic logic [63:0] cell_test_pattern(input logic [7:0] cfg);
        logic [63:0] pattern;
        pattern = 64'h00000000ffffffff;
        if (cfg[7]) begin
            pattern = '0;
            for (int i = 1; i <= 32; i++) pattern[(int'(cfg[5:0]) + i) % 64] = 1'b1;
            pattern[cfg[5:0]] = cfg[6];
        end
        return pattern;
    endfunction

    wire bench_cell = bench_applied[1:0] == 1;
    wire [7:0] bench_cell_cfg = {1'b1, bench_applied[3], bench_applied[9:4]};
    logic dem_out_valid;
    assign dem_out_valid = (bench_cell || cell_test_active) ? pace_tick : dem_valid_l;

    logic [63:0] staging_l, staging_r;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            staging_l <= '0;
            staging_r <= '0;
        end else if (dem_out_valid) begin
            staging_l <= bench_cell ? cell_test_pattern(bench_applied[2] ? 8'd0 : bench_cell_cfg) :
                         cell_test_active ? cell_test_pattern(cell_test_applied[0]) : dem_out_l;
            staging_r <= bench_cell ? cell_test_pattern(bench_applied[2] ? bench_cell_cfg : 8'd0) :
                         cell_test_active ? cell_test_pattern(cell_test_applied[1]) : dem_out_r;
        end
    end

    logic dem_update_tgl;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            dem_update_tgl <= 1'b0;
        else if (dem_out_valid)
            dem_update_tgl <= ~dem_update_tgl;
    end

    (* ASYNC_REG = "TRUE" *) logic [2:0] tgl_sync;
    logic cell_capture_en;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n)
            tgl_sync <= '0;
        else
            tgl_sync <= {tgl_sync[1:0], dem_update_tgl};
    end
    assign cell_capture_en = tgl_sync[2] ^ tgl_sync[1];

    // RTZ frame is locked to pace_div (crystal-derived cell_clk/8 counter) so
    // the 6-of-8 gate window has zero CDC jitter. cell_capture_en only
    // refreshes the shadow word; the visible output switches at the frame
    // boundary (pace_div==7) so a cascode pulse can never be truncated by a
    // late or early CDC edge.
    logic [63:0] cell_shadow_l, cell_shadow_r;
    logic [63:0] cell_cap_l, cell_cap_r;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            cell_shadow_l <= '0;
            cell_shadow_r <= '0;
            cell_cap_l    <= '0;
            cell_cap_r    <= '0;
        end else begin
            if (cell_capture_en) begin
                cell_shadow_l <= staging_l;
                cell_shadow_r <= staging_r;
            end
            if (pace_div == 3'd7) begin
                cell_cap_l <= cell_shadow_l;
                cell_cap_r <= cell_shadow_r;
            end
        end
    end

    // Stream-alive watchdog: while samples flow, cell_capture_en arrives
    // once per 8-cycle frame; two full missed frames (16 cell_clk) means the
    // stream stalled or diagnostics exited — silence the output rather than
    // replay the last DEM word at 75% duty forever. The gate window itself
    // stays pace_div-locked; alive only qualifies emission, so pulse timing
    // keeps zero CDC jitter. Timeout >> sync jitter (±1 cell_clk).
    logic       cell_alive;
    logic [4:0] cell_alive_cnt;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            cell_alive     <= 1'b0;
            cell_alive_cnt <= '0;
        end else if (cell_capture_en) begin
            cell_alive     <= 1'b1;
            cell_alive_cnt <= '0;
        end else if (cell_alive_cnt != 5'd16) begin
            cell_alive_cnt <= cell_alive_cnt + 1'b1;
        end else begin
            cell_alive <= 1'b0;
        end
    end

    logic rtz_gate;

    assign rtz_gate = (pace_div != 3'd0) && (pace_div != 3'd7);

    (* IOB = "TRUE" *) logic [63:0] cascode_iob_l;
    (* IOB = "TRUE" *) logic [63:0] cascode_iob_r;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            cascode_iob_l <= '0;
            cascode_iob_r <= '0;
        end else begin
            cascode_iob_l <= (rtz_gate && cell_alive) ? cell_cap_l : 64'd0;
            cascode_iob_r <= (rtz_gate && cell_alive) ? cell_cap_r : 64'd0;
        end
    end

    assign cascode_l = cascode_iob_l;
    assign cascode_r = cascode_iob_r;

endmodule
