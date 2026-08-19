`timescale 1ns / 1ps

// =============================================================================
// DAC DSP Core — XCVU13P single-FPGA stereo design
//
// Signal chain (stereo throughout):
//   1. fir_polyphase_stereo  : ×16 polyphase FIR, 1M taps, URAM288 coef storage
//   2. halfband_x2 HB1       : ×2 interpolation, 768k  → 1.536 MHz, 63 taps
//   3. halfband_x2 HB2       : ×2 interpolation, 1.536 → 3.072 MHz, 31 taps
//   4. halfband_x2 HB3       : ×2 interpolation, 3.072 → 6.144 MHz, 15 taps
//   5. Volume multiplier     : DSP48, 4-stage pipeline, shared combined_volume
//   6. Sample pacer          : elastic FIFO, one paced sample per 6.144 MHz tick
//   7. TPDF dither           : 42-bit, independent L+R
//   8. noise_shaper_ef3      : 3rd-order EF, IIR NTF (1-z)^3/(1-z/2)^3, per
//                              channel (Round 30: replaces the 7th-order FIR-EF
//                              whose placeholder coefs had NO DC zero)
//   9. dem_sort              : 64-element sort-based 2nd-order vector shaper
//                              (Round 30, ratified with RTZ; tones <= -168 dBFS)
//  10. IOB output registers  : staging (dsp_clk) -> CDC -> RTZ pattern gen +
//                              IOB register (cell_clk). Each selected cell
//                              emits a 6-of-8 mclk-cycle pulse per 6.144 MHz
//                              sample (RTZ 75 % duty, Round 30).
//
// Output: 64 RTZ data bits per channel (1 pin per cell, 128 total) -> AXC1T45
//         translator -> SN74LVC1G74 per-cell reclock FF, whose Q/~Q pair
//         drives the DMMT5551 steering cell (~3.3 V) -> cascode cells.
// No LVDS serial TX, no CDC FIFO, no external FPGA interface.
// =============================================================================
module dac_dsp_core #(
    parameter int NUM_MACS = 1024,  // Production: 1024 (1M taps) or 2048 (2M taps)
    parameter int TAPS_PER_PHASE = 64  // Coefs per MAC per phase; taps = 16*NUM_MACS*TAPS_PER_PHASE
)(
    // Single clock domain — all logic runs on dsp_clk (350-400 MHz, BUFG)
    input  logic        dsp_clk,
    input  logic        sys_rst_n,

    // Audio input (from dac_i2s_ingress, dsp_clk domain)
    input  logic [23:0] audio_l,
    input  logic [23:0] audio_r,
    input  logic        new_sample,
    input  logic        force_zero,    // 1: clamp FIR input to 0 (mute / relay sequencing)

    // Coefficient write bus (from dac_coef_subsys, dsp_clk domain)
    input  logic                            coef_we,
    input  logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,  // coef index within MAC
    input  logic signed [17:0]              coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]     coef_wmac,

    // Bank switching (from dac_coef_subsys, dsp_clk domain)
    input  logic        bank_select,
    input  logic        bank_load_target,

    // Volume control (from dac_ctrl_plane, registered into dsp_clk domain)
    input  logic [31:0] sys_volume,

    // Boot envelope gain (from dac_coef_subsys, dsp_clk domain)
    input  logic [15:0] boot_envelope_gain,

    // Sample tick output (768 kHz post-FIR, to dac_coef_subsys)
    output logic        sample_768k_tick,

    // Cascode IOB launch clock — mclk-rate MMCM output, phase-aligned to the
    // external SN74LVC1G74 reclock-FF clock (same LMK00304 tree, Round 30)
    input  logic        cell_clk,

    // Direct cascode cell outputs — IOB-registered on cell_clk, RTZ-encoded
    // (6-of-8 mclk pulse per selected cell per sample, Round 30). ONE pin per
    // cell; the external SN74LVC1G74 reclock FF (Fig. 1b) produces the
    // complementary base-drive pair (Q/~Q) for the DMMT5551 cell (Fig. 2).
    // Constraint in XDC: set_property IOB TRUE [get_cells {*cascode_iob*}]
    output logic [63:0] cascode_l,   // Left  channel: 64 cascode cell data bits
    output logic [63:0] cascode_r    // Right channel: 64 cascode cell data bits
);

    // =========================================================================
    // Mute input gating: zero audio data but keep new_sample alive so the FIR
    // pipeline continues flushing and produces a true DC-zero output, not a
    // held stale value.
    logic [23:0] gated_audio_l, gated_audio_r;
    assign gated_audio_l = force_zero ? 24'd0 : audio_l;
    assign gated_audio_r = force_zero ? 24'd0 : audio_r;

    // =========================================================================
    // 1. Polyphase FIR ×16 — stereo, URAM288 coefficient storage
    //    Output rate: 768 kHz (48k) / 705.6 kHz (44.1k)
    // =========================================================================
    logic signed [47:0] interp_l,     interp_r;
    logic               interp_l_valid, interp_r_valid;

    assign sample_768k_tick = interp_l_valid;

    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (24),
        .COEF_WIDTH     (18),
        .ACC_WIDTH      (48)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (sys_rst_n),
        .new_sample_valid     (new_sample),
        .new_sample_l         (gated_audio_l),
        .new_sample_r         (gated_audio_r),
        .interpolated_l       (interp_l),
        .interpolated_l_valid (interp_l_valid),
        .interpolated_r       (interp_r),
        .interpolated_r_valid (interp_r_valid),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (bank_select),
        .bank_load_target     (bank_load_target)
    );

    // =========================================================================
    // 2. Half-band ×2 stage HB1 — stereo
    //    63 taps, 768k → 1.536 MHz
    // =========================================================================
    logic signed [47:0] hb1_l,     hb1_r;
    logic               hb1_l_valid, hb1_r_valid;

    halfband_x2 #(.NUM_TAPS(63), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(4))
    u_hb1_l (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (interp_l_valid),
        .data_in  (interp_l),
        .out_valid(hb1_l_valid),
        .data_out (hb1_l)
    );

    halfband_x2 #(.NUM_TAPS(63), .DATA_WIDTH(48), .COEF_WIDTH(18), .ACC_WIDTH(48), .OUT_SPACING(4))
    u_hb1_r (
        .clk      (dsp_clk),
        .rst_n    (sys_rst_n),
        .in_valid (interp_r_valid),
        .data_in  (interp_r),
        .out_valid(hb1_r_valid),
        .data_out (hb1_r)
    );

    // =========================================================================
    // 3. Half-band ×2 stage HB2 — stereo
    //    31 taps, 1.536 → 3.072 MHz
    // =========================================================================
    logic signed [47:0] hb2_l,     hb2_r;
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
    // 4. Half-band ×2 stage HB3 — stereo
    //    15 taps, 3.072 → 6.144 MHz
    // =========================================================================
    logic signed [47:0] hb3_l,     hb3_r;
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
    // 5. Volume multiplier — shared combined_volume, stereo paths
    //    effective_volume = (sys_volume * boot_envelope_gain) >> 16
    //    DSP48 pipeline: AREG(1) + MREG(1) + PREG(1) + output reg = 4 cycles
    // =========================================================================
    // Registered (f9wd route review 2026-08-15): as always_comb this 32x16
    // multiply rode combinationally from u_boot_envelope/gain_r through a DSP
    // into the vol_b_r1 capture (-0.16 ns). Both inputs are slow controls
    // (volume pot / boot ramp), so one extra cycle of gain latency is free.
    (* use_dsp = "yes" *) logic [31:0] combined_volume;
    always_ff @(posedge dsp_clk)
        combined_volume <= (sys_volume * {16'h0, boot_envelope_gain}) >> 16;

    // Left volume pipeline
    logic signed [47:0] vol_a_l_r1;
    logic        [31:0] vol_b_r1;
    (* use_dsp = "yes" *) logic signed [79:0] vol_m_l_r2, vol_m_r_r2;
    (* use_dsp = "yes" *) logic signed [79:0] vol_p_l_r3, vol_p_r_r3;
    logic signed [47:0] vol_a_r_r1;
    logic signed [63:0] volumed_l, volumed_r;
    logic        [4:0]  vol_valid_pipe;
    logic               volumed_valid;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_a_l_r1  <= '0;  vol_a_r_r1  <= '0;
            vol_b_r1    <= '0;
            vol_m_l_r2  <= '0;  vol_m_r_r2  <= '0;
            vol_p_l_r3  <= '0;  vol_p_r_r3  <= '0;
            volumed_l   <= '0;  volumed_r   <= '0;
            vol_valid_pipe <= '0;
        end else begin
            vol_a_l_r1 <= hb3_l;
            vol_a_r_r1 <= hb3_r;
            vol_b_r1   <= combined_volume;
            vol_m_l_r2 <= vol_a_l_r1 * $signed({1'b0, vol_b_r1});
            vol_m_r_r2 <= vol_a_r_r1 * $signed({1'b0, vol_b_r1});
            vol_p_l_r3 <= vol_m_l_r2;
            vol_p_r_r3 <= vol_m_r_r2;
            volumed_l  <= vol_p_l_r3[79:16];
            volumed_r  <= vol_p_r_r3[79:16];
            vol_valid_pipe <= {vol_valid_pipe[3:0], hb3_l_valid};
        end
    end

    assign volumed_valid = vol_valid_pipe[4];

    // =========================================================================
    // 6. Sample pacer (Round 30) — elastic FIFO + cell_clk/8 tick.
    //    The FIR sweep and HB chain produce the 128 per-sample updates in
    //    BURSTS (FIR emits 16 outputs paced by the coefficient sweep, each
    //    fanning out x8 through the HBs within ~11 clk). The NS/DEM/CDC
    //    stages need one update per 6.144 MHz sample, evenly. The FIR sweep
    //    compresses all 128 updates of one input sample into ~1024 clk while
    //    draining spans the whole sample period -> peak occupancy ~110; a
    //    256-deep FIFO (LUTRAM) absorbs it; the pop tick is cell_clk/8
    //    (= exactly 6.144 MHz, same MMCM family as the input rate, so the
    //    Scaling fix (Round 30, found by the e2e sine FFT): with unity-DC
    //    production coefficients the FIR output occupies the 48-bit FS
    //    (2^47) and the volume stage (x0.5 inherent) leaves full scale at
    //    volumed bit 46. The old feed took volumed[63:16] (top 48 bits),
    //    delivering the NS only 2^-17 of its input range (-102 dB — the
    //    converter would have produced shaped idle noise with a buried
    //    signal). Correct feed: volumed[46:0] << 1, saturating (headroom:
    //    modulator uses +-28 of +-32 levels; NS also clamps internally).
    //    long-term rates match exactly). Pop skips silently on empty
    //    (startup fill). Overflow DROPS the newest write (state stays
    //    consistent) and warns once in simulation — accelerated testbenches
    //    (tb_vu13p_top's 768 kHz I2S frames vs the sim-shortened watchdog)
    //    legitimately overrun the 6.144 MHz drain; hardware rates are
    //    mclk-locked and cannot.
    // =========================================================================
    logic [95:0] pace_fifo [256];
    logic [7:0]  pace_wptr, pace_rptr;
    logic [8:0]  pace_count;
    logic        pace_valid;
    logic signed [47:0] paced_l, paced_r;
    // synthesis translate_off
    logic        pace_ovf_warned = 1'b0;
    // synthesis translate_on

    // Saturating NS feed: volumed x2 with bit-46 full scale (see note above)
    function automatic logic signed [47:0] ns_feed(input logic signed [63:0] v);
        if (v[63:46] == '0 || v[63:46] == '1)
            return {v[46:0], 1'b0};                       // in range: x2
        else
            return v[63] ? 48'sh8000_0000_0001 : 48'sh7FFF_FFFF_FFFF;  // saturate
    endfunction

    // cell_clk domain: /8 tick toggle (6.144 MHz)
    logic [2:0] pace_div;
    logic       pace_tgl;

    always_ff @(posedge cell_clk) begin
        if (!sys_rst_n) begin
            pace_div <= '0;
            pace_tgl <= 1'b0;
        end else begin
            pace_div <= pace_div + 3'd1;
            if (pace_div == 3'd7)
                pace_tgl <= ~pace_tgl;
        end
    end

    // dsp_clk domain: sync + edge detect -> pop tick
    (* ASYNC_REG = "TRUE" *) logic [2:0] pace_sync;
    logic pace_tick;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            pace_sync <= '0;
        else
            pace_sync <= {pace_sync[1:0], pace_tgl};
    end
    assign pace_tick = pace_sync[2] ^ pace_sync[1];

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            pace_wptr  <= '0;
            pace_rptr  <= '0;
            pace_count <= '0;
            pace_valid <= 1'b0;
            paced_l    <= '0;
            paced_r    <= '0;
        end else begin
            pace_valid <= 1'b0;
            if (volumed_valid && pace_count != 9'd256) begin
                pace_fifo[pace_wptr] <= {ns_feed(volumed_l), ns_feed(volumed_r)};
                pace_wptr <= pace_wptr + 8'd1;
            end
            // synthesis translate_off
            if (volumed_valid && pace_count == 9'd256 && !pace_ovf_warned) begin
                $warning("dac_dsp_core: pace FIFO overflow, dropping samples (expected only in accelerated testbenches)");
                pace_ovf_warned <= 1'b1;
            end
            // synthesis translate_on
            if (pace_tick && pace_count != 0) begin
                {paced_l, paced_r} <= pace_fifo[pace_rptr];
                pace_rptr  <= pace_rptr + 8'd1;
                pace_valid <= 1'b1;
            end
            case ({volumed_valid && pace_count != 9'd256, pace_tick && pace_count != 0})
                2'b10:   pace_count <= pace_count + 9'd1;
                2'b01:   pace_count <= pace_count - 9'd1;
                default: pace_count <= pace_count;
            endcase
        end
    end

    // =========================================================================
    // 7. TPDF Dither — independent L and R
    // =========================================================================
    logic signed [41:0] dither_l, dither_r;

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_dither_l (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (pace_valid),   // Round 30: one fresh value per NS sample
        .dither_out (dither_l)
    );

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_dither_r (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (pace_valid),   // Round 30: one fresh value per NS sample
        .dither_out (dither_r)
    );

    // =========================================================================
    // 8. Noise Shaper — independent L and R (Round 30: noise_shaper_ef3)
    //    3rd-order error feedback, NTF (1-z^-1)^3/(1-z^-1/2)^3, 136 dB
    //    in-band SNDR (ns_ef3_gen.py; code budget line 133.5 dB).
    //    Input:  48-bit paced samples (bit-46 FS, see pacer note)
    //    Output: 7-bit amplitude to DEM (range 0..63)
    //    Pipeline: 4 stages, fires every 6.144 MHz tick
    // =========================================================================
    logic [6:0] dem_cmd_l, dem_cmd_r;

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
        .dem_drive_out (dem_cmd_l)
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
        .dem_drive_out (dem_cmd_r)
    );

    // =========================================================================
    // 9. 64-Element DEM — sort-based 2nd-order vector shaper (Round 30)
    //    Unconstrained selection (legal under RTZ: toggles are free): each
    //    sample picks the c cells with the smallest 2*acc1+acc2 metric.
    //    Mismatch + per-cell duty spread shaped to <= -153 dBFS, idle tones
    //    <= -168 dBFS (dem_sort_check.py). Replaces dem_dwa (DWA had audible
    //    -130 dBFS-class idle tones above the thermal floor).
    //    Multi-cycle (35 dsp_clk of 56-65 available) — uses valid_out instead
    //    of a fixed pipeline delay.
    //    enable is delayed to match NS pipeline (6 stages above + volumed_valid)
    // =========================================================================

    // Delay enable by NS pipeline depth (6 stages) to align dem enable with NS output
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
    // 10. IOB Output Registers — two stages for minimum skew
    //
    //  Stage 1: Staging register (fabric FF, placed anywhere)
    //           Captures DEM output 3 cycles after dem_enable (DEM pipeline depth).
    //           Gives router slack from DEM logic to IOB.
    //
    //  Stage 2 (Round 29, todo #13): dsp_clk -> cell_clk CDC + IOB register.
    //           The DEM word is stable for ~8 cell_clk cycles per 6.144 MHz
    //           update, so a toggle handshake moves it safely into the
    //           cell_clk domain (mclk-rate MMCM output, phase-aligned to the
    //           external reclock-FF clock). Round 30: an RTZ phase counter
    //           gates the captured word into a 6-of-8 mclk-cycle pulse per
    //           sample (75 % duty); the IOB register launches on cell_clk,
    //           giving the LVC1G74 D inputs ~9-13 ns of setup (bom.md §1.4).
    //           Pulse width is ALWAYS exactly 6 cell_clk periods (phase
    //           counter resets on capture) -> identical charge packets, the
    //           RTZ invariant.  All 128 IOB FFs share the cell_clk BUFG.
    //
    //  XDC constraints required (see vu13p_dac_top.xdc §8):
    //    set_property IOB TRUE [get_cells {u_dsp_core/cascode_iob_l_reg[*]}]
    //    set_property IOB TRUE [get_cells {u_dsp_core/cascode_iob_r_reg[*]}]
    //    set_max_delay -datapath_only across staging -> cellclk capture
    //    set_output_delay vs virtual ff_clk on cascode_l/r ports
    // =========================================================================

    // DEM output valid: dem_sort is multi-cycle; both channels get identical
    // enable cadence so their valids coincide — use the L one.
    logic dem_out_valid;
    assign dem_out_valid = dem_valid_l;

    // Stage 1: staging registers (fabric, gated load)
    logic [63:0] staging_l, staging_r;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            staging_l <= '0;
            staging_r <= '0;
        end else if (dem_out_valid) begin
            staging_l <= dem_out_l;
            staging_r <= dem_out_r;
        end
    end

    // dsp_clk domain: update toggle flips whenever a new DEM word is staged
    logic dem_update_tgl;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            dem_update_tgl <= 1'b0;
        else if (dem_out_valid)
            dem_update_tgl <= ~dem_update_tgl;
    end

    // cell_clk domain: local reset synchronizer (sys_rst_n is dsp_clk-domain)
    (* ASYNC_REG = "TRUE" *) logic [1:0] cell_rst_sync;
    logic cell_rst_n;

    always_ff @(posedge cell_clk or negedge sys_rst_n) begin
        if (!sys_rst_n)
            cell_rst_sync <= 2'b00;
        else
            cell_rst_sync <= {cell_rst_sync[0], 1'b1};
    end
    assign cell_rst_n = cell_rst_sync[1];

    // cell_clk domain: toggle synchronizer + edge detect -> capture enable.
    // staging_l/r are stable for ~8 cell_clk cycles by the time the toggle
    // lands (2-FF sync = 2-3 cell_clk after the dsp_clk staging load, and the
    // next DEM update is ~160 dsp_clk away), so the bus capture is race-free.
    (* ASYNC_REG = "TRUE" *) logic [2:0] tgl_sync;
    logic cell_capture_en;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n)
            tgl_sync <= '0;
        else
            tgl_sync <= {tgl_sync[1:0], dem_update_tgl};
    end
    assign cell_capture_en = tgl_sync[2] ^ tgl_sync[1];

    // cell_clk domain: bus capture registers (single fabric stage)
    logic [63:0] cell_cap_l, cell_cap_r;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            cell_cap_l <= '0;
            cell_cap_r <= '0;
        end else if (cell_capture_en) begin
            cell_cap_l <= staging_l;
            cell_cap_r <= staging_r;
        end
    end

    // cell_clk domain: RTZ phase counter (Round 30). Resets on capture so
    // every pulse is exactly 6 cell_clk wide regardless of CDC arrival
    // wobble. Gate low on phases 0 and 7: phase 0 = data-update/settle
    // window, phase 7 = return-to-zero before the next sample.
    logic [2:0] rtz_phase;
    logic       rtz_gate;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n)
            rtz_phase <= 3'd7;                   // parked: gate low
        else if (cell_capture_en)
            rtz_phase <= 3'd0;
        else if (rtz_phase != 3'd7)
            rtz_phase <= rtz_phase + 3'd1;       // saturate at 7 until next capture
    end

    assign rtz_gate = (rtz_phase != 3'd0) && (rtz_phase != 3'd7);

    // cell_clk domain: IOB output registers (unconditional — timing-closure
    // friendly). Vivado honours IOB=TRUE and places these FFs inside the
    // output IOB. Reset '0 parks every cell on bus_minus (matches DEM reset).
    (* IOB = "TRUE" *) logic [63:0] cascode_iob_l;
    (* IOB = "TRUE" *) logic [63:0] cascode_iob_r;

    always_ff @(posedge cell_clk) begin
        if (!cell_rst_n) begin
            cascode_iob_l <= '0;
            cascode_iob_r <= '0;
        end else begin
            cascode_iob_l <= rtz_gate ? cell_cap_l : 64'd0;
            cascode_iob_r <= rtz_gate ? cell_cap_r : 64'd0;
        end
    end

    assign cascode_l = cascode_iob_l;
    assign cascode_r = cascode_iob_r;

endmodule
