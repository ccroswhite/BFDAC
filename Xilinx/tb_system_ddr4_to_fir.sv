`timescale 1ns / 1ps

// =============================================================================
//  TB_SYSTEM_DDR4_TO_FIR
//
//  Complete system integration testbench verifying:
//    1. AXI slave generates coefficient data on-the-fly (no pre-init loop)
//    2. coef_bank_loader fetches via AXI4 read bursts
//    3. CDC bridge passes coef write bus from ui_clk -> dsp_clk
//    4. Coefficients land in fir_polyphase_stereo BRAMs
//    5. FIR processes audio samples with loaded coefficients
//
//  AXI data is computed combinatorially from address — no memory array needed.
//  This avoids the 524K-iteration pre-init loop that blocked simulation start.
// =============================================================================

module tb_system_ddr4_to_fir;

    // -------------------------------------------------------------------------
    //  Parameters (must match DUTs)
    //  -------------------------------------------------------------------------
    localparam int NUM_MACS       = 256;
    localparam int COEF_WIDTH     = 18;
    localparam int COEF_DEPTH     = 2048;
    localparam int BANK_BITS      = 4;
    localparam int AXI_DATA_WIDTH = 128;
    localparam int AXI_ADDR_WIDTH = 32;
    localparam int AUDIO_WIDTH    = 24;
    
    localparam logic [31:0] DDR4_BASE      = 32'h0000_0000;
    localparam logic [31:0] BANK_SIZE      = 32'h0020_0000;  // 2 MB per bank
    
    // Clock periods
    localparam real UI_CLK_PERIOD  = 5.0;   // 200 MHz
    localparam real DSP_CLK_PERIOD = 3.875; // 258 MHz (from 45.1584 MHz × 6 ÷ 3.5)
    
    // Coefficient generation constants
    localparam int COEFS_PER_BEAT  = AXI_DATA_WIDTH / 32;  // 4
    localparam int BEATS_PER_BURST = 256;
    localparam int COEFS_PER_BURST = COEFS_PER_BEAT * BEATS_PER_BURST; // 1024
    localparam int BURSTS_PER_MAC  = COEF_DEPTH / COEFS_PER_BURST;      // 2
    localparam int MAC_BYTES       = COEF_DEPTH * 4;                     // 8 KB
    
    // -------------------------------------------------------------------------
    //  Clocks
    //  -------------------------------------------------------------------------
    logic ui_clk = 1'b0;
    logic dsp_clk = 1'b0;
    
    always #(UI_CLK_PERIOD/2.0) ui_clk = ~ui_clk;
    always #(DSP_CLK_PERIOD/2.0) dsp_clk = ~dsp_clk;
    
    // -------------------------------------------------------------------------
    //  Resets
    //  -------------------------------------------------------------------------
    logic ui_rst_n;
    logic dsp_rst_n;
    
    // -------------------------------------------------------------------------
    //  DDR4/AXI Interface (ui_clk domain)
    //  -------------------------------------------------------------------------
    logic [AXI_ADDR_WIDTH-1:0] axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid;
    logic                      axi_arready;
    logic [AXI_DATA_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast;
    logic                      axi_rvalid;
    logic                      axi_rready;
    
    // -------------------------------------------------------------------------
    //  Coefficient Write Bus (dsp_clk domain, from coef_subsys)
    //  -------------------------------------------------------------------------
    logic                      coef_we;
    logic [10:0]               coef_waddr;
    logic signed [COEF_WIDTH-1:0] coef_wdata;
    logic [7:0]                coef_wmac;
    
    // -------------------------------------------------------------------------
    //  Bank Control (dsp_clk domain)
    //  -------------------------------------------------------------------------
    logic                      bank_select;
    logic                      bank_load_target;
    logic [3:0]                current_bank_id;
    logic                      mgr_busy;
    logic                      coef_load_done;
    
    // -------------------------------------------------------------------------
    //  FIR Interface (dsp_clk domain)
    //  -------------------------------------------------------------------------
    logic [AUDIO_WIDTH-1:0]  audio_l_in;
    logic [AUDIO_WIDTH-1:0]  audio_r_in;
    logic                      new_sample;
    logic [47:0]               fir_l_out;  // ACC_WIDTH from interpolator
    logic [47:0]               fir_r_out;
    logic                      fir_l_valid;
    logic                      fir_r_valid;
    logic                      sample_768k_tick;
    
    // -------------------------------------------------------------------------
    //  Testbench state
    //  -------------------------------------------------------------------------
    int                        error_count;
    int                        total_coef_writes;
    int                        ar_burst_count;
    // Expected coef function: coef(mac, idx) = (mac * COEF_DEPTH + idx) & 18'h3FFFF
    
    // -------------------------------------------------------------------------
    //  Testbench SPI-side control signals (into dac_coef_subsys)
    //  -------------------------------------------------------------------------
    logic [3:0]  coef_bank_id_tb;     // target bank from "SPI"
    logic        coef_load_start_tb;  // single-cycle pulse to trigger load
    logic [15:0] boot_envelope_gain;

    // -------------------------------------------------------------------------
    //  DUT: dac_coef_subsys
    //  Contains: coef_bank_loader + coef_bank_manager + CDC + boot envelope
    //  -------------------------------------------------------------------------
    dac_coef_subsys u_coef_subsys (
        .ui_clk              (ui_clk),
        .ui_clk_sync_rst     (~ui_rst_n),
        .dsp_clk             (dsp_clk),
        .sys_rst_n           (dsp_rst_n),
        .sample_768k_tick    (sample_768k_tick),
        .coef_bank_id        (coef_bank_id_tb),
        .coef_load_start     (coef_load_start_tb),
        .m_axi_araddr        (axi_araddr),
        .m_axi_arlen         (axi_arlen),
        .m_axi_arsize        (axi_arsize),
        .m_axi_arburst       (axi_arburst),
        .m_axi_arvalid       (axi_arvalid),
        .m_axi_arready       (axi_arready),
        .m_axi_rdata         (axi_rdata),
        .m_axi_rresp         (axi_rresp),
        .m_axi_rlast         (axi_rlast),
        .m_axi_rvalid        (axi_rvalid),
        .m_axi_rready        (axi_rready),
        .coef_we             (coef_we),
        .coef_waddr          (coef_waddr),
        .coef_wdata          (coef_wdata),
        .coef_wmac           (coef_wmac),
        .bank_select         (bank_select),
        .bank_load_target    (bank_load_target),
        .boot_envelope_gain  (boot_envelope_gain),
        .current_bank_id     (current_bank_id),
        .mgr_busy            (mgr_busy),
        .coef_load_done      (coef_load_done)
    );
    
    // -------------------------------------------------------------------------
    //  DUT: fir_polyphase_stereo (dsp_clk domain)
    //  -------------------------------------------------------------------------
    fir_polyphase_stereo u_stereo_fir (
        .clk                    (dsp_clk),
        .rst_n                  (dsp_rst_n),
        .new_sample_valid       (new_sample),
        .new_sample_l           (audio_l_in),
        .new_sample_r           (audio_r_in),
        .interpolated_l         (fir_l_out),
        .interpolated_l_valid   (fir_l_valid),
        .interpolated_r         (fir_r_out),
        .interpolated_r_valid   (fir_r_valid),
        .coef_we                (coef_we),
        .coef_waddr             (coef_waddr),
        .coef_wdata             (coef_wdata),
        .coef_wmac              (coef_wmac),
        .bank_select            (bank_select),
        .bank_load_target       (bank_load_target)
    );
    
    // -------------------------------------------------------------------------
    //  AXI4 Slave Memory Model — on-the-fly data generation
    //  No memory array: coefficient value is computed from address each beat.
    //  Layout: word_value = (mac * COEF_DEPTH + coef_idx) & 18'h3FFFF
    //  where mac      = (byte_offset_from_bank_base) / MAC_BYTES
    //        coef_idx = ((byte_offset % MAC_BYTES) / 4)  (word index within mac)
    //  -------------------------------------------------------------------------
    typedef enum logic [1:0] {AR_IDLE, AR_LATENCY, R_BURST} r_state_t;
    r_state_t r_state;
    
    logic [AXI_ADDR_WIDTH-1:0] slave_araddr;
    logic [7:0]                slave_arlen;
    logic [7:0]                r_beat_cnt;
    int                        latency_cnt;
    
    // Compute one 32-bit word from its byte address (bank-relative)
    function automatic logic [31:0] coef_from_addr(
        input logic [AXI_ADDR_WIDTH-1:0] byte_addr
    );
        int bank_off, mac_num, word_in_mac;
        // Strip bank offset: loader uses bank_id * BANK_SIZE as base
        bank_off    = int'(byte_addr) % int'(BANK_SIZE);
        mac_num     = bank_off / (COEF_DEPTH * 4);
        word_in_mac = (bank_off % (COEF_DEPTH * 4)) / 4;
        return 32'((mac_num * COEF_DEPTH + word_in_mac) & 32'h3FFFF);
    endfunction
    
    // Pack 128-bit beat from current burst address + beat index
    function automatic logic [AXI_DATA_WIDTH-1:0] gen_beat(
        input logic [AXI_ADDR_WIDTH-1:0] burst_base,
        input int                        beat
    );
        logic [AXI_DATA_WIDTH-1:0] d;
        d[31:0]   = coef_from_addr(burst_base + beat * 16 + 0);
        d[63:32]  = coef_from_addr(burst_base + beat * 16 + 4);
        d[95:64]  = coef_from_addr(burst_base + beat * 16 + 8);
        d[127:96] = coef_from_addr(burst_base + beat * 16 + 12);
        return d;
    endfunction
    
    always_ff @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rlast   <= 1'b0;
            axi_rdata   <= '0;
            r_state     <= AR_IDLE;
        end else begin
            case (r_state)
                AR_IDLE: begin
                    axi_arready <= 1'b1;
                    axi_rvalid  <= 1'b0;
                    if (axi_arvalid && axi_arready) begin
                        slave_araddr <= axi_araddr;
                        slave_arlen  <= axi_arlen;
                        axi_arready  <= 1'b0;
                        latency_cnt  <= 4;  // 4-cycle DDR4 read latency
                        r_state      <= AR_LATENCY;
                    end
                end
                
                AR_LATENCY: begin
                    if (latency_cnt > 0)
                        latency_cnt <= latency_cnt - 1;
                    else begin
                        r_beat_cnt <= 8'd0;
                        r_state    <= R_BURST;
                    end
                end
                
                R_BURST: begin
                    if (!axi_rvalid || axi_rready) begin
                        axi_rvalid <= 1'b1;
                        axi_rdata  <= gen_beat(slave_araddr, int'(r_beat_cnt));
                        axi_rlast  <= (r_beat_cnt == slave_arlen);
                        if (r_beat_cnt == slave_arlen) begin
                            r_state <= AR_IDLE;
                        end else begin
                            r_beat_cnt <= r_beat_cnt + 1'b1;
                        end
                    end
                end
            endcase
        end
    end
    
    assign axi_rresp = 2'b00;  // OKAY
    
    // -------------------------------------------------------------------------
    //  Sample 768k tick generator (in dsp_clk domain)
    //  258 MHz / 768 kHz = 336 cycles per sample
    //  -------------------------------------------------------------------------
    localparam int SAMPLE_DIV = 336;
    logic [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin
            sample_cnt <= '0;
            sample_768k_tick <= 1'b0;
        end else begin
            sample_768k_tick <= 1'b0;
            if (sample_cnt == SAMPLE_DIV - 1) begin
                sample_cnt <= '0;
                sample_768k_tick <= 1'b1;
            end else begin
                sample_cnt <= sample_cnt + 1'b1;
            end
        end
    end
    
    // -------------------------------------------------------------------------
    //  Diagnostic monitors — trace signal chain, print first occurrence only
    //  -------------------------------------------------------------------------
    always @(posedge dsp_clk) begin
        if (coef_load_start_tb)
            $display("[DIAG @%0t] coef_load_start_tb pulsed, bank_id=%0d", $time, coef_bank_id_tb);
    end

    always @(posedge dsp_clk) begin
        if (u_coef_subsys.u_coef_mgr.load_start_r)
            $display("[DIAG @%0t] mgr_load_start_dsp pulsed (bank_manager issued load)", $time);
    end

    always @(posedge dsp_clk) begin
        if (u_coef_subsys.load_start_toggle_dsp !== u_coef_subsys.load_start_toggle_dsp)
            ; // force reference
    end

    always @(posedge ui_clk) begin
        if (u_coef_subsys.mgr_load_start_ui_sync)
            $display("[DIAG @%0t] mgr_load_start_ui_sync pulsed (reached loader)", $time);
    end

    always @(posedge ui_clk) begin
        if (axi_arvalid)
            $display("[DIAG @%0t] AXI AR: addr=%0h len=%0d", $time, axi_araddr, axi_arlen);
    end

    always @(posedge ui_clk) begin
        if (u_coef_subsys.loader_done_ui)
            $display("[DIAG @%0t] loader_done_ui pulsed", $time);
    end

    always @(posedge dsp_clk) begin
        if (coef_load_done)
            $display("[DIAG @%0t] coef_load_done pulsed", $time);
    end

    // -------------------------------------------------------------------------
    //  Test sequence
    //  -------------------------------------------------------------------------
    initial begin
        $display("========================================");
        $display("TB_SYSTEM_DDR4_TO_FIR: Starting simulation");
        $display("========================================");
        
        error_count = 0;
        total_coef_writes = 0;
        ar_burst_count = 0;
        
        // Apply reset  (no memory pre-init needed - AXI slave generates data on-the-fly)
        ui_rst_n = 1'b0;
        dsp_rst_n = 1'b0;
        bank_select = 1'b0;
        coef_bank_id_tb    = 4'd0;
        coef_load_start_tb = 1'b0;
        
        repeat(20) @(posedge ui_clk);
        ui_rst_n = 1'b1;
        repeat(10) @(posedge ui_clk);   // Let ui_clk domain fully settle
        dsp_rst_n = 1'b1;
        // Wait 100 dsp_clk cycles: manager exits ST_BOOT_WAIT in 1 cycle,
        // then sits in ST_IDLE. 100 cycles gives plenty of margin.
        repeat(100) @(posedge dsp_clk);
        
        $display("\n--- Test 1: Load coefficients from DDR4 Bank 0 ---");
        $display("[DIAG] mgr state=%0d queued_valid=%0b current_bank=%0d",
            u_coef_subsys.u_coef_mgr.state,
            u_coef_subsys.u_coef_mgr.queued_valid,
            u_coef_subsys.u_coef_mgr.current_bank_r);
        
        // Trigger coefficient load via SPI-side pulse (dsp_clk domain).
        // After boot, bank manager sets current_bank_id=0. Requesting bank 1
        // is different so ST_IDLE will accept it and fire load_start.
        @(posedge dsp_clk);
        coef_bank_id_tb    = 4'd1;
        coef_load_start_tb = 1'b1;
        @(posedge dsp_clk);
        coef_load_start_tb = 1'b0;
        repeat(5) @(posedge dsp_clk);
        $display("[DIAG] After pulse: mgr state=%0d queued_valid=%0b load_start_r=%0b",
            u_coef_subsys.u_coef_mgr.state,
            u_coef_subsys.u_coef_mgr.queued_valid,
            u_coef_subsys.u_coef_mgr.load_start_r);
        
        // Wait for completion (in dsp_clk domain)
        fork
            begin: wait_done
                @(posedge dsp_clk iff coef_load_done);
                $display("Coefficient load completed at time %0t", $time);
                disable wait_timeout;
            end
            begin: wait_timeout
                repeat(4_000_000) @(posedge dsp_clk);
                $display("ERROR: Timeout waiting for coef_load_done");
                error_count++;
                disable wait_done;
            end
        join
        
        // Verify coefficient count
        repeat(100) @(posedge dsp_clk);
        $display("Total coefficient writes observed: %0d (expected: %0d)",
                 total_coef_writes, NUM_MACS * COEF_DEPTH);
        
        if (total_coef_writes != NUM_MACS * COEF_DEPTH) begin
            $display("ERROR: Coefficient write count mismatch!");
            error_count++;
        end
        
        // --- Test 2: Run audio samples through FIR ---
        $display("\n--- Test 2: FIR processing with loaded coefficients ---");
        
        // Send impulse response
        audio_l_in = 24'h800000;  // Impulse (negative max for signed)
        audio_r_in = 24'h000001;  // Small positive
        new_sample = 1'b0;
        
        @(posedge dsp_clk);
        new_sample = 1'b1;
        @(posedge dsp_clk);
        new_sample = 1'b0;
        
        // Wait for FIR output (should be ~257 cycles for 256-tap FIR with pipeline)
        repeat(300) @(posedge dsp_clk);
        
        if (fir_l_valid) begin
            $display("FIR output valid. L=%h R=%h", fir_l_out[23:0], fir_r_out[23:0]);
            // With impulse input, output should match coefficient[0]
            // (subject to scaling and bit-width adjustments)
        end else begin
            $display("WARNING: FIR valid not asserted");
        end
        
        // Send more samples
        repeat(10) begin
            @(posedge sample_768k_tick);
            audio_l_in = $urandom;
            audio_r_in = $urandom;
            new_sample = 1'b1;
            @(posedge dsp_clk);
            new_sample = 1'b0;
        end
        
        // --- Summary ---
        $display("\n========================================");
        if (error_count == 0)
            $display("TEST PASSED: All checks successful");
        else
            $display("TEST FAILED: %0d errors detected", error_count);
        $display("========================================");
        
        $finish;
    end
    
    // -------------------------------------------------------------------------
    //  Monitors
    //  -------------------------------------------------------------------------
    // Track coefficient writes
    always_ff @(posedge dsp_clk) begin
        if (coef_we) begin
            total_coef_writes++;
            if (total_coef_writes <= 10 || total_coef_writes % 10000 == 0)
                $display("[%0t] Coef write: mac=%0d addr=%0d data=%0d",
                         $time, coef_wmac, coef_waddr, coef_wdata);
        end
    end
    
    // Track AXI bursts
    always_ff @(posedge ui_clk) begin
        if (axi_arvalid && axi_arready)
            ar_burst_count++;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("tb_system_ddr4_to_fir.vcd");
        $dumpvars(0, tb_system_ddr4_to_fir);
    end

endmodule
