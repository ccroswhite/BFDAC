`timescale 1ns / 1ps

// =============================================================================
//  TB_SCHEMA4_LOAD  (schema-4 hybrid coefficient path, review-10)
//
//  Exercises the virtual slot map end-to-end at a small geometry
//  (NUM_MACS=16, SPLIT_MACS=4 -> NUM_OUTER=12, 20 URAM slots + exp slot 20,
//  coef_wmac = 5 bits):
//
//    AXI memory model (packed 7x18b data + 32B directory)
//      -> dac_coef_subsys (loader @ ui_clk, CDC, bank manager)
//      -> fir_polyphase_stereo (paired outer URAMs + dedicated split URAMs
//         + dual-banked exp_mem)
//
//    T1  packing=2/schema=4 load: 20*1024 + 16 writes, sequential flat
//        pattern, wmac walk 0..19 then EXP slot 20 (waddr 0..15)
//    T2  packing=2 but schema=3 entry -> err code 2, zero writes
//    T3  packing=1/schema=4 legacy image: hi-slot remap means wmac
//        for MACs 12..15 lands on slots 12,14,16,18; the loader then
//        zero-sweeps the exp slot AND odd lo slots 13,15,17,19 (ST_EXPZ +
//        ST_LOZ tails) so no stale packed2 residue survives the reload
//    T4  exp_mem[bank][m] holds the flat-pattern low 5 bits; exp_active
//        follows bank_select after the atomic swap
//    T5  FIR output valid and X-free with the loaded pattern coefs
// =============================================================================

module tb_schema4_load;

    // ---- Geometry -------------------------------------------------------------
    localparam int NUM_MACS       = 16;
    localparam int SPLIT_MACS     = 4;
    localparam int NUM_OUTER      = NUM_MACS - SPLIT_MACS;   // 12
    localparam int TAPS_PER_PHASE = 64;
    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE;     // 1024
    localparam int COEF_WIDTH     = 18;
    localparam int AUDIO_WIDTH    = 24;
    localparam int AXI_DATA_WIDTH = 128;

    localparam int          COEF_SLOTS = NUM_MACS + SPLIT_MACS;            // 20
    localparam int          EXP_SLOT   = COEF_SLOTS;                       // 20
    localparam int          PK4_WORDS  = COEF_SLOTS * COEF_DEPTH + NUM_MACS; // 20496
    localparam int          PK1_WORDS  = NUM_MACS * COEF_DEPTH;            // 16384
    localparam logic [31:0] PK4_BYTES  = ((PK4_WORDS + 6) / 7) * 16;       // 46848
    localparam logic [31:0] PK1_BYTES  = ((PK1_WORDS + 6) / 7) * 16;       // 37456
    localparam logic [31:0] DIR_BASE   = 32'h3FFF_0000;
    localparam logic [31:0] PK2_BASE   = 32'h0200_0000;   // schema-4 bank region
    localparam logic [31:0] PK1_BASE   = 32'h0400_0000;   // schema-4 packing=1 region

    localparam logic [15:0] FID_S4      = 16'h0101;  // packing=2, schema=4
    localparam logic [15:0] FID_BAD_SCH = 16'h0202;  // packing=2, schema=3 -> reject
    localparam logic [15:0] FID_PK1     = 16'h0303;  // packing=1, schema=4

    localparam real UI_CLK_PERIOD  = 3.333;
    localparam real DSP_CLK_PERIOD = 2.8;

    // ---- Clocks / resets ------------------------------------------------------
    logic ui_clk = 0, dsp_clk = 0;
    always #(UI_CLK_PERIOD/2.0)  ui_clk  = ~ui_clk;
    always #(DSP_CLK_PERIOD/2.0) dsp_clk = ~dsp_clk;
    logic ui_rst_n = 0, dsp_rst_n = 0;

    // ---- AXI -------------------------------------------------------------------
    logic [29:0]               axi_araddr;
    logic [7:0]                axi_arlen;
    logic [2:0]                axi_arsize;
    logic [1:0]                axi_arburst;
    logic                      axi_arvalid, axi_arready;
    logic [AXI_DATA_WIDTH-1:0] axi_rdata;
    logic [1:0]                axi_rresp;
    logic                      axi_rlast, axi_rvalid, axi_rready;

    // ---- Coef bus / bank control ------------------------------------------------
    logic                          coef_we;
    logic [$clog2(COEF_DEPTH)-1:0] coef_waddr;
    logic signed [COEF_WIDTH-1:0]  coef_wdata;
    logic [$clog2(NUM_MACS+SPLIT_MACS+1)-1:0] coef_wmac;   // 5 bits (21 slots)
    wire  bank_select, bank_load_target;
    logic [3:0] current_bank_id;
    logic mgr_busy, bank_valid, coef_load_done, coef_load_err;
    logic [2:0] coef_load_err_code;
    logic [15:0] boot_envelope_gain;

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

    // ---- DUT: coefficient subsystem ---------------------------------------------
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
        .sample_768k_tick   (sample_768k_tick),
        .fir_frame_done     (sample_768k_tick),
        .stream_rate        (3'd0),
        .enforce_stream_rate(1'b0),
        .coef_bank_id       (4'd0),
        .coef_load_start    (1'b0),
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

    // ---- DUT: FIR ----------------------------------------------------------------
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

    // ---- AXI slave model --------------------------------------------------------
    //  Directory entries (32 B): beat0 = {payload_bytes, offset>>4, tap_count,
    //  rate_code, phase_type, filter_id}; beat1 = {rsv, schema, rate_shift,
    //  packing, latency}. Stream data: 7 x 18b words per 128b beat, word value
    //  = flat word index & 0x3FFFF.
    function automatic logic [AXI_DATA_WIDTH-1:0] dir_beat(input int entry, input int beat);
        logic [AXI_DATA_WIDTH-1:0] d = '0;
        case (entry)
            0: if (beat == 0)
                   d = {PK4_BYTES, 32'(PK2_BASE >> 4), 32'(NUM_MACS * COEF_DEPTH),
                        8'd0, 8'd0, FID_S4};
               else begin d[55:48] = 8'd4; d[39:32] = 8'd2; end
            1: if (beat == 0)
                   d = {PK4_BYTES, 32'(PK2_BASE >> 4), 32'(NUM_MACS * COEF_DEPTH),
                        8'd0, 8'd0, FID_BAD_SCH};
               else begin d[55:48] = 8'd3; d[39:32] = 8'd2; end   // schema=3 -> reject
            2: if (beat == 0)
                   d = {PK1_BYTES, 32'(PK1_BASE >> 4), 32'(NUM_MACS * COEF_DEPTH),
                        8'd0, 8'd0, FID_PK1};
               else begin d[55:48] = 8'd4; d[39:32] = 8'd1; end
            default: d = '0;
        endcase
        return d;
    endfunction

    function automatic logic [AXI_DATA_WIDTH-1:0] pk_beat(input int beat_idx);
        logic [17:0] s [0:6];
        logic [63:0] lo, hi;
        for (int k = 0; k < 7; k++)
            s[k] = 18'((beat_idx * 7 + k) & 32'h3FFFF);
        lo = 64'(s[0]) | (64'(s[1]) << 18) | (64'(s[2]) << 36)
           | (64'(s[3] & 18'h003FF) << 54);
        hi = (64'(s[3]) >> 10) | (64'(s[4]) << 8) | (64'(s[5]) << 26)
           | (64'(s[6]) << 44);
        return {hi, lo};
    endfunction

    function automatic logic [AXI_DATA_WIDTH-1:0] gen_beat(input logic [31:0] base, input int beat);
        logic [AXI_DATA_WIDTH-1:0] d = '0;
        if (base >= DIR_BASE)
            return dir_beat(int'((base - DIR_BASE) / 32), beat);
        if (base >= PK1_BASE)
            return pk_beat(int'((base - PK1_BASE) / 16) + beat);
        return pk_beat(int'((base - PK2_BASE) / 16) + beat);
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

    // ---- 768 kHz tick ------------------------------------------------------------
    localparam int SAMPLE_DIV = 465;
    logic [$clog2(SAMPLE_DIV)-1:0] sample_cnt;
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin sample_cnt <= '0; sample_768k_tick <= 1'b0; end
        else begin
            sample_768k_tick <= (sample_cnt == SAMPLE_DIV-1);
            sample_cnt <= (sample_cnt == SAMPLE_DIV-1) ? '0 : sample_cnt + 1'b1;
        end
    end

    // ---- Write monitor: strictly sequential flat-index stream --------------------
    //  flat = word index in the emitted stream; expected wdata = flat & 0x3FFFF.
    //  exp_wmac tracks the expected virtual slot for each write.
    int  total_coef_writes = 0;
    int  flat_cnt          = 0;
    int  data_errors       = 0;
    int  wmac_errors       = 0;
    int  exp_wmac;
    int  slot_i;
    bit  remapped_mode = 0;

    always @(posedge dsp_clk) if (coef_we) begin
        total_coef_writes++;
        // Expected slot for this flat index
        if (!remapped_mode) begin
            exp_wmac = (flat_cnt < COEF_SLOTS * COEF_DEPTH)
                     ? flat_cnt / COEF_DEPTH : EXP_SLOT;
        end else begin
            if (flat_cnt < NUM_MACS * COEF_DEPTH) begin
                slot_i   = flat_cnt / COEF_DEPTH;
                exp_wmac = (slot_i < NUM_OUTER) ? slot_i
                                                : NUM_OUTER + 2 * (slot_i - NUM_OUTER);
            end else if (flat_cnt < NUM_MACS * COEF_DEPTH + NUM_MACS) begin
                exp_wmac = EXP_SLOT;                        // ST_EXPZ exp-zero tail
            end else begin
                // ST_LOZ: odd (lo) slots NUM_OUTER+1,+3,... zero-swept so a
                // prior packed2 bank's stale C_lo can't contaminate this image
                slot_i   = (flat_cnt - NUM_MACS * COEF_DEPTH - NUM_MACS)
                           / COEF_DEPTH;
                exp_wmac = NUM_OUTER + 2 * slot_i + 1;
            end
        end
        if (int'(coef_wmac) !== exp_wmac) begin
            wmac_errors++;
            if (wmac_errors <= 5)
                $display("[%0t] WMAC MISMATCH flat=%0d got wmac=%0d exp=%0d",
                         $time, flat_cnt, coef_wmac, exp_wmac);
        end
        begin
            automatic logic [17:0] exp_data =
                (remapped_mode && (flat_cnt >= NUM_MACS * COEF_DEPTH))
                    ? 18'd0 : 18'(flat_cnt & 32'h3FFFF);
            if (coef_wdata !== exp_data) begin
                data_errors++;
                if (data_errors <= 5)
                    $display("[%0t] WDATA MISMATCH flat=%0d wmac=%0d waddr=%0d got=%0h exp=%0h",
                             $time, flat_cnt, coef_wmac, coef_waddr, coef_wdata, exp_data);
            end
        end
        flat_cnt++;
    end

    logic fir_valid_seen = 1'b0, fir_x_seen = 1'b0;
    always @(posedge dsp_clk) begin
        if (!fir_rst_n) begin fir_valid_seen <= 1'b0; fir_x_seen <= 1'b0; end
        else if (fir_l_valid) begin
            fir_valid_seen <= 1'b1;
            if (^fir_l_out === 1'bx || ^fir_r_out === 1'bx) fir_x_seen <= 1'b1;
        end
    end

    // ---- Helpers ------------------------------------------------------------------
    int errors = 0;
    task automatic check(input string name, input longint got, input longint exp);
        if (got !== exp) begin
            $display("FAIL: %s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else
            $display("PASS: %s = %0d", name, got);
    endtask

    task automatic filter_load(input [15:0] id);
        @(posedge dsp_clk); filter_id_tb       <= id;
        @(posedge dsp_clk); filter_load_req_tb <= ~filter_load_req_tb;
    endtask

    task automatic wait_load_done(input string what);
        fork
            begin : w_done
                wait (!coef_load_done);
                @(posedge coef_load_done);
                $display("[%0t] %s: coef_load_done", $time, what);
                disable w_to;
            end
            begin : w_to
                repeat (2_000_000) @(posedge dsp_clk);
                $display("FAIL: %s: timeout waiting for coef_load_done", what);
                errors++;
                disable w_done;
            end
        join
        fork : settle
            begin wait (!mgr_busy); end
            begin repeat (2 * SAMPLE_DIV + 20) @(posedge dsp_clk); end
        join_any
        disable settle;
    endtask

    task automatic run_fir_samples(input int n);
        for (int i = 0; i < n; i++) begin
            repeat (16) @(posedge sample_768k_tick);
            @(posedge dsp_clk);
            audio_l_in <= (i == 0) ? 24'h7FFFFF : 24'h000000;
            audio_r_in <= 24'h000000;
            new_sample <= 1'b1;
            @(posedge dsp_clk);
            new_sample <= 1'b0;
        end
    endtask

    // ---- Debug: trace manager + loader state and AR traffic -------------------------
    always @(posedge ui_clk) begin : dbg
        static int pstate = -1, lstate = -1;
        if (u_coef_subsys.u_coef_mgr.state != pstate) begin
            $display("[%0t] MGR state %0d -> %0d (target=%0d sel=%b tgt=%b)",
                     $time, pstate, u_coef_subsys.u_coef_mgr.state,
                     u_coef_subsys.u_coef_mgr.target_bank, bank_select, bank_load_target);
            pstate = u_coef_subsys.u_coef_mgr.state;
        end
        if (coef_load_done)
            $display("[%0t] DONE pulse (err_ui=%b ldr_done=%b)",
                     $time, u_coef_subsys.loader_err_ui,
                     u_coef_subsys.loader_done_ui);
        if (u_coef_subsys.u_coef_loader.state == 9)
            $display("[%0t] LDR ERR code=%0d mac_idx=%0d pk_left=%0d",
                     $time, u_coef_subsys.u_coef_loader.load_err_code,
                     u_coef_subsys.u_coef_loader.mac_idx,
                     u_coef_subsys.u_coef_loader.pk_left);
        if (u_coef_subsys.u_coef_loader.state != lstate) begin
            $display("[%0t] LDR state %0d -> %0d (mac_idx=%0d pk_left=%0d p2=%b)",
                     $time, lstate, u_coef_subsys.u_coef_loader.state,
                     u_coef_subsys.u_coef_loader.mac_idx,
                     u_coef_subsys.u_coef_loader.pk_left,
                     u_coef_subsys.u_coef_loader.packed2_r);
            lstate = u_coef_subsys.u_coef_loader.state;
        end
    end
    always @(posedge ui_clk)
        if (axi_arvalid && axi_arready)
            $display("[%0t] AR addr=%08x len=%0d", $time, axi_araddr, axi_arlen);
    int dirr_prints = 0;
    always @(posedge ui_clk)
        if (u_coef_subsys.u_coef_loader.state == 7 && dirr_prints < 12) begin
            dirr_prints <= dirr_prints + 1;
            $display("[%0t] DIR_R: rv=%b rr=%b rl=%b bc=%0d resp=%b rdata_hi=%x",
                     $time,
                     u_coef_subsys.u_coef_loader.m_axi_rvalid,
                     u_coef_subsys.u_coef_loader.m_axi_rready,
                     u_coef_subsys.u_coef_loader.m_axi_rlast,
                     u_coef_subsys.u_coef_loader.beat_count,
                     u_coef_subsys.u_coef_loader.m_axi_rresp,
                     u_coef_subsys.u_coef_loader.m_axi_rdata[95:32]);
        end
    always @(posedge ui_clk) begin : rdbg
        static int prev_rstate = -1;
        if (r_state != prev_rstate) begin
            $display("[%0t] SLV r_state %0d -> %0d (rvalid=%b rready=%b)", $time, prev_rstate, r_state, axi_rvalid, axi_rready);
            prev_rstate = r_state;
        end
        if (axi_rvalid && axi_rready)
            $display("[%0t]   R beat rlast=%b rdata[31:0]=%08x", $time, axi_rlast, axi_rdata[31:0]);
    end

    // ---- Test sequence -------------------------------------------------------------
    initial begin
        $display("=== TB_SCHEMA4_LOAD: NUM_MACS=%0d SPLIT=%0d OUTER=%0d SLOTS=%0d DEPTH=%0d ===",
                 NUM_MACS, SPLIT_MACS, NUM_OUTER, COEF_SLOTS, COEF_DEPTH);

        repeat (20) @(posedge ui_clk);  ui_rst_n  = 1'b1;
        repeat (10) @(posedge ui_clk);  dsp_rst_n = 1'b1;
        repeat (50) @(posedge dsp_clk);
        boot_ok_tb  <= 1'b1;
        fir_rst_n   <= 1'b1;
        repeat (3000) @(posedge dsp_clk);

        // T1: schema-4 packed load
        $display("\n--- T1: packing=2 / schema=4 load (FID %h) ---", FID_S4);
        begin
            automatic int writes_before = total_coef_writes;
            flat_cnt = 0; remapped_mode = 0;
            filter_load(FID_S4);
            wait_load_done("T1");
            check("T1 coef writes",     total_coef_writes - writes_before, PK4_WORDS);
            check("T1 data errors",     data_errors, 0);
            check("T1 wmac errors",     wmac_errors, 0);
            check("T1 no load_err",     coef_load_err, 0);
            check("T1 bank_valid",      bank_valid, 1);
            check("T1 bank_select ->B", bank_select, 1);
        end

        // T4: exp_mem content + atomic swap (write order kept T1's stream hot)
        $display("\n--- T4: exponent file content ---");
        begin
            automatic int exp_errs = 0;
            $display("T4 dbg: bank_select_r1=%b tgt_r=%b exp_mem[0][0:3]=%0d,%0d,%0d,%0d exp_mem[1][0:3]=%0d,%0d,%0d,%0d exp_active[0:3]=%0d,%0d,%0d,%0d",
                     u_stereo_fir.bank_select_r1, u_stereo_fir.bank_load_target_r,
                     u_stereo_fir.exp_mem[0][0], u_stereo_fir.exp_mem[0][1],
                     u_stereo_fir.exp_mem[0][2], u_stereo_fir.exp_mem[0][3],
                     u_stereo_fir.exp_mem[1][0], u_stereo_fir.exp_mem[1][1],
                     u_stereo_fir.exp_mem[1][2], u_stereo_fir.exp_mem[1][3],
                     u_stereo_fir.exp_active[0], u_stereo_fir.exp_active[1],
                     u_stereo_fir.exp_active[2], u_stereo_fir.exp_active[3]);
            for (int m = 0; m < NUM_MACS; m++) begin
                // flat word index of exp word m = COEF_SLOTS*COEF_DEPTH + m;
                // 20*1024 + m ≡ m (mod 32) -> exp_mem[bank1][m] == m[4:0]
                if (u_stereo_fir.exp_mem[1][m] !== 5'(m)) exp_errs++;
            end
            check("T4 exp_mem[1][m]==m errors", exp_errs, 0);
            exp_errs = 0;
            // exp_active mirrors exp_mem[bank_select_r1]; r1 lags the
            // manager's bank_select by one dsp_clk — let it settle.
            repeat (4) @(posedge dsp_clk);
            for (int m = 0; m < NUM_MACS; m++)
                if (u_stereo_fir.exp_active[m] !== 5'(m)) exp_errs++;
            check("T4 exp_active==bank1 errors", exp_errs, 0);
        end

        // T5: FIR still produces output (pattern coefs -> finite, non-X)
        $display("\n--- T5: FIR impulse with pattern coefs ---");
        run_fir_samples(40);
        check("T5 FIR output seen",   fir_valid_seen, 1);
        check("T5 FIR output X-free", fir_x_seen, 0);

        // T2: packing=2 entry with schema=3 must be rejected
        $display("\n--- T2: packing=2 / schema=3 entry (FID %h) rejected ---", FID_BAD_SCH);
        begin
            automatic int writes_before = total_coef_writes;
            flat_cnt = 0;
            filter_load(FID_BAD_SCH);
            wait_load_done("T2");
            check("T2 load_err",       coef_load_err, 1);
            check("T2 err code",       coef_load_err_code, 2);
            check("T2 no coef writes", total_coef_writes - writes_before, 0);
        end

        // T3: schema=4 packing=1 legacy image -> hi-slot remap
        $display("\n--- T3: packing=1 / schema=4 load (FID %h), hi-slot remap ---", FID_PK1);
        begin
            automatic int writes_before = total_coef_writes;
            flat_cnt = 0; remapped_mode = 1;
            filter_load(FID_PK1);
            wait_load_done("T3");
            check("T3 coef writes",    total_coef_writes - writes_before,
                  PK1_WORDS + NUM_MACS + SPLIT_MACS * COEF_DEPTH);
            check("T3 data errors",    data_errors, 0);
            check("T3 wmac errors",    wmac_errors, 0);
            // coef_load_err is a toggle-parity EVENT (flips once per failed
            // load, still high from T2). The per-attempt status is the
            // loader's ui_clk level, quasi-static at the done edge.
            check("T3 no load_err",    u_coef_subsys.loader_err_ui, 0);
            // Manager swaps on the next fir_frame_done boundary after done;
            // wait one tick plus margin before sampling bank_select.
            repeat (2) @(posedge sample_768k_tick);
            repeat (4) @(posedge dsp_clk);
            check("T3 bank_select->A", bank_select, 0);
        end

        $display("\n========================================");
        if (errors == 0) $display("TB_PASS: tb_schema4_load all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $display("========================================");
        $finish;
    end

endmodule
