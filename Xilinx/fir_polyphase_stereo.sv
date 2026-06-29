`timescale 1ns / 1ps

// =============================================================================
//  FIR_POLYPHASE_STEREO  —  XCVU13P single-FPGA stereo design
//
//  Stereo wrapper around two fir_polyphase_interpolator instances (L and R).
//
//  Coefficient storage: URAM288 (UltraRAM), 2 MACs packed per URAM.
//  URAM288 SDP mode: 4096 × 72-bit.
//  Layout per URAM (pair of MACs, indexed u = m/2):
//    Bits [17: 0] = MAC(2u+0) Bank A coef  (18-bit signed)
//    Bits [35:18] = MAC(2u+0) Bank B coef  (18-bit signed)
//    Bits [53:36] = MAC(2u+1) Bank A coef  (18-bit signed)
//    Bits [71:54] = MAC(2u+1) Bank B coef  (18-bit signed)
//  Address [11:0]: lower COEF_DEPTH addresses = coef index (0..COEF_DEPTH-1).
//
//  Write: coef_bank_loader supplies (coef_wmac, coef_waddr, coef_wdata, bank_load_target).
//         Address into URAM = coef_waddr. URAM index = coef_wmac/2. Lane = coef_wmac[0].
//         WEN[7:0] selects the 9-bit byte lanes for the target MAC+bank within the 72-bit word.
//
//  Read:  coef_addr driven by L interpolator (R lockstep identical).
//         2-cycle registered URAM read latency (OUTPUT_REG=1).
//         bank_select mux picks Bank A or Bank B slice from registered output.
//
//  Resource usage:
//    NUM_MACS=1024: 512 URAMs (41% of 1,250)  — 1M taps/ch
//    NUM_MACS=2048: 1024 URAMs (82% of 1,250) — 2M taps/ch
//
//  Both channels share the same coef array (coefficient sets are channel-independent
//  for a symmetric linear-phase prototype filter).
// =============================================================================
module fir_polyphase_stereo #(
    parameter int NUM_MACS       = 1024,  // Production: 1024 (1M taps) or 2048 (2M taps)
    parameter int TAPS_PER_PHASE = 64,    // 16 phases × 64 = 1024 coefs/MAC
    parameter int DATA_WIDTH     = 24,
    parameter int COEF_WIDTH     = 18,
    parameter int ACC_WIDTH      = 48
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

    // Coefficient write bus (from coef_bank_loader, dsp_clk domain)
    input  logic                               coef_we,
    input  logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_waddr,  // 10 bits for COEF_DEPTH=1024
    input  logic signed [COEF_WIDTH-1:0]       coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]        coef_wmac,     // Which MAC to write

    // Dual-bank gapless switching control
    input  logic                          bank_select,       // 0=Bank A active, 1=Bank B active
    input  logic                          bank_load_target   // 0=write Bank A, 1=write Bank B
);

    // -------------------------------------------------------------------------
    //  Parameters and local constants
    // -------------------------------------------------------------------------
    localparam int COEF_DEPTH  = 16 * TAPS_PER_PHASE;  // 1024 for TAPS_PER_PHASE=64
    localparam int NUM_URAMS   = NUM_MACS / 2;          // 2 MACs packed per URAM288
    // URAM288 SDP: 4096 × 72-bit. We only use COEF_DEPTH addresses (lower 1024 of 4096).
    localparam int URAM_AW     = 12;   // URAM address is always 12-bit (4096 deep)
    localparam int URAM_DW     = 72;   // URAM data width in SDP mode

    // -------------------------------------------------------------------------
    //  Write-bus pipeline registers (1-cycle register for fanout relief)
    //  Registered into URAM write port next cycle.
    // -------------------------------------------------------------------------
    (* max_fanout = 32 *) logic [URAM_AW-1:0]              coef_waddr_r;
    (* max_fanout = 32 *) logic signed [COEF_WIDTH-1:0]    coef_wdata_r;
    (* max_fanout = 32 *) logic                            bank_load_target_r;
    (* max_fanout = 32 *) logic [$clog2(NUM_MACS)-1:0]     coef_wmac_r;
    (* max_fanout = 32 *) logic                            coef_we_r;

    always_ff @(posedge clk) begin
        coef_waddr_r        <= URAM_AW'(coef_waddr);
        coef_wdata_r        <= coef_wdata;
        bank_load_target_r  <= bank_load_target;
        coef_wmac_r         <= coef_wmac;
        coef_we_r           <= coef_we;
    end

    // -------------------------------------------------------------------------
    //  Coefficient address from L interpolator (R is lockstep identical)
    // -------------------------------------------------------------------------
    logic [$clog2(COEF_DEPTH)-1:0] coef_addr;

    // -------------------------------------------------------------------------
    //  Muxed coefficient output to FIR engines (one 18-bit value per MAC per cycle)
    // -------------------------------------------------------------------------
    logic signed [COEF_WIDTH-1:0] coef_out [0:NUM_MACS-1];

    // -------------------------------------------------------------------------
    //  URAM288 coefficient storage — NUM_URAMS instances, 2 MACs per URAM
    //
    //  72-bit word layout:
    //    [17: 0] = MAC(even) Bank A
    //    [35:18] = MAC(even) Bank B
    //    [53:36] = MAC(odd)  Bank A
    //    [71:54] = MAC(odd)  Bank B
    //
    //  WEN[7:0]: each bit gates 9 bits of the 72-bit word (UG573):
    //    WEN[0] → bits[ 8: 0],  WEN[1] → bits[17: 9]  → MAC(even) Bank A [17:0]
    //    WEN[2] → bits[26:18],  WEN[3] → bits[35:27]  → MAC(even) Bank B [35:18]
    //    WEN[4] → bits[44:36],  WEN[5] → bits[53:45]  → MAC(odd)  Bank A [53:36]
    //    WEN[6] → bits[62:54],  WEN[7] → bits[71:63]  → MAC(odd)  Bank B [71:54]
    //
    //  URAM read latency: 2 cycles (IREG_PRE=1, OREG=1).
    //  bank_select mux applied after URAM output register.
    // -------------------------------------------------------------------------
    genvar u;
    generate
        for (u = 0; u < NUM_URAMS; u++) begin : gen_uram_coef

            // Determine if this URAM is being written this cycle
            // coef_wmac_r[0]=0 → even MAC (lower lane), [0]=1 → odd MAC (upper lane)
            wire uram_sel    = (coef_wmac_r[$clog2(NUM_MACS)-1:1] == $clog2(NUM_URAMS)'(u));
            wire uram_we     = coef_we_r && uram_sel;
            wire lane_odd    = coef_wmac_r[0];  // 0=even MAC (lower 36b), 1=odd MAC (upper 36b)

            // WEN[7:0]: select the correct 18-bit field within the 72-bit word
            // Bank A = lower 18b of each 36b lane, Bank B = upper 18b
            // Even MAC: lanes [1:0]=Bank A, [3:2]=Bank B
            // Odd  MAC: lanes [5:4]=Bank A, [7:6]=Bank B
            // Each WEN bit gates 9 bits; 18-bit coef needs 2 WEN bits asserted.
            wire [7:0] uram_wen;
            assign uram_wen = !uram_we ? 8'h00 :
                              (!lane_odd && !bank_load_target_r) ? 8'h03 :  // even, Bank A
                              (!lane_odd &&  bank_load_target_r) ? 8'h0C :  // even, Bank B
                              ( lane_odd && !bank_load_target_r) ? 8'h30 :  // odd,  Bank A
                                                                   8'hC0;   // odd,  Bank B

            // Write data: place coef_wdata_r into the correct 18-bit lane of the 72-bit word.
            // Other lanes are don't-care since WEN gates them.
            wire [URAM_DW-1:0] uram_din;
            assign uram_din = {coef_wdata_r, coef_wdata_r, coef_wdata_r, coef_wdata_r};

            // URAM288 read data (2-cycle latency)
            wire [URAM_DW-1:0] uram_dout;

            // synthesis translate_off
            // Behavioral model for simulation (Vivado XSim doesn't have URAM288 primitive)
            (* ram_style = "ultra" *) logic [URAM_DW-1:0] uram_mem [0:4095];
            logic [URAM_DW-1:0] uram_rd_s1, uram_rd_s2;

            initial begin
                for (int i = 0; i < 4096; i++) uram_mem[i] = '0;
            end

            always_ff @(posedge clk) begin
                if (uram_we) begin
                    // Byte-enable write: only update enabled 9-bit groups
                    for (int b = 0; b < 8; b++) begin
                        if (uram_wen[b])
                            uram_mem[coef_waddr_r][b*9 +: 9] <= uram_din[b*9 +: 9];
                    end
                end
                uram_rd_s1 <= uram_mem[URAM_AW'(coef_addr)];
                uram_rd_s2 <= uram_rd_s1;
            end

            assign uram_dout = uram_rd_s2;
            // synthesis translate_on

            // synthesis translate_off is above — for synthesis the URAM288 primitive is used below
            // synthesis translate_on

`ifndef SYNTHESIS
            // simulation path already handled above via uram_dout
