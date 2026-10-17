`timescale 1ns / 1ps

// =============================================================================
//  TB_SYSTEM_DDR4_TO_FIR  (rewritten 2026-09-03, progress.md TODO-19)
//
//  End-to-end coefficient path at the RELEASE geometry (TAPS_PER_PHASE=256,
//  NUM_MACS scaled 256 -> 64 for sim time; same per-MAC burst structure):
//
//    AXI memory model (on-the-fly data + filter directory)
//      -> dac_coef_subsys (loader @ ui_clk, CDC, bank manager, boot envelope)
//      -> fir_polyphase_stereo (URAM coefficient banks, dsp_clk)
//
//  Tests
//    T1  request before boot_ok is QUEUED: no AXI traffic, bank_valid=0,
//        boot envelope fully muted                         (TODO-16)
//    T2  boot_ok -> queued legacy-slot load runs; write count, swap, bank_valid
//    T3  boot fade-in starts after the first good load     (TODO-16)
//    T4  FIR impulse -> interpolated output valid and X-free
//    T5  directory load by ID while the FIR runs (gapless): writes, swap,
//        no load_err, FIR output still X-free               (TODO-23 path)
//    T6  directory miss   -> coef_load_err code 1, no swap
//    T7  payload mismatch -> coef_load_err code 2, no swap
// =============================================================================

module tb_system_ddr4_to_fir;

    // ---- Geometry -------------------------------------------------------------
    localparam int NUM_MACS       = 64;
    localparam int TAPS_PER_PHASE = 256;
    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE;      // 4096
    localparam int COEF_WIDTH     = 18;
    localparam int AUDIO_WIDTH    = 24;
    localparam int AXI_DATA_WIDTH = 128;

    localparam logic [31:0] BANK_SIZE     = 32'(NUM_MACS * COEF_DEPTH * 4);  // 1 MB
    localparam logic [31:0] DIR_BASE_ADDR = 32'h3FFF_0000;                    // loader default
    localparam int          MAC_BYTES     = COEF_DEPTH * 4;

    // Directory contents served by the AXI model (32-byte entries)
    localparam logic [15:0] FILT_OK_ID   = 16'h0101;  // -> bank-2 region, payload = BANK_SIZE
    localparam logic [15:0] FILT_BAD_SZ  = 16'h0202;  // payload = BANK_SIZE/2 -> FILT_SIZE
    localparam logic [15:0] FILT_MISSING = 16'h0404;  // not in directory

    localparam real UI_CLK_PERIOD  = 3.333;  // 300 MHz MIG ui_clk
    localparam real DSP_CLK_PERIOD = 2.8;    // ~357 MHz

    // ---- Clocks / resets ------------------------------------------------------
    logic ui_clk = 0, dsp_clk = 0;
    always #(UI_CLK_PERIOD/2.0)  ui_clk  = ~ui_clk;
    always #(DSP_CLK_PERIOD/2.0) dsp_clk = ~dsp_clk;
    logic ui_rst_n = 0, dsp_rst_n = 0;

    // ---- AXI (ui_clk) -----------------------------------------------------------
    logic [29:0]               axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid, axi_arready;
    logic [AXI_DATA_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast, axi_rvalid, axi_rready;

    // ---- Coef bus / bank control (dsp_clk) ---------------------------------------
    logic                          coef_we;
    logic [$clog2(COEF_DEPTH)-1:0] coef_waddr;
    logic signed [COEF_WIDTH-1:0]  coef_wdata;
    logic [$clog2(NUM_MACS)-1:0]   coef_wmac;
    wire  bank_select, bank_load_target;
    logic [3:0] current_bank_id;
    logic mgr_busy, bank_valid, coef_load_done, coef_load_err;
    logic [1:0] coef_load_err_code;
    logic [15:0] boot_envelope_gain;

    // ---- "SPI side" controls (driven on dsp_clk in this TB) ----------------------
    logic [3:0]  coef_bank_id_tb    = 4'd0;
    logic        coef_load_start_tb = 1'b0;
    logic [15:0] filter_id_tb       = 16'd0;
    logic        filter_load_req_tb = 1'b0;
    logic        boot_ok_tb         = 1'b0;

    // ---- FIR ----------------------------------------------------------------------
    logic [AUDIO_WIDTH-1:0] audio_l_in = '0, audio_r_in = '0;
    logic        new_sample = 1'b0;
    logic [47:0] fir_l_out, fir_r_out;
    wire         fir_l_valid, fir_r_valid;
    logic        fir_rst_n = 1'b0;
    logic        sample_768k_tick;

    // ---- DUT: coefficient subsystem ------------------------------------------------
    dac_coef_subsys #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE)
    ) u_coef_subsys (
        .ui_clk             (ui_clk),
        .ui_clk_sync_rst    (~ui_rst_n),
        .dsp_clk            (dsp_clk),
        .sys_rst_n          (dsp_rst_n),
        .sample_768k_tick   (sample_768k_tick),
        .coef_bank_id       (coef_bank_id_tb),
        .coef_load_start    (coef_load_start_tb),
        .filter_id          (filter_id_tb),
        .filter_load_req    (filter_load_req_tb),
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
        .current_bank_id    (current_bank_id),
        .mgr_busy           (mgr_busy),
        .bank_valid         (bank_valid),
        .coef_load_done     (coef_load_done),
        .coef_load_err      (coef_load_err),
        .coef_load_err_code (coef_load_err_code)
    );

    // ---- DUT: FIR -------------------------------------------------------------------
    fir_polyphase_stereo #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (AUDIO_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (48)
    ) u_stereo_fir (
        .clk                  (dsp_clk),
        .rst_n                (fir_rst_n),
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

    // ---- AXI slave model: coefficient data + directory, computed from address ----
    //  coef word = (mac * COEF_DEPTH + idx) & 0x3FFFF within any bank-sized region
    function automatic logic [31:0] coef_from_addr(input logic [31:0] byte_addr);
        int bank_off, mac_num, word_in_mac;
        bank_off    = int'(byte_addr) % int'(BANK_SIZE);
        mac_num     = bank_off / MAC_BYTES;
        word_in_mac = (bank_off % MAC_BYTES) / 4;
        return 32'((mac_num * COEF_DEPTH + word_in_mac) & 32'h3FFFF);
    endfunction

    //  Directory entry beat 0: {payload_bytes, ddr4_offset(16B units), tap_count,
    //  rate_family, phase_type, filter_id}; beat 1 = 0. Entry 2 = terminator.
    function automatic logic [AXI_DATA_WIDTH-1:0] dir_beat(input int entry, input int beat);
        logic [AXI_DATA_WIDTH-1:0] d = '0;
        if (beat != 0) return '0;
        case (entry)
            0: d = {BANK_SIZE, 32'((2 * BANK_SIZE) >> 4), 32'(16 * NUM_MACS * TAPS_PER_PHASE),
                    8'd1, 8'd0, FILT_OK_ID};
            1: d = {32'(BANK_SIZE / 2), 32'((3 * BANK_SIZE) >> 4), 32'd0,
                    8'd1, 8'd0, FILT_BAD_SZ};
            default: d = '0;
        endcase
        return d;
    endfunction

    function automatic logic [AXI_DATA_WIDTH-1:0] gen_beat(input logic [31:0] burst_base, input int beat);
        logic [AXI_DATA_WIDTH-1:0] d;
        if (burst_base >= DIR_BASE_ADDR)
            return dir_beat(int'((burst_base - DIR_BASE_ADDR) / 32), beat);
        d[31:0]   = coef_from_addr(burst_base + beat*16 + 0);
        d[63:32]  = coef_from_addr(burst_base + beat*16 + 4);
        d[95:64]  = coef_from_addr(burst_base + beat*16 + 8);
        d[127:96] = coef_from_addr(burst_base + beat*16 + 12);
        return d;
    endfunction

    typedef enum logic [1:0] {AR_IDLE, AR_LATENCY, R_BURST} r_state_t;
    r_state_t    r_state;
    logic [31:0] slave_araddr;
    logic [7:0]  slave_arlen, r_beat_cnt;
    int          latency_cnt;
    int          ar_burst_count = 0;

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
                        ar_burst_count <= ar_burst_count + 1;
                        r_state      <= AR_LATENCY;
                    end
                end
                AR_LATENCY: begin
                    if (latency_cnt > 0) latency_cnt <= latency_cnt - 1;
                    else begin r_beat_cnt <= 8'd0; r_state <= R_BURST; end
                end
                R_BURST: begin
                    if (!axi_rvalid || axi_rready) begin
                        axi_rvalid <= 1'b1;
                        axi_rdata  <= gen_beat(slave_araddr, int'(r_beat_cnt));
                        axi_rlast  <= (r_beat_cnt == slave_arlen);
                        if (r_beat_cnt == slave_arlen) r_state <= AR_IDLE;
                        else                            r_beat_cnt <= r_beat_cnt + 1'b1;
                    end
                end
            endcase
        end
    end
    assign axi_rresp = 2'b00;

    // ---- 768 kHz tick (dsp_clk) --------------------------------------------------------
    localparam int SAMPLE_DIV = 465;   // 357 MHz / 768 kHz
    logic [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin sample_cnt <= '0; sample_768k_tick <= 1'b0; end
        else begin
            sample_768k_tick <= (sample_cnt == SAMPLE_DIV-1);
            sample_cnt <= (sample_cnt == SAMPLE_DIV-1) ? '0 : sample_cnt + 1'b1;
        end
    end

    // ---- Monitors -------------------------------------------------------------------------
    int  total_coef_writes = 0;
    int  coef_data_errors  = 0;
    always @(posedge dsp_clk) if (coef_we) begin
        total_coef_writes++;
        if (coef_wdata !== 18'((int'(coef_wmac) * COEF_DEPTH + int'(coef_waddr)) & 32'h3FFFF)) begin
            coef_data_errors++;
            if (coef_data_errors <= 5)
                $display("[%0t] COEF DATA MISMATCH mac=%0d addr=%0d got=%0h",
                         $time, coef_wmac, coef_waddr, coef_wdata);
        end
    end

    logic fir_valid_seen;
    logic fir_x_seen;
    always @(posedge dsp_clk) begin
        if (!fir_rst_n) begin fir_valid_seen <= 1'b0; fir_x_seen <= 1'b0; end
        else if (fir_l_valid) begin
            fir_valid_seen <= 1'b1;
            if (^fir_l_out === 1'bx || ^fir_r_out === 1'bx) fir_x_seen <= 1'b1;
        end
    end

    // ---- Helpers --------------------------------------------------------------------------
    int errors = 0;
    task automatic check(input string name, input longint got, input longint exp);
        if (got !== exp) begin
            $display("FAIL: %s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else
            $display("PASS: %s = %0d", name, got);
    endtask

    task automatic legacy_load(input [3:0] bank);
        @(posedge dsp_clk); coef_bank_id_tb    <= bank;
        @(posedge dsp_clk); coef_load_start_tb <= 1'b1;
        @(posedge dsp_clk); coef_load_start_tb <= 1'b0;
    endtask

    task automatic filter_load(input [15:0] id);
        @(posedge dsp_clk); filter_id_tb       <= id;
        @(posedge dsp_clk); filter_load_req_tb <= 1'b1;
        @(posedge dsp_clk); filter_load_req_tb <= 1'b0;
    endtask

    task automatic wait_load_done(input string what);
        fork
            begin : w_done
                @(posedge dsp_clk iff coef_load_done);
                $display("[%0t] %s: coef_load_done", $time, what);
                disable w_to;
            end
            begin : w_to
                repeat (4_000_000) @(posedge dsp_clk);
                $display("FAIL: %s: timeout waiting for coef_load_done", what);
                errors++;
                disable w_done;
            end
        join
        repeat (20) @(posedge dsp_clk);   // manager SWITCHING -> IDLE, status settle
    endtask

    // Drive N INPUT-rate samples (48 kHz = one per 16 output ticks; the FIR
    // needs 16 phases x TAPS_PER_PHASE cycles per input sample), impulse first.
    task automatic run_fir_samples(input int n, input bit impulse);
        for (int i = 0; i < n; i++) begin
            repeat (16) @(posedge sample_768k_tick);
            @(posedge dsp_clk);
            audio_l_in <= (impulse && i == 0) ? 24'h7FFFFF : 24'h000000;
            audio_r_in <= 24'h000000;
            new_sample <= 1'b1;
            @(posedge dsp_clk);
            new_sample <= 1'b0;
        end
    endtask

    // ---- Test sequence -----------------------------------------------------------------------
    initial begin
        $display("=== TB_SYSTEM_DDR4_TO_FIR: NUM_MACS=%0d TPP=%0d (COEF_DEPTH=%0d, bank=%0d B) ===",
                 NUM_MACS, TAPS_PER_PHASE, COEF_DEPTH, BANK_SIZE);

        repeat (20) @(posedge ui_clk);  ui_rst_n  = 1'b1;
        repeat (10) @(posedge ui_clk);  dsp_rst_n = 1'b1;
        repeat (50) @(posedge dsp_clk);

        // T1: request before DDR4 is staged must queue, not run
        $display("\n--- T1: legacy load request before boot_ok ---");
        legacy_load(4'd1);
        repeat (3000) @(posedge dsp_clk);
        check("T1 no AXI bursts before boot_ok", ar_burst_count, 0);
        check("T1 bank_valid",                  bank_valid, 0);
        check("T1 manager busy (BOOT_WAIT)",    mgr_busy, 1);
        check("T1 boot envelope muted",         boot_envelope_gain, 0);

        // T2: boot_ok releases the queued request
        $display("\n--- T2: boot_ok -> queued load runs ---");
        @(posedge dsp_clk); boot_ok_tb <= 1'b1;
        wait_load_done("T2");
        check("T2 coef writes",       total_coef_writes, NUM_MACS * COEF_DEPTH);
        check("T2 coef data errors",  coef_data_errors, 0);
        check("T2 AXI bursts",        ar_burst_count, NUM_MACS * (COEF_DEPTH / 1024));
        check("T2 bank_select -> B",  bank_select, 1);
        check("T2 bank_valid",        bank_valid, 1);
        check("T2 current_bank_id",   current_bank_id, 1);
        check("T2 no load_err",       coef_load_err, 0);

        // T3: boot fade-in starts only now
        $display("\n--- T3: boot fade-in after first good load ---");
        repeat (40) @(posedge sample_768k_tick);
        if (boot_envelope_gain == 16'h0000) begin
            $display("FAIL: T3 envelope still muted 40 ticks after first load"); errors++;
        end else
            $display("PASS: T3 envelope ramping (gain=0x%04h)", boot_envelope_gain);

        // T4: FIR with loaded coefficients
        $display("\n--- T4: FIR impulse response ---");
        @(posedge dsp_clk); fir_rst_n <= 1'b1;
        repeat (10) @(posedge dsp_clk);
        run_fir_samples(40, 1);
        check("T4 FIR output seen",   fir_valid_seen, 1);
        check("T4 FIR output X-free", fir_x_seen, 0);

        // T5: directory load by ID while FIR keeps running (gapless path)
        $display("\n--- T5: filter load by ID %h under running FIR ---", FILT_OK_ID);
        begin
            automatic int writes_before = total_coef_writes;
            fork
                begin : t5_audio
                    forever run_fir_samples(1, 0);
                end
                begin : t5_load
                    filter_load(FILT_OK_ID);
                    wait_load_done("T5");
                    disable t5_audio;
                end
            join
            @(posedge dsp_clk); new_sample <= 1'b0;
            check("T5 coef writes",      total_coef_writes - writes_before, NUM_MACS * COEF_DEPTH);
            check("T5 coef data errors", coef_data_errors, 0);
            check("T5 bank_select -> A", bank_select, 0);
            check("T5 no load_err",      coef_load_err, 0);
            check("T5 bank_valid",       bank_valid, 1);
            fir_x_seen = 1'b0;
            run_fir_samples(20, 1);
            check("T5 FIR X-free after swap", fir_x_seen, 0);
        end

        // T6: directory miss
        $display("\n--- T6: filter ID %h not in directory ---", FILT_MISSING);
        begin
            automatic int writes_before = total_coef_writes;
            filter_load(FILT_MISSING);
            wait_load_done("T6");
            check("T6 load_err",        coef_load_err, 1);
            check("T6 err code",        coef_load_err_code, 1);
            check("T6 no coef writes",  total_coef_writes - writes_before, 0);
            check("T6 bank unchanged",  bank_select, 0);
            check("T6 bank_valid held", bank_valid, 1);
        end

        // T7: payload size mismatch
        $display("\n--- T7: filter ID %h payload mismatch ---", FILT_BAD_SZ);
        begin
            automatic int writes_before = total_coef_writes;
            filter_load(FILT_BAD_SZ);
            wait_load_done("T7");
            check("T7 load_err",        coef_load_err, 1);
            check("T7 err code",        coef_load_err_code, 2);
            check("T7 no coef writes",  total_coef_writes - writes_before, 0);
            check("T7 bank unchanged",  bank_select, 0);
        end

        $display("\n========================================");
        if (errors == 0) $display("TB_PASS: tb_system_ddr4_to_fir all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $display("========================================");
        $finish;
    end

endmodule
