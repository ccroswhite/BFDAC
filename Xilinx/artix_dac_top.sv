`timescale 1ns / 1ps

module artix_dac_top (
    // 3.3V Domain (Single-Ended Clocks per XDC)
    input  logic       clk_45m, 
    input  logic       clk_49m, 
    input  logic       ext_rst_n,

    // ARM SPI Interface (Control Plane)
    input  logic       spi_sclk,
    input  logic       spi_cs_n,
    input  logic       spi_mosi,
    output logic       spi_miso,

    // Dedicated Flash SPI Interface (Storage Plane)
    output logic       qspi_cs_n,
    output logic       qspi_mosi,
    input  logic       qspi_miso,

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
    // STARTUPE2 Primitive (Hijack CCLK for Flash Bridge)
    // ==============================================================
    logic internal_flash_clk;
    
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) u_startup (
        .CFGCLK     (),
        .CFGMCLK    (),
        .EOS        (),
        .PREQ       (),
        .CLK        (1'b0),
        .GSR        (1'b0),
        .GTS        (1'b0),
        .KEYCLEARB  (1'b1),
        .PACK       (1'b0),
        .USRCCLKO   (internal_flash_clk), // Driven by flash_bridge.sv
        .USRCCLKTS  (1'b0),               // 0 = Enable CCLK output
        .USRDONEO   (1'b1),
        .USRDONETS  (1'b1)
    );

    // ==============================================================
    // Control & Data Nets
    // ==============================================================
    logic [31:0] ctrl_bus_data;
    logic        ctrl_bus_valid;
    logic        spi_crc_error;
    logic [31:0] sys_volume;
    logic        cmd_gain_6v;
    logic        base_rate_sel; 

    // Flash Control Nets
    logic [7:0]  flash_cmd_opcode;
    logic [23:0] flash_cmd_addr;
    logic        flash_cmd_trigger;
    logic        flash_busy;
    logic [7:0]  flash_fifo_wdata;
    logic        flash_fifo_we;
    logic [7:0]  flash_fifo_waddr;

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
    // FPGA Heartbeat & Stuck-At Watchdogs
    // ==============================================================
    logic [31:0] fpga_heartbeat;
    logic [2:0]  wd_bclk_sync, wd_lrclk_sync;
    logic [19:0] wd_bclk_cnt, wd_lrclk_cnt, wd_sclk_cnt;
    logic        err_wdog_bclk, err_wdog_lrclk, err_wdog_spi;
    
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fpga_heartbeat <= '0;
            wd_bclk_sync   <= '0;
            wd_lrclk_sync  <= '0;
            wd_bclk_cnt    <= '0;
            wd_lrclk_cnt   <= '0;
            wd_sclk_cnt    <= '0;
            err_wdog_bclk  <= 1'b0;
            err_wdog_lrclk <= 1'b0;
            err_wdog_spi   <= 1'b0;
        end else begin
            fpga_heartbeat <= fpga_heartbeat + 1'b1;

            wd_bclk_sync  <= {wd_bclk_sync[1:0], i2s_bclk};
            wd_lrclk_sync <= {wd_lrclk_sync[1:0], i2s_lrclk};

            if (wd_bclk_sync[2] ^ wd_bclk_sync[1]) wd_bclk_cnt <= '0; 
            else if (wd_bclk_cnt < 20'd1_000_000)  wd_bclk_cnt <= wd_bclk_cnt + 1'b1;
            if (wd_bclk_cnt == 20'd950_000)        err_wdog_bclk <= 1'b1; 

            if (wd_lrclk_sync[2] ^ wd_lrclk_sync[1]) wd_lrclk_cnt <= '0;
            else if (wd_lrclk_cnt < 20'd1_000_000)   wd_lrclk_cnt <= wd_lrclk_cnt + 1'b1;
            if (wd_lrclk_cnt == 20'd950_000)         err_wdog_lrclk <= 1'b1; 

            if (spi_cs_n == 1'b1)                 wd_sclk_cnt <= '0; 
            else if (wd_sclk_cnt < 20'd1_000_000) wd_sclk_cnt <= wd_sclk_cnt + 1'b1;
            if (wd_sclk_cnt == 20'd950_000)       err_wdog_spi <= 1'b1; 

            if (ctrl_bus_valid && ctrl_bus_data[31] && ctrl_bus_data[30:24] == 7'h24) begin
                err_wdog_bclk  <= 1'b0;
                err_wdog_lrclk <= 1'b0;
                err_wdog_spi   <= 1'b0;
            end
        end
    end

    // ==============================================================
    // Thermal & Power State (XADC)
    // ==============================================================
    logic [15:0] xadc_do;
    logic        xadc_drdy;
    logic        xadc_eoc;
    logic [4:0]  xadc_channel;
    logic [15:0] fpga_temp_raw, vccint_raw, vccaux_raw, vccbram_raw;

    XADC #(
        .INIT_40(16'h0000), .INIT_41(16'h2000), .INIT_48(16'h0047), 
        .INIT_49(16'h0000), .INIT_4A(16'h0000), .INIT_4B(16'h0000),
        .INIT_4E(16'h0000), .INIT_4F(16'h0000)
    ) u_xadc (
        .DADDR({2'b00, xadc_channel}), .DCLK(dsp_clk), .DEN(xadc_eoc),
        .DI(16'h0000), .DWE(1'b0), .RESET(~sys_rst_n),
        .VAUXN(16'h0000), .VAUXP(16'h0000), .VN(1'b0), .VP(1'b0),
        .DO(xadc_do), .DRDY(xadc_drdy), .EOC(xadc_eoc),
        .ALM(), .BUSY(), .CHANNEL(xadc_channel), .EOS(),
        .JTAGBUSY(), .JTAGLOCKED(), .JTAGMODIFIED(), .OT(), .MUXADDR()
    );

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fpga_temp_raw <= '0; vccint_raw <= '0; vccaux_raw <= '0; vccbram_raw <= '0;
        end else if (xadc_drdy) begin
            case (xadc_channel)
                5'h00: fpga_temp_raw <= xadc_do;
                5'h01: vccint_raw    <= xadc_do;
                5'h02: vccaux_raw    <= xadc_do;
                5'h06: vccbram_raw   <= xadc_do;
            endcase
        end
    end

    // ==============================================================
    // I2S Framing Integrity Check 
    // ==============================================================
    logic [6:0] bclk_counter;
    logic       i2s_lrclk_q, frame_err_raw, i2s_synced; 

    always_ff @(posedge i2s_bclk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            bclk_counter <= '0; i2s_lrclk_q <= 1'b0; frame_err_raw <= 1'b0; i2s_synced <= 1'b0;
        end else begin
            i2s_lrclk_q <= i2s_lrclk; frame_err_raw <= 1'b0; 
            if (i2s_lrclk_q == 1'b0 && i2s_lrclk == 1'b1) begin
                if (i2s_synced && (bclk_counter != 7'd64)) frame_err_raw <= 1'b1;
                bclk_counter <= 7'd1; i2s_synced <= 1'b1; 
            end else begin
                if (bclk_counter < 7'd127) bclk_counter <= bclk_counter + 7'd1;
            end
        end
    end

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
    logic [15:0] lrclk_counter, last_lrclk_count;
    logic [6:0]  read_addr_reg;
    logic [31:0] spi_tx_data;

    always_ff @(posedge dsp_clk) begin
        if (!ext_rst_n) begin
            err_fifo_overflow <= 1'b0; err_fifo_underflow <= 1'b0; err_clk_unlock <= 1'b0;
            err_audio_clip <= 1'b0; err_i2s_frame <= 1'b0; spi_comms_err_count <= '0;
            lrclk_sync <= 2'b00; lrclk_counter <= '0; last_lrclk_count <= '0;
        end else begin
            if (fifo_full)  err_fifo_overflow  <= 1'b1;
            if (fifo_empty) err_fifo_underflow <= 1'b1;
            if (!clk_locked) err_clk_unlock    <= 1'b1;
            if (spi_crc_error) spi_comms_err_count <= spi_comms_err_count + 1'b1;
            if (frame_err_sync[1]) err_i2s_frame <= 1'b1;
            if (volumed_clip_detect) err_audio_clip <= 1'b1;
            if (raw_data_valid && (raw_left_data == 32'h7FFFFFFF || raw_left_data == 32'h80000000)) err_audio_clip <= 1'b1;

            if (ctrl_bus_valid && ctrl_bus_data[31]) begin
                if (ctrl_bus_data[30:24] == 7'h13) begin
                    err_fifo_overflow <= 1'b0; err_fifo_underflow <= 1'b0; err_clk_unlock <= 1'b0;
                end
                if (ctrl_bus_data[30:24] == 7'h15) spi_comms_err_count <= '0;
                if (ctrl_bus_data[30:24] == 7'h16) err_audio_clip      <= 1'b0;
                if (ctrl_bus_data[30:24] == 7'h17) err_i2s_frame       <= 1'b0;
            end

            lrclk_sync <= {lrclk_sync[0], i2s_lrclk};
            if (lrclk_sync == 2'b01) begin 
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
            sys_volume        <= 32'hFFFFFFFF; 
            cmd_gain_6v       <= 1'b0;
            relay_gain_6v     <= 1'b0;
            base_rate_sel     <= 1'b0; 
            read_addr_reg     <= 7'h00;
            flash_cmd_trigger <= 1'b0;
            flash_fifo_we     <= 1'b0;
        end else begin
            flash_cmd_trigger <= 1'b0;
            flash_fifo_we     <= 1'b0;
            
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin 
                    // WRITE OPERATION
                    case (ctrl_bus_data[30:24])
                        7'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]};
                        7'h02: cmd_gain_6v   <= ctrl_bus_data[0];             
                        7'h03: base_rate_sel <= ctrl_bus_data[0]; 
                        // Flash Commands
                        7'h30: begin 
                               flash_cmd_opcode  <= ctrl_bus_data[7:0];
                               flash_cmd_trigger <= 1'b1;
                               end
                        7'h31: flash_cmd_addr    <= ctrl_bus_data[23:0];
                        7'h32: begin
                               flash_fifo_wdata  <= ctrl_bus_data[7:0];
                               flash_fifo_waddr  <= ctrl_bus_data[15:8];
                               flash_fifo_we     <= 1'b1;
                               end
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
            7'h11: spi_tx_data = {24'd0, blade_detect_pins}; 
            7'h12: spi_tx_data = {29'd0, relay_iv_filter, base_rate_sel, relay_gain_6v}; 
            7'h13: spi_tx_data = {29'd0, err_clk_unlock, err_fifo_underflow, err_fifo_overflow}; 
            7'h14: spi_tx_data = {16'd0, last_lrclk_count}; 
            7'h15: spi_tx_data = {24'd0, spi_comms_err_count}; 
            7'h16: spi_tx_data = {31'd0, err_audio_clip}; 
            7'h17: spi_tx_data = {31'd0, err_i2s_frame}; 
            7'h18: spi_tx_data = {16'd0, fpga_temp_raw}; 
            7'h19: spi_tx_data = fpga_heartbeat; 
            7'h20: spi_tx_data = safe_audio_data; 
            7'h21: spi_tx_data = volumed_audio_data; 
            7'h22: spi_tx_data = interpolated_audio_48b[47:16]; 
            7'h23: spi_tx_data = {26'd0, dem_drive_command}; 
            7'h24: spi_tx_data = {29'd0, err_wdog_spi, err_wdog_lrclk, err_wdog_bclk}; 
            7'h25: spi_tx_data = {16'd0, vccint_raw}; 
            7'h26: spi_tx_data = {16'd0, vccaux_raw}; 
            7'h27: spi_tx_data = {16'd0, vccbram_raw}; 
            
            // Flash Status
            7'h33: spi_tx_data = {31'd0, flash_busy};

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

    flash_bridge u_flash_bridge (
        .clk         (dsp_clk),
        .rst_n       (sys_rst_n),
        .cmd_opcode  (flash_cmd_opcode),
        .cmd_addr    (flash_cmd_addr),
        .cmd_trigger (flash_cmd_trigger),
        .cmd_busy    (flash_busy),
        .fifo_wdata  (flash_fifo_wdata),
        .fifo_we     (flash_fifo_we),
        .fifo_waddr  (flash_fifo_waddr),
        .flash_clk   (internal_flash_clk), // Routes implicitly via STARTUPE2
        .flash_cs_n  (qspi_cs_n),
        .flash_mosi  (qspi_mosi),
        .flash_miso  (qspi_miso)
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