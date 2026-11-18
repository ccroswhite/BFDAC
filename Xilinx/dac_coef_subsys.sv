`timescale 1ns / 1ps

`include "spi_regs.svh"   // SPI register map defines

// Coefficient Loading Subsystem
// Combines:
//   - coef_bank_loader  (AXI4 read master, runs at ui_clk 300 MHz)
//   - CDC bridge        (ui_clk -> dsp_clk for coef write bus)
//   - coef_bank_manager (dual-bank switching at complete FIR-frame boundary, dsp_clk)
//   - coef_mute_envelope (boot-time fade-in, dsp_clk)
//   - Boot sequence: hold requests until the QSPI boot loader has staged
//     DDR4 (boot_ok); output stays fully muted until the FIRST successful
//     bank load + swap (bank_valid), then fade in. Default filter selection
//     is ARM policy (FILTER_SELECT after BOOT_STATUS.boot_ok) - TODO-16.

module dac_coef_subsys #(
    parameter int NUM_MACS = 1024,  // Any multiple of 64; taps = 16*NUM_MACS*TAPS_PER_PHASE
    parameter int TAPS_PER_PHASE = 64  // Coefs per MAC per phase; taps = 16*NUM_MACS*TAPS_PER_PHASE
)(
    // ui_clk domain (300 MHz = DDR4-2400 / 4, from MIG)
    input  logic        ui_clk,
    input  logic        ui_clk_sync_rst,    // Active-high sync reset

    // dsp_clk domain (~357 MHz)
    input  logic        dsp_clk,
    input  logic        sys_rst_n,
    input  tri0 [2:0]   stream_rate,
    input  tri0         enforce_stream_rate,

    // Sample tick from DSP core (768 kHz, dsp_clk domain)
    input  logic        sample_768k_tick,
    input  tri0         fir_frame_done,

    // SPI control inputs (clk_200m domain — registers held stable after the
    // pulse; pulses are level-synced into dsp_clk here before use)
    input  logic [3:0]  coef_bank_id,       // Legacy fixed slot (reg 0x05)
    input  logic        coef_load_start,    // Single-cycle pulse from SPI handler
    input  logic [15:0] filter_id,          // Directory filter ID (regs 0x08-0x0A, 0x17)
    input  logic        filter_load_req,    // Single-cycle pulse on select/advance

    // Voicing shadow set (clk_200m, regs 0x1D-0x1F) + commit toggle.
    // Quasi-static while commit pending; applied atomically by
    // voicing_commit_ctrl at fir_frame_done (see that module).
    input  logic              voicing_commit_toggle,
    input  logic              voicing_sh_en,
    input  logic signed [26:0] voicing_sh_k2,
    input  logic signed [26:0] voicing_sh_k3,
    input  logic [15:0]       voicing_sh_fid,
    input  logic              voicing_err_seen,     // clk_200m err parity back

    // Boot loader status (clk_200m domain, quasi-static level: all coefficient
    // records staged into DDR4 and CRC-verified)
    input  logic        boot_ok,

    // AXI4 Read Master (to dac_ddr4_if, ui_clk domain)
    output logic [29:0] m_axi_araddr,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    input  logic [127:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rlast,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    // Coefficient write bus (dsp_clk domain, to fir_polyphase_stereo)
    output logic        coef_we,
    output logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,  // coef index within MAC
    output logic signed [17:0]           coef_wdata,
    output logic [$clog2(NUM_MACS)-1:0]  coef_wmac,

    // Bank switching outputs (dsp_clk domain, to fir_polyphase_stereo)
    output logic        bank_select,        // 0=Bank A active, 1=Bank B active
    output logic        bank_load_target,   // Which bank loader writes to

    // Boot envelope gain (dsp_clk domain, to dac_dsp_core)
    output logic [15:0] boot_envelope_gain,

    // Applied voicing set (dsp_clk domain, to dac_dsp_core) + readback
    output logic              voicing_en,
    output logic signed [26:0] voicing_k2,
    output logic signed [26:0] voicing_k3,
    output logic              voicing_ack_toggle,    // -> clk_200m commit_pending
    output logic              voicing_swap_busy,     // dsp_clk level -> status
    output logic              voicing_err_toggle,    // flips on failed preset load
    output logic [15:0]       voicing_applied_fid,
    output logic              voicing_bank_chg,   // dsp_clk toggle: flips on
                                                  // ANY bank swap (voicing or
                                                  // manual) for status CDC
    output logic              voicing_applied_en,

    // Status outputs (dsp_clk domain)
    output logic [3:0]  current_bank_id,
    output logic        mgr_busy,
    output logic        bank_valid,         // Level: active FIR bank holds a good load
    output logic        coef_load_done,     // Pulse in dsp_clk domain

    // Load failure (ui_clk domain, level: set on a failed directory lookup,
    // cleared on the next load; code 1 = ID not found, 2 = size mismatch)
    output logic        coef_load_err,
    output logic [2:0]  coef_load_err_code
);

    localparam int REQ_BITS = 17;   // {by_id, id[15:0]}

    // ----------------------------------------------------------------
    // 1. coef_bank_loader (ui_clk domain)
    // ----------------------------------------------------------------
    logic         loader_done_ui;     // Single-cycle pulse in ui_clk domain
    logic         mgr_load_start_ui;  // From bank manager (dsp_clk -> ui_clk via handshake)
    logic         coef_we_ui;
    logic         coef_stall_ui;      // from the coef CDC FIFO (section 3)
    logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr_ui;
    logic signed [17:0]          coef_wdata_ui;
    logic [$clog2(NUM_MACS)-1:0] coef_wmac_ui;

    // CDC for load_start: toggle synchronizer (dsp_clk -> ui_clk).
    // mgr_load_start_dsp is a single-cycle pulse at dsp_clk (~3.9ns).
    // A direct 2FF sync would miss it since ui_clk period (5ns) > pulse width.
    // Toggle sync converts the pulse to an edge that ui_clk can reliably catch.
    logic mgr_load_start_dsp;
    logic load_start_toggle_dsp;
    logic [2:0] load_start_sync_ui;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            load_start_toggle_dsp <= 1'b0;
        else if (mgr_load_start_dsp)
            load_start_toggle_dsp <= ~load_start_toggle_dsp;
    end

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            load_start_sync_ui <= '0;
        else
            load_start_sync_ui <= {load_start_sync_ui[1:0], load_start_toggle_dsp};
    end

    // Rising or falling edge on synced toggle = load_start pulse in ui_clk domain
    wire mgr_load_start_ui_sync = load_start_sync_ui[2] ^ load_start_sync_ui[1];

    // Manager's latched request {by_id, id} (dsp_clk). Stable from load_start
    // until load_done, and the loader samples it only on the synced
    // load_start pulse (>= 3 ui_clk later) -> quasi-static crossing.
    logic [REQ_BITS-1:0] mgr_load_req_dsp;
    logic                loader_err_ui;

    coef_bank_loader #(
        .NUM_MACS   (NUM_MACS),
        .COEF_DEPTH (16*TAPS_PER_PHASE)
    ) u_coef_loader (
        .clk             (ui_clk),
        .rst_n           (~ui_clk_sync_rst),
        .stream_rate     (stream_rate),
        .enforce_stream_rate(enforce_stream_rate),
        .load_start      (mgr_load_start_ui_sync),
        .load_by_id      (mgr_load_req_dsp[16]),
        .load_bank_id    (mgr_load_req_dsp[3:0]),
        .load_filter_id  (mgr_load_req_dsp[15:0]),
        .load_done       (loader_done_ui),
        .load_err        (loader_err_ui),
        .load_err_code   (coef_load_err_code),

        .m_axi_araddr    (m_axi_araddr),
        .m_axi_arlen     (m_axi_arlen),
        .m_axi_arsize    (m_axi_arsize),
        .m_axi_arburst   (m_axi_arburst),
        .m_axi_arvalid   (m_axi_arvalid),
        .m_axi_arready   (m_axi_arready),
        .m_axi_rdata     (m_axi_rdata),
        .m_axi_rresp     (m_axi_rresp),
        .m_axi_rlast     (m_axi_rlast),
        .m_axi_rvalid    (m_axi_rvalid),
        .m_axi_rready    (m_axi_rready),

        .coef_stall      (coef_stall_ui),
        .coef_we         (coef_we_ui),
        .coef_waddr      (coef_waddr_ui),
        .coef_wdata      (coef_wdata_ui),
        .coef_wmac       (coef_wmac_ui)
    );

    // ----------------------------------------------------------------
    // 2. CDC: loader_done ui_clk -> dsp_clk (toggle synchronizer)
    // ----------------------------------------------------------------
    logic load_done_toggle_ui;
    logic [2:0] load_done_sync_dsp;

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            load_done_toggle_ui <= 1'b0;
        else if (loader_done_ui)
            load_done_toggle_ui <= ~load_done_toggle_ui;
    end

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n)
            load_done_sync_dsp <= '0;
        else
            load_done_sync_dsp <= {load_done_sync_dsp[1:0], load_done_toggle_ui};
    end

    // load_done must not overtake the last coefficients still queued in the
    // coef CDC FIFO (section 3): hold it until the FIFO has drained and the
    // final coef_we has been issued, then pulse once.
    logic load_done_pend;
    logic cf_empty_dsp;     // driven in section 3
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            load_done_pend <= 1'b0;
            coef_load_done <= 1'b0;
        end else begin
            coef_load_done <= 1'b0;
            if (load_done_sync_dsp[2] ^ load_done_sync_dsp[1])
                load_done_pend <= 1'b1;
            else if (load_done_pend && cf_empty_dsp && !coef_we) begin
                load_done_pend <= 1'b0;
                coef_load_done <= 1'b1;
            end
        end
    end
    assign coef_load_err  = loader_err_ui;

    // ----------------------------------------------------------------
    // 3. CDC: coef write bus ui_clk -> dsp_clk (async FIFO, 2026-09-04)
    //    ui_clk is 300 MHz (DDR4-2400 / 4), dsp_clk ~258 MHz. The loader
    //    emits 4 back-to-back coef_we per beat, i.e. faster than dsp_clk
    //    can sample: the former per-write toggle synchronizer dropped ~21%
    //    of writes and sampled stale addr/data (seen in tb_vu13p_mig on
    //    the real MIG; the stub's slower ui_clk hid it). Gray-pointer FIFO
    //    with almost-full backpressure to the loader; average loader rate
    //    (4 coefs / ~6.5 ui_clk) is below the dsp_clk pop rate so the
    //    stall is a safety net only.
    // ----------------------------------------------------------------
    localparam int CW_ADDR = $clog2(16*TAPS_PER_PHASE);
    localparam int CW_MAC  = $clog2(NUM_MACS);
    localparam int CW_W    = CW_ADDR + 18 + CW_MAC;
    localparam int CF_AW   = 5;                        // 32 entries

    logic [CW_W-1:0]  cfifo_mem [0:(1<<CF_AW)-1];
    logic [CF_AW:0]   cf_wptr_bin, cf_rptr_bin;
    logic [CF_AW:0]   cf_wptr_gray, cf_rptr_gray;
    (* ASYNC_REG = "TRUE" *) logic [CF_AW:0] cf_wptr_gray_d1, cf_wptr_gray_d2;   // -> dsp_clk
    (* ASYNC_REG = "TRUE" *) logic [CF_AW:0] cf_rptr_gray_u1, cf_rptr_gray_u2;   // -> ui_clk

    function automatic logic [CF_AW:0] cf_bin2gray(input logic [CF_AW:0] b);
        return b ^ (b >> 1);
    endfunction
    function automatic logic [CF_AW:0] cf_gray2bin(input logic [CF_AW:0] g);
        logic [CF_AW:0] b;
        b[CF_AW] = g[CF_AW];
        for (int i = CF_AW-1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Write side (ui_clk). Stall is registered from the synced read pointer;
    // 8-entry headroom covers the loader's 1-cycle stall latency.
    logic [CF_AW:0]   cf_used_ui;
    assign cf_used_ui = cf_wptr_bin - cf_gray2bin(cf_rptr_gray_u2);

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst) begin
            cf_wptr_bin   <= '0;
            cf_wptr_gray  <= '0;
            coef_stall_ui <= 1'b0;
        end else begin
            if (coef_we_ui) begin
                cfifo_mem[cf_wptr_bin[CF_AW-1:0]] <= {coef_wmac_ui, coef_waddr_ui, coef_wdata_ui};
                cf_wptr_bin  <= cf_wptr_bin + 1'b1;
                cf_wptr_gray <= cf_bin2gray(cf_wptr_bin + 1'b1);
            end
            coef_stall_ui <= (cf_used_ui >= (CF_AW+1)'((1<<CF_AW) - 8));
        end
        {cf_rptr_gray_u2, cf_rptr_gray_u1} <= {cf_rptr_gray_u1, cf_rptr_gray};
    end

    // Read side (dsp_clk): pop one coefficient per cycle while not empty.
    assign cf_empty_dsp = (cf_rptr_gray == cf_wptr_gray_d2);

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            cf_rptr_bin  <= '0;
            cf_rptr_gray <= '0;
            coef_we      <= 1'b0;
            coef_waddr   <= '0;
            coef_wdata   <= '0;
            coef_wmac    <= '0;  // width driven by $clog2(NUM_MACS)
        end else begin
            coef_we <= 1'b0;
            if (!cf_empty_dsp) begin
                {coef_wmac, coef_waddr, coef_wdata} <= cfifo_mem[cf_rptr_bin[CF_AW-1:0]];
                coef_we      <= 1'b1;
                cf_rptr_bin  <= cf_rptr_bin + 1'b1;
                cf_rptr_gray <= cf_bin2gray(cf_rptr_bin + 1'b1);
            end
        end
        {cf_wptr_gray_d2, cf_wptr_gray_d1} <= {cf_wptr_gray_d1, cf_wptr_gray};
    end

    // ----------------------------------------------------------------
    // 4. coef_bank_manager (dsp_clk domain)
    // ----------------------------------------------------------------
    // boot_ok: clk_200m level, monotonic once set -> plain 2-FF sync.
    (* ASYNC_REG = "TRUE" *) logic [1:0] boot_ok_sync;
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) boot_ok_sync <= '0;
        else            boot_ok_sync <= {boot_ok_sync[0], boot_ok};
    end

    // Boot sequence: the envelope stays at ST_FULL_MUTE out of reset; the
    // fade-in is requested once the first bank load has swapped in
    // (bank_valid). Nothing here depends on the coefficient contents.
    logic boot_load_done;
    logic boot_in_progress;
    logic boot_fade_in_req;
    logic boot_fade_done;

    assign boot_load_done = bank_valid;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            boot_in_progress <= 1'b1;
            boot_fade_in_req <= 1'b0;
        end else begin
            if (boot_in_progress) begin
                if (boot_load_done && boot_fade_done) begin
                    boot_in_progress <= 1'b0;
                    boot_fade_in_req <= 1'b0;
                end else if (boot_load_done && !boot_fade_done) begin
                    boot_fade_in_req <= 1'b1;
                end
            end
        end
    end

    // ---- Request capture: clk_200m pulses -> dsp_clk --------------------
    // The 5 ns SPI-side pulses are wider than a dsp_clk period, so a 3-FF
    // level sync + rising-edge detect yields exactly one request per pulse.
    // The edge lands >= 2 dsp_clk after the ctrl-plane registers updated
    // (they change on the same clk_200m edge as the pulse and then hold),
    // so coef_bank_id / filter_id are stable when sampled here.
    (* ASYNC_REG = "TRUE" *) logic [2:0] legacy_req_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] filter_req_sync;
    logic                 req_pulse_dsp;
    logic [REQ_BITS-1:0]  req_data_dsp;

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            legacy_req_sync <= '0;
            filter_req_sync <= '0;
            req_pulse_dsp   <= 1'b0;
            req_data_dsp    <= '0;
        end else begin
            legacy_req_sync <= {legacy_req_sync[1:0], coef_load_start};
            filter_req_sync <= {filter_req_sync[1:0], filter_load_req};
            req_pulse_dsp   <= 1'b0;
            if (filter_req_sync[1] && !filter_req_sync[2]) begin
                req_pulse_dsp <= 1'b1;
                req_data_dsp  <= {1'b1, filter_id};
            end else if (legacy_req_sync[1] && !legacy_req_sync[2]) begin
                req_pulse_dsp <= 1'b1;
                req_data_dsp  <= {1'b0, 12'd0, coef_bank_id};
            end
        end
    end

    // Failed-load flag: ui_clk level, set >= 1 ui_clk before the load_done
    // toggle and sampled here only when the synced toggle edge arrives.
    logic [REQ_BITS-1:0] mgr_current_req;

    // Voicing preset swap: voicing_commit_ctrl emits its bank-load request
    // only while the manager is IDLE and no SPI request is pulsing, so a
    // simple priority mux cannot lose either request.
    logic        vo_req_pulse;
    logic [16:0] vo_req_data;
    wire [REQ_BITS-1:0] mgr_req_data  = req_pulse_dsp ? req_data_dsp : vo_req_data;
    wire                mgr_req_pulse = req_pulse_dsp | vo_req_pulse;

    coef_bank_manager #(
        .REQ_BITS           (REQ_BITS)
    ) u_coef_mgr (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .sample_tick        (fir_frame_done),
        .bank_select_req    (mgr_req_data),
        .bank_select_pulse  (mgr_req_pulse),
        .ddr4_ready         (boot_ok_sync[1]),
        .bank_select        (bank_select),
        .bank_load_target   (bank_load_target),
        .load_start         (mgr_load_start_dsp),
        .load_bank_id       (mgr_load_req_dsp),
        .load_done          (coef_load_done),
        .load_failed        (loader_err_ui),
        .current_bank_id    (mgr_current_req),
        .bank_valid         (bank_valid),
        .busy               (mgr_busy)
    );

    // Legacy 4-bit status view (reg 0x13); the ctrl plane tracks the
    // selected filter_id itself (reg 0x17).
    assign current_bank_id = mgr_current_req[3:0];

    // ----------------------------------------------------------------
    // 5. Mute envelope + voicing commit FSM (dsp_clk domain)
    // ----------------------------------------------------------------
    // One envelope serves both boot fade-in and voicing preset swaps:
    // boot only ever requests fade_in once (before bank_valid), voicing
    // fades only after bank_valid, so the requests never collide.
    logic vo_fade_out, vo_fade_in;

    coef_mute_envelope u_boot_envelope (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .sample_tick        (sample_768k_tick),
        .fade_out_req       (vo_fade_out),
        .fade_in_req        (boot_fade_in_req | vo_fade_in),
        .gain               (boot_envelope_gain),
        .fade_done          (boot_fade_done)
    );

    voicing_commit_ctrl u_voicing_commit (
        .clk               (dsp_clk),
        .rst_n             (sys_rst_n),
        .commit_toggle_in  (voicing_commit_toggle),
        .sh_en             (voicing_sh_en),
        .sh_k2             (voicing_sh_k2),
        .sh_k3             (voicing_sh_k3),
        .sh_filter_id      (voicing_sh_fid),
        .fir_frame_done    (fir_frame_done),
        .bank_valid        (bank_valid),
        .mgr_busy          (mgr_busy),
        .coef_load_done    (coef_load_done),
        .coef_load_failed  (loader_err_ui),
        .mgr_current_bank  (mgr_current_req),
        .spi_req_active    (req_pulse_dsp),
        .err_seen_in       (voicing_err_seen),
        .fade_done         (boot_fade_done),
        .voicing_en        (voicing_en),
        .voicing_k2        (voicing_k2),
        .voicing_k3        (voicing_k3),
        .applied_filter_id (voicing_applied_fid),
        .ack_toggle        (voicing_ack_toggle),
        .swap_busy         (voicing_swap_busy),
        .vo_err_toggle     (voicing_err_toggle),
        .vo_req_pulse      (vo_req_pulse),
        .vo_req_data       (vo_req_data),
        .fade_out_req      (vo_fade_out),
        .fade_in_req       (vo_fade_in)
    );
    assign voicing_applied_en = voicing_en;

    // Bank-changed event toggle: flips once per bank swap regardless of who
    // requested it (voicing FSM, SPI filter select, boot). clk_200m captures
    // voicing_applied_fid on its synced edge, so the status echo always
    // tracks ground truth — no free-running 16-bit CDC bus.
    logic [16:0] mgr_bank_d;
    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            mgr_bank_d       <= mgr_current_req;   // park — no phantom edge
            voicing_bank_chg <= 1'b0;
        end else begin
            mgr_bank_d <= mgr_current_req;
            if (mgr_current_req != mgr_bank_d)
                voicing_bank_chg <= ~voicing_bank_chg;
        end
    end

endmodule
