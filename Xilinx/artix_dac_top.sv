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
    // 3. I2S Ingress & Clock Domain Crossing
    // ==============================================================
    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
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

    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(4)) u_async_fifo (
        .w_clk   (i2s_bclk),
        .w_rst_n (sys_rst_n),
        .w_en    (raw_data_valid & ~fifo_full),
        .w_data  (raw_left_data),       
        .w_full  (fifo_full),
        .r_clk   (dsp_clk),
        .r_rst_n (sys_rst_n),
        .r_en    (~fifo_empty),
        .r_data  (safe_audio_data),
        .r_empty (fifo_empty)
    );

    assign new_sample_trigger = ~fifo_empty;

    // ==============================================================
    // 4. The 357 MHz Overclocked DSP Core
    // ==============================================================
    logic signed [47:0] interpolated_audio_48b; // FIXED: Matches internal MAC width
    logic               interpolated_valid;

    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (48) // STRICTLY 48 BITS
    ) u_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (new_sample_trigger),
        .new_sample_data    (safe_audio_data[31:8]),
        .interpolated_out   (interpolated_audio_48b),
        .interpolated_valid (interpolated_valid)
    );

    // --- Boundary Pipelining (Absorbs routing delay from FIR edge) ---
    logic signed [47:0] fir_out_reg;
    logic               fir_valid_reg;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fir_out_reg   <= '0;
            fir_valid_reg <= 1'b0;
        end else begin
            fir_out_reg   <= interpolated_audio_48b;
            fir_valid_reg <= interpolated_valid;
        end
    end

    // --- 64-Bit Volume Multiplier (Xilinx DSP IP - 4 Cycle Latency) ---
    logic [95:0]        volume_full_product; 
    logic signed [63:0] volumed_audio_64b;
    //logic [3:0]         vol_valid_pipeline;
    logic               volumed_valid;

    vol_mult_ip u_volume_dsp_core (
        .CLK (dsp_clk),
        .A   (fir_out_reg),    // Connect to pipeline register
        .B   (sys_volume),
        .P   (volume_full_product)
    );

    // Update the width to match the new latency MINUS 1 (e.g., 6 cycles = [5:0])
    logic [5:0] vol_valid_pipeline; 

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_valid_pipeline <= '0;
            volumed_audio_64b  <= '0;
        end else begin
            // Shift the valid flag to track the IP latency
            vol_valid_pipeline <= {vol_valid_pipeline[4:0], fir_valid_reg}; 
            
            // Note: Since 'A' is now 48 bits, the product 'P' is 48+32 = 80 bits.
            // Adjust the extraction to pull the top 64 bits of the 80-bit product.
            volumed_audio_64b  <= volume_full_product[79:16];
        end
    end

    // Tap the highest bit to trigger the downstream noise shaper
    assign volumed_valid = vol_valid_pipeline[5];   

    // =================================---------------------------------------
    // THE MULTICYCLE HOLDING REGISTER (Isolates 357MHz thrashing)
    // =================================---------------------------------------
    logic signed [63:0] stable_audio_64b;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            stable_audio_64b <= '0;
        end else if (volumed_valid) begin
            // Capture the valid audio and freeze it for 127 cycles
            stable_audio_64b <= volumed_audio_64b;
        end
    end

    // --- Hardware TPDF Dither ---
    logic [41:0] dither_noise;
    
    tpdf_dither_gen #(.DITHER_WIDTH(42)) u_dither (
        .clk        (dsp_clk),
        .rst_n      (sys_rst_n),
        .enable     (volumed_valid),
        .dither_out (dither_noise)
    );

    // --- 5th-Order Modulator Routing ---
    logic [8:0] dem_drive_command;
    logic [255:0] left_resistor_bus;
    logic [255:0] right_resistor_bus;

    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),   // Catch the top 48 bits of the 64-bit accumulator
        .FRAC_WIDTH(42),
        .OUT_WIDTH(9)
    ) u_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .data_in        (stable_audio_64b[63 : 16]), // Pass stable frozen data safely
        .dither_in      (dither_noise),
        .dem_drive_out  (dem_drive_command)
    );

    // --- DEM Mapper ---
    dem_mapper #(
        .ARRAY_SIZE(256),  // 128 resistors per leg = 256 bits per channel
        .AMP_WIDTH(9)      
    ) u_dem_mapper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .amplitude_in   (dem_drive_command),
        .resistor_out   (left_resistor_bus) 
    );

    // Duplicate Left to Right for testing until dual-channel logic is fully implemented
    assign right_resistor_bus = left_resistor_bus;

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
        .w_en    (volumed_valid),
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