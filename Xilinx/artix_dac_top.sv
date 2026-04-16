`timescale 1ns / 1ps

module artix_dac_top (
    // 3.3V Domain (Single-Ended Clocks per XDC)
    input  logic       clk_45m, 
    input  logic       clk_49m, 
    input  logic       ext_rst_n,

    // ARM SPI Interface
    input  logic       spi_sclk,
    input  logic       spi_cs_n,
    input  logic       spi_mosi,
    output logic       spi_miso,

    // Hardware Control & Sensing Plane
    input  logic [7:0] blade_detect_pins, 
    output logic       relay_iv_filter,   
    output logic       relay_gain_6v,     

    // Moat I2S Interface 
    input  logic       i2s_bclk,
    input  logic       i2s_lrclk,
    input  logic       i2s_data,

    // HyperRAM Interface
    output logic       hyper_ck,
    output logic       hyper_cs_n,
    inout  logic       hyper_rwds,
    inout  logic [7:0] hyper_dq,
    output logic       hyper_reset_n,

    // High-Speed LVDS Outputs to 8 Converter Blades
    output logic [7:0] lvds_data_p,
    output logic [7:0] lvds_data_n,
    output logic [7:0] lvds_clk_p,
    output logic [7:0] lvds_clk_n,
    output logic [7:0] lvds_frame_p,
    output logic [7:0] lvds_frame_n
);

    // ==============================================================
    // Clock & Reset Nets
    // ==============================================================
    logic dsp_clk;         
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
    logic        spi_crc_error;
    logic [31:0] sys_volume;
    logic        cmd_gain_6v;
    logic        base_rate_sel; 

    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty, fifo_read_en;
    logic [31:0] volumed_audio_data;
    logic        volumed_audio_valid;
    logic        volumed_clip_detect;

    logic signed [47:0] interpolated_audio_48b; 
    logic               interpolated_valid;
    logic [5:0]         dem_drive_command;
    logic [63:0]        resistor_ring_bus; 

    // ==============================================================
    // FPGA Heartbeat
    // ==============================================================
    logic [31:0] fpga_heartbeat;
    
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) fpga_heartbeat <= '0;
        else            fpga_heartbeat <= fpga_heartbeat + 1'b1;
    end

    // ==============================================================
    // Thermal State (XADC)
    // ==============================================================
    logic [15:0] xadc_do;
    logic        xadc_drdy;
    logic        xadc_eoc;
    logic [15:0] fpga_temp_raw;

    XADC u_xadc (
        .DADDR   (7'h00),      // 0x00 = Die Temperature Sensor
        .DCLK    (dsp_clk),    // DRP Clock
        .DEN     (xadc_eoc),   // Read when conversion finishes
        .DI      (16'h0000),
        .DWE     (1'b0),
        .RESET   (~sys_rst_n),
        .VAUXN   (16'h0000),
        .VAUXP   (16'h0000),
        .VN      (1'b0),
        .VP      (1'b0),
        .DO      (xadc_do),
        .DRDY    (xadc_drdy),
        .EOC     (xadc_eoc),
        .ALM     (),
        .BUSY    (),
        .CHANNEL (),
        .EOS     (),
        .JTAGBUSY(),
        .JTAGLOCKED(),
        .JTAGMODIFIED(),
        .OT      (),
        .MUXADDR ()
    );

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) fpga_temp_raw <= '0;
        else if (xadc_drdy) fpga_temp_raw <= xadc_do;
    end

    // ==============================================================
    // I2S Framing Integrity Check (i2s_bclk Domain)
    // ==============================================================
    logic [6:0] bclk_counter;
    logic       i2s_lrclk_q;
    logic       frame_err_raw;
    logic       i2s_synced; 

    always_ff @(posedge i2s_bclk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            bclk_counter  <= '0;
            i2s_lrclk_q   <= 1'b0;
            frame_err_raw <= 1'b0;
            i2s_synced    <= 1'b0;
        end else begin
            i2s_lrclk_q   <= i2s_lrclk;
            frame_err_raw <= 1'b0; 

            // Check exactly 64 BCLKs on the rising edge of LRCLK (Start of frame)
            if (i2s_lrclk_q == 1'b0 && i2s_lrclk == 1'b1) begin
                if (i2s_synced && (bclk_counter != 7'd64)) begin
                    frame_err_raw <= 1'b1;
                end
                bclk_counter <= 7'd1; 
                i2s_synced   <= 1'b1; 
            end else begin
                // Prevent counter overflow
                if (bclk_counter < 7'd127) bclk_counter <= bclk_counter + 7'd1;
            end
        end
    end

    // CDC: Bring 3MHz frame error pulse safely into 90MHz DSP domain
    (* ASYNC_REG = "TRUE" *) logic [1:0] frame_err_sync;
    always_ff @(posedge dsp_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) frame_err_sync <= 2'b00;
        else            frame_err_sync <= {frame_err_sync[0], frame_err_raw};
    end

    // ==============================================================
    // Status & Error Logic (DSP Domain)
    // ==============================================================
    logic       err_fifo_overflow, err_fifo_underflow, err_clk_unlock;
    logic       err_audio_clip, err_i2s_frame;
    logic [7:0] spi_comms_err_count;
    logic [1:0] lrclk_sync;
    logic [15:0] lrclk_counter;
    logic [15:0] last_lrclk_count;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;

    // Sticky Error Trapping & Sample Rate Counter
    always_ff @(posedge dsp_clk) begin
        if (!ext_rst_n) begin
            err_fifo_overflow   <= 1'b0;
            err_fifo_underflow  <= 1'b0;
            err_clk_unlock      <= 1'b0;
            err_audio_clip      <= 1'b0;
            err_i2s_frame       <= 1'b0;
            spi_comms_err_count <= '0;
            lrclk_sync          <= 2'b00;
            lrclk_counter       <= '0;
            last_lrclk_count    <= '0;
        end else begin
            // Track Flow, Comms, and Frame Errors
            if (fifo_full)  err_fifo_overflow  <= 1'b1;
            if (fifo_empty) err_fifo_underflow <= 1'b1;
            if (!clk_locked) err_clk_unlock    <= 1'b1;
            if (spi_crc_error) spi_comms_err_count <= spi_comms_err_count + 1'b1;
            if (frame_err_sync[1]) err_i2s_frame <= 1'b1;

            // Track Audio Saturation (DSP Math Clip OR 0dBFS Source Clip)
            if (volumed_clip_detect) err_audio_clip <= 1'b1;
            if (raw_data_valid && (raw_left_data == 32'h7FFFFFFF || raw_left_data == 32'h80000000)) begin
                err_audio_clip <= 1'b1;
            end

            // Clear Errors on SPI Read 
            if (ctrl_bus_valid && ctrl_bus_data[31]) begin
                if (ctrl_bus_data[30:24] == 7'h13) begin
                    err_fifo_overflow  <= 1'b0;
                    err_fifo_underflow <= 1'b0;
                    err_clk_unlock     <= 1'b0;
                end
                if (ctrl_bus_data[30:24] == 7'h15) spi_comms_err_count <= '0;
                if (ctrl_bus_data[30:24] == 7'h16) err_audio_clip      <= 1'b0;
                if (ctrl_bus_data[30:24] == 7'h17) err_i2s_frame       <= 1'b0;
            end

            // Measure I2S Sample Rate
            lrclk_sync <= {lrclk_sync[0], i2s_lrclk};
            if (lrclk_sync == 2'b01) begin // Rising Edge
                last_lrclk_count <= lrclk_counter;
                lrclk_counter    <= 16'd1;
            end else begin
                lrclk_counter <= lrclk_counter + 16'd1;
            end
        end
    end

    // SPI Read/Write Command Decoder
    always_ff @(posedge dsp_clk) begin
        if (!ext_rst_n) begin
            sys_volume    <= 32'hFFFFFFFF; 
            cmd_gain_6v   <= 1'b0;
            relay_gain_6v <= 1'b0;
            base_rate_sel <= 1'b0; 
            read_addr_reg <= 7'h00;
        end else if (ctrl_bus_valid) begin
            if (ctrl_bus_data[31] == 1'b0) begin 
                // WRITE OPERATION (Bit 31 = 0)
                case (ctrl_bus_data[30:24])
                    7'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]};
                    7'h02: cmd_gain_6v   <= ctrl_bus_data[0];             
                    7'h03: base_rate_sel <= ctrl_bus_data[0];             
                endcase
                relay_gain_6v <= cmd_gain_6v; 
            end else begin
                // READ OPERATION (Bit 31 = 1)
                read_addr_reg <= ctrl_bus_data[30:24];
            end
        end
    end

    // SPI Read Output MUX
    always_comb begin
        case (read_addr_reg)
            7'h10: spi_tx_data = 32'hDAC02026; // Magic ID for firmware confirmation
            7'h11: spi_tx_data = {24'd0, blade_detect_pins}; // Connected Converter Blades
            7'h12: spi_tx_data = {29'd0, relay_iv_filter, base_rate_sel, relay_gain_6v}; // Hardware Config
            7'h13: spi_tx_data = {29'd0, err_clk_unlock, err_fifo_underflow, err_fifo_overflow}; // Audio Flow Errors
            7'h14: spi_tx_data = {16'd0, last_lrclk_count}; // DSP Clocks per Audio Frame (Rate Est)
            7'h15: spi_tx_data = {24'd0, spi_comms_err_count}; // SPI Data Integrity Failures
            7'h16: spi_tx_data = {31'd0, err_audio_clip}; // DSP Math Clipping / 0dBFS Hit
            7'h17: spi_tx_data = {31'd0, err_i2s_frame}; // I2S Framing Out-of-Sync
            7'h18: spi_tx_data = {16'd0, fpga_temp_raw}; // XADC Die Temperature
            7'h19: spi_tx_data = fpga_heartbeat; // FPGA Heartbeat Counter
            default: spi_tx_data = 32'hDEADBEEF; 
        endcase
    end

    assign relay_iv_filter = (blade_detect_pins > 8'd1) ? 1'b1 : 1'b0;

    // ==============================================================
    // Module Instantiations
    // ==============================================================
    sys_clock_gen u_clk_gen (
        .clk_45m        (clk_45m),
        .clk_49m        (clk_49m),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .locked         (clk_locked)
    );
    
    spi_slave u_spi_slave (
        .clk           (dsp_clk),   
        .rst_n         (ext_rst_n), 
        .spi_sclk      (spi_sclk),  
        .spi_cs_n      (spi_cs_n),
        .spi_mosi      (spi_mosi),  
        .spi_miso      (spi_miso),
        .tx_data_in    (spi_tx_data),   
        .data_out      (ctrl_bus_data), 
        .data_valid    (ctrl_bus_valid),
        .crc_err_pulse (spi_crc_error)
    );

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

    volume_multiplier #(.DATA_WIDTH(32)) u_vol_mult (
        .clk             (dsp_clk),
        .rst_n           (sys_rst_n),
        .volume_coef     (sys_volume),
        .audio_in        (safe_audio_data),
        .audio_valid_in  (fifo_read_en),
        .audio_out       (volumed_audio_data),
        .audio_valid_out (volumed_audio_valid),
        .audio_clip_out  (volumed_clip_detect) 
    );

    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (48)  
    ) u_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (volumed_audio_valid),
        .new_sample_data    (volumed_audio_data[31:8]), 
        .interpolated_out   (interpolated_audio_48b),
        .interpolated_valid (interpolated_valid)
    );

    localparam int FIR_GAIN_SHIFT = 16; 
    
    noise_shaper_2nd_order #(
        .INPUT_WIDTH(32), .FRAC_WIDTH(26)
    ) u_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (interpolated_valid),
        .data_in        (interpolated_audio_48b[FIR_GAIN_SHIFT + 31 : FIR_GAIN_SHIFT]),
        .dem_drive_out  (dem_drive_command)
    );

    dem_mapper #(
        .ARRAY_SIZE(32), .AMP_WIDTH(6)
    ) u_dem_mapper (
        .clk          (dsp_clk),
        .rst_n        (sys_rst_n),
        .enable       (interpolated_valid),
        .amplitude_in (dem_drive_command),
        .resistor_out (resistor_ring_bus)
    );

    logic interpolated_valid_q;
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) interpolated_valid_q <= 1'b0;
        else            interpolated_valid_q <= interpolated_valid;
    end

    lvds_blade_tx u_lvds_tx (
        .bit_clk        (lvds_bit_clk),    
        .rst_n          (sys_rst_n),
        .data_in_64     (resistor_ring_bus),
        .data_valid     (interpolated_valid | interpolated_valid_q), 
        .lvds_data_p    (lvds_data_p),
        .lvds_data_n    (lvds_data_n),
        .lvds_clk_p     (lvds_clk_p),
        .lvds_clk_n     (lvds_clk_n),
        .lvds_frame_p   (lvds_frame_p),
        .lvds_frame_n   (lvds_frame_n)
    );

    assign hyper_ck = 1'b0;
    assign hyper_cs_n = 1'b1;
    assign hyper_reset_n = 1'b1;

endmodule