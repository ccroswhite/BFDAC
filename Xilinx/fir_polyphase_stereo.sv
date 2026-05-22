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
    parameter int NUM_MACS   = 256,
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
    input  logic [10:0]                   coef_waddr,
    input  logic signed [COEF_WIDTH-1:0]  coef_wdata,
    input  logic [7:0]                    coef_wmac,

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
    (* max_fanout = 32 *) logic [10:0]                  coef_waddr_r;
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
            mac_we_oh[i]   <= coef_we && !bank_load_target && (coef_wmac == 8'(i));
            mac_we_oh_b[i] <= coef_we &&  bank_load_target && (coef_wmac == 8'(i));
        end
    end

    // Coefficient address from L interpolator (R is lockstep identical)
    logic [10:0] coef_addr;

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

            wire [31:0] wdata_di = bank_load_target_q
                                   ? {coef_wdata_r[17:0], 14'b0}  // Bank B → [31:14]
                                   : {14'b0, coef_wdata_r[17:0]}; // Bank A → [17:0]

            // WEA from pre-decoded one-hot registers — fanout=1, no routing penalty.
            wire [3:0] we = mac_we_oh[m]   ? 4'b0011 :   // Bank A
                            mac_we_oh_b[m] ? 4'b1100 :   // Bank B
                                             4'b0000;

            wire [31:0] rdata_do;

            RAMB36E2 #(
                .READ_WIDTH_A       (0),
                .READ_WIDTH_B       (36),
                .WRITE_WIDTH_A      (36),
                .WRITE_WIDTH_B      (0),
                .DOB_REG            (1),
                .WRITE_MODE_A       ("NO_CHANGE"),
                .CLOCK_DOMAINS      ("COMMON"),
                .SIM_COLLISION_CHECK("NONE")
            ) u_bram (
                // Port A — write only
                .CLKARDCLK          (clk),
                .ENARDEN            (1'b1),
                .REGCEAREGCE        (1'b0),
                .RSTRAMARSTRAM      (1'b0),
                .RSTREGARSTREG      (1'b0),
                .ADDRARDADDR        ({1'b1, coef_waddr_r, 5'b11111}),
                .DINADIN            (wdata_di),
                .DINPADINP          (4'b0),
                .WEA                (we),
                .DOUTADOUT          (),
                .DOUTPADOUTP        (),

                // Port B — read only
                .CLKBWRCLK          (clk),
                .ENBWREN            (1'b1),
                .REGCEB             (1'b1),
                .RSTRAMB            (1'b0),
                .RSTREGB            (1'b0),
                .ADDRBWRADDR        ({1'b1, coef_addr, 5'b11111}),
                .DINBDIN            (32'b0),
                .DINPBDINP          (4'b0),
                .WEBWE              (8'b0),
                .DOUTBDOUT          (rdata_do),
                .DOUTPBDOUTP        (),

                // Unused cascade/ECC ports
                .ADDRENA            (1'b0),
                .ADDRENB            (1'b0),
                .CASDIMUXA          (1'b0),
                .CASDIMUXB          (1'b0),
                .CASDINA            (32'b0),
                .CASDINB            (32'b0),
                .CASDINPA           (4'b0),
                .CASDINPB           (4'b0),
                .CASDOMUXA          (1'b0),
                .CASDOMUXB          (1'b0),
                .CASDOMUXEN_A       (1'b0),
                .CASDOMUXEN_B       (1'b0),
                .CASINDBITERR       (1'b0),
                .CASINSBITERR       (1'b0),
                .CASOREGIMUXA       (1'b0),
                .CASOREGIMUXB       (1'b0),
                .CASOREGIMUXEN_A    (1'b0),
                .CASOREGIMUXEN_B    (1'b0),
                .ECCPIPECE          (1'b0),
                .INJECTDBITERR      (1'b0),
                .INJECTSBITERR      (1'b0),
                .SLEEP              (1'b0),
                .CASDOUTA           (),
                .CASDOUTB           (),
                .CASDOUTPA          (),
                .CASDOUTPB          (),
                .CASOUTDBITERR      (),
                .CASOUTSBITERR      (),
                .DBITERR            (),
                .ECCPARITY          (),
                .RDADDRECC          (),
                .SBITERR            ()
            );

            // Bank select mux on registered read output (DOB_REG=1, 2-cycle latency)
            assign coef_out[m] = bank_select
                                 ? signed'(rdata_do[31:14])   // Bank B
                                 : signed'(rdata_do[17:0]);   // Bank A

        end
    endgenerate

    // --- DEBUG: log first 8 coef reads after rst_n releases ---
    // synthesis translate_off
    int dbg_coef_read_cnt = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_coef_read_cnt <= 0;
        end else if (dbg_coef_read_cnt < 8) begin
            dbg_coef_read_cnt <= dbg_coef_read_cnt + 1;
            $display("[BRAM_DBG @%0t] cnt=%0d bank_sel=%0b rdata_do[0]=%08h coef_out[0]=%0h coef_out[1]=%0h",
                $time, dbg_coef_read_cnt, bank_select,
                gen_dual_coef_bram[0].rdata_do,
                coef_out[0], coef_out[1]);
        end
    end
    // synthesis translate_on

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
    logic [10:0] coef_addr_r_unused;

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
