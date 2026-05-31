`timescale 1ns / 1ps

// =============================================================================
//  FIR_POLYPHASE_STEREO
//
//  Stereo wrapper around two fir_polyphase_interpolator instances (L and R).
//  The 256 coefficient BRAMs are owned HERE and shared between both channels:
//    - Port A : bank-load writes from coef_bank_loader (one MAC at a time)
//    - Port B : audio-rate reads, broadcast to both L and R MACs each cycle
//
//  This halves BRAM usage vs the prior per-channel design (256 instead of 512
//  RAMB36E2 for coefficients), making the design fit on the AU25P.
//
//  Both channels share the same coef_addr (driven by the L interpolator's
//  master_coef_addr -- the R interpolator is lockstep-identical since both
//  receive the same new_sample_valid and rst_n).
// =============================================================================
module fir_polyphase_stereo #(
    parameter int NUM_MACS   = 128,
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // Baseband inputs (one per channel)
    input  logic                          new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_l,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_r,

    // Interpolated outputs
    output logic signed [ACC_WIDTH-1:0]   interpolated_l,
    output logic                          interpolated_l_valid,
    output logic signed [ACC_WIDTH-1:0]   interpolated_r,
    output logic                          interpolated_r_valid,

    // Coefficient write bus (from coef_bank_loader)
    input  logic                          coef_we,
    input  logic [11:0]                   coef_waddr,
    input  logic signed [COEF_WIDTH-1:0]  coef_wdata,
    input  logic [6:0]                    coef_wmac,

    // Dual-bank gapless switching control
    input  logic                          bank_select,      // 0=Bank A (active), 1=Bank B (shadow)
    input  logic                          bank_load_target    // 0=Load Bank A, 1=Load Bank B (async to bank_select)
);

    // -------------------------------------------------------------------------
    //  Dual-Bank Coefficient Architecture for Gapless Switching
    //
    //  256 BRAMs total: one RAMB36E2 per MAC, address-interleaved dual-bank.
    //    - Bank A: addresses [0..2047]   (bank_load_target=0 / bank_select=0)
    //    - Bank B: addresses [2048..4095] (bank_load_target=1 / bank_select=1)
    //    - Write port: coef_bank_loader selects bank via MSB of write address
    //    - Read port:  bank_select MSB chooses active bank each cycle
    //
    //  Gapless switch: bank_select instantly redirects read address MSB.
    //
    //  Inferred as RAMB36E2 SDP by Vivado: depth=4096, width=18 per MAC.
    // -------------------------------------------------------------------------

    // Write-bus pipeline register (fanout relief to 256 BRAMs)
    (* max_fanout = 32 *) logic [11:0]                  coef_waddr_r;
    (* max_fanout = 32 *) logic signed [COEF_WIDTH-1:0] coef_wdata_r;
    (* max_fanout = 32 *) logic                         bank_load_target_q;

    // Pre-decoded one-hot WEA per MAC: registered to eliminate the high-fanout
    // LUT decode tree (coef_wmac_r == 8'(m)) on the critical path to BRAM WEA.
    // Each bit drives exactly one BRAM's WEA — fanout=1 per bit, zero long routes.
    (* max_fanout = 1 *) logic [NUM_MACS-1:0] mac_we_oh;   // one-hot, Bank A
    (* max_fanout = 1 *) logic [NUM_MACS-1:0] mac_we_oh_b; // one-hot, Bank B

    always_ff @(posedge clk) begin
        coef_waddr_r        <= coef_waddr;
        coef_wdata_r        <= coef_wdata;
        bank_load_target_q  <= bank_load_target;
        for (int i = 0; i < NUM_MACS; i++) begin
            mac_we_oh[i]   <= coef_we && !bank_load_target && (coef_wmac == 7'(i));
            mac_we_oh_b[i] <= coef_we &&  bank_load_target && (coef_wmac == 7'(i));
        end
    end
    
    // synthesis translate_off
    // DEBUG: Trace coefficient writes and verify readback
    int dbg_write_cnt = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_write_cnt <= 0;
        end else if (coef_we) begin
            dbg_write_cnt <= dbg_write_cnt + 1;
`ifdef SIM_DEBUG
            $display("[COEF_DBG @%0t] we=1 wmac=%0d waddr=%0d wdata=%0d target=%0b mac0_we=%0b wcnt=%0d",
                $time, coef_wmac, coef_waddr, coef_wdata, bank_load_target, mac_we_oh[0], dbg_write_cnt);
`endif
        end else if (!coef_we && dbg_write_cnt > 0 && dbg_write_cnt < 20) begin
            dbg_write_cnt <= dbg_write_cnt + 1;
`ifdef SIM_DEBUG
            if (coef_addr == 0)
                $display("[COEF_CHECK @%0t] After write: addr=0 coef_out[0]=%0d", $time, coef_out[0]);
`endif
        end
    end
    
    // NEGEDGE debug to verify combinational mac_we_oh settles correctly
    always_ff @(negedge clk) begin
`ifdef SIM_DEBUG
        if (rst_n && coef_we && coef_wmac == 0)
            $display("[WE_NEGEDGE @%0t] coef_we=%0b wmac=%0d mac0_we=%0b (should be 1)",
                $time, coef_we, coef_wmac, mac_we_oh[0]);