`else
            // ----------------------------------------------------------------
            //  Synthesis: explicit URAM288 primitive instantiation
            //  UG974 / PG-Xilinx UltraRAM primitive
            // ----------------------------------------------------------------
            URAM288 #(
                .OREG_A             ("FALSE"),  // No output reg on write port (write-only)
                .OREG_B             ("TRUE"),   // Output register on read port (1 extra cycle)
                .IREG_PRE_A         ("FALSE"),
                .IREG_PRE_B         ("TRUE"),   // Input addr register (total 2-cycle read latency)
                .AUTO_SLEEP_LATENCY (8),
                .AVG_CONS_INACTIVE_CYCLES(10),
                .BWE_MODE_A         ("PARITY_INTERLEAVED"),
                .BWE_MODE_B         ("PARITY_INTERLEAVED"),
                .EN_AUTO_SLEEP_MODE ("FALSE"),
                .EN_ECC_RD_A        ("FALSE"),
                .EN_ECC_RD_B        ("FALSE"),
                .EN_ECC_WR_A        ("FALSE"),
                .EN_ECC_WR_B        ("FALSE"),
                .INIT_VALUE         (72'h000000000000000000),
                .RST_MODE_A         ("SYNC"),
                .RST_MODE_B         ("SYNC"),
                .SELF_ADDR_A        (11'h000),
                .SELF_ADDR_B        (11'h000),
                .SELF_MASK_A        (11'h7ff),
                .SELF_MASK_B        (11'h7ff),
                .USE_EXT_CE_A       ("FALSE"),
                .USE_EXT_CE_B       ("FALSE")
            ) u_uram (
                // Port A — Write only (coefficient load)
                .ADDRA      (URAM_AW'(coef_waddr_r)),
                .DINA       (uram_din),
                .BWEa       (uram_wen),
                .ENA        (uram_we),
                .RDB_WR_A   (1'b1),              // 1=write mode
                .DOUTA      (),                  // unused
                .SLEEP      (1'b0),
                .RSTA       (1'b0),

                // Port B — Read only (coefficient sweep)
                .ADDRB      (URAM_AW'(coef_addr)),
                .DINB       ('0),
                .BWEb       (8'hFF),
                .ENB        (1'b1),
                .RDB_WR_B   (1'b0),              // 0=read mode
                .DOUTB      (uram_dout),
                .RSTB       (!rst_n),

                .OREG_CE_A  (1'b1),
                .OREG_CE_B  (1'b1),
                .CLK        (clk)
            );
`endif

            // Extract coef_out for even and odd MAC from registered URAM output
            // bank_select mux picks Bank A or Bank B slice
            assign coef_out[2*u]   = bank_select
                                     ? signed'(uram_dout[35:18])  // even MAC, Bank B
                                     : signed'(uram_dout[17:0]);  // even MAC, Bank A

            assign coef_out[2*u+1] = bank_select
                                     ? signed'(uram_dout[71:54])  // odd MAC, Bank B
                                     : signed'(uram_dout[53:36]); // odd MAC, Bank A

        end
    endgenerate


    // -------------------------------------------------------------------------
    //  Left channel interpolator
    // -------------------------------------------------------------------------
    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH)
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
    logic [$clog2(16*TAPS_PER_PHASE)-1:0] coef_addr_r_unused;

    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH)
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
