`timescale 1ns / 1ps

// =============================================================================
//  VOICING_COMMIT_CTRL  (Step 2 â€” SPI shadow registers -> atomic DSP apply)
//
//  Lives in dac_coef_subsys on dsp_clk. Converts the clk_200m shadow-register
//  commit into a click-free, frame-synced application of {voicing_en, k2, k3}
//  plus the preset's FIR coefficient bank.
//
//  Commit handshake (same toggle pattern as cal_commit):
//    - clk_200m: host writes VOICING_K2/K3 then VOICING_CTRL[8]=1; the ctrl
//      plane flips commit_toggle_in and blocks further voicing writes until
//      ack_toggle catches up (commit_pending covers the whole swap).
//    - dsp_clk : 3-FF sync + edge detect; the shadow bus is quasi-static
//      (stable since the SPI write, held while pending) and is latched once,
//      atomically, at that edge.
//
//  Two apply paths:
//    - Field-only change (filter_id == applied, FFFF sentinel, or no valid bank):
//      applied at the next fir_frame_done. Frame-boundary apply keeps the
//      shaper consistent with the frame the FIR is working on.
//    - Preset change (bank_valid): full swap sequence â€”
//        fade_out_req -> fade_done -> emit bank-load request while the
//        manager is IDLE (so the next coef_load_done is OURS) ->
//        confirm the swap via mgr_current_bank == request ->
//        apply at next fir_frame_done -> fade_in_req.
//      The mute envelope covers the whole load window (dCS-style automute;
//      total ~50 ms dominated by the DDR4 coefficient stream).
//
//  Load failure (directory lookup / size mismatch): the bank manager returns
//  to IDLE without swapping; coef_load_done pulses with coef_load_failed=1.
//  We then skip the apply, fade back in, ack (releasing commit_pending), and
//  pulse vo_load_err -> ctrl-plane sticky[6] + CMD_ERR_INFO.
//
//  The bank-load request is muxed upstream into coef_bank_manager's queue;
//  we emit only when the manager is IDLE and the SPI request path is not
//  pulsing, so our request can neither squash nor be squashed.
//
//  applied_* outputs are the DSP-side truth â€” readback shows what is running,
//  not what was requested (they diverge during the load window).
// =============================================================================
module voicing_commit_ctrl (
    input  logic              clk,          // dsp_clk
    input  logic              rst_n,

    // ---- clk_200m shadow set (quasi-static while commit pending) -----------
    input  logic              commit_toggle_in,
    input  logic              sh_en,
    input  logic signed [26:0] sh_k2,       // Q2.25
    input  logic signed [26:0] sh_k3,       // Q2.25
    input  logic [15:0]       sh_filter_id,  // raw directory ID; 16'hFFFF =
                                             // "don't touch bank" sentinel

    // ---- dsp_clk environment ----------------------------------------------
    input  logic              err_seen_in,      // clk_200m error-parity level
    input  logic              fir_frame_done,   // input-frame boundary pulse
    input  logic              bank_valid,       // active FIR bank holds a load
    input  logic              mgr_busy,         // bank manager not IDLE
    input  logic              coef_load_done,   // shadow-bank load finished
    input  logic              coef_load_failed, // sampled with coef_load_done
    input  logic [16:0]       mgr_current_bank, // {by_id, id} of active bank
    input  logic              spi_req_active,   // SPI bank req wins the mux slot
    input  logic              fade_done,        // mute envelope finished a fade

    // ---- outputs -----------------------------------------------------------
    output logic              voicing_en,       // applied (to dac_dsp_core)
    output logic signed [26:0] voicing_k2,
    output logic signed [26:0] voicing_k3,
    output logic [15:0]       applied_filter_id,
    output logic              ack_toggle,       // dsp_clk -> clk_200m (pending)
    output logic              swap_busy,        // FSM active (status readback)
    output logic              vo_err_toggle,    // flips on failed preset load

    // ---- bank-load request (muxed upstream into coef_bank_manager) --------
    output logic              vo_req_pulse,
    output logic [16:0]       vo_req_data,      // {by_id=1, filter_id}

    // ---- mute envelope requests -------------------------------------------
    output logic              fade_out_req,
    output logic              fade_in_req
);

    // ---- Commit CDC: toggle sync + edge detect -----------------------------
    // The synchronizer free-runs and is NEVER reset: on a dsp_clk reset
    // (oscillator family switch) commit_sync settles to the live
    // commit_toggle_in value and commit_d parks there, so no phantom edge
    // can fire on release. ack_toggle is likewise parked at commit_sync[2]
    // during reset (FSM block below) so the clk_200m commit_pending parity
    // can never lock high â€” an in-flight commit is discarded, the applied
    // set drops to bypass, and the AP re-commits after the rate switch.
    (* ASYNC_REG = "TRUE" *) logic [2:0] commit_sync;
    logic commit_d;
    always_ff @(posedge clk) begin
        commit_sync <= {commit_sync[1:0], commit_toggle_in};
        commit_d    <= commit_sync[2];
    end
    wire commit_evt = commit_sync[2] ^ commit_d;

    // ---- Pending set (latched once, atomically, at the commit edge) --------
    logic              pend_en;
    logic signed [26:0] pend_k2, pend_k3;
    logic [15:0]       pend_filter_id;

    // err parity partner: the clk_200m seen-tracker level, synced here so a
    // dsp_clk reset can park vo_err_toggle at it (a plain reset would desync
    // the toggle parity and fire a phantom error event in clk_200m).
    (* ASYNC_REG = "TRUE" *) logic [1:0] err_seen_sync;
    always_ff @(posedge clk) begin
        err_seen_sync <= {err_seen_sync[0], err_seen_in};
    end

    // ---- FSM ---------------------------------------------------------------
    typedef enum logic [2:0] {
        V_IDLE      = 3'd0,
        V_FADE_OUT  = 3'd1,
        V_REQ       = 3'd2,
        V_WAIT_DONE = 3'd3,
        V_APPLY     = 3'd4,
        V_FADE_IN   = 3'd5,
        V_ERR_FADE  = 3'd6
    } state_t;
    state_t state;

    logic did_fade;   // remember to fade back in after a preset swap
    // RTL holds ZERO persona/variant/rate convention: filter_id is an
    // opaque 16-bit directory ID (packing is a generator/firmware contract).
    // applied_filter_id is DERIVED from the manager's live current bank —
    // manual FILTER_SELECT_ID / BANK_LOAD paths self-invalidate it (a
    // by_id=0 slot load reads back as the FFFF "not a directory filter"
    // state), so A -> manual B -> voicing A still reloads A correctly.
    // 16'hFFFF = sentinel: "apply fields only, leave the bank alone".
    wire  [16:0] vo_req_id = {1'b1, pend_filter_id};
    assign       applied_filter_id = mgr_current_bank[16]
                                     ? mgr_current_bank[15:0] : 16'hFFFF;
    // bank_valid is NOT in the swap test: a post-boot commit with no valid
    // bank may still load the default persona filter (boot envelope already
    // mutes audio); did_fade decides whether fade-out is needed.
    wire         want_swap = (sh_filter_id != 16'hFFFF) &&
                ({1'b1, sh_filter_id} != mgr_current_bank);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= V_IDLE;
            pend_en        <= 1'b0;
            pend_k2        <= '0;
            pend_k3        <= '0;
            pend_filter_id <= 16'hFFFF;
            voicing_en     <= 1'b0;
            voicing_k2     <= '0;
            voicing_k3     <= '0;
            vo_req_pulse   <= 1'b0;
            vo_req_data    <= '0;
            fade_out_req   <= 1'b0;
            fade_in_req    <= 1'b0;
            did_fade       <= 1'b0;
            // ack/err toggles track their LIVE synced partner levels through
            // reset so both clk_200m parities survive a dsp_clk reset
            // (Catch 5) — no phantom commit edge, no phantom error event.
            ack_toggle     <= commit_sync[2];
            vo_err_toggle  <= err_seen_sync[1];
        end else begin
            vo_req_pulse <= 1'b0;
            fade_out_req <= 1'b0;
            fade_in_req  <= 1'b0;

            unique case (state)
                V_IDLE: begin
                    if (commit_evt) begin
                        // Atomic snapshot â€” shadow set is quasi-static.
                        pend_en     <= sh_en;
                        pend_k2     <= sh_k2;
                        pend_k3     <= sh_k3;
                        pend_filter_id <= sh_filter_id;
                        // A bank swap only when a valid bank is running and
                        // the preset actually changes; otherwise the shaper
                        // fields alone apply at the next frame boundary.
                        if (want_swap) begin
                            // Fade out only if a live bank is playing; on a
                            // post-boot commit (!bank_valid) the boot
                            // envelope already holds mute — skip straight to
                            // the request, still run fade-in at the end.
                            did_fade <= bank_valid;
                            state    <= bank_valid ? V_FADE_OUT : V_REQ;
                        end else begin
                            did_fade <= 1'b0;
                            state    <= V_APPLY;
                        end
                    end
                end

                V_FADE_OUT: begin
                    fade_out_req <= 1'b1;
                    if (fade_done)
                        state <= V_REQ;
                end

                V_REQ: begin
                    // Emit only into an idle manager with no SPI pulse in
                    // flight: our request is then the next load_done, and
                    // it can neither squash nor be squashed at the mux.
                    if (!mgr_busy && !spi_req_active) begin
                        vo_req_pulse <= 1'b1;
                        vo_req_data  <= vo_req_id;
                        state        <= V_WAIT_DONE;
                    end
                end

                V_WAIT_DONE: begin
                    if (mgr_current_bank == vo_req_id)
                        state <= V_APPLY;            // our swap completed
                    else if (coef_load_done && coef_load_failed)
                        state <= V_ERR_FADE;         // our load was rejected
                end

                V_APPLY: begin
                    if (fir_frame_done) begin
                        voicing_en     <= pend_en;
                        voicing_k2     <= pend_k2;
                        voicing_k3     <= pend_k3;
                        state <= did_fade ? V_FADE_IN : V_IDLE;
                        if (!did_fade)
                            ack_toggle <= ~ack_toggle;
                    end
                end

                V_FADE_IN: begin
                    fade_in_req <= 1'b1;
                    if (fade_done) begin
                        ack_toggle <= ~ack_toggle;
                        state      <= V_IDLE;
                    end
                end

                V_ERR_FADE: begin
                    // Load failed: no apply, just restore audio and release
                    // the commit handshake with an error pulse for sticky[6].
                    vo_err_toggle <= ~vo_err_toggle;
                    fade_in_req  <= 1'b1;
                    ack_toggle   <= ~ack_toggle;
                    state        <= V_IDLE;
                end

                default: state <= V_IDLE;
            endcase
        end
    end

    assign swap_busy = (state != V_IDLE);

endmodule