`endif
    end
    // synthesis translate_on

    // Coefficient address from L interpolator (R is lockstep identical)
    logic [11:0] coef_addr;
    
    // Muxed coefficient output to FIR engines
    logic signed [COEF_WIDTH-1:0] coef_out [0:NUM_MACS-1];

    genvar m;
    generate
        for (m = 0; m < NUM_MACS; m++) begin : gen_dual_coef_bram

            // Explicit RAMB36E2: 36-bit wide x 2048 deep SDP.
            // Bank A coef in bits [17:0],  Bank B coef in bits [35:18].
            // Write port (A): WE[1:0]=1 writes Bank A half only (bits [17:0])
            //                 WE[3:2]=1 writes Bank B half only (bits [35:18])
            // Read  port (B): 36-bit registered read; bank_select mux picks half.
            // One RAMB36E2 per MAC = 256 total (vs 512 with two inferred BRAMs).

            // RAMB36E2 SDP 36-bit layout (per UG974):
            //   DIADI[31:0] + DIPADIP[3:0] = 36 bits total
            //   WEAWEL[n] gates {DIPADIP[n], DIADI[9n+8 : 9n]} (9 bits each)
            //   WE[1:0] → lower 18 bits: {DIPADIP[1:0], DIADI[15:0]}
            //   WE[3:2] → upper 18 bits: {DIPADIP[3:2], DIADI[31:16]}
            //
            // We map 18-bit coefficients using only DIADI (no parity bits needed):
            //   Bank A: coef[17:0] → DIADI[17:0]  (WE[1:0], parity DIPADIP[1:0]=0)
            //   Bank B: coef[17:0] → DIADI[31:14] (WE[3:2], parity DIPADIP[3:2]=0)
            // Note: DIADI[13:0] overlap is fine — WEs gate independently per half.

            // Inferred simple dual-port BRAM for simulation (4096 deep: 2 banks of 2048)
            (* ram_style = "block" *) logic [31:0] bram_mem [0:4095];
            logic [31:0] rdata_do;
            
            // Initialize BRAM to 0
            initial begin
                for (int i = 0; i < 4096; i++) begin
                    bram_mem[i] = 32'h0;
                end
            end
            
            // Write port - use full 32-bit assignments to avoid partial select issues
            always_ff @(posedge clk) begin
                if (mac_we_oh[m]) begin
                    bram_mem[coef_waddr_r] <= {14'b0, coef_wdata_r};
                end
                if (mac_we_oh_b[m]) begin
                    bram_mem[coef_waddr_r] <= {coef_wdata_r, 14'b0};
                end
            end
            
            // Read port with 2-cycle registered output to match RAMB36E2 DOB_REG=1
            // Stage 1: BRAM array output register
            // Stage 2: DOB_REG output register
            logic [31:0] rdata_do_stage1;
            always_ff @(posedge clk) begin
                rdata_do_stage1 <= bram_mem[coef_addr];
                rdata_do        <= rdata_do_stage1;
            end

            // Bank select mux on registered read output (DOB_REG=1, 2-cycle latency)
            assign coef_out[m] = bank_select
                                 ? signed'(rdata_do[31:14])   // Bank B
                                 : signed'(rdata_do[17:0]);   // Bank A
                                 
            // synthesis translate_off
            // DEBUG: Trace coef_out[0] and coef_addr during active FIR sweeps
            if (m == 0) begin : gen_bram_dbg
                int dbg_sweep_cnt = 0;
                logic dbg_coef_nonzero_seen = 0;
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        dbg_sweep_cnt    <= 0;
                        dbg_coef_nonzero_seen <= 0;
                    end else begin
                        // Trace every write to MAC[0]
`ifdef SIM_DEBUG
                        if (mac_we_oh[m] || mac_we_oh_b[m])
                            $display("[BRAM_WRITE @%0t] addr=%0d wdata_r=%0h we_a=%0b we_b=%0b",
                                $time, coef_waddr_r, coef_wdata_r, mac_we_oh[m], mac_we_oh_b[m]);
`endif
                        // Track when coef_addr wraps to 0 (start of sweep)
                        if (coef_addr == 0) begin
                            dbg_sweep_cnt <= dbg_sweep_cnt + 1;
`ifdef SIM_DEBUG
                            $display("[SWEEP_START @%0t] sweep=%0d bram_mem[0]=%0h rdata_do_s1=%0h rdata_do=%0h coef_out=%0d",
                                $time, dbg_sweep_cnt, bram_mem[0], rdata_do_stage1, rdata_do, coef_out[m]);
`endif
                        end
                        // First time coef_out[0] goes non-zero
                        if (coef_out[m] != 0 && !dbg_coef_nonzero_seen) begin
                            dbg_coef_nonzero_seen <= 1;
`ifdef SIM_DEBUG
                            $display("[COEF_NONZERO @%0t] coef_addr=%0d coef_out=%0d rdata_do=%0h",
                                $time, coef_addr, coef_out[m], rdata_do);
`endif
                        end
                    end
                end
            end
            // synthesis translate_on

        end
    endgenerate


    // -------------------------------------------------------------------------
    //  Left channel interpolator
    // -------------------------------------------------------------------------
    fir_polyphase_interpolator #(
        .NUM_MACS   (NUM_MACS),
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_l_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_l),
        .interpolated_out   (interpolated_l),
        .interpolated_valid (interpolated_l_valid),
        .coef_in            (coef_out),
        .coef_addr_out      (coef_addr)
    );

    // -------------------------------------------------------------------------
    //  Right channel interpolator
    //  coef_in is the same coef_out[] array -- shared BRAMs.
    //  coef_addr_out is ignored (lockstep with L).
    // -------------------------------------------------------------------------
    logic [11:0] coef_addr_r_unused;

    fir_polyphase_interpolator #(
        .NUM_MACS   (NUM_MACS),
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_r_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_r),
        .interpolated_out   (interpolated_r),
        .interpolated_valid (interpolated_r_valid),
        .coef_in            (coef_out),
        .coef_addr_out      (coef_addr_r_unused)
    );

endmodule
