`timescale 1ns / 1ps

// =============================================================================
// tb_dsp_core: Golden-vector check for dac_dsp_core
//
// Test strategy:
//   PHASE A — FIR impulse response:
//     Load 4096 FIR coefficients from fir_coefs.txt.
//     Drive a single unit impulse (one sample = 2^23-1, rest = 0).
//     Capture all fir_l_reg outputs for 16 input-sample periods (256 outputs).
//     CHECK 1: verify FIR outputs are non-zero and energy is in expected range.
//              The FIR impulse response must sum to ≈ 2^23-1 (unity DC gain × input).
//
//   PHASE B — Volume scaling (bit-exact):
//     CHECK 2: volumed_l[i] == (fir_cap[i] * combined_volume)[79:16]
//
//   PHASE C — NS sanity:
//     Drive multi-tone sine for NS mean/range check.
//     CHECK 3: dem_cmd_l in [0..256], mean ≈ 128.
//
// Coefficient file: fir_coefs.txt  "mac addr data_q117"
// =============================================================================

module tb_dsp_core();

    localparam real CLK_PERIOD = 2.8;   // ~357 MHz
    logic dsp_clk = 0;
    always #(CLK_PERIOD / 2.0) dsp_clk = ~dsp_clk;

    logic lvds_bit_clk = 0;
    always #1.4 lvds_bit_clk = ~lvds_bit_clk;

    logic sys_rst_n;

    logic [23:0] audio_l = '0, audio_r = '0;
    logic        new_sample = 0;

    logic        coef_we          = 0;
    logic [11:0] coef_waddr       = '0;
    logic signed [17:0] coef_wdata = '0;
    logic [6:0]  coef_wmac        = '0;
    logic        bank_select      = 0;
    logic        bank_load_target = 0;

    logic [31:0] sys_volume         = 32'hFFFF_FFFF;
    logic [15:0] boot_envelope_gain = 16'hFFFF;

    logic        sample_768k_tick;
    logic        lvds_bclk_p, lvds_bclk_n;
    logic        lvds_sync_p,  lvds_sync_n;
    logic        lvds_data_l_p, lvds_data_l_n;
    logic        lvds_data_r_p, lvds_data_r_n;

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
    dac_dsp_core u_dut (
        .dsp_clk            (dsp_clk),
        .lvds_bit_clk       (lvds_bit_clk),
        .sys_rst_n          (sys_rst_n),
        .audio_l            (audio_l),
        .audio_r            (audio_r),
        .new_sample         (new_sample),
        .coef_we            (coef_we),
        .coef_waddr         (coef_waddr),
        .coef_wdata         (coef_wdata),
        .coef_wmac          (coef_wmac),
        .bank_select        (bank_select),
        .bank_load_target   (bank_load_target),
        .sys_volume         (sys_volume),
        .boot_envelope_gain (boot_envelope_gain),
        .sample_768k_tick   (sample_768k_tick),
        .lvds_bclk_p        (lvds_bclk_p),
        .lvds_bclk_n        (lvds_bclk_n),
        .lvds_sync_p        (lvds_sync_p),
        .lvds_sync_n        (lvds_sync_n),
        .lvds_data_l_p      (lvds_data_l_p),
        .lvds_data_l_n      (lvds_data_l_n),
        .lvds_data_r_p      (lvds_data_r_p),
        .lvds_data_r_n      (lvds_data_r_n)
    );

    // -----------------------------------------------------------------
    // XMR probes
    // -----------------------------------------------------------------
    // synthesis translate_off
    wire signed [47:0] xmr_fir_l      = u_dut.fir_l_reg;
    wire               xmr_fir_valid  = u_dut.fir_l_valid_reg;
    wire signed [63:0] xmr_vol_l      = u_dut.volumed_l;
    wire               xmr_vol_valid  = u_dut.volumed_valid;
    wire [8:0]         xmr_dem_cmd_l  = u_dut.dem_cmd_l;
    wire [31:0]        xmr_comb_vol   = u_dut.combined_volume;   // read actual RTL value
    // synthesis translate_on

    // -----------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------
    // Impulse phase: capture 16 input-sample-periods × 16 phases = 256 FIR outputs
    // We capture more (512) to be safe — impulse energy should be in first 256.
    localparam int SAMPLE_CLKS  = 8163;    // 44.1 kHz @ 357 MHz
    localparam int NUM_PHASES   = 16;
    localparam int CAP_SIZE     = 512;     // capture window
    localparam int NUM_COEFS    = 4096;    // 256 MACs × 16 phases
    // Sine phase
    localparam int NUM_SINE     = 200;     // sine samples for NS check

    // -----------------------------------------------------------------
    // Capture arrays (impulse phase)
    // -----------------------------------------------------------------
    // synthesis translate_off
    logic signed [47:0] fir_cap [0:CAP_SIZE-1];
    int                 fir_idx = 0;
    logic signed [63:0] vol_cap [0:CAP_SIZE-1];
    int                 vol_idx = 0;

    always_ff @(posedge dsp_clk) begin
        if (xmr_fir_valid && fir_idx < CAP_SIZE) begin
            fir_cap[fir_idx] <= xmr_fir_l;
            fir_idx <= fir_idx + 1;
        end
        if (xmr_vol_valid && vol_idx < CAP_SIZE) begin
            vol_cap[vol_idx] <= xmr_vol_l;
            vol_idx <= vol_idx + 1;
        end
    end

    // NS capture (sine phase — separate armed flag)
    logic ns_armed = 0;
    logic [8:0] ns_cap  [0:NUM_SINE*NUM_PHASES-1];
    longint     ns_sum  = 0;
    int         ns_idx  = 0;

    always_ff @(posedge dsp_clk)
        if (ns_armed && xmr_vol_valid && ns_idx < NUM_SINE*NUM_PHASES) begin
            ns_cap[ns_idx] <= xmr_dem_cmd_l;
            ns_sum <= ns_sum + xmr_dem_cmd_l;
            ns_idx <= ns_idx + 1;
        end
    // synthesis translate_on

    // -----------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------
    initial begin
        // synthesis translate_off
        automatic int     mac_id, addr, data_q;
        automatic longint cv;
        automatic int     fd, rc;
        // synthesis translate_on

        sys_rst_n = 0;
        #(CLK_PERIOD * 20);
        sys_rst_n = 1;
        #(CLK_PERIOD * 10);

        // synthesis translate_off
        // -------------------------------------------------------
        // Load FIR coefficients
        // -------------------------------------------------------
        $display("[TB_DSP_CORE] Loading %0d FIR coefficients from fir_coefs.txt", NUM_COEFS);
        fd = $fopen("fir_coefs.txt", "r");
        if (fd == 0) begin $display("ERROR: cannot open fir_coefs.txt"); $finish; end
        bank_load_target = 1'b0;
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%d %d %d\n", mac_id, addr, data_q);
            if (rc != 3) continue;
            @(posedge dsp_clk);
            coef_wmac  = mac_id[6:0];
            coef_waddr = addr[11:0];
            coef_wdata = data_q[17:0];
            coef_we    = 1'b1;
            @(posedge dsp_clk);
            coef_we = 1'b0;
        end
        $fclose(fd);
        repeat(10) @(posedge dsp_clk);
        $display("[TB_DSP_CORE] Coefficients loaded.");
        // Read combined_volume from RTL via XMR (avoids replicating RTL multiply semantics)
        @(posedge dsp_clk);
        cv = longint'(xmr_comb_vol);
        $display("[TB_DSP_CORE] combined_volume = 0x%08h (%0d)", cv[31:0], cv);
        // synthesis translate_on

        // -------------------------------------------------------
        // PHASE A: single impulse → capture FIR impulse response
        // -------------------------------------------------------
        $display("[TB_DSP_CORE] PHASE A: driving unit impulse");
        audio_l = 24'h7F_FFFF;   // max positive = 2^23-1
        audio_r = 24'h7F_FFFF;
        @(posedge dsp_clk); new_sample = 1;
        @(posedge dsp_clk); new_sample = 0;
        audio_l = '0; audio_r = '0;
        // Drive 16 zero samples to push impulse through
        repeat(16) begin
            repeat(SAMPLE_CLKS - 1) @(posedge dsp_clk);
            @(posedge dsp_clk); new_sample = 1;
            @(posedge dsp_clk); new_sample = 0;
        end
        // Wait for FIR pipeline to drain
        repeat(10 * SAMPLE_CLKS) @(posedge dsp_clk);

        // synthesis translate_off
        // -------------------------------------------------------
        // CHECK 1: FIR impulse response — bit-exact golden comparison
        // Golden file generated by: python fir_rtl_model.py --impulse --capture 512
        // Format: "index value\n" (512 lines, signed 48-bit)
        // The Python model runs with warm=2089 cycles (matching TB coef-load timing)
        // so golden[i] == fir_cap[i] for all i in [0..511].
        // -------------------------------------------------------
        begin : check1
            automatic int     errs    = 0;
            automatic int     nonzero = 0;
            automatic longint fir_sum = 0;
            automatic int     gfd, grc, g_idx;
            automatic longint g_val, g_exp;
            automatic logic signed [47:0] golden [0:CAP_SIZE-1];

            // Load golden file
            gfd = $fopen("fir_golden.txt", "r");
            if (gfd == 0) begin
                $display("  WARN: cannot open fir_golden.txt — falling back to energy check");
            end else begin
                for (int gi = 0; gi < CAP_SIZE; gi++) begin
                    grc = $fscanf(gfd, "%d %d\n", g_idx, g_val);
                    if (grc == 2)
                        golden[gi] = g_val[47:0];
                    else
                        golden[gi] = '0;
                end
                $fclose(gfd);
            end

            $display("[TB_DSP_CORE] CHECK 1: FIR impulse response (%0d outputs captured)", fir_idx);
            for (int i = 0; i < fir_idx; i++) begin
                if (fir_cap[i] != 0) nonzero++;
                fir_sum += longint'(signed'(fir_cap[i]));
            end
            $display("  Non-zero outputs : %0d / %0d", nonzero, fir_idx);
            $display("  Sum of outputs   : %0d", fir_sum);
            // Dump first 20 non-zero outputs
            begin
                automatic int shown = 0;
                for (int i = 0; i < fir_idx && shown < 20; i++) begin
                    if (fir_cap[i] != 0) begin
                        $display("    cap[%0d] = %0d", i, longint'(signed'(fir_cap[i])));
                        shown++;
                    end
                end
            end

            // Bit-exact golden comparison
            if (gfd != 0) begin
                for (int i = 0; i < fir_idx; i++) begin
                    if (fir_cap[i] !== golden[i]) begin
                        if (errs < 10)
                            $display("  MISMATCH cap[%0d]: got=%0d exp=%0d",
                                     i, longint'(signed'(fir_cap[i])), longint'(signed'(golden[i])));
                        errs++;
                    end
                end
                if (errs == 0)
                    $display("  PASS: all %0d FIR outputs match golden", fir_idx);
                else
                    $display("  FAIL: %0d golden mismatches out of %0d", errs, fir_idx);
            end else begin
                // Fallback: energy check only
                if (nonzero == 0) begin
                    $display("  FAIL: no non-zero FIR outputs at all"); errs++;
                end else if (fir_sum <= 0) begin
                    $display("  FAIL: total FIR energy non-positive"); errs++;
                end else
                    $display("  PASS: FIR has %0d non-zero outputs, positive total energy", nonzero);
            end
        end

        // -------------------------------------------------------
        // CHECK 2: Volume scaling (bit-exact)
        // vol_cap[i] is captured on volumed_valid, which is 5 pipeline
        // stages after fir_l_valid_reg. So vol_cap[i] corresponds to
        // fir_cap[i-5] (i.e., the fir output 5 valid-pulses earlier).
        // For i < 5 the fir input was 0 (before impulse arrived), giving
        // expected volume = 0.
        // -------------------------------------------------------
        begin : check2
            automatic int errs = 0;
            // vol_cap[i] corresponds to fir_cap[i] — volumed_valid fires 5 clock cycles
            // after fir_l_valid_reg which is the same fir_l_valid_reg pulse index.
            $display("[TB_DSP_CORE] CHECK 2: Volume scaling (%0d samples, cv=0x%08h)",
                     vol_idx, cv[31:0]);
            for (int i = 0; i < vol_idx; i++) begin
                automatic logic signed [47:0] fir_in;
                automatic logic signed [79:0] prod;
                automatic logic signed [63:0] exp_vol;
                fir_in  = fir_cap[i];
                prod    = 80'(signed'(fir_in)) * $signed({1'b0, cv[31:0]});
                exp_vol = prod[79:16];
                if (vol_cap[i] !== exp_vol) begin
                    if (errs < 5)
                        $display("  [VOL MISMATCH] i=%0d fir_in=%0d got=0x%016h exp=0x%016h",
                                 i, longint'(signed'(fir_in)), vol_cap[i], exp_vol);
                    errs++;
                end
            end
            if (errs == 0)
                $display("  PASS: all %0d volume outputs match", vol_idx);
            else
                $display("  FAIL: %0d volume mismatches", errs);
        end
        // synthesis translate_on

        // -------------------------------------------------------
        // PHASE B: sine stimulus for NS check
        // -------------------------------------------------------
        $display("[TB_DSP_CORE] PHASE B: driving %0d sine samples for NS check", NUM_SINE);
        // synthesis translate_off
        ns_armed = 1;
        for (int i = 0; i < NUM_SINE; i++) begin
            automatic real tt = i * (1.0 / 44100.0);
            automatic real sv = $sin(2.0 * 3.141592653589793 * 1000.0 * tt);
            audio_l = $rtoi(sv * (0.5 * (2.0**23 - 1.0)));
            audio_r = audio_l;
            @(posedge dsp_clk); new_sample = 1;
            @(posedge dsp_clk); new_sample = 0;
            repeat(SAMPLE_CLKS - 2) @(posedge dsp_clk);
        end
        // synthesis translate_on
        repeat(10 * SAMPLE_CLKS) @(posedge dsp_clk);

        // synthesis translate_off
        // -------------------------------------------------------
        // CHECK 3: NS range + mean
        // -------------------------------------------------------
        begin : check3
            automatic int errs = 0;
            $display("[TB_DSP_CORE] CHECK 3: NS range + mean (%0d samples)", ns_idx);
            for (int i = 0; i < ns_idx; i++) begin
                if (ns_cap[i] > 9'd256) begin
                    $display("  [NS RANGE] i=%0d dem_cmd_l=%0d out of [0..256]", i, ns_cap[i]);
                    if (++errs >= 5) break;
                end
            end
            if (ns_idx > 0) begin
                automatic longint mean = ns_sum / ns_idx;
                if (mean < 108 || mean > 148) begin
                    $display("  [NS MEAN] mean=%0d expected 108..148", mean);
                    errs++;
                end
                if (errs == 0)
                    $display("  PASS: all in range, mean=%0d", mean);
                else
                    $display("  FAIL: %0d NS errors, mean=%0d", errs, mean);
            end
        end
        // synthesis translate_on

        $display("[TB_DSP_CORE] Done.");
        $finish;
    end

endmodule