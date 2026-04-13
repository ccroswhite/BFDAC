`timescale 1ns / 1ps

module artix_dac_top (
    // External Physical Pin I/O (Dual Crystek Master Clocks)
    input  logic        clk_45m_p, 
    input  logic        clk_45m_n,
    input  logic        clk_49m_p, 
    input  logic        clk_49m_n,
    input  logic        ext_rst_n,

    // ARM SPI Interface
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Hardware Control & Sensing Plane
    input  logic [3:0]  blade_detect_pins, 
    output logic        relay_iv_filter,   
    output logic        relay_gain_6v,     

    // Moat I2S Interface 
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // High-Speed LVDS Outputs to 8 Converter Blades (Data, Clock, Frame)
    output logic [7:0]  lvds_data_p,
    output logic [7:0]  lvds_data_n,
    output logic [7:0]  lvds_clk_p,
    output logic [7:0]  lvds_clk_n,
    output logic [7:0]  lvds_frame_p,
    output logic [7:0]  lvds_frame_n
    
);

    // ==============================================================
    // Clock & Reset Nets
    // ==============================================================
    logic dsp_clk;         // DSP domain (Now exactly 90.3168 MHz or 98.304 MHz)
    logic lvds_bit_clk;    
    logic lvds_frame_clk;  
    logic clk_locked;
    logic sys_rst_n;       

    assign sys_rst_n = ext_rst_n & clk_locked;
    assign lvds_frame_clk = dsp_clk;

    // ==============================================================
    // Control & Data Nets
    // ==============================================================
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic [31:0] sys_volume;
    logic        cmd_gain_6v;
    logic        base_rate_sel; 

    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty, fifo_read_en;
    logic [31:0] volumed_audio_data;
    logic        volumed_audio_valid;

    // New Super-DSP Nets
    logic signed [47:0] interpolated_audio_48b; // FIXED: Now 48 bits
    logic               interpolated_valid;
    logic [5:0]         dem_drive_command;
    logic [63:0]        resistor_ring_bus; 

    // ==============================================================
    // Clock Generation & SPI Control Plane
    // ==============================================================
    sys_clock_gen u_clk_gen (
        .clk_45m_p      (clk_45m_p),     .clk_45m_n      (clk_45m_n),
        .clk_49m_p      (clk_49m_p),     .clk_49m_n      (clk_49m_n),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .locked         (clk_locked)
    );
    
    spi_slave #(.WORD_WIDTH(32)) u_spi_slave (
        .clk        (dsp_clk),   .rst_n      (ext_rst_n), 
        .spi_sclk   (spi_sclk),  .spi_cs_n   (spi_cs_n),
        .spi_mosi   (spi_mosi),  .spi_miso   (spi_miso),
        .data_out   (ctrl_bus_data), .data_valid (ctrl_bus_valid)
    );

    always_ff @(posedge dsp_clk or negedge ext_rst_n) begin
        if (!ext_rst_n) begin
            sys_volume    <= 32'hFFFFFFFF; 
            cmd_gain_6v   <= 1'b0;
            relay_gain_6v <= 1'b0;
            base_rate_sel <= 1'b0; // Default to 45MHz (44.1k family)
        end else if (ctrl_bus_valid) begin
            case (ctrl_bus_data[31:24])
                8'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]};
                8'h02: cmd_gain_6v   <= ctrl_bus_data[0];             
                8'h03: base_rate_sel <= ctrl_bus_data[0];             
            endcase
            relay_gain_6v <= cmd_gain_6v; 
        end
    end

    assign relay_iv_filter = (blade_detect_pins > 4'b0001) ? 1'b1 : 1'b0;

    // ==============================================================
    // Audio Ingress & Asynchronous Moat
    // ==============================================================
    i2s_rx #(.DATA_WIDTH(32)) u_i2s_rx (
        .clk        (dsp_clk),   .rst_n      (sys_rst_n), 
        .i2s_bclk   (i2s_bclk),  .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (raw_left_data),
        .right_data (raw_right_data),
        .data_valid (raw_data_valid)
    );

    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(4)) u_async_fifo (
        .w_clk      (i2s_bclk),  .w_rst_n    (sys_rst_n),
        .w_en       (raw_data_valid & ~fifo_full),
        .w_data     (raw_left_data), // Processing Left channel only for this instantiation
        .w_full     (fifo_full),
        .r_clk      (dsp_clk),   .r_rst_n    (sys_rst_n), 
        .r_en       (~fifo_empty), 
        .r_data     (safe_audio_data),
        .r_empty    (fifo_empty)
    );
    always_ff @(posedge dsp_clk) fifo_read_en <= ~fifo_empty;

    // ==============================================================
    // --- THE SUPER-DSP PIPELINE --- 
    // ==============================================================
    
    // 1. 32-Bit Volume Control with Symmetric Rounding
    volume_multiplier #(.DATA_WIDTH(32)) u_vol_mult (
        .clk             (dsp_clk),
        .rst_n           (sys_rst_n),
        .volume_coef     (sys_volume),
        .audio_in        (safe_audio_data),
        .audio_valid_in  (fifo_read_en),
        .audio_out       (volumed_audio_data),
        .audio_valid_out (volumed_audio_valid)
    );

    // 2. The 1-Million Tap Folded Polyphase Interpolator (16x Upsampling)
    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (48)  // LOCKED to DSP48E1 Hardware Limit
    ) u_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (volumed_audio_valid),
        .new_sample_data    (volumed_audio_data[31:8]), 
        .interpolated_out   (interpolated_audio_48b), // Catch the 48-bit word
        .interpolated_valid (interpolated_valid)
    );

    // 3. The 2nd-Order Digital Delta-Sigma Modulator
    // Extract the top 32 bits from the 48-bit accumulator. 
    // Shift = 48 (total) - 32 (needed) = 16.
    localparam int FIR_GAIN_SHIFT = 16; 
    
    noise_shaper_2nd_order #(
        .INPUT_WIDTH(32), .FRAC_WIDTH(26)
    ) u_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (interpolated_valid),
        // FIXED: Now listening to the 48b wire, safely slicing bits [47:16]
        .data_in        (interpolated_audio_48b[FIR_GAIN_SHIFT + 31 : FIR_GAIN_SHIFT]),
        .dem_drive_out  (dem_drive_command) // The physical 0-32 command
    );

    // 4. The Galois LFSR Dynamic Element Matcher
    dem_mapper #(
        .ARRAY_SIZE(32), .AMP_WIDTH(6)
    ) u_dem_mapper (
        .clk          (dsp_clk),
        .rst_n        (sys_rst_n),
        .enable       (interpolated_valid),
        .amplitude_in (dem_drive_command),
        .resistor_out (resistor_ring_bus)   // 32-Hot / 32-Cold differential output
    );

    // ==============================================================
    // High-Speed LVDS Egress to 8 DIMM Blades
    // ==============================================================
    lvds_blade_tx u_lvds_tx (
        .bit_clk        (lvds_bit_clk),    // Natively 45.1584 MHz or 49.152 MHz
        .rst_n          (sys_rst_n),
        
        .data_in_64     (resistor_ring_bus),
        .data_valid     (interpolated_valid), // 705.6 kHz pulse from the FIR
        
        .lvds_data_p    (lvds_data_p),
        .lvds_data_n    (lvds_data_n),
        .lvds_clk_p     (lvds_clk_p),
        .lvds_clk_n     (lvds_clk_n),
        .lvds_frame_p   (lvds_frame_p),
        .lvds_frame_n   (lvds_frame_n)
    );

endmodule