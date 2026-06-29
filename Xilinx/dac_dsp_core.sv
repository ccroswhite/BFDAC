`timescale 1ns / 1ps

// DAC DSP Core — single XCVU13P stereo design
// Contains:
//   - fir_polyphase_stereo (NUM_MACS shared-BRAM FIR, stereo)
//   - FIR output pipeline register
//   - Volume multiplier (DSP48 inferred, 4-stage pipeline)
//   - Stable-hold register
//   - TPDF dither generator
//   - 5th-order noise shaper
//   - DEM mapper
//   - 512-bit output FIFO (dsp_clk -> lvds_bit_clk CDC)
//   - LVDS serial TX

module dac_dsp_core #(
    parameter int NUM_MACS = 1024  // Production: 1024 (1M taps) or 2048 (2M taps)
)(
    // Clock domains
    input  logic        dsp_clk,
    input  logic        lvds_bit_clk,
    input  logic        sys_rst_n,

    // Audio input (from dac_i2s_ingress, dsp_clk domain)
    // Both L and R arrive; channel_sel picks which feeds the FIR.
    input  logic [23:0] audio_l,
    input  logic [23:0] audio_r,
    input  logic        new_sample,

    // Coefficient write bus (from dac_coef_subsys, dsp_clk domain)
    input  logic        coef_we,
    input  logic [$clog2(16*64)-1:0] coef_waddr,  // 10 bits for 1024 coefs/MAC
    input  logic signed [17:0] coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]  coef_wmac,  // 12 bits for 4096 MACs

    // Bank switching (from dac_coef_subsys, dsp_clk domain)
    input  logic        bank_select,
    input  logic        bank_load_target,

    // Volume control (from dac_ctrl_plane, clk_49m -> registered)
    input  logic [31:0] sys_volume,

    // Boot envelope gain (from dac_coef_subsys, dsp_clk domain)
    input  logic [15:0] boot_envelope_gain,

    // Sample tick output (768 kHz, to dac_coef_subsys)
    output logic        sample_768k_tick,

    // LVDS outputs
    output logic        lvds_bclk_p,
    output logic        lvds_bclk_n,
    output logic        lvds_sync_p,
    output logic        lvds_sync_n,
    output logic        lvds_data_l_p,
    output logic        lvds_data_l_n,
    output logic        lvds_data_r_p,
    output logic        lvds_data_r_n
);

    // ----------------------------------------------------------------
    // 1. FIR Polyphase — stereo
    // ----------------------------------------------------------------
    logic signed [47:0] interpolated_l, interpolated_r;
    logic               interp_l_valid, interp_r_valid;

    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (64),   // 4K MACs × 64 × 16 = 4,194,304 taps (4M target)
        .DATA_WIDTH     (24),
        .COEF_WIDTH     (18),
        .ACC_WIDTH      (48)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (sys_rst_n),
        .new_sample_valid     (new_sample),
        .new_sample_l         (audio_l),
        .new_sample_r         (audio_r),
        .interpolated_l       (interpolated_l),
        .interpolated_l_valid (interp_l_valid),
        .interpolated_r       (interpolated_r),
        .interpolated_r_valid (interp_r_valid),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (bank_select),
        .bank_load_target     (bank_load_target)
    );

    // ----------------------------------------------------------------
    // 2. FIR boundary pipeline + sample tick
    // ----------------------------------------------------------------
    logic signed [47:0] fir_reg;
    logic               fir_valid_reg;

    assign sample_768k_tick = interp_l_valid;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fir_reg       <= '0;
            fir_valid_reg <= 1'b0;
        end else begin
            fir_reg       <= interpolated_l;  // TODO: stereo volume/NS path per channel
            fir_valid_reg <= interp_l_valid;
        end
    end

    // ----------------------------------------------------------------
    // 3. Volume multiplier (DSP48 inferred, 3-stage pipeline)
    //    effective_volume = sys_volume * boot_envelope_gain >> 16
    // ----------------------------------------------------------------
    logic [31:0] combined_volume;
    always_comb begin
        combined_volume = (sys_volume * {16'h0, boot_envelope_gain}) >> 16;
    end

    // Volume DSP pipeline — fully pipelined AREG=BREG=MREG=PREG=1:
    //   Cycle 0: fir_reg, combined_volume arrive
    //   Cycle 1: vol_a_r1 (AREG), vol_b_r1 (BREG)
    //   Cycle 2: vol_m_r2 (MREG)
    //   Cycle 3: vol_p_r3 (PREG)
    //   Cycle 4: volumed (shift+truncate)
    logic signed [47:0] vol_a_r1;
    logic        [31:0] vol_b_r1;
    (* use_dsp = "yes" *) logic signed [79:0] vol_m_r2; // MREG
    (* use_dsp = "yes" *) logic signed [79:0] vol_p_r3; // PREG

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_a_r1 <= '0;
            vol_b_r1 <= '0;
            vol_m_r2 <= '0;
            vol_p_r3 <= '0;
        end else begin
            vol_a_r1 <= fir_reg;
            vol_b_r1 <= combined_volume;
            vol_m_r2 <= vol_a_r1 * $signed({1'b0, vol_b_r1});
            vol_p_r3 <= vol_m_r2;
        end
    end

    logic signed [63:0] volumed;
    logic               volumed_valid;
    logic [4:0]         vol_valid_pipe;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_valid_pipe <= '0;
            volumed        <= '0;
        end else begin
            vol_valid_pipe <= {vol_valid_pipe[3:0], fir_valid_reg};
            volumed        <= vol_p_r3[79:16];
        end
    end

    assign volumed_valid = vol_valid_pipe[4];

    // ----------------------------------------------------------------
    // 4. Stable-hold register
    // ----------------------------------------------------------------
    logic signed [63:0] stable;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            stable <= '0;
        else if (volumed_valid)
            stable <= volumed;
    end

    // ----------------------------------------------------------------
    // 5. TPDF Dither
    // ----------------------------------------------------------------
    logic [41:0] dither;

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_dither (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (volumed_valid),
        .dither_out (dither)
    );

    // ----------------------------------------------------------------
    // 6. 5th-Order Noise Shaper
    // ----------------------------------------------------------------
    logic [8:0] dem_cmd;

    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),
        .FRAC_WIDTH (42),
        .OUT_WIDTH  (9)
    ) u_ns (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .data_in        (stable[63:16]),
        .dither_in      (dither),
        .dem_drive_out  (dem_cmd)
    );

    // ----------------------------------------------------------------
    // 7. DEM Mapper
    // ----------------------------------------------------------------
    logic [255:0] my_ring;

    dem_mapper #(.ARRAY_SIZE(256), .AMP_WIDTH(9)) u_dem (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .amplitude_in   (dem_cmd),
        .resistor_out   (my_ring)
    );

    // ----------------------------------------------------------------
    // 8. 512-bit output FIFO (dsp_clk -> lvds_bit_clk CDC)
    // ----------------------------------------------------------------
    logic [511:0] cross_domain_bus;
    logic         tx_fifo_empty, tx_fifo_full;
    logic         lvds_tx_read_trigger;

    async_fifo_wide #(.DATA_WIDTH(512), .ADDR_WIDTH(4)) u_output_fifo (
        .w_clk   (dsp_clk),
        .w_rst_n (sys_rst_n),
        .w_en    (volumed_valid),
        .w_data  ({my_ring, my_ring}),
        .w_full  (tx_fifo_full),
        .r_clk   (lvds_bit_clk),
        .r_rst_n (sys_rst_n),
        .r_en    (lvds_tx_read_trigger),
        .r_data  (cross_domain_bus),
        .r_empty (tx_fifo_empty)
    );

    assign lvds_tx_read_trigger = ~tx_fifo_empty;

    // ----------------------------------------------------------------
    // 9. LVDS Serial TX (lvds_bit_clk domain)
    // ----------------------------------------------------------------
    lvds_serial_tx u_lvds_tx (
        .bit_clk         (lvds_bit_clk),
        .rst_n           (sys_rst_n),
        .left_ring_data  (cross_domain_bus[511:256]),
        .right_ring_data (cross_domain_bus[255:0]),
        .data_valid      (lvds_tx_read_trigger),
        .lvds_bclk_p     (lvds_bclk_p),
        .lvds_bclk_n     (lvds_bclk_n),
        .lvds_sync_p     (lvds_sync_p),
        .lvds_sync_n     (lvds_sync_n),
        .lvds_data_l_p   (lvds_data_l_p),
        .lvds_data_l_n   (lvds_data_l_n),
        .lvds_data_r_p   (lvds_data_r_p),
        .lvds_data_r_n   (lvds_data_r_n)
    );

endmodule
