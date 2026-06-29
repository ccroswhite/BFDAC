`timescale 1ns / 1ps

// =============================================================================
//  FIR_POLYPHASE_MONO
//
//  Single-channel wrapper around one fir_polyphase_interpolator instance.
//  Used in the dual-FPGA design where each FPGA handles exactly one channel.
//
//  Owns NUM_MACS coefficient BRAMs — one explicit RAMB36E2 per MAC:
//    RAMB36E2 configured as 36-bit SDP, 1024 deep (4M taps: 16*64=1024 coefs/MAC).
//    Bank A coef → DIADI[17:0],  WE[1:0] gates write.
//    Bank B coef → DIADI[31:14], WE[3:2] gates write.
//    Byte-enable-gated partial writes allow both banks to coexist at the
//    same address without overwriting the inactive bank — this is what
//    allows 2K×36 in a single RAMB36E2 (inferred BRAMs cascade instead).
//
//  Budget: NUM_MACS RAMB36E2 coef + audio + misc.
// =============================================================================
module fir_polyphase_mono #(
    parameter int NUM_MACS       = 4096,  // Scalable: 256, 512, 1024, 2048, 4096
    parameter int NUM_PHASES     = 16,
    parameter int TAPS_PER_PHASE = 64,   // 4K MACs * 16 * 64 = 4,194,304 taps (4M)
    parameter int DATA_WIDTH     = 24,
    parameter int COEF_WIDTH     = 18,
    parameter int ACC_WIDTH      = 48
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // Baseband input
    input  logic                          new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]  new_sample_data,

    // Interpolated output
    output logic signed [ACC_WIDTH-1:0]   interpolated_out,
    output logic                          interpolated_valid,

    // Coefficient write bus (from coef_bank_loader)
    input  logic                          coef_we,
    input  logic [$clog2(NUM_PHASES*TAPS_PER_PHASE)-1:0] coef_waddr,  // 10 bits for 1024 coefs/MAC
    input  logic signed [COEF_WIDTH-1:0]   coef_wdata,
    input  logic [$clog2(NUM_MACS)-1:0]     coef_wmac,  // 12 bits for 4096 MACs

    // Dual-bank gapless switching control
    input  logic                          bank_select,
    input  logic                          bank_load_target
);

    // -------------------------------------------------------------------------
    //  Write-bus pipeline register (fanout relief)
    // -------------------------------------------------------------------------
    (* max_fanout = 32 *) logic [$clog2(NUM_PHASES*TAPS_PER_PHASE)-1:0] coef_waddr_r;
    (* max_fanout = 32 *) logic signed [COEF_WIDTH-1:0] coef_wdata_r;
    (* max_fanout = 32 *) logic                         bank_load_target_q;

    // Pre-decoded one-hot WE per MAC — Bank A and Bank B separately
    (* max_fanout = 1 *) logic [NUM_MACS-1:0] mac_we_oh;    // Bank A WE
    (* max_fanout = 1 *) logic [NUM_MACS-1:0] mac_we_oh_b;  // Bank B WE

    always_ff @(posedge clk) begin
        coef_waddr_r       <= coef_waddr;
        coef_wdata_r       <= coef_wdata;
        bank_load_target_q <= bank_load_target;
        for (int i = 0; i < NUM_MACS; i++) begin
            mac_we_oh[i]   <= coef_we && !bank_load_target && (coef_wmac == $clog2(NUM_MACS)'(i));
            mac_we_oh_b[i] <= coef_we &&  bank_load_target && (coef_wmac == $clog2(NUM_MACS)'(i));
        end
    end

    // Coefficient address and output — driven by the interpolator
    logic [$clog2(NUM_PHASES*TAPS_PER_PHASE)-1:0] coef_addr;  // Coeff depth per MAC
    logic signed [COEF_WIDTH-1:0]     coef_out [0:NUM_MACS-1];

    genvar m;
    generate
        for (m = 0; m < NUM_MACS; m++) begin : gen_coef_bram

            // ------------------------------------------------------------------
            // One RAMB36E2 per MAC — 18-bit SDP.
            // 4M taps: 16 phases * 64 TAPS_PER_PHASE = 1024 coefs/MAC (fits in 1 RAMB36E2).
            // XSim simulates RAMB36E2 via the built-in Unisim library model.
            localparam int COEF_ADDR_BITS = $clog2(NUM_PHASES * TAPS_PER_PHASE);
            localparam int ROW_BITS = (COEF_ADDR_BITS > 11) ? 11 : COEF_ADDR_BITS;  // Max 2048
            logic [31:0] dob_out;
            logic [3:0]  dob_outp;
            wire we_a = mac_we_oh[m];
            wire we_b = mac_we_oh_b[m];

            RAMB36E2 #(
                .WRITE_WIDTH_A     (18),
                .READ_WIDTH_A      (0),
                .READ_WIDTH_B      (18),
                .WRITE_WIDTH_B     (0),
                .DOB_REG           (1),
                .WRITE_MODE_A      ("READ_FIRST"),
                .WRITE_MODE_B      ("READ_FIRST"),
                .RSTREG_PRIORITY_A ("RSTREG"),
                .RSTREG_PRIORITY_B ("RSTREG"),
                .RDADDRCHANGEA     ("FALSE"),
                .RDADDRCHANGEB     ("FALSE")
            ) u_coef_bram (
                .CLKARDCLK    (clk),
                .CLKBWRCLK    (clk),
                .ENARDEN      (1'b1),
                .ENBWREN      (1'b1),
                .REGCEAREGCE  (1'b1),
                .REGCEB       (1'b1),
                .RSTRAMARSTRAM(1'b0),
                .RSTRAMB      (1'b0),
                .RSTREGARSTREG(1'b0),
                .RSTREGB      (1'b0),
                .SLEEP        (1'b0),
                .ADDRENA      (1'b1),
                .ADDRENB      (1'b1),
                // Write port (A): coefficient load
                // SDP 18-bit: ADDRARDADDR[14:4]=row, [3:0]=col (always 1111)
                .ADDRARDADDR  ({ {(15-4-ROW_BITS){1'b0}}, coef_waddr_r[ROW_BITS-1:0], 4'b1111 }),
                .DINADIN      ({16'b0, coef_wdata_r[15:0]}),
                .DINPADINP    ({2'b0, coef_wdata_r[17:16]}),
                .WEA          ({2'b0, we_a | we_b, we_a | we_b}),
                // Read port (B): coefficient read
                .ADDRBWRADDR  ({ {(15-4-ROW_BITS){1'b0}}, coef_addr[ROW_BITS-1:0], 4'b1111 }),
                .DOUTBDOUT    (dob_out),
                .DOUTPBDOUTP  (dob_outp),
                .DINBDIN      (32'b0),
                .DINPBDINP    (4'b0),
                .WEBWE        (8'b0),
                // Cascade ports (unused)
                .CASDIMUXA    (1'b0),
                .CASDIMUXB    (1'b0),
                .CASDOMUXA    (1'b0),
                .CASDOMUXB    (1'b0),
                .CASDOMUXEN_A (1'b0),
                .CASDOMUXEN_B (1'b0),
                .CASOREGIMUXA (1'b0),
                .CASOREGIMUXB (1'b0),
                .CASOREGIMUXEN_A(1'b0),
                .CASOREGIMUXEN_B(1'b0),
                .CASDINA      (32'b0),
                .CASDINB      (32'b0),
                .CASDINPA     (4'b0),
                .CASDINPB     (4'b0),
                .CASINDBITERR (1'b0),
                .CASINSBITERR (1'b0),
                .INJECTDBITERR(1'b0),
                .INJECTSBITERR(1'b0),
                .ECCPIPECE    (1'b0)
            );

            // Single-bank: 18 bits = {dob_outp[1:0], dob_out[15:0]}
            assign coef_out[m] = signed'({dob_outp[1:0], dob_out[15:0]});

        end
    endgenerate

    // -------------------------------------------------------------------------
    //  Single interpolator instance
    // -------------------------------------------------------------------------
    fir_polyphase_interpolator #(
        .NUM_MACS       (NUM_MACS),
        .NUM_PHASES     (NUM_PHASES),
        .TAPS_PER_PHASE (TAPS_PER_PHASE),
        .DATA_WIDTH     (DATA_WIDTH),
        .COEF_WIDTH     (COEF_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH)
    ) u_fir (
        .clk                (clk),
        .rst_n              (rst_n),
        .new_sample_valid   (new_sample_valid),
        .new_sample_data    (new_sample_data),
        .interpolated_out   (interpolated_out),
        .interpolated_valid (interpolated_valid),
        .coef_in            (coef_out),
        .coef_addr_out      (coef_addr)
    );

endmodule
