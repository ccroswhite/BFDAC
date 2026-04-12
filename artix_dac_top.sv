`timescale 1ns / 1ps

module artix_dac_top (
    // External Physical Pin I/O (Dual Crystek Master Clocks)
    input  logic        clk_45m_p, // 45.1584 MHz (44.1k family)
    input  logic        clk_45m_n,
    input  logic        clk_49m_p, // 49.152 MHz (48k family)
    input  logic        clk_49m_n,
    input  logic        ext_rst_n,

    // ARM SPI Interface (Administrative control plane)
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Hardware Control & Sensing Plane
    input  logic [3:0]  blade_detect_pins, // Reads which DIMM slots are populated
    output logic        relay_iv_filter,   // Switches OPA1632 feedback network
    output logic        relay_gain_6v,     // Switches OPA827/BUF634A to direct-drive

    // Moat I2S Interface (Physical external boundary audio in)
    input  logic        i2s_bclk,
    input  logic        i2s_lrclk,
    input  logic        i2s_data,

    // High-Speed LVDS Outputs to Converter Blades (8 Data + 1 Strobe)
    output logic [8:0]  lvds_tx_p,
    output logic [8:0]  lvds_tx_n
);

    // ==============================================================
    // Internal Clock & Reset Nets
    // ==============================================================
    logic dsp_clk;         // Master DSP domain (e.g., ~98 MHz)
    logic lvds_bit_clk;    // High-speed serial shift clock (e.g., ~393 MHz)
    logic lvds_frame_clk;  // Parallel load clock
    logic clk_locked;
    
    logic sys_rst_n;       // Safe Data-Path Reset

    // Only allow audio data to flow when the MMCM is perfectly locked
    assign sys_rst_n = ext_rst_n & clk_locked;

    // ==============================================================
    // Internal Structural Data Nets
    // ==============================================================
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    
    // SPI Decoded Registers (Control Domain)
    logic [31:0] sys_volume;
    logic        cmd_gain_6v;
    logic        base_rate_sel; 

    // Data Plane Nets (Data Domain)
    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty, fifo_read_en;
    logic [31:0] volumed_audio_data;
    logic        volumed_audio_valid;
    logic [5:0]  noise_shaped_audio;
    logic        dsp_audio_valid;
    logic [63:0] resistor_ring_bus; 
    logic [8191:0] flattened_coef_bus;
    logic [31:0]   fir_sample_bus;
    logic [63:0]   fir_acc_in_bus, fir_acc_out_bus;

    // ==============================================================
    // Clock Generation (Glitch-Free Dual Oscillator Mux)
    // ==============================================================
    sys_clock_gen u_clk_gen (
        .clk_45m_p      (clk_45m_p),
        .clk_45m_n      (clk_45m_n),
        .clk_49m_p      (clk_49m_p),
        .clk_49m_n      (clk_49m_n),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel), // Driven by SPI
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .locked         (clk_locked)
    );
    
    // Note: OSERDES logic uses the dsp_clk as the frame clock.
    assign lvds_frame_clk = dsp_clk;

    // ==============================================================
    // Control Plane: SPI Slave & Register Decoder
    // Uses ext_rst_n ONLY so registers survive the clock switch.
    // ==============================================================
    spi_slave #(
        .WORD_WIDTH(32) 
    ) u_spi_slave (
        .clk        (dsp_clk),
        .rst_n      (ext_rst_n), 
        .spi_sclk   (spi_sclk),
        .spi_cs_n   (spi_cs_n),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso),
        .data_out   (ctrl_bus_data),
        .data_valid (ctrl_bus_valid)
    );

    // Command Decoder & Hardware Actuator
    always_ff @(posedge dsp_clk or negedge ext_rst_n) begin
        if (!ext_rst_n) begin
            sys_volume    <= 32'hFFFFFFFF; 
            cmd_gain_6v   <= 1'b0;
            relay_gain_6v <= 1'b0;
            base_rate_sel <= 1'b1; // Default to 48k family (49.152MHz)
        end else if (ctrl_bus_valid) begin
            case (ctrl_bus_data[31:24])
                8'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]}; // Volume Command
                8'h02: cmd_gain_6v   <= ctrl_bus_data[0];             // Gain Command
                8'h03: base_rate_sel <= ctrl_bus_data[0];             // 0=45MHz, 1=49MHz
            endcase
            relay_gain_6v <= cmd_gain_6v; 
        end
    end

    always_comb begin
        if (blade_detect_pins > 4'b0001) relay_iv_filter = 1'b1;
        else                             relay_iv_filter = 1'b0;
    end

    // ==============================================================
    // Audio Ingress Plane: I2S Decoder Receiver
    // Muted immediately if sys_rst_n goes low
    // ==============================================================
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

    // ==============================================================
    // Asynchronous CDC Isolation Moat
    // ==============================================================
    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(4)) u_async_fifo (
        .w_clk      (i2s_bclk),
        .w_rst_n    (sys_rst_n),
        .w_en       (raw_data_valid & ~fifo_full),
        .w_data     (raw_left_data), 
        .w_full     (fifo_full),

        .r_clk      (dsp_clk),
        .r_rst_n    (sys_rst_n), 
        .r_en       (~fifo_empty), 
        .r_data     (safe_audio_data),
        .r_empty    (fifo_empty)
    );
    
    always_ff @(posedge dsp_clk) fifo_read_en <= ~fifo_empty;

    // ==============================================================
    // --- DSP PIPELINE --- 
    // (All blocks use sys_rst_n to flush during clock switch)
    // ==============================================================
    
    volume_multiplier #(.DATA_WIDTH(32)) u_vol_mult (
        .clk             (dsp_clk),
        .rst_n           (sys_rst_n),
        .volume_coef     (sys_volume),
        .audio_in        (safe_audio_data),
        .audio_valid_in  (fifo_read_en),
        .audio_out       (volumed_audio_data),
        .audio_valid_out (volumed_audio_valid)
    );

    dsp_master_ctrl #(
        .DATA_WIDTH(32), .NUM_MACS(256), .OVERSAMPLE_RATIO(5120)
    ) u_dsp_master (
        .clk              (dsp_clk),
        .rst_n            (sys_rst_n),
        .new_sample_valid (volumed_audio_valid),
        .new_sample_data  (volumed_audio_data),
        .fir_sample_in    (fir_sample_bus),
        .fir_acc_in       (fir_acc_in_bus),
        .fir_acc_out      (fir_acc_out_bus),
        .dsp_audio_out    (noise_shaped_audio),
        .dsp_audio_valid  (dsp_audio_valid)
    );
    
    coef_bram #(.NUM_COEFS(256), .COEF_WIDTH(32)) u_coef_ram (
        .clka  (dsp_clk), .wea (1'b0), .addra ('0), .dina ('0),
        .clkb  (dsp_clk), .enb (1'b1), .doutb (flattened_coef_bus)
    );

    fir_systolic_array #(
        .NUM_MACS(256), .DATA_WIDTH(32), .COEF_WIDTH(32), .ACC_WIDTH(64)
    ) u_fir_array (
        .clk         (dsp_clk),
        .rst_n       (sys_rst_n),
        .sample_in   (fir_sample_bus),
        .acc_in      (fir_acc_in_bus),
        .coef_bus_in (flattened_coef_bus),
        .sample_out  (), 
        .acc_out     (fir_acc_out_bus)
    );

    dem_mapper #(
        .RESISTOR_COUNT(64), 
        .AMP_WIDTH     (6)
    ) u_dem_mapper (
        .clk          (dsp_clk),
        .rst_n        (sys_rst_n),
        .enable       (dsp_audio_valid),
        .amplitude_in (noise_shaped_audio),
        .resistor_out (resistor_ring_bus)
    );

    // ==============================================================
    // High-Speed LVDS Output Serializer 
    // ==============================================================
    lvds_tx_serializer u_lvds_tx (
        .bit_clk        (lvds_bit_clk),
        .frame_clk      (lvds_frame_clk),
        .rst_n          (sys_rst_n),
        .data_in_64     (resistor_ring_bus),
        .lvds_tx_p      (lvds_tx_p),
        .lvds_tx_n      (lvds_tx_n)
    );

endmodule