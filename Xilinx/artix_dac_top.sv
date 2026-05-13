`timescale 1ns / 1ps

module artix_dac_top (
    // Base Clocks & Reset
    input  logic        clk_45m,      
    input  logic        clk_49m,      
    input  logic        ext_rst_n,

    // I2S Ingress
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // ARM SPI Interface (Control Plane)
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Hardware Control Plane
    output logic        relay_gain_6v,
    output logic        relay_audio_out,

    // High-Speed Serial LVDS (To MAX10 Tubs)
    output logic        lvds_bclk_p,
    output logic        lvds_bclk_n,
    output logic        lvds_sync_p,
    output logic        lvds_sync_n,
    output logic        lvds_data_l_p,
    output logic        lvds_data_l_n,
    output logic        lvds_data_r_p,
    output logic        lvds_data_r_n
);

    // ==============================================================
    // 1. Dual Clock Domains (357 MHz and 196.6 MHz)
    // ==============================================================
    logic dsp_clk;              
    logic lvds_bit_clk;
    logic clk_locked;
    logic sys_rst_n;      
    logic base_rate_sel; // MOVED HERE: Fixes implicit declaration warning
    
    assign sys_rst_n = ext_rst_n & clk_locked;

    sys_clock_gen u_clk_gen (
        .clk_45m        (clk_45m),
        .clk_49m        (clk_49m),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),         
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .locked         (clk_locked)
    );

    // ==============================================================
    // 2. Control Plane (SPI & Relays - Clocked by 49MHz to Break Loop)
    // ==============================================================
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;
    logic        spi_crc_error;

    logic [31:0] sys_volume;
    logic        cmd_gain_6v;
    logic        cmd_unmute;

    spi_slave u_spi_slave (
        .clk            (clk_49m),      // STRICTLY 49MHz Master Clock
        .rst_n          (ext_rst_n),
        .spi_sclk       (spi_sclk),
        .spi_cs_n       (spi_cs_n),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .tx_data_in     (spi_tx_data),
        .data_out       (ctrl_bus_data),
        .data_valid     (ctrl_bus_valid),
        .crc_err_pulse  (spi_crc_error)
    );

    always_ff @(posedge clk_49m) begin 
        if (!ext_rst_n) begin
            sys_volume      <= 32'hFFFFFFFF;
            cmd_gain_6v     <= 1'b0;
            relay_gain_6v   <= 1'b0;
            base_rate_sel   <= 1'b0;
            cmd_unmute      <= 1'b0;
            read_addr_reg   <= 7'h00;
        end else begin
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin
                    // WRITE OPERATION
                    case (ctrl_bus_data[30:24])
                        7'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]};
                        7'h02: cmd_gain_6v   <= ctrl_bus_data[0];                        
                        7'h03: base_rate_sel <= ctrl_bus_data[0];                        
                        7'h04: cmd_unmute    <= ctrl_bus_data[0];
                    endcase
                    relay_gain_6v <= cmd_gain_6v;
                end else begin                  
                    // READ OPERATION
                    read_addr_reg <= ctrl_bus_data[30:24];
                end
            end
        end
    end

    // SPI Read Output MUX
    always_comb begin
        case (read_addr_reg)
            7'h10: spi_tx_data = 32'hDAC02026;
            7'h12: spi_tx_data = {30'd0, base_rate_sel, relay_gain_6v};              
            default: spi_tx_data = 32'hDEADBEEF;
        endcase
    end

    // ==============================================================
    // 3. I2S Ingress & Stereo-Locked Clock Domain Crossing
    //
    // The i2s_rx aggregates both subframes and pulses data_valid exactly
    // once per stereo pair, with left_data and right_data simultaneously
    // valid. Packing {L,R} into a single 64-bit async FIFO guarantees the
    // downstream L and R DSP chains receive their source samples on the
    // SAME dsp_clk edge -- no inter-channel drift possible by construction.
    // ==============================================================
    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [63:0] safe_audio_lr;
    logic [31:0] safe_audio_l_data, safe_audio_r_data;
    logic        fifo_full, fifo_empty, new_sample_trigger;

    i2s_rx #(.DATA_WIDTH(32)) u_i2s_rx (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .i2s_bclk   (i2s_bclk),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (raw_left_data),
        .right_data (raw_right_data),
        .data_valid (raw_data_valid)
    );

    // TODO(CDC-FIX): i2s_rx is clocked on dsp_clk (357 MHz), so raw_data_valid
    // is a 2.8 ns pulse in the dsp_clk domain. This FIFO writes on i2s_bclk
    // (~3 MHz period, ~333 ns), which will almost always miss the 2.8 ns pulse.
    //
    // Correct fix: change w_clk from i2s_bclk to dsp_clk. The signals being
    // written (raw_data_valid, raw_left_data, raw_right_data) are ALREADY in
    // the dsp_clk domain coming out of i2s_rx, so no CDC is needed on the
    // write side. The async_fifo then provides elastic buffering between the
    // bursty i2s sample-arrival rate and the steady FIR consumption rate.
    //
    // Not fixed here per explicit "restore baseline first" directive. Address
    // before any real audio path validation -- the current baseline only met
    // TIMING, not functional correctness end-to-end.
    async_fifo #(.DATA_WIDTH(64), .ADDR_WIDTH(4)) u_async_fifo (
        .w_clk   (i2s_bclk),
        .w_rst_n (sys_rst_n),
        .w_en    (raw_data_valid & ~fifo_full),
        .w_data  ({raw_left_data, raw_right_data}),
        .w_full  (fifo_full),
        .r_clk   (dsp_clk),
        .r_rst_n (sys_rst_n),
        .r_en    (~fifo_empty),
        .r_data  (safe_audio_lr),
        .r_empty (fifo_empty)
    );

    assign safe_audio_l_data  = safe_audio_lr[63:32];
    assign safe_audio_r_data  = safe_audio_lr[31:0];
    assign new_sample_trigger = ~fifo_empty;

    // ==============================================================
    // 4. The 357 MHz Overclocked Stereo DSP Core
    //
    // TWO independent fir_polyphase_interpolator instances (u_l_1m_tap_fir,
    // u_r_1m_tap_fir). Each is FULLY SELF-CONTAINED: its own state machine,
    // its own audio history, its own per-MAC coefficient ROMs placed local
    // to its DSP48E1s. The two engines share NO physical FPGA resources
    // beyond clock and reset -- so Vivado is free to place each engine in
    // its own region of the die, eliminating cross-channel routing tension.
    //
    // Lockstep is guaranteed by the shared new_sample_trigger, sys_rst_n,
    // and dsp_clk; both engines complete their FIR sweeps on the same cycle.
    // ==============================================================
    logic signed [47:0] interpolated_audio_l_48b, interpolated_audio_r_48b;
    logic               interpolated_l_valid,    interpolated_r_valid;

    // ----- LEFT CHANNEL FIR -----
    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (48) // STRICTLY 48 BITS
    ) u_l_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (new_sample_trigger),
        .new_sample_data    (safe_audio_l_data[31:8]),
        .interpolated_out   (interpolated_audio_l_48b),
        .interpolated_valid (interpolated_l_valid)
    );

    // ----- RIGHT CHANNEL FIR -----
    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (48) // STRICTLY 48 BITS
    ) u_r_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (new_sample_trigger),
        .new_sample_data    (safe_audio_r_data[31:8]),
        .interpolated_out   (interpolated_audio_r_48b),
        .interpolated_valid (interpolated_r_valid)
    );

    // --- FIR Boundary Pipelining (Absorbs routing delay from FIR edge) ---
    logic signed [47:0] fir_l_out_reg, fir_r_out_reg;
    logic               fir_l_valid_reg, fir_r_valid_reg;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fir_l_out_reg   <= '0;
            fir_r_out_reg   <= '0;
            fir_l_valid_reg <= 1'b0;
            fir_r_valid_reg <= 1'b0;
        end else begin
            fir_l_out_reg   <= interpolated_audio_l_48b;
            fir_r_out_reg   <= interpolated_audio_r_48b;
            fir_l_valid_reg <= interpolated_l_valid;
            fir_r_valid_reg <= interpolated_r_valid;
        end
    end

    // --- 64-Bit Volume Multipliers (Xilinx DSP IP - 11 Cycle Latency, per channel) ---
    //
    //   The DSP48E1 instances inside vol_mult_ip require Tmin <= 2.797 ns to
    //   meet the 357 MHz dsp_clk used in the 49.152 MHz / 768 kHz family
    //   configuration. Mult_Gen v12.0 only places MREG=1, PREG=1 on every
    //   cascade DSP (including the bppDSP[0][0] cascade head) when
    //   PipeStages >= 11; lower values leave at least one DSP per channel
    //   without MREG, which raises its silicon Tmin to ~2.86 ns and causes
    //   pulse-width violations. PipeStages=11 drops Tmin to ~1.95 ns.
    //   The valid-pipeline width below tracks this latency exactly:
    //     IP latency (11) + downstream P[79:16] register (1) = 12 cycles.
    logic [95:0]        volume_full_product_l, volume_full_product_r;
    logic signed [63:0] volumed_audio_l_64b,   volumed_audio_r_64b;
    logic               volumed_l_valid,       volumed_r_valid;

    vol_mult_ip u_l_volume_dsp_core (
        .CLK (dsp_clk),
        .A   (fir_l_out_reg),
        .B   (sys_volume),
        .P   (volume_full_product_l)
    );

    vol_mult_ip u_r_volume_dsp_core (
        .CLK (dsp_clk),
        .A   (fir_r_out_reg),
        .B   (sys_volume),
        .P   (volume_full_product_r)
    );

    // Single shared valid pipeline -- both chains have identical latency.
    // Depth = (vol_mult_ip latency) + 1 downstream register = 11 + 1 = 12.
    logic [11:0] vol_valid_pipeline;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_valid_pipeline  <= '0;
            volumed_audio_l_64b <= '0;
            volumed_audio_r_64b <= '0;
        end else begin
            vol_valid_pipeline  <= {vol_valid_pipeline[10:0], fir_l_valid_reg};
            // P width = A(48) + B(32) = 80 bits; extract top 64 for downstream
            volumed_audio_l_64b <= volume_full_product_l[79:16];
            volumed_audio_r_64b <= volume_full_product_r[79:16];
        end
    end

    assign volumed_l_valid = vol_valid_pipeline[11];
    assign volumed_r_valid = vol_valid_pipeline[11];

    // --- Multicycle Holding Registers (one per channel, freezes the value
    //     across the inter-sample dead window of the 357 MHz pipeline) ---
    logic signed [63:0] stable_audio_l_64b, stable_audio_r_64b;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            stable_audio_l_64b <= '0;
            stable_audio_r_64b <= '0;
        end else begin
            if (volumed_l_valid) stable_audio_l_64b <= volumed_audio_l_64b;
            if (volumed_r_valid) stable_audio_r_64b <= volumed_audio_r_64b;
        end
    end

    // --- Hardware TPDF Dither (independent generators for L/R to keep
    //     inter-channel noise uncorrelated -- improves stereo noise floor) ---
    logic [41:0] dither_noise_l, dither_noise_r;

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_l_dither (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (volumed_l_valid),
        .dither_out (dither_noise_l)
    );

    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_r_dither (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (volumed_r_valid),
        .dither_out (dither_noise_r)
    );

    // --- 5th-Order Noise Shapers (one per channel) ---
    logic [8:0]   dem_drive_command_l, dem_drive_command_r;
    logic [255:0] left_resistor_bus, right_resistor_bus;

    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),
        .FRAC_WIDTH (42),
        .OUT_WIDTH  (9)
    ) u_l_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_l_valid),
        .data_in        (stable_audio_l_64b[63:16]),
        .dither_in      (dither_noise_l),
        .dem_drive_out  (dem_drive_command_l)
    );

    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),
        .FRAC_WIDTH (42),
        .OUT_WIDTH  (9)
    ) u_r_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_r_valid),
        .data_in        (stable_audio_r_64b[63:16]),
        .dither_in      (dither_noise_r),
        .dem_drive_out  (dem_drive_command_r)
    );

    // --- DEM Mappers (one per channel; independent randomization)  ---
    dem_mapper #(
        .ARRAY_SIZE(256),  // 128 resistors per leg = 256 bits per channel
        .AMP_WIDTH (9)
    ) u_l_dem_mapper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_l_valid),
        .amplitude_in   (dem_drive_command_l),
        .resistor_out   (left_resistor_bus)
    );

    dem_mapper #(
        .ARRAY_SIZE(256),  // 128 resistors per leg = 256 bits per channel
        .AMP_WIDTH (9)
    ) u_r_dem_mapper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_r_valid),
        .amplitude_in   (dem_drive_command_r),
        .resistor_out   (right_resistor_bus)
    );

    // ==============================================================
    // 5. The 512-Bit Asynchronous Output Boundary
    // ==============================================================
    logic [511:0] cross_domain_bus;
    logic         tx_fifo_empty, tx_fifo_full;
    logic         lvds_tx_read_trigger;

    async_fifo_wide #(
        .DATA_WIDTH(512),
        .ADDR_WIDTH(4)
    ) u_output_fifo (
        .w_clk   (dsp_clk),
        .w_rst_n (sys_rst_n),
        .w_en    (volumed_l_valid), // L and R valids are identical by construction
        .w_data  ({left_resistor_bus, right_resistor_bus}),
        .w_full  (tx_fifo_full),
        
        .r_clk   (lvds_bit_clk),
        .r_rst_n (sys_rst_n),
        .r_en    (lvds_tx_read_trigger),
        .r_data  (cross_domain_bus),
        .r_empty (tx_fifo_empty)
    );

    // ==============================================================
    // 6. LVDS Egress (196.6 MHz Domain)
    // ==============================================================
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

    assign lvds_tx_read_trigger = ~tx_fifo_empty;
    assign relay_audio_out = 1'b1; // Simplified output relay drive (Will trigger synthesis warning)

endmodule