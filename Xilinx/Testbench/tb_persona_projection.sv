`timescale 1ns / 1ps

// =============================================================================
//  TB_PERSONA_PROJECTION
//
//  Projects a generated persona coefficient bank through the REAL load +
//  interpolate + voicing-shaper path and dumps output samples for analysis:
//
//    $readmemh AXI image (bfdac_voicing_gen --emit-sim-hex)
//      -> dac_coef_subsys (dir scan, schema-4 unpack, bank manager)
//        -> fir_polyphase_stereo (1A persona + 1B halfband cascade)
//          -> dac_voicing_shaper x2 (probe: interp pre-shaper, vox post-shaper)
//
//  Sim geometry: NUM_MACS=4, TAPS_PER_PHASE=256, SPLIT_MACS=2
//  (per-MAC URAM structure identical to production; schema-4 outer/split
//  paths both exercised). The generator's q_eff target is recomputed at the
//  same geometry, so RTL-vs-design comparison is self-consistent.
//
//  Plusargs:
//    +IMAGE=<hex>      unified DDR4 image (dir @0x3FFF0000, payload @0)
//    +FID=<hex>        filter_id to load by directory ID
//    +RATE=<0..3>      rate_shift
//    +VOEN=<0|1>       voicing_en driven on the shapers
//    +K2=<s32>         k2 Q2.25 (decimal, signed)
//    +K3=<s32>         k3 Q2.25 (decimal, signed)
//    +STIM=impulse|dc|tone   stimulus kind
//    +AMP=<0..8388607> input amplitude LSBs (default: 0.891 FS = -1 dBFS)
//    +TONE_CYCLE=<n>   sine LUT length -> f0 = Fs_in / TONE_CYCLE
//    +NSAMP=<n>        input samples to stream (default 12288)
//    +OUT=<file>       capture path: "i|v <l_hex> <r_hex>" per output valid
// =============================================================================

module tb_persona_projection;

    localparam int NUM_MACS       = 4;
    localparam int SPLIT_MACS     = 2;
    localparam int TAPS_PER_PHASE = 256;
    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE;
    localparam int COEF_WIDTH     = 18;
    localparam int AUDIO_WIDTH    = 24;
    localparam int AXI_DATA_WIDTH = 128;

    localparam real UI_CLK_PERIOD  = 3.333;   // 300 MHz MIG ui_clk
    localparam real DSP_CLK_PERIOD = 2.8;     // ~357 MHz dsp_clk
    localparam int SAMPLE_DIV      = 465;     // 768 kHz frame tick

    // ---- Clocks / resets --------------------------------------------------
    logic ui_clk = 0, dsp_clk = 0;
    always #(UI_CLK_PERIOD/2.0)  ui_clk  = ~ui_clk;
    always #(DSP_CLK_PERIOD/2.0) dsp_clk = ~dsp_clk;

    logic ui_rst_n = 0, dsp_rst_n = 0;

    // ---- Plusargs ----------------------------------------------------------
    string        image_path, stim_kind, out_path;
    logic [15:0]  fid;
    logic [15:0]  fid_list [0:255];
    int           n_fids;
    int           rate_shift_i, tone_cycle, nsamp, amp_in;
    logic         voen;
    int           k2_i, k3_i;

    initial begin
        string fids_arg;
        if (!$value$plusargs("IMAGE=%s", image_path)) image_path = "proj.hex";
        if ($value$plusargs("FIDS=%s", fids_arg)) begin
            // comma-separated hex FIDs, e.g. +FIDS=0000,0208,0400
            int p0 = 0, p1;
            n_fids = 0;
            forever begin
                p1 = p0;
                while (p1 < fids_arg.len() && fids_arg.substr(p1, p1) != ",") p1++;
                void'($sscanf(fids_arg.substr(p0, p1-1), "%h", fid_list[n_fids]));
                n_fids++;
                if (p1 >= fids_arg.len()) break;
                p0 = p1 + 1;
            end
        end else begin
            if (!$value$plusargs("FID=%h", fid)) fid = 16'h0000;
            fid_list[0] = fid;
            n_fids = 1;
        end
        fid = fid_list[0];
        rate_shift_i = fid[2:1];   // rc[2:0]=fid[2:0]: [2:1]=rate_shift, [0]=family
        $display("[PERSONA] %0d fids; first rc=%0d -> rate_shift=%0d fam=%0d",
                 n_fids, fid[2:0], rate_shift_i, fid[0]);
        if (!$value$plusargs("STIM=%s",  stim_kind))  stim_kind  = "impulse";
        if (!$value$plusargs("AMP=%d",   amp_in))     amp_in     = 7474300; // ~-1 dBFS
        if (!$value$plusargs("TONE_CYCLE=%d", tone_cycle)) tone_cycle = 128;
        if (!$value$plusargs("NSAMP=%d", nsamp))      nsamp      = 12288;
        if (!$value$plusargs("OUT=%s",   out_path))   out_path   = "persona_cap.txt";
        if (!$value$plusargs("VOEN=%d",  voen))       voen       = 1'b0;
        if (!$value$plusargs("K2=%d",    k2_i))       k2_i       = 0;
        if (!$value$plusargs("K3=%d",    k3_i))       k3_i       = 0;
    end

    // ---- AXI memory image ----------------------------------------------------
    // 128-bit beats indexed by word address (byte_addr >> 4); $readmemh
    // resolves the file's @word-address sections.
    logic [AXI_DATA_WIDTH-1:0] ddr_mem [longint unsigned];

    initial begin
        // $readmemh into an associative array ignores @word-address section
        // headers (loads sequentially), so parse the image explicitly:
        // '@hex' sets the next word index; 32-hex-digit lines are 128b beats.
        int fd, code, n;
        string line;
        longint unsigned wa;
        logic [AXI_DATA_WIDTH-1:0] beat;
        $display("[PERSONA] loading image %s", image_path);
        fd = $fopen(image_path, "r");
        if (fd == 0) $fatal(1, "cannot open IMAGE=%s", image_path);
        n = 0;
        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0) continue;
            if (line.substr(0, 0) == "@") begin
                wa = 0;
                void'($sscanf(line.substr(1, line.len()-1), "%h", wa));
            end else begin
                beat = '0;
                void'($sscanf(line, "%h", beat));
                ddr_mem[wa] = beat;
                wa++;
                n++;
            end
        end
        $fclose(fd);
        $display("[PERSONA] image loaded: %0d words", n);
    end

    // ---- AXI read channel ----------------------------------------------------
    logic [31:0]               axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid, axi_arready;
    logic [AXI_DATA_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast, axi_rvalid, axi_rready;

    typedef enum logic [1:0] {AR_IDLE, AR_LATENCY, R_BURST} r_state_t;
    r_state_t    r_state;
    logic [31:0] slave_araddr;
    logic [7:0]  slave_arlen, r_beat_cnt;
    int          latency_cnt;

    always_ff @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            axi_arready <= 1'b0; axi_rvalid <= 1'b0; axi_rlast <= 1'b0;
            axi_rdata <= '0;     r_state <= AR_IDLE;
        end else begin
            case (r_state)
                AR_IDLE: begin
                    axi_arready <= 1'b1;
                    axi_rvalid  <= 1'b0;
                    if (axi_arvalid && axi_arready) begin
                        slave_araddr <= {2'b00, axi_araddr};
                        slave_arlen  <= axi_arlen;
                        axi_arready  <= 1'b0;
                        latency_cnt  <= 4;
                        r_state      <= AR_LATENCY;
                    end
                end
                AR_LATENCY: begin
                    if (latency_cnt > 0) latency_cnt <= latency_cnt - 1;
                    else begin r_beat_cnt <= 8'd0; r_state <= R_BURST; end
                end
                R_BURST: begin
                    if (!axi_rvalid || axi_rready) begin
                        longint unsigned wa;
                        wa = longint'(slave_araddr + 32'(r_beat_cnt) * 16) >> 4;
                        axi_rvalid <= 1'b1;
                        axi_rdata  <= ddr_mem.exists(wa) ? ddr_mem[wa] : '0;
                        if (slave_araddr >= 32'h3FFF_0000)
                            $display("[AXI] dir wa=%0h hit=%0d data=%032h",
                                     wa, ddr_mem.exists(wa), ddr_mem.exists(wa) ? ddr_mem[wa] : '0);
                        axi_rlast  <= (r_beat_cnt == slave_arlen);
                        if (r_beat_cnt == slave_arlen) r_state <= AR_IDLE;
                        else                           r_beat_cnt <= r_beat_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
    assign axi_rresp = 2'b00;

    // ---- 768 kHz tick (dsp_clk) ----------------------------------------------
    logic        sample_768k_tick;
    logic [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin sample_cnt <= '0; sample_768k_tick <= 1'b0; end
        else begin
            sample_768k_tick <= (sample_cnt == SAMPLE_DIV-1);
            sample_cnt <= (sample_cnt == SAMPLE_DIV-1) ? '0 : sample_cnt + 1'b1;
        end
    end

    // ---- Coef bus / control --------------------------------------------------
    logic                          coef_we;
    logic [$clog2(COEF_DEPTH)-1:0] coef_waddr;
    logic signed [COEF_WIDTH-1:0]  coef_wdata;
    logic [$clog2(NUM_MACS+SPLIT_MACS+1)-1:0] coef_wmac;
    wire  bank_select, bank_load_target;
    logic [3:0] current_bank_id;
    logic mgr_busy, bank_valid, coef_load_done, coef_load_err;
    logic [2:0] coef_load_err_code;
    logic [15:0] boot_envelope_gain;

    logic        filter_load_req_tb = 1'b0;
    logic [15:0] filter_id_tb       = 16'd0;
    logic        boot_ok_tb         = 1'b0;
    logic [3:0]  coef_bank_id_tb    = 4'd0;
    logic        coef_load_start_tb = 1'b0;

    // ---- Audio ---------------------------------------------------------------
    logic [AUDIO_WIDTH-1:0] audio_l_in = '0, audio_r_in = '0;
    logic        new_sample = 1'b0;
    logic [47:0] interp_l, interp_r;
    wire         interp_l_valid, interp_r_valid;
    wire         fir_frame_done_w, input_overrun;
    logic        fir_rst_n = 1'b0;

    // ---- DUT: coefficient subsystem -------------------------------------------
    dac_coef_subsys #(
        .NUM_MACS       (NUM_MACS),
        .SPLIT_MACS     (SPLIT_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE)
    ) u_coef_subsys (
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (~ui_rst_n),
        .dsp_clk            (dsp_clk),
        .sys_rst_n          (dsp_rst_n),
        .ext_rst_n          (dsp_rst_n),
        .stream_rate        ({fid[2:1], ~fid[0]}),  // stream_rate fam bit inverted vs dir/FID
        .enforce_stream_rate(1'b1),
        .sample_768k_tick   (sample_768k_tick),
        .fir_frame_done     (fir_frame_done_w),
        .coef_bank_id       (coef_bank_id_tb),
        .coef_load_start    (coef_load_start_tb),
        .filter_id          (filter_id_tb),
        .filter_load_req    (filter_load_req_tb),
        .voicing_commit_toggle (1'b0),
        .voicing_sh_en      (1'b0),
        .voicing_sh_k2      ('0),
        .voicing_sh_k3      ('0),
        .voicing_sh_fid     (16'hFFFF),
        .voicing_err_seen   (1'b0),
        .boot_ok            (boot_ok_tb),
        .m_axi_araddr       (axi_araddr),
        .m_axi_arlen        (axi_arlen),
        .m_axi_arsize       (axi_arsize),
        .m_axi_arburst      (axi_arburst),
        .m_axi_arvalid      (axi_arvalid),
        .m_axi_arready      (axi_arready),
        .m_axi_rdata        (axi_rdata),
        .m_axi_rresp        (axi_rresp),
        .m_axi_rlast        (axi_rlast),
        .m_axi_rvalid       (axi_rvalid),
        .m_axi_rready       (axi_rready),
        .coef_we            (coef_we),
        .coef_waddr         (coef_waddr),
        .coef_wdata         (coef_wdata),
        .coef_wmac          (coef_wmac),
        .bank_select        (bank_select),
        .bank_load_target   (bank_load_target),
        .boot_envelope_gain (boot_envelope_gain),
        .voicing_en         (),
        .voicing_k2         (),
        .voicing_k3         (),
        .voicing_ack_toggle (),
        .voicing_swap_busy  (),
        .voicing_err_toggle (),
        .voicing_applied_fid(),
        .voicing_bank_chg   (),
        .voicing_applied_en (),
        .current_bank_id    (current_bank_id),
        .mgr_busy           (mgr_busy),
        .bank_valid         (bank_valid),
        .coef_load_done     (coef_load_done),
        .coef_load_err      (coef_load_err),
        .coef_load_err_code (coef_load_err_code)
    );

    // ---- DUT: stereo FIR (1A persona + 1B halfband cascade) --------------------
    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .SPLIT_MACS     (SPLIT_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (AUDIO_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (48)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (fir_rst_n),
        .rate_shift           (2'(rate_shift_i)),
        .input_overrun        (input_overrun),
        .new_sample_valid     (new_sample),
        .new_sample_l         (audio_l_in),
        .new_sample_r         (audio_r_in),
        .interpolated_l       (interp_l),
        .interpolated_l_valid (interp_l_valid),
        .interpolated_r       (interp_r),
        .interpolated_r_valid (interp_r_valid),
        .input_frame_done     (fir_frame_done_w),
        .coef_we              (coef_we),
        .coef_waddr           (coef_waddr),
        .coef_wdata           (coef_wdata),
        .coef_wmac            (coef_wmac),
        .bank_select          (bank_select),
        .bank_load_target     (bank_load_target)
    );

    // ---- DUT: voicing shapers (probe point) -----------------------------------
    logic [47:0] vox_l, vox_r;
    wire         vox_l_valid, vox_r_valid;

    dac_voicing_shaper #(.DATA_WIDTH(48), .FS_SHIFT(41)) u_vox_l (
        .clk        (dsp_clk),
        .rst_n      (fir_rst_n),
        .in_valid   (interp_l_valid),
        .data_in    (interp_l),
        .voicing_en (voen),
        .k2         (27'(k2_i)),
        .k3         (27'(k3_i)),
        .out_valid  (vox_l_valid),
        .data_out   (vox_l)
    );

    dac_voicing_shaper #(.DATA_WIDTH(48), .FS_SHIFT(41)) u_vox_r (
        .clk        (dsp_clk),
        .rst_n      (fir_rst_n),
        .in_valid   (interp_r_valid),
        .data_in    (interp_r),
        .voicing_en (voen),
        .k2         (27'(k2_i)),
        .k3         (27'(k3_i)),
        .out_valid  (vox_r_valid),
        .data_out   (vox_r)
    );

    // ---- Capture ---------------------------------------------------------------
    int out_fd;
    initial begin
        out_fd = $fopen(out_path, "w");
        if (out_fd == 0) $fatal(1, "cannot open OUT=%s", out_path);
    end
    always @(posedge dsp_clk) begin
        if (interp_l_valid)
            $fwrite(out_fd, "i %012h %012h\n", interp_l, interp_r);
        if (vox_l_valid)
            $fwrite(out_fd, "v %012h %012h\n", vox_l, vox_r);
    end

    // ---- Probes ----------------------------------------------------------------
    int n_samp_driven = 0, n_frame_done = 0, n_interp = 0;
    int n_coef_writes [int];
    always @(posedge dsp_clk) begin
        if (new_sample)      n_samp_driven++;
        if (fir_frame_done_w) n_frame_done++;
        if (interp_l_valid)  n_interp++;
        if (coef_we)         n_coef_writes[int'(coef_wmac)]++;
    end
    final begin
        $display("[PERSONA] probes: driven=%0d frame_done=%0d interp_valid=%0d overrun=%0d busy=%0d",
                 n_samp_driven, n_frame_done, n_interp, input_overrun, mgr_busy);
        foreach (n_coef_writes[s]) $display("[PERSONA]   coef slot %0d: %0d writes", s, n_coef_writes[s]);
        begin : uram_audit
            int nz0, nz1, nz2;
            nz0 = 0; nz1 = 0; nz2 = 0;
            for (int a = 0; a < 4096; a++) begin
                if (u_stereo_fir.gen_ch[0].gen_uram_coef[0].uram_mem[a] != '0) nz0++;
                if (u_stereo_fir.gen_ch[0].gen_uram_coef[1].uram_mem[a] != '0) nz1++;
                if (u_stereo_fir.gen_ch[0].gen_uram_coef[2].uram_mem[a] != '0) nz2++;
            end
            $display("[PERSONA]   URAM0(outer) nonzero=%0d  URAM1(mac2)=%0d  URAM2(mac3)=%0d",
                     nz0, nz1, nz2);
        end
    end

    // ---- Stimulus ---------------------------------------------------------------
    // One input sample every 16>>rate_shift output ticks (rs0: 48k@16,
    // rs1: 96k@8, rs2: 192k@4, rs3: 384k@2). The feeder runs FOREVER from t=0:
    // the bank manager's atomic swap needs fir_frame_done, which only exists
    // while input frames stream, so zeros must flow before the first load.
    localparam int SAMP_TONE_TAB = 4096;
    logic [AUDIO_WIDTH-1:0] tone_tab [0:SAMP_TONE_TAB-1];
    initial begin
        for (int i = 0; i < SAMP_TONE_TAB; i++)
            tone_tab[i] = AUDIO_WIDTH'($rtoi(8388607.0 * $sin(6.283185307179586 * i / SAMP_TONE_TAB)));
    end

    logic        slot_pulse = 1'b0;
    logic [23:0] feed_val   = '0;

    task automatic feed_forever;
        forever begin
            repeat (16 >> rate_shift_i) @(posedge sample_768k_tick);
            @(posedge dsp_clk);
            audio_l_in <= feed_val;
            audio_r_in <= '0;
            new_sample <= 1'b1;
            @(posedge dsp_clk);
            new_sample <= 1'b0;
            slot_pulse <= ~slot_pulse;
        end
    endtask

    int errors = 0;
    task automatic run_stimulus;
        int step = SAMP_TONE_TAB / tone_cycle;
        for (int i = 0; i < nsamp; i++) begin
            unique case (stim_kind)
                "impulse": feed_val <= (i == 0) ? 24'h7FFFFF : '0;
                "dc":      feed_val <= 24'h7FFFFF;
                "tone":    feed_val <= tone_tab[(i * step) % SAMP_TONE_TAB];
                default:   feed_val <= '0;
            endcase
            @(posedge slot_pulse);   // one slot consumed
        end
        feed_val <= '0;
    endtask

    // ---- Sequence ---------------------------------------------------------------
    task automatic filter_load(input [15:0] id);
        @(posedge dsp_clk); filter_id_tb       <= id;
        @(posedge dsp_clk); filter_load_req_tb <= ~filter_load_req_tb;
    endtask

    initial begin
        repeat (20) @(posedge dsp_clk);
        ui_rst_n  <= 1'b1;
        dsp_rst_n <= 1'b1;
        fir_rst_n <= 1'b1;
        repeat (50) @(posedge dsp_clk);
        boot_ok_tb <= 1'b1;
        fork feed_forever(); join_none
        repeat (200) @(posedge dsp_clk);

        for (int fi = 0; fi < n_fids; fi++) begin
            fid = fid_list[fi];
            rate_shift_i = fid[2:1];
            $display("[PERSONA] load-by-id FID=0x%04h rate_shift=%0d stim=%s voen=%0d k2=%0d k3=%0d",
                     fid, rate_shift_i, stim_kind, voen, k2_i, k3_i);
            filter_load(fid);

            fork
                begin : w_done
                    wait (!coef_load_done);
                    @(posedge coef_load_done);
                    disable w_to;
                end
                begin : w_to
                    repeat (4_000_000) @(posedge dsp_clk);
                    $display("FAIL: FID 0x%04h timeout waiting for coef_load_done", fid);
                    errors++;
                    disable w_done;
                end
            join
            if (coef_load_err) begin
                $display("FAIL: FID 0x%04h coef_load_err code=%0d", fid, coef_load_err_code);
                errors++;
            end
            fork : bv_wait
                begin wait (bank_valid); end
                begin
                    repeat (256 * SAMPLE_DIV) @(posedge dsp_clk);
                    $display("FAIL: FID 0x%04h bank_valid timeout (mgr_busy=%0d err=%0d code=%0d)",
                             fid, mgr_busy, coef_load_err, coef_load_err_code);
                    errors++;
                end
            join_any
            disable bv_wait;
            if (bank_valid)
                $display("[PERSONA] bank 0x%04h loaded, running %0d samples", fid, nsamp);

            $fwrite(out_fd, "f %04h\n", fid);   // per-FID capture marker
            run_stimulus();
            repeat (2 * SAMPLE_DIV) @(posedge dsp_clk);
        end
        $fclose(out_fd);

        if (input_overrun) begin
            $display("FAIL: input_overrun asserted");
            errors++;
        end
        if (errors == 0) $display("PERSONA_PROJECTION PASS: capture -> %s", out_path);
        else             $display("PERSONA_PROJECTION FAIL: errors=%0d", errors);
        $finish;
    end

endmodule
