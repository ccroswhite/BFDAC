`timescale 1ns / 1ps

// Coefficient Loading Subsystem
// Combines:
//   - coef_bank_loader  (AXI4 read master, runs at ui_clk ~200 MHz)
//   - CDC bridge        (ui_clk -> dsp_clk for coef write bus)
//   - coef_bank_manager (gapless dual-bank switching FSM, dsp_clk)
//   - coef_mute_envelope (boot-time fade-in, dsp_clk)
//   - Boot sequence FSM

module dac_coef_subsys (
    // ui_clk domain (~200 MHz, from MIG)
    input  logic        ui_clk,
    input  logic        ui_clk_sync_rst,    // Active-high sync reset

    // dsp_clk domain (~357 MHz)
    input  logic        dsp_clk,
    input  logic        sys_rst_n,

    // Sample tick from DSP core (768 kHz, dsp_clk domain)
    input  logic        sample_768k_tick,

    // SPI control inputs (clk_49m domain - registered before crossing)
    input  logic [3:0]  coef_bank_id,       // Target bank from SPI
    input  logic        coef_load_start,    // Single-cycle pulse from SPI handler

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
    output logic [10:0] coef_waddr,
    output logic signed [17:0] coef_wdata,
    output logic [7:0]  coef_wmac,

    // Bank switching outputs (dsp_clk domain, to fir_polyphase_stereo)
    output logic        bank_select,        // 0=Bank A active, 1=Bank B active
    output logic        bank_load_target,   // Which bank loader writes to

    // Boot envelope gain (dsp_clk domain, to dac_dsp_core)
    output logic [15:0] boot_envelope_gain,

    // Status outputs (dsp_clk domain)
    output logic [3:0]  current_bank_id,
    output logic        mgr_busy,
    output logic        coef_load_done      // Pulse in dsp_clk domain
);

    // ----------------------------------------------------------------
    // 1. coef_bank_loader (ui_clk domain)
    // ----------------------------------------------------------------
    logic         loader_done_ui;     // Single-cycle pulse in ui_clk domain
    logic         mgr_load_start_ui;  // From bank manager (dsp_clk -> ui_clk via handshake)
    logic         coef_we_ui;
    logic [10:0]  coef_waddr_ui;
    logic signed [17:0] coef_wdata_ui;
    logic [7:0]   coef_wmac_ui;

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

    coef_bank_loader u_coef_loader (
        .clk             (ui_clk),
        .rst_n           (~ui_clk_sync_rst),
        .load_start      (mgr_load_start_ui_sync),
        .load_bank_id    (coef_bank_id),
        .load_done       (loader_done_ui),

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

    assign coef_load_done = load_done_sync_dsp[2] ^ load_done_sync_dsp[1];

    // ----------------------------------------------------------------
    // 3. CDC: coef write bus ui_clk -> dsp_clk
    //    ui_clk (~200 MHz) is slower than dsp_clk (~258 MHz).
    //    coef_we_ui is a 1-cycle pulse at ui_clk (5 ns wide).
    //    Direct level-sampling by dsp_clk (3.875 ns) double-counts
    //    ~29% of pulses. Use toggle sync so each pulse maps to exactly
    //    one dsp_clk coef_we pulse.
    //    addr/data/mac are held stable for the full ui_clk cycle so
    //    they are safe to sample on the dsp_clk rising edge of coef_we.
    // ----------------------------------------------------------------
    logic        coef_we_toggle_ui;
    logic [2:0]  coef_we_sync_dsp;

    always_ff @(posedge ui_clk) begin
        if (ui_clk_sync_rst)
            coef_we_toggle_ui <= 1'b0;
        else if (coef_we_ui)
            coef_we_toggle_ui <= ~coef_we_toggle_ui;
    end

    always_ff @(posedge dsp_clk) begin
        if (!sys_rst_n) begin
            coef_we_sync_dsp <= '0;
            coef_we          <= 1'b0;
            coef_waddr       <= '0;
            coef_wdata       <= '0;
            coef_wmac        <= '0;
        end else begin
            coef_we_sync_dsp <= {coef_we_sync_dsp[1:0], coef_we_toggle_ui};
            coef_we          <= coef_we_sync_dsp[2] ^ coef_we_sync_dsp[1];
            if (coef_we_sync_dsp[2] ^ coef_we_sync_dsp[1]) begin
                coef_waddr <= coef_waddr_ui;
                coef_wdata <= coef_wdata_ui;
                coef_wmac  <= coef_wmac_ui;
            end
        end
    end

    // ----------------------------------------------------------------
    // 4. coef_bank_manager (dsp_clk domain)
    // ----------------------------------------------------------------
    logic boot_load_done;

    // Boot sequence FSM
    logic boot_in_progress;
    logic boot_fade_in_req;
    logic boot_fade_done;

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

    // TODO: Connect to actual boot loader when implemented
    assign boot_load_done = 1'b1;  // Placeholder - assumes instant boot

    coef_bank_manager u_coef_mgr (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .sample_tick        (1'b0),         // Unused in gapless switching
        .bank_select_req    (coef_bank_id),
        .bank_select_pulse  (coef_load_start),
        .boot_load_done     (boot_load_done),
        .bank_select        (bank_select),
        .bank_load_target   (bank_load_target),
        .load_start         (mgr_load_start_dsp),
        .load_bank_id       (),
        .load_done          (coef_load_done),
        .current_bank_id    (current_bank_id),
        .busy               (mgr_busy)
    );

    // ----------------------------------------------------------------
    // 5. Boot-time mute envelope (dsp_clk domain)
    // ----------------------------------------------------------------
    coef_mute_envelope u_boot_envelope (
        .clk                (dsp_clk),
        .rst_n              (sys_rst_n),
        .sample_tick        (sample_768k_tick),
        .fade_out_req       (1'b0),
        .fade_in_req        (boot_fade_in_req),
        .gain               (boot_envelope_gain),
        .fade_done          (boot_fade_done)
    );

endmodule
