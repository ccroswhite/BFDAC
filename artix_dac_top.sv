`timescale 1ns / 1ps

module artix_dac_top (
    // External Physical Pin I/O System (Differential VCXO Master)
    input  logic       sys_clk_p,
    input  logic       sys_clk_n,
    input  logic       ext_rst_n,

    // ARM SPI Interface (Administrative control plane)
    input  logic       spi_sclk,
    input  logic       spi_cs_n,
    input  logic       spi_mosi,
    output logic       spi_miso,

    // Moat I2S Interface (Physical external boundary audio in)
    input  logic       i2s_bclk,
    input  logic       i2s_lrclk,
    input  logic       i2s_data,

    // High-Speed LVDS Outputs to Output Buffers/DIMMs
    output logic [7:0] lvds_tx_p,
    output logic [7:0] lvds_tx_n
);

    // ==============================================================
    // Internal Clock Nets (Targeted from generalized internal MMCM)
    // ==============================================================
    logic dsp_clk;

    // ==============================================================
    // Internal Structural Data Nets
    // ==============================================================
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    
    // SPI Decoded Registers
    logic [31:0] sys_volume;

    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;

    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty;
    logic        fifo_read_en;
    
    // DSP Pipeline Nets
    logic [31:0] volumed_audio_data;
    logic        volumed_audio_valid;
    
    logic [5:0]  noise_shaped_audio;
    logic        dsp_audio_valid;
    
    logic [47:0] resistor_ring_bus;
    
    // FIR & BRAM Nets
    logic [8191:0] flattened_coef_bus;
    logic [31:0]   fir_sample_bus;
    logic [63:0]   fir_acc_in_bus, fir_acc_out_bus;

    // ==============================================================
    // Control Plane: SPI Slave & Register Decoder
    // ==============================================================
    spi_slave #(
        .WORD_WIDTH(32) // Upgraded to 32-bit for volume fractions
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

    // Simple SPI Command Decoder (Example: Top 8 bits = Address)
    always_ff @(posedge dsp_clk or negedge ext_rst_n) begin
        if (!ext_rst_n) begin
            sys_volume <= 32'hFFFFFFFF; // Default to 100% Volume
        end else if (ctrl_bus_valid) begin
            if (ctrl_bus_data[31:24] == 8'h01) begin // Address 0x01 = Volume Command
                sys_volume <= {8'h00, ctrl_bus_data[23:0]}; // Latch new volume
            end
        end
    end

    // ==============================================================
    // Audio Ingress Plane: I2S Decoder Receiver
    // ==============================================================
    i2s_rx #(
        .DATA_WIDTH(32)
    ) u_i2s_rx (
        .clk        (dsp_clk),
        .rst_n      (ext_rst_n),
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
    async_fifo #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(4)
    ) u_async_fifo (
        .w_clk      (i2s_bclk),
        .w_rst_n    (ext_rst_n),
        .w_en       (raw_data_valid & ~fifo_full),
        .w_data     (raw_left_data), // Hardcoded left channel for single-channel DIMM
        .w_full     (fifo_full),

        .r_clk      (dsp_clk),
        .r_rst_n    (ext_rst_n),
        .r_en       (~fifo_empty), 
        .r_data     (safe_audio_data),
        .r_empty    (fifo_empty)
    );
    
    // Create a single-cycle valid pulse when the FIFO successfully reads
    always_ff @(posedge dsp_clk) begin
        fifo_read_en <= ~fifo_empty;
    end

    // ==============================================================
    // --- DSP PIPELINE ---
    // ==============================================================
    
    // 1. Digital Volume Attenuation
    volume_multiplier #(
        .DATA_WIDTH(32)
    ) u_vol_mult (
        .clk             (dsp_clk),
        .rst_n           (ext_rst_n),
        .volume_coef     (sys_volume),
        .audio_in        (safe_audio_data),
        .audio_valid_in  (fifo_read_en),
        .audio_out       (volumed_audio_data),
        .audio_valid_out (volumed_audio_valid)
    );

    // 2. The Brain: Master Memory & Array Controller
    dsp_master_ctrl #(
        .DATA_WIDTH(32),
        .NUM_MACS(256),
        .OVERSAMPLE_RATIO(5120)
    ) u_dsp_master (
        .clk              (dsp_clk),
        .rst_n            (ext_rst_n),
        .new_sample_valid (volumed_audio_valid),
        .new_sample_data  (volumed_audio_data),
        
        // DMA Interface (Stubbed for now, connects to MIG later)
        // .dma_wr_req(), .dma_rd_req(), .dma_addr(), .dma_wr_data(),
        // .dma_rd_data(), .dma_rd_valid(), .dma_busy(),
        
        // FIR Interface
        .fir_sample_in    (fir_sample_bus),
        .fir_acc_in       (fir_acc_in_bus),
        .fir_acc_out      (fir_acc_out_bus),
        
        // Output Interface
        .dsp_audio_out    (noise_shaped_audio),
        .dsp_audio_valid  (dsp_audio_valid)
    );
    
    // 3. Coefficient BRAM
    coef_bram #(
        .NUM_COEFS(256),
        .COEF_WIDTH(32)
    ) u_coef_ram (
        // SPI will eventually write to this Port A
        .clka  (dsp_clk),
        .wea   (1'b0), // Tied low until SPI logic is fully implemented
        .addra ('0),
        .dina  ('0),
        
        // DSP Read Port B
        .clkb  (dsp_clk),
        .enb   (1'b1), // Always enabled for the array
        .doutb (flattened_coef_bus)
    );

    // 4. The 1-Million Tap Systolic Array
    fir_systolic_array #(
        .NUM_MACS(256),
        .DATA_WIDTH(32),
        .COEF_WIDTH(32),
        .ACC_WIDTH(64)
    ) u_fir_array (
        .clk         (dsp_clk),
        .rst_n       (ext_rst_n),
        .sample_in   (fir_sample_bus),
        .acc_in      (fir_acc_in_bus),
        .coef_bus_in (flattened_coef_bus),
        .sample_out  (), // Floating, absorbed by final MAC
        .acc_out     (fir_acc_out_bus)
    );

    // 5. Dynamic Element Matching Load Balancer Array
    dem_mapper #(
        .RESISTOR_COUNT(48),
        .AMP_WIDTH     (6)
    ) u_dem_mapper (
        .clk          (dsp_clk),
        .rst_n        (ext_rst_n),
        .enable       (dsp_audio_valid),
        .amplitude_in (noise_shaped_audio),
        .resistor_out (resistor_ring_bus)
    );

    // ==============================================================
    // LVDS Output Physical Mapping
    // ==============================================================
    genvar i;
    generate
        for (i = 0; i < 8; i++) begin : lvds_buffers
            OBUFDS u_lvds_buf (
                .I  (resistor_ring_bus[i]), 
                .O  (lvds_tx_p[i]),         
                .OB (lvds_tx_n[i])          
            );
        end
    endgenerate

endmodule