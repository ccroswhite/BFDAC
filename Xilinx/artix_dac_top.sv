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

    // Dedicated QSPI Flash Interface (Storage Plane)
    output logic        qspi_cs_n,
    output logic        qspi_mosi,
    input  logic        qspi_miso,

    // High-Speed Serial LVDS (To MAX10 Tubs)
    output logic        lvds_bclk_p,
    output logic        lvds_bclk_n,
    output logic        lvds_sync_p,
    output logic        lvds_sync_n,
    output logic        lvds_data_l_p,
    output logic        lvds_data_l_n,
    output logic        lvds_data_r_p,
    output logic        lvds_data_r_n,

    // DDR3L Physical Interface (Bank 14/15 1.35V Domain)
    inout  logic [15:0] ddr3_dq,
    inout  logic [1:0]  ddr3_dqs_n,
    inout  logic [1:0]  ddr3_dqs_p,
    output logic [14:0] ddr3_addr,
    output logic [2:0]  ddr3_ba,
    output logic        ddr3_ras_n,
    output logic        ddr3_cas_n,
    output logic        ddr3_we_n,
    output logic        ddr3_reset_n,
    output logic [0:0]  ddr3_ck_p,
    output logic [0:0]  ddr3_ck_n,
    output logic [0:0]  ddr3_cke,
    output logic [0:0]  ddr3_cs_n,
    output logic [1:0]  ddr3_dm,
    output logic [0:0]  ddr3_odt
);

    // ==============================================================
    // 1. Core Clocking & Reset Nets
    // ==============================================================
    logic dsp_clk;
    logic lvds_bit_clk;
    logic clk_200m; // Dedicated 200MHz Ref Clock for the MIG IDELAYCTRL
    logic clk_locked;
    logic sys_rst_n;
    logic base_rate_sel;

    assign sys_rst_n = ext_rst_n & clk_locked;

    sys_clock_gen u_clk_gen (
        .clk_45m        (clk_45m),
        .clk_49m        (clk_49m),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .clk_200m       (clk_200m),
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
            sys_volume    <= 32'hFFFFFFFF;
            cmd_gain_6v   <= 1'b0;
            relay_gain_6v <= 1'b0;
            base_rate_sel <= 1'b0;
            cmd_unmute    <= 1'b0;
            read_addr_reg <= 7'h00;
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
    // 3. I2S Ingress & Initial Clock Domain Crossing
    // ==============================================================
    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty, new_sample_trigger;

    // MIG Interface Clocks
    logic ui_clk;
    logic ui_rst;
    logic ui_rst_n;
    logic mig_locked;

    assign ui_rst_n = ~ui_rst;

    i2s_rx #(.DATA_WIDTH(32)) u_i2s_rx (
        .clk        (dsp_clk), // I2S RX logic can oversample securely
        .rst_n      (sys_rst_n),
        .i2s_bclk   (i2s_bclk),
        .i2s_lrclk  (i2s_lrclk),
        .i2s_data   (i2s_data),
        .left_data  (raw_left_data),
        .right_data (raw_right_data),
        .data_valid (raw_data_valid)
    );

    // Cross the new incoming sample into the 83.33 MHz MIG domain
    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(4)) u_i2s_to_ui_fifo (
        .w_clk   (i2s_bclk),
        .w_rst_n (sys_rst_n),
        .w_en    (raw_data_valid & ~fifo_full),
        .w_data  (raw_left_data),
        .w_full  (fifo_full),
        .r_clk   (ui_clk),
        .r_rst_n (ui_rst_n), 
        .r_en    (~fifo_empty),
        .r_data  (safe_audio_data),
        .r_empty (fifo_empty)
    );

    assign new_sample_trigger = ~fifo_empty;

    // ==============================================================
    // 4. The DDR3L 1,000,000-Tap Memory Bridge
    // ==============================================================
    
    // AXI4 Interface Nets
    logic [28:0] m_axi_awaddr;
    logic [7:0]  m_axi_awlen;
    logic [2:0]  m_axi_awsize;
    logic [1:0]  m_axi_awburst;
    logic        m_axi_awvalid, m_axi_awready;
    logic [127:0]m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic        m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0]  m_axi_bresp;
    logic        m_axi_bvalid, m_axi_bready;
    logic [28:0] m_axi_araddr;
    logic [7:0]  m_axi_arlen;
    logic [2:0]  m_axi_arsize;
    logic [1:0]  m_axi_arburst;
    logic        m_axi_arvalid, m_axi_arready;
    logic [127:0]m_axi_rdata;
    logic [1:0]  m_axi_rresp;
    logic        m_axi_rlast, m_axi_rvalid, m_axi_rready;

    // Cache Nets
    logic         cache_we;
    logic [7:0]   cache_waddr;
    logic [127:0] cache_wdata;

    ddr3_axi_master #(
        .C_M_AXI_ADDR_WIDTH (29),
        .C_M_AXI_DATA_WIDTH (128)
    ) u_ddr3_master (
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_rst),
        .new_sample_trigger (new_sample_trigger),
        .new_sample_data    (safe_audio_data),
        .cache_we           (cache_we),
        .cache_waddr        (cache_waddr),
        .cache_wdata        (cache_wdata),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready)
    );

    mig_ddr3_core u_mig_ddr3 (
        .ddr3_addr          (ddr3_addr),
        .ddr3_ba            (ddr3_ba),
        .ddr3_cas_n         (ddr3_cas_n),
        .ddr3_ck_n          (ddr3_ck_n),
        .ddr3_ck_p          (ddr3_ck_p),
        .ddr3_cke           (ddr3_cke),
        .ddr3_ras_n         (ddr3_ras_n),
        .ddr3_reset_n       (ddr3_reset_n),
        .ddr3_we_n          (ddr3_we_n),
        .ddr3_dq            (ddr3_dq),
        .ddr3_dqs_n         (ddr3_dqs_n),
        .ddr3_dqs_p         (ddr3_dqs_p),
        .ddr3_cs_n          (ddr3_cs_n),
        .ddr3_dm            (ddr3_dm),
        .ddr3_odt           (ddr3_odt),
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_rst),
        .mmcm_locked        (mig_locked),
        .aresetn            (sys_rst_n),
        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         (),
        .s_axi_awid         (4'b0),
        .s_axi_awaddr       (m_axi_awaddr),
        .s_axi_awlen        (m_axi_awlen),
        .s_axi_awsize       (m_axi_awsize),
        .s_axi_awburst      (m_axi_awburst),
        .s_axi_awlock       (1'b0),
        .s_axi_awcache      (4'b0),
        .s_axi_awprot       (3'b0),
        .s_axi_awqos        (4'b0),
        .s_axi_awvalid      (m_axi_awvalid),
        .s_axi_awready      (m_axi_awready),
        .s_axi_wdata        (m_axi_wdata),
        .s_axi_wstrb        (m_axi_wstrb),
        .s_axi_wlast        (m_axi_wlast),
        .s_axi_wvalid       (m_axi_wvalid),
        .s_axi_wready       (m_axi_wready),
        .s_axi_bid          (),
        .s_axi_bresp        (m_axi_bresp),
        .s_axi_bvalid       (m_axi_bvalid),
        .s_axi_bready       (m_axi_bready),
        .s_axi_arid         (4'b0),
        .s_axi_araddr       (m_axi_araddr),
        .s_axi_arlen        (m_axi_arlen),
        .s_axi_arsize       (m_axi_arsize),
        .s_axi_arburst      (m_axi_arburst),
        .s_axi_arlock       (1'b0),
        .s_axi_arcache      (4'b0),
        .s_axi_arprot       (3'b0),
        .s_axi_arqos        (4'b0),
        .s_axi_arvalid      (m_axi_arvalid),
        .s_axi_arready      (m_axi_arready),
        .s_axi_rid          (),
        .s_axi_rdata        (m_axi_rdata),
        .s_axi_rresp        (m_axi_rresp),
        .s_axi_rlast        (m_axi_rlast),
        .s_axi_rvalid       (m_axi_rvalid),
        .s_axi_rready       (m_axi_rready),
        .sys_clk_i          (clk_200m),
        .sys_rst            (ext_rst_n)
    );

    // ==============================================================
    // 5. The Ping-Pong BRAM Cache (Crossing to the 357MHz Domain)
    // ==============================================================
    logic [9:0]  dsp_cache_raddr;
    logic [31:0] dsp_cache_rdata;
    logic        dsp_audio_valid_strobe;

    // True Dual-Port RAM isolates the 83MHz 128-bit bus from the 357MHz 32-bit bus.
    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(8),
        .ADDR_WIDTH_B(10),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(128),
        .BYTE_WRITE_WIDTH_B(32),
        .CLOCKING_MODE("independent_clock"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(32768), // 256 * 128 = 32Kb
        .READ_DATA_WIDTH_A(128),
        .READ_DATA_WIDTH_B(32),
        .READ_LATENCY_A(1),
        .READ_LATENCY_B(2), // 2 cycles for DSP performance
        .USE_MEM_INIT(0),
        .WRITE_DATA_WIDTH_A(128),
        .WRITE_DATA_WIDTH_B(32)
    ) u_ping_pong_cache (
        .clka           (ui_clk),
        .ena            (1'b1),
        .wea            (cache_we),
        .addra          (cache_waddr),
        .dina           (cache_wdata),
        .douta          (),
        .clkb           (dsp_clk),
        .enb            (1'b1),
        .web            (1'b0),
        .addrb          (dsp_cache_raddr),
        .dinb           (32'd0),
        .doutb          (dsp_cache_rdata),
        .sleep          (1'b0),
        .injectdbiterra (1'b0),
        .injectdbiterrb (1'b0),
        .injectsbiterra (1'b0),
        .injectsbiterrb (1'b0),
        .regcea         (1'b1),
        .regceb         (1'b1),
        .rsta           (ui_rst),
        .rstb           (~sys_rst_n),
        .dbiterra       (),
        .dbiterrb       (),
        .sbiterra       (),
        .sbiterrb       ()
    );

    // DSP Cache Read Fetcher
    // Steps through the 1024 samples safely inside the 357MHz domain
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            dsp_cache_raddr <= '0;
            dsp_audio_valid_strobe <= 1'b0;
        end else begin
            // Trigger 1 fetch continuously over the DSP execution block length
            // Example logic: simplistic cyclic read (Requires tying to FIR sequencer)
            dsp_cache_raddr <= dsp_cache_raddr + 1'b1;
            dsp_audio_valid_strobe <= 1'b1; 
        end
    end

    // ==============================================================
    // 6. The 357 MHz Overclocked DSP Core
    // ==============================================================
    logic signed [63:0] interpolated_audio_64b;
    logic               interpolated_valid;

    // Sign-extend 24-bit audio to 25-bit for the Xilinx DSP multiplier port
    logic signed [24:0] audio_in_25b;
    assign audio_in_25b = {dsp_cache_rdata[31], dsp_cache_rdata[31:8]};

    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (64) // 64 BITS
    ) u_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (dsp_audio_valid_strobe),
        .new_sample_data    (audio_in_25b[23:0]), 
        .interpolated_out   (interpolated_audio_64b),
        .interpolated_valid (interpolated_valid)
    );

    // --- Boundary Pipelining (Absorbs routing delay from FIR edge) ---
    logic signed [63:0] fir_out_reg;
    logic               fir_valid_reg;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fir_out_reg   <= '0;
            fir_valid_reg <= 1'b0;
        end else begin
            fir_out_reg   <= interpolated_audio_64b;
            fir_valid_reg <= interpolated_valid;
        end
    end

    // --- 64-Bit Volume Multiplier (Xilinx DSP IP - 4 Cycle Latency) ---
    logic [95:0]        volume_full_product;
    logic signed [63:0] volumed_audio_64b;
    logic               volumed_valid;

    vol_mult_ip u_volume_dsp_core (
        .CLK (dsp_clk),
        .A   (fir_out_reg),    
        .B   (sys_volume),     
        .P   (volume_full_product) 
    );

    logic [5:0] vol_valid_pipeline;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_valid_pipeline <= '0;
            volumed_audio_64b  <= '0;
        end else begin
            vol_valid_pipeline <= {vol_valid_pipeline[4:0], fir_valid_reg};
            volumed_audio_64b  <= volume_full_product[95:32];
        end
    end

    assign volumed_valid = vol_valid_pipeline[5];

    // =================================---------------------------------------
    // 7. THE MULTICYCLE HOLDING REGISTER (Isolates 357MHz thrashing)
    // =================================---------------------------------------
    logic signed [63:0] stable_audio_64b;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            stable_audio_64b <= '0;
        end else if (volumed_valid) begin
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

    // --- 5th-Order Modulator ---
    logic [8:0] dem_drive_command;
    logic [255:0] left_resistor_bus;
    logic [255:0] right_resistor_bus;
    
    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),
        .FRAC_WIDTH(42),
        .OUT_WIDTH(9)
    ) u_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .data_in        (stable_audio_64b[63 : 16]),
        .dither_in      (dither_noise),
        .dem_drive_out  (dem_drive_command)
    );

    // --- DEM Mapper ---
    dem_mapper #(
        .ARRAY_SIZE(256),
        .AMP_WIDTH(9)
    ) u_dem_mapper (
        .clk           (dsp_clk),
        .rst_n         (sys_rst_n),
        .enable        (volumed_valid),
        .amplitude_in  (dem_drive_command),
        .resistor_out  (left_resistor_bus)
    );

    assign right_resistor_bus = left_resistor_bus;

    // ==============================================================
    // 8. The 512-Bit Asynchronous Output Boundary
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
    // 9. LVDS Egress (196.6 MHz Domain)
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
    assign relay_audio_out = 1'b1;

endmodule`timescale 1ns / 1ps

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
    output logic        lvds_data_r_n,

    // DDR3L Physical Interface (Bank 14/15 1.35V Domain)
    inout  logic [15:0] ddr3_dq,
    inout  logic [1:0]  ddr3_dqs_n,
    inout  logic [1:0]  ddr3_dqs_p,
    output logic [14:0] ddr3_addr,
    output logic [2:0]  ddr3_ba,
    output logic        ddr3_ras_n,
    output logic        ddr3_cas_n,
    output logic        ddr3_we_n,
    output logic        ddr3_reset_n,
    output logic [0:0]  ddr3_ck_p,
    output logic [0:0]  ddr3_ck_n,
    output logic [0:0]  ddr3_cke,
    output logic [0:0]  ddr3_cs_n,
    output logic [1:0]  ddr3_dm,
    output logic [0:0]  ddr3_odt
);

    // ==============================================================
    // 1. Core Clocking & Reset Nets
    // ==============================================================
    logic dsp_clk;
    logic lvds_bit_clk;
    logic clk_200m; 
    logic clk_locked;
    logic sys_rst_n;
    logic base_rate_sel;

    assign sys_rst_n = ext_rst_n & clk_locked;

    sys_clock_gen u_clk_gen (
        .clk_45m        (clk_45m),
        .clk_49m        (clk_49m),
        .rst_n          (ext_rst_n),
        .base_rate_sel  (base_rate_sel),
        .dsp_clk        (dsp_clk),
        .lvds_bit_clk   (lvds_bit_clk),
        .clk_200m       (clk_200m),
        .locked         (clk_locked)
    );

    // ==============================================================
    // 2. Control Plane (SPI & Relays - Clocked by 49MHz)
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
        .clk            (clk_49m),      
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
            sys_volume    <= 32'hFFFFFFFF;
            cmd_gain_6v   <= 1'b0;
            relay_gain_6v <= 1'b0;
            base_rate_sel <= 1'b0;
            cmd_unmute    <= 1'b0;
            read_addr_reg <= 7'h00;
        end else begin
            if (ctrl_bus_valid) begin
                if (ctrl_bus_data[31] == 1'b0) begin
                    case (ctrl_bus_data[30:24])
                        7'h01: sys_volume    <= {8'h00, ctrl_bus_data[23:0]};
                        7'h02: cmd_gain_6v   <= ctrl_bus_data[0];
                        7'h03: base_rate_sel <= ctrl_bus_data[0];
                        7'h04: cmd_unmute    <= ctrl_bus_data[0];
                    endcase
                    relay_gain_6v <= cmd_gain_6v;
                end else begin
                    read_addr_reg <= ctrl_bus_data[30:24];
                end
            end
        end
    end

    always_comb begin
        case (read_addr_reg)
            7'h10: spi_tx_data = 32'hDAC02026;
            7'h12: spi_tx_data = {30'd0, base_rate_sel, relay_gain_6v};
            default: spi_tx_data = 32'hDEADBEEF;
        endcase
    end

    // ==============================================================
    // 3. I2S Ingress & Initial Clock Domain Crossing
    // ==============================================================
    logic [31:0] raw_left_data, raw_right_data;
    logic        raw_data_valid;
    logic [31:0] safe_audio_data;
    logic        fifo_full, fifo_empty, new_sample_trigger;

    // MIG Interface Clocks
    logic ui_clk;
    logic ui_rst;
    logic ui_rst_n;
    logic mig_locked;

    assign ui_rst_n = ~ui_rst;

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

    // Cross the new incoming sample into the 83.33 MHz MIG domain
    async_fifo #(.DATA_WIDTH(32), .ADDR_WIDTH(4)) u_i2s_to_ui_fifo (
        .w_clk   (i2s_bclk),
        .w_rst_n (sys_rst_n),
        .w_en    (raw_data_valid & ~fifo_full),
        .w_data  (raw_left_data),
        .w_full  (fifo_full),
        .r_clk   (ui_clk),
        .r_rst_n (ui_rst_n), 
        .r_en    (~fifo_empty),
        .r_data  (safe_audio_data),
        .r_empty (fifo_empty)
    );

    assign new_sample_trigger = ~fifo_empty;

    // ==============================================================
    // 4. The DDR3L 1,000,000-Tap Memory Bridge
    // ==============================================================
    logic [28:0]  m_axi_awaddr;
    logic [7:0]   m_axi_awlen;
    logic [2:0]   m_axi_awsize;
    logic [1:0]   m_axi_awburst;
    logic         m_axi_awvalid, m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0]  m_axi_wstrb;
    logic         m_axi_wlast, m_axi_wvalid, m_axi_wready;
    logic [1:0]   m_axi_bresp;
    logic         m_axi_bvalid, m_axi_bready;
    logic [28:0]  m_axi_araddr;
    logic [7:0]   m_axi_arlen;
    logic [2:0]   m_axi_arsize;
    logic [1:0]   m_axi_arburst;
    logic         m_axi_arvalid, m_axi_arready;
    logic [127:0] m_axi_rdata;
    logic [1:0]   m_axi_rresp;
    logic         m_axi_rlast, m_axi_rvalid, m_axi_rready;

    logic         cache_we;
    logic [7:0]   cache_waddr;
    logic [127:0] cache_wdata;

    ddr3_axi_master #(
        .C_M_AXI_ADDR_WIDTH (29),
        .C_M_AXI_DATA_WIDTH (128)
    ) u_ddr3_master (
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_rst),
        .new_sample_trigger (new_sample_trigger),
        .new_sample_data    (safe_audio_data),
        .cache_we           (cache_we),
        .cache_waddr        (cache_waddr),
        .cache_wdata        (cache_wdata),
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready)
    );

    mig_ddr3_core u_mig_ddr3 (
        .ddr3_addr          (ddr3_addr),
        .ddr3_ba            (ddr3_ba),
        .ddr3_cas_n         (ddr3_cas_n),
        .ddr3_ck_n          (ddr3_ck_n),
        .ddr3_ck_p          (ddr3_ck_p),
        .ddr3_cke           (ddr3_cke),
        .ddr3_ras_n         (ddr3_ras_n),
        .ddr3_reset_n       (ddr3_reset_n),
        .ddr3_we_n          (ddr3_we_n),
        .ddr3_dq            (ddr3_dq),
        .ddr3_dqs_n         (ddr3_dqs_n),
        .ddr3_dqs_p         (ddr3_dqs_p),
        .ddr3_cs_n          (ddr3_cs_n),
        .ddr3_dm            (ddr3_dm),
        .ddr3_odt           (ddr3_odt),
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (ui_rst),
        .mmcm_locked        (mig_locked),
        .aresetn            (sys_rst_n),
        .app_sr_req         (1'b0),
        .app_ref_req        (1'b0),
        .app_zq_req         (1'b0),
        .app_sr_active      (),
        .app_ref_ack        (),
        .app_zq_ack         (),
        .s_axi_awid         (4'b0),
        .s_axi_awaddr       (m_axi_awaddr),
        .s_axi_awlen        (m_axi_awlen),
        .s_axi_awsize       (m_axi_awsize),
        .s_axi_awburst      (m_axi_awburst),
        .s_axi_awlock       (1'b0),
        .s_axi_awcache      (4'b0),
        .s_axi_awprot       (3'b0),
        .s_axi_awqos        (4'b0),
        .s_axi_awvalid      (m_axi_awvalid),
        .s_axi_awready      (m_axi_awready),
        .s_axi_wdata        (m_axi_wdata),
        .s_axi_wstrb        (m_axi_wstrb),
        .s_axi_wlast        (m_axi_wlast),
        .s_axi_wvalid       (m_axi_wvalid),
        .s_axi_wready       (m_axi_wready),
        .s_axi_bid          (),
        .s_axi_bresp        (m_axi_bresp),
        .s_axi_bvalid       (m_axi_bvalid),
        .s_axi_bready       (m_axi_bready),
        .s_axi_arid         (4'b0),
        .s_axi_araddr       (m_axi_araddr),
        .s_axi_arlen        (m_axi_arlen),
        .s_axi_arsize       (m_axi_arsize),
        .s_axi_arburst      (m_axi_arburst),
        .s_axi_arlock       (1'b0),
        .s_axi_arcache      (4'b0),
        .s_axi_arprot       (3'b0),
        .s_axi_arqos        (4'b0),
        .s_axi_arvalid      (m_axi_arvalid),
        .s_axi_arready      (m_axi_arready),
        .s_axi_rid          (),
        .s_axi_rdata        (m_axi_rdata),
        .s_axi_rresp        (m_axi_rresp),
        .s_axi_rlast        (m_axi_rlast),
        .s_axi_rvalid       (m_axi_rvalid),
        .s_axi_rready       (m_axi_rready),
        .sys_clk_i          (clk_200m), // CRITICAL: DDR3L PHY Ref Clock
        .clk_ref_i          (clk_200m), // CRITICAL: Fixes [Synth 8-4442]
        .sys_rst            (ext_rst_n) // ACTIVE LOW configured in MIG wizard
    );

    // ==============================================================
    // 5. The Ping-Pong BRAM Cache (Crossing to the 357MHz Domain)
    // ==============================================================
    logic [9:0]  dsp_cache_raddr;
    logic [31:0] dsp_cache_rdata;
    logic        dsp_audio_valid_strobe;

    xpm_memory_tdpram #(
        .ADDR_WIDTH_A(8),
        .ADDR_WIDTH_B(10),
        .AUTO_SLEEP_TIME(0),
        .BYTE_WRITE_WIDTH_A(128),
        .BYTE_WRITE_WIDTH_B(32),
        .CLOCKING_MODE("independent_clock"),
        .MEMORY_INIT_FILE("none"),
        .MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),
        .MEMORY_PRIMITIVE("block"),
        .MEMORY_SIZE(32768), 
        .READ_DATA_WIDTH_A(128),
        .READ_DATA_WIDTH_B(32),
        .READ_LATENCY_A(1),
        .READ_LATENCY_B(2), 
        .USE_MEM_INIT(0),
        .WRITE_DATA_WIDTH_A(128),
        .WRITE_DATA_WIDTH_B(32)
    ) u_ping_pong_cache (
        .clka           (ui_clk),
        .ena            (1'b1),
        .wea            (cache_we),
        .addra          (cache_waddr),
        .dina           (cache_wdata),
        .douta          (),
        .clkb           (dsp_clk),
        .enb            (1'b1),
        .web            (1'b0),
        .addrb          (dsp_cache_raddr),
        .dinb           (32'd0),
        .doutb          (dsp_cache_rdata),
        .sleep          (1'b0),
        .injectdbiterra (1'b0),
        .injectdbiterrb (1'b0),
        .injectsbiterra (1'b0),
        .injectsbiterrb (1'b0),
        .regcea         (1'b1),
        .regceb         (1'b1),
        .rsta           (ui_rst),
        .rstb           (~sys_rst_n),
        .dbiterra       (),
        .dbiterrb       (),
        .sbiterra       (),
        .sbiterrb       ()
    );

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            dsp_cache_raddr <= '0;
            dsp_audio_valid_strobe <= 1'b0;
        end else begin
            dsp_cache_raddr <= dsp_cache_raddr + 1'b1;
            dsp_audio_valid_strobe <= 1'b1; 
        end
    end

    // ==============================================================
    // 6. The 357 MHz Overclocked DSP Core
    // ==============================================================
    logic signed [63:0] interpolated_audio_64b;
    logic               interpolated_valid;

    logic signed [24:0] audio_in_25b;
    assign audio_in_25b = {dsp_cache_rdata[31], dsp_cache_rdata[31:8]};

    fir_polyphase_interpolator #(
        .NUM_MACS   (256),
        .DATA_WIDTH (24),
        .COEF_WIDTH (18),
        .ACC_WIDTH  (64) 
    ) u_1m_tap_fir (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .new_sample_valid   (dsp_audio_valid_strobe),
        .new_sample_data    (audio_in_25b[23:0]), 
        .interpolated_out   (interpolated_audio_64b),
        .interpolated_valid (interpolated_valid)
    );

    logic signed [63:0] fir_out_reg;
    logic               fir_valid_reg;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            fir_out_reg   <= '0;
            fir_valid_reg <= 1'b0;
        end else begin
            fir_out_reg   <= interpolated_audio_64b;
            fir_valid_reg <= interpolated_valid;
        end
    end

    // --- 64-Bit Volume Multiplier (Xilinx DSP IP - 4 Cycle Latency) ---
    logic [95:0]        volume_full_product;
    logic signed [63:0] volumed_audio_64b;
    logic               volumed_valid;

    vol_mult_ip u_volume_dsp_core (
        .CLK (dsp_clk),
        .A   (fir_out_reg),    
        .B   (sys_volume),     
        .P   (volume_full_product) 
    );

    logic [5:0] vol_valid_pipeline;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            vol_valid_pipeline <= '0;
            volumed_audio_64b  <= '0;
        end else begin
            vol_valid_pipeline <= {vol_valid_pipeline[4:0], fir_valid_reg};
            volumed_audio_64b  <= volume_full_product[95:32];
        end
    end

    assign volumed_valid = vol_valid_pipeline[5];

    // =================================---------------------------------------
    // 7. THE MULTICYCLE HOLDING REGISTER (Isolates 357MHz thrashing)
    // =================================---------------------------------------
    logic signed [63:0] stable_audio_64b;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            stable_audio_64b <= '0;
        end else if (volumed_valid) begin
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

    // --- 5th-Order Modulator ---
    logic [8:0] dem_drive_command;
    logic [255:0] left_resistor_bus;
    logic [255:0] right_resistor_bus;
    
    noise_shaper_5th_order #(
        .INPUT_WIDTH(48),
        .FRAC_WIDTH(42),
        .OUT_WIDTH(9)
    ) u_noise_shaper (
        .clk            (dsp_clk),
        .rst_n          (sys_rst_n),
        .enable         (volumed_valid),
        .data_in        (stable_audio_64b[63 : 16]),
        .dither_in      (dither_noise),
        .dem_drive_out  (dem_drive_command)
    );

    // --- DEM Mapper ---
    dem_mapper #(
        .ARRAY_SIZE(128),  // 128 Hot / 128 Cold = 256 physical lines per channel
        .AMP_WIDTH(9)
    ) u_dem_mapper (
        .clk           (dsp_clk),
        .rst_n         (sys_rst_n),
        .enable        (volumed_valid),
        .amplitude_in  (dem_drive_command),
        .resistor_out  (left_resistor_bus) // Native 256-bit mapped bus
    );

    assign right_resistor_bus = left_resistor_bus;

    // ==============================================================
    // 8. The 512-Bit Asynchronous Output Boundary
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
    // 9. LVDS Egress (196.6 MHz Domain)
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
    assign relay_audio_out = 1'b1;

endmodule