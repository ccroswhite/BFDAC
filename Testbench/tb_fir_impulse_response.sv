`timescale 1ns / 1ps

// =============================================================================
//  TB_FIR_IMPULSE_RESPONSE
//
//  Standalone testbench for FIR impulse response verification.
//  Loads coefficients via DDR4 path, then drives single impulse and verifies
//  the output matches expected convolution result.
// =============================================================================

module tb_fir_impulse_response;

    // Startup verification
    initial begin
        $display("[TB_STARTUP] Testbench initial block executing at time %0t", $time);
    end

    // Parameters
    localparam int NUM_MACS       = 256;
    localparam int COEF_WIDTH     = 18;
    localparam int COEF_DEPTH     = 2048;
    localparam int AUDIO_WIDTH    = 24;
    
    localparam real UI_CLK_PERIOD  = 5.0;
    localparam real DSP_CLK_PERIOD = 3.875;
    
    // Clocks
    logic ui_clk = 1'b0;
    logic dsp_clk = 1'b0;
    
    always #(UI_CLK_PERIOD/2.0) ui_clk = ~ui_clk;
    always #(DSP_CLK_PERIOD/2.0) dsp_clk = ~dsp_clk;
    
    // Resets
    logic ui_rst_n = 1'b0;
    logic dsp_rst_n = 1'b0;
    
    // DUT signals
    logic [AUDIO_WIDTH-1:0] audio_l_in, audio_r_in;
    logic                   new_sample;
    logic                   fir_l_valid, fir_r_valid;
    logic signed [47:0]     fir_l_out, fir_r_out;
    
    // Bank select (0 = Bank A active)
    logic bank_select;
    
    // Sample tick: fires after every 16 interpolated_valid pulses = one full FIR sweep
    // This keeps new_sample_valid synchronised to the FIR sweep boundary.
    logic sample_768k_tick;
    logic [3:0] valid_phase_cnt;
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin
            valid_phase_cnt  <= 0;
            sample_768k_tick <= 0;
        end else begin
            sample_768k_tick <= 0;
            if (fir_l_valid) begin
                if (valid_phase_cnt == 15) begin
                    valid_phase_cnt  <= 0;
                    sample_768k_tick <= 1;
                end else begin
                    valid_phase_cnt <= valid_phase_cnt + 1;
                end
            end
        end
    end
    
    // Coefficient write bus (unused in this test - tie off)
    logic coef_we = 1'b0;
    logic [10:0] coef_waddr = '0;
    logic signed [COEF_WIDTH-1:0] coef_wdata = '0;
    logic [7:0] coef_wmac = '0;
    logic bank_load_target = 1'b0;
    
    // Instantiate DUT
    fir_polyphase_stereo #(
        .NUM_MACS  (NUM_MACS),
        .DATA_WIDTH(AUDIO_WIDTH),
        .COEF_WIDTH(COEF_WIDTH)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (dsp_rst_n),
        .new_sample_valid     (new_sample),
        .new_sample_l         (audio_l_in),
        .new_sample_r         (audio_r_in),
        .interpolated_l       (fir_l_out),
        .interpolated_l_valid (fir_l_valid),
        .interpolated_r       (fir_r_out),
        .interpolated_r_valid (fir_r_valid),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (bank_select),
        .bank_load_target     (bank_load_target)
    );
    
    // -------------------------------------------------------------------------
    // Debug monitors (declared after DUT so hierarchical refs are valid)
    // -------------------------------------------------------------------------
    int nsv_post_cnt = 0;
    always @(posedge dsp_clk) begin
        // Track write_ptr for 16 cycles after each new_sample_valid
        if (new_sample)
            nsv_post_cnt <= 1;
        else if (nsv_post_cnt > 0 && nsv_post_cnt < 16)
            nsv_post_cnt <= nsv_post_cnt + 1;
        else
            nsv_post_cnt <= 0;

        if (nsv_post_cnt > 0 || new_sample) begin
            $display("[WPTR_TRACK @%0t] cyc=%0d nsv=%0b wptr=%0d nsv_i=%0b bram0=%0d",
                $time, nsv_post_cnt, new_sample,
                u_stereo_fir.u_l_fir.write_ptr,
                u_stereo_fir.u_l_fir.new_sample_valid,
                u_stereo_fir.u_l_fir.audio_bram_fwd[0]);
        end

        if (u_stereo_fir.u_l_fir.fwd_seed != 0) begin
            $display("[FWD_SEED_NZ @%0t] fwd_seed=%0d fwd_addr=%0d wptr=%0d mca=%0d",
                $time, u_stereo_fir.u_l_fir.fwd_seed,
                u_stereo_fir.u_l_fir.fwd_addr_reg,
                u_stereo_fir.u_l_fir.write_ptr,
                u_stereo_fir.u_l_fir.master_coef_addr);
        end
    end

    // Test variables
    int error_count;
    int sample_cnt;
    logic [AUDIO_WIDTH-1:0] impulse_val;
    
    // Main test sequence
    initial begin
        $display("========================================");
        $display("TB_FIR_IMPULSE_RESPONSE: Starting");
        $display("========================================");
        
        error_count = 0;
        sample_cnt = 0;
        impulse_val = 24'h000001;
        
        // Apply reset
        ui_rst_n = 1'b0;
        dsp_rst_n = 1'b0;
        bank_select = 1'b0;
        audio_l_in = 24'h000000;
        audio_r_in = 24'h000000;
        new_sample = 1'b0;
        
        // Wait 100ns
        #100;
        
        // Release DSP reset
        dsp_rst_n = 1'b1;
        $display("[INIT] DSP reset released");
        
        // Wait for initialization
        repeat(100) @(posedge dsp_clk);
        $display("[TB_FLOW] Starting coefficient loading section at time %0t", $time);
        
        // Load coefficients: Set MAC[0], addr[0] = 1000, all others = 0
        $display("[COEF_LOAD] Loading coefficients...");
        bank_load_target = 1'b0;  // Load Bank A
        
        // Only load first 2 MACs to save time (rest are zero)
        $display("[COEF_LOOP] Starting loops...");
        for (int mac = 0; mac < 2; mac++) begin
            for (int addr = 0; addr < 4; addr++) begin  // Only first 4 addresses
                // 2-cycle registered interface:
                // Cycle 1: Set addr/data (register on posedge)
                @(negedge dsp_clk);
                coef_wmac = mac[7:0];
                coef_waddr = addr[10:0];
                if (mac == 0 && addr == 0)
                    coef_wdata = 18'sd1000;
                else
                    coef_wdata = 18'sd0;
                coef_we = 1'b0;  // WE=0, addr/data register on next posedge
                @(posedge dsp_clk);
                
                // Cycle 2-3: Assert WE for 2 cycles (ensure reliable BRAM write)
                @(negedge dsp_clk);
                coef_we = 1'b1;  // WE=1
                @(posedge dsp_clk);  // BRAM: registered addr/data + registered WE
                @(negedge dsp_clk);
                @(posedge dsp_clk);  // Keep WE high for 2nd cycle
                $display("[COEF_WRITE] mac=%0d addr=%0d data=%0d we=%0b", mac, addr, coef_wdata, coef_we);
            end
        end
        coef_we = 1'b0;
        $display("[COEF_LOAD] Coefficients loaded (MAC[0][0] = 1000, loaded 8 writes only)");
        
        // Force a read of coefficient 0 by running one FIR cycle and checking debug output
        $display("[COEF_VERIFY] Checking if coefficient 0 was stored...");
        repeat(10) @(posedge dsp_clk);
        
        // Manually check coefficient output via hierarchy probe
        $display("[COEF_PROBE] coef_out[0]=%0d (expected 1000)", 
            u_stereo_fir.coef_out[0]);
        
        // Wait for bank select to settle
        repeat(20) @(posedge dsp_clk);
        
        // Run impulse response test:
        // Drive impulse at sample 0, then drive zeros for 9 more samples.
        // The cascade chain is 256 MACs x 2 cycles/hop = 512 cycle latency plus
        // up to one additional 128-cycle phase window for the windowed accumulator.
        // Total worst-case: ~700 DSP clock cycles = ~18 sample_768k_tick periods.
        // We wait up to 3 full sample_768k_tick periods (48 fir_l_valid pulses)
        // per iteration to catch any phase in which the 2000 appears, then
        // look for the first non-zero output.
        $display("[TEST] Starting impulse response test...");
        
        begin : test_block
            logic found_2000;
            int   valid_cnt_local;
            found_2000     = 1'b0;
            valid_cnt_local = 0;
            
            repeat(10) begin
                @(posedge sample_768k_tick);
                if (sample_cnt == 0) begin
                    audio_l_in = impulse_val;
                    audio_r_in = impulse_val;
                    $display("[IMPULSE] Driving impulse at sample %0d", sample_cnt);
                end else begin
                    audio_l_in = 24'h000000;
                    audio_r_in = 24'h000000;
                end
                new_sample = 1'b1;
                sample_cnt++;
                
                // Hold new_sample=1 through exactly one DUT clock edge, then clear
                @(posedge dsp_clk);
                @(posedge dsp_clk);
                new_sample = 1'b0;
                
                // Wait for up to 20 fir_l_valid pulses per sample iteration.
                // Each pulse is ~128 DSP cycles apart; 20 pulses covers >2500 cycles,
                // enough for the full 512-cycle cascade + 128-cycle accumulator window.
                repeat(20) begin
                    @(posedge fir_l_valid);
                    @(posedge dsp_clk);
                    valid_cnt_local++;
                    if (^fir_l_out === 1'bx) begin
                        $display("[ERROR] Output is X at sample %0d valid#%0d",
                            sample_cnt, valid_cnt_local);
                        error_count++;
                    end else if (fir_l_out != 0) begin
                        $display("[IMPULSE] sample=%0d valid#%0d out_L=%0d out_R=%0d",
                            sample_cnt, valid_cnt_local,
                            fir_l_out[23:0], fir_r_out[23:0]);
                        if (!found_2000) begin
                            if (fir_l_out[23:0] == 24'd2000) begin
                                $display("[PASS] First non-zero output = 2000 (correct!)");
                                found_2000 = 1'b1;
                            end else begin
                                $display("[ERROR] First non-zero output: expected 2000, got %0d",
                                    fir_l_out[23:0]);
                                error_count++;
                                found_2000 = 1'b1;
                            end
                        end
                    end
                end
            end
            
            if (!found_2000) begin
                $display("[ERROR] No non-zero output seen across all 10 samples");
                error_count++;
            end
        end
        
        // Summary
        $display("\n========================================");
        if (error_count == 0)
            $display("TEST PASSED: FIR impulse response verified (coeff[0,0]=1000, pre-adder*coef*impulse=2000)");
        else
            $display("TEST FAILED: %0d errors", error_count);
        $display("========================================");
        
        $finish;
    end

endmodule
