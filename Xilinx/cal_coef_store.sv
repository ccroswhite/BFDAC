`timescale 1ns / 1ps

// =============================================================================
// Calibration Coefficient Store (Step 6.3 / 6.7 — DECIDED Aug 2026)
//
// Architecture decision: the APPLICATION PROCESSOR reads the board temperature
// sensors (I2C stays on the app board) and computes the final, temperature-
// corrected calibration coefficient values (static LUT + Volterra kernel +
// FIR nuisance taps, per channel). The FPGA performs NO temperature math —
// it only stores the values and applies them to every conversion.
//
// This module is the store: a dual-bank (ping-pong) coefficient memory.
//   - ARM writes the INACTIVE bank word-by-word over the SPI control plane
//     (each word arrives as one SPI frame — microseconds apart, so simple
//     toggle handshakes cross ctrl_clk -> dsp_clk with huge margin).
//   - A commit toggle flips the active bank pointer ATOMICALLY at the next
//     sample tick (same gapless pattern as the FIR bank_select switch): no
//     conversion ever sees a half-updated coefficient set.
//   - The ACTIVE bank is continuously readable by the DPD datapath on the
//     dpd_rd_* ports (4 ports: 2 lanes x 2 channel engines, 2026-08-22) —
//     values are applied to every conversion by construction. Distributed
//     RAM: extra read ports cost only LUTRAM replication.
//   - A verification read port lets ARM read back the ACTIVE bank over SPI
//     (quasi-static after commit, so the ctrl-domain resample is safe).
//
// Word layout per channel (addr[8] = channel: 0 = L, 1 = R) — W18/F24 format
// per dpd_fx_golden.py (utils/dpd_rtl_gen.py is the layout source of truth):
//   addr[7:0]  0 -  63 : lut24[code]  24-bit signed, 2^-24 code-LSB grid
//             64 - 102 : Qm[39]   Volterra 18-bit signed mantissas
//            103 - 118 : Fm[16]   FIR nuisance-tap mantissas
//            119 - 122 : shQ / shS / shF / GF  (6-bit shifts, ARM-computed)
//            128 - 191 : Sm[64]   static-content mantissas
//            else      : reserved
// =============================================================================
module cal_coef_store #(
    parameter int NUM_DPD_PORTS = 4
) (
    // --- dsp_clk domain ------------------------------------------------------
    input  logic        dsp_clk,
    input  logic        dsp_rst_n,
    input  logic        sample_tick,     // commit alignment (768k sample tick)
    input  tri0         dpd_busy,        // hold bank constant through each DPD calculation

    // DPD datapath ports — active bank, 1-cycle registered reads
    input  logic [NUM_DPD_PORTS-1:0][8:0]  dpd_rd_addr,
    output logic [NUM_DPD_PORTS-1:0][23:0] dpd_rd_data,

    // --- ctrl_clk domain (SPI control plane, 200 MHz) ------------------------
    input  logic        ctrl_clk,
    input  logic        ctrl_rst_n,
    input  logic        wr_toggle,       // flips once per word write
    input  logic [8:0]  wr_addr,         // stable when wr_toggle flips
    input  logic [23:0] wr_data,         // stable when wr_toggle flips
    input  logic        commit_toggle,   // flips once per commit request
    input  logic [8:0]  rd_addr,         // verification readback (active bank)
    output logic [23:0] rd_data,         // quasi-static after commit
    output logic        active_bank,     // status, resynced to ctrl_clk
    output logic        commit_pending,  // status, resynced to ctrl_clk
    output logic        write_reject_toggle,
    output logic        calibration_valid
);

    // =========================================================================
    // Storage: two banks, 512 x 24 each (distributed RAM scale)
    // =========================================================================
    logic [23:0] mem0 [0:511];
    logic [23:0] mem1 [0:511];

    // Power-up zero (synthesizable distributed-RAM init; matches bitstream)
    initial begin
        for (int i = 0; i < 512; i++) begin
            mem0[i] = '0;
            mem1[i] = '0;
        end
    end

    // =========================================================================
    // ctrl_clk -> dsp_clk CDC: write and commit toggles
    // =========================================================================
    (* ASYNC_REG = "TRUE" *) logic [2:0] wr_tg_sync_dsp;
    (* ASYNC_REG = "TRUE" *) logic [2:0] commit_tg_sync_dsp;
    logic [2:0] toggle_sync_warm;

    logic wr_pulse_dsp, commit_pulse_dsp;

    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin
            wr_tg_sync_dsp     <= '0;
            commit_tg_sync_dsp <= '0;
            toggle_sync_warm   <= '0;
        end else begin
            wr_tg_sync_dsp     <= {wr_tg_sync_dsp[1:0],     wr_toggle};
            commit_tg_sync_dsp <= {commit_tg_sync_dsp[1:0], commit_toggle};
            toggle_sync_warm   <= {toggle_sync_warm[1:0], 1'b1};
        end
    end

    // Ignore synchronizer fill transitions after an audio-path reset. The
    // control-domain request toggles survive rate changes; treating the
    // settled current phase as a new request would fabricate a write/commit.
    assign wr_pulse_dsp = (wr_tg_sync_dsp[2] ^ wr_tg_sync_dsp[1]) &&
                          (&toggle_sync_warm);
    assign commit_pulse_dsp = (commit_tg_sync_dsp[2] ^ commit_tg_sync_dsp[1]) &&
                              (&toggle_sync_warm);

    // =========================================================================
    // Write into the INACTIVE bank. wr_addr/wr_data are set by the SPI frame
    // that flips wr_toggle and stay stable until the next frame (microseconds)
    // — sampled here 2-3 dsp_clk after the toggle edge (XDC: datapath-only
    // max_delay on the bus, same pattern as the coef write bus CDC).
    // =========================================================================
    logic        active_sel;      // which bank the datapath reads
    logic        pending;         // commit requested, waiting for sample_tick
    logic        calibration_valid_dsp;
    wire         write_rejected_dsp = wr_pulse_dsp && (pending || commit_pulse_dsp);

    always_ff @(posedge dsp_clk) begin
        if (dsp_rst_n && wr_pulse_dsp && !write_rejected_dsp) begin
            if (active_sel)
                mem0[wr_addr] <= wr_data;  // bank1 active -> write bank0
            else
                mem1[wr_addr] <= wr_data;  // bank0 active -> write bank1
        end
    end

    // Reject-event phase is reset only by the external control reset, not by
    // an audio-rate DSP reset; a rate switch must not fabricate a host error.
    always_ff @(posedge dsp_clk or negedge ctrl_rst_n) begin
        if (!ctrl_rst_n)
            write_reject_toggle <= 1'b0;
        else if (dsp_rst_n && write_rejected_dsp)
            write_reject_toggle <= ~write_reject_toggle;
    end

    // =========================================================================
    // Atomic commit at the sample boundary
    // =========================================================================
    always_ff @(posedge dsp_clk) begin
        if (!dsp_rst_n) begin
            active_sel <= 1'b0;
            pending    <= 1'b0;
            calibration_valid_dsp <= 1'b0;
        end else begin
            if (commit_pulse_dsp)
                pending <= 1'b1;
            if (pending && sample_tick && !dpd_busy) begin
                active_sel <= ~active_sel;
                pending    <= 1'b0;
                calibration_valid_dsp <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Active-bank read ports (registered)
    // =========================================================================
    always_ff @(posedge dsp_clk) begin
        for (int p = 0; p < NUM_DPD_PORTS; p++)
            dpd_rd_data[p] <= active_sel ? mem1[dpd_rd_addr[p]]
                                         : mem0[dpd_rd_addr[p]];
    end

    // Verification readback: rd_addr is quasi-static (an SPI register written
    // frames before the readback frame), so resampling the multibit address
    // and returning the multibit data across domains is safe.
    (* ASYNC_REG = "TRUE" *) logic [8:0] rd_addr_meta, rd_addr_dsp;
    logic [23:0] rd_data_dsp;

    always_ff @(posedge dsp_clk) begin
        rd_addr_meta <= rd_addr;
        rd_addr_dsp  <= rd_addr_meta;
        rd_data_dsp  <= active_sel ? mem1[rd_addr_dsp] : mem0[rd_addr_dsp];
    end

    always_ff @(posedge ctrl_clk)
        rd_data <= rd_data_dsp;    // quasi-static resample (XDC max_delay)

    // Status back to ctrl domain (single-bit levels, 2-FF sync each)
    (* ASYNC_REG = "TRUE" *) logic [1:0] active_sync_ctrl, pending_sync_ctrl, cal_valid_sync_ctrl;
    always_ff @(posedge ctrl_clk) begin
        if (!ctrl_rst_n) begin
            active_sync_ctrl  <= '0;
            pending_sync_ctrl <= '0;
            cal_valid_sync_ctrl <= '0;
        end else begin
            active_sync_ctrl  <= {active_sync_ctrl[0],  active_sel};
            pending_sync_ctrl <= {pending_sync_ctrl[0], pending};
            cal_valid_sync_ctrl <= {cal_valid_sync_ctrl[0], calibration_valid_dsp};
        end
    end

    assign active_bank    = active_sync_ctrl[1];
    assign commit_pending = pending_sync_ctrl[1];
    assign calibration_valid = cal_valid_sync_ctrl[1];

endmodule
