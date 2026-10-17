`timescale 1ns / 1ps

// =============================================================================
// tb_vu13p_mig — FULL TOP with the REAL DDR4 MIG (ddr4_0, Simulation_Mode=BFM)
// and the Micron DDR4 SDRAM model (2026-09-04, plan Step 4.4 residue).
//
// This is the only simulation of the true boot chain on the real MIG:
//   STARTUPE3.EOS && init_calib_complete
//     -> qspi_boot_loader reads the record chain from Flash 1 (behavioral
//        SPI flash below; SCK tapped hierarchically because CCLK is a
//        dedicated config pin, not a user I/O)
//     -> AXI write (128 b) -> axi_dwc_coef (512 b) -> ddr4_0 -> Micron model
//     -> ARM (SPI) builds a 1-entry list and commits -> coef_bank_loader
//        walks the DDR4 directory, streams the bank back over AXI read
//     -> FIR bank written, bank_valid, COEF_STATUS[12]
//
// Boot image staged in flash (records are packed, 16 B header each):
//   rec A @0x00 : dest DIR_BASE_ADDR (0x3FFF_0000), 64 B = entry 0 + terminator
//   rec B @0x50 : dest BANK_DDR4 (0x0010_0000), BANK_SIZE (16 KB) of coefficients,
//                 word k (mac = k / COEF_DEPTH, idx = k % COEF_DEPTH) = k
//   then erased flash (0xFF) = end of chain
//
// Tests:
//   T1 MIG calibration completes (led_debug[2] / init_calib_complete)
//   T2 boot loader: boot_done, boot_ok, 2 records, no CRC/AXI fail
//   T3 list commit -> directory load by ID -> every coefficient matches the
//      DDR4 image (NUM_MACS*COEF_DEPTH writes, 0 mismatches), bank_valid,
//      COEF_STATUS[12]=1, no load_err
//   T4 FILTER_SELECT_ID with an unknown ID -> sticky[6], CMD_ERR reason
//      FILT_NOTFOUND, bank still valid (previous filter keeps playing)
//
// Geometry: NUM_MACS=4, TAPS_PER_PHASE=64 -> COEF_DEPTH=1024, bank = 16 KB
// (the loader's minimum: COEF_DEPTH must be a multiple of the 1024-coef burst).
// Runner: Testbench/run_tb_mig.ps1 (needs sim_mig/ from
// scripts/gen_ddr4_example.tcl for the Micron model + IP compile lists).
// =============================================================================
import arch_package::*;

// xsim has no `tran`; the reference sim_tb_top shorts DQ/DQS/DM with this.
module short(in1, in1);
    inout in1;
endmodule

module tb_vu13p_mig;

    localparam real P200 = 5.0;       // 200 MHz system clock
    localparam real PREF = 4.998;     // MIG C0_SYS_CLK (200.08 MHz, 4998 ps)
    localparam real P49  = 20.345;    // 49.152 MHz
    localparam real P45  = 22.151;    // 45.1584 MHz

    localparam int NUM_MACS       = 4;
    localparam int TAPS_PER_PHASE = 64;   // loader minimum: COEF_DEPTH = one 1024-coef burst
    localparam int COEF_DEPTH     = 16 * TAPS_PER_PHASE;             // 1024
    localparam logic [31:0] BANK_SIZE     = 32'(NUM_MACS * COEF_DEPTH * 4);  // 16384
    localparam logic [31:0] DIR_BASE_ADDR = 32'h3FFF_0000;           // loader default
    localparam logic [31:0] BANK_DDR4     = 32'h0010_0000;
    localparam logic [15:0] FILT_ID       = 16'h0101;
    localparam logic [15:0] FILT_MISSING  = 16'h0404;

    // ---- Clocks / reset ---------------------------------------------------------------------
    logic clk_200m = 0, clk_ref = 0, clk_45m = 0, clk_49m = 0;
    logic mclk;
    wire  clk_sel;
    logic ext_rst_n = 0;
    always #(P200/2) clk_200m = ~clk_200m;
    always #(PREF/2) clk_ref  = ~clk_ref;
    always #(P49/2)  clk_49m  = ~clk_49m;
    always #(P45/2)  clk_45m  = ~clk_45m;
    assign mclk = clk_sel ? clk_45m : clk_49m;

    // I2S source (768 kHz frame) — keeps the ingress watchdog quiet
    wire i2s_bclk, i2s_lrclk;
    logic i2s_data = 0;

    // ---- SPI / misc pins ----------------------------------------------------------------------
    logic spi_sclk = 0, spi_cs_n = 1, spi_mosi = 0;
    wire  spi_miso, fpga_irq_n;
    wire  relay_line_mute, relay_hp_mute, relay_hp_rails;
    wire  [1:0]  relay_level;
    wire         led_status;
    wire  [3:0]  led_debug;     // [3]=clk_locked [2]=ddr4_calib [1]=i2s_err [0]=force_zero
    wire         qspi1_cs_n;
    wire  [3:0]  qspi1_dq;
    wire         cf_sck;             // carrier coef flash (bom 18a) - not populated here
    wire  [3:0]  cf_cs_n;
    wire  [3:0]  cf_dq;
    pullup (cf_dq[1]);               // absent device reads 0xFF -> SoM Flash 1 fallback
    wire  [63:0] cascode_l, cascode_r;

    // ---- DDR4 pins (64-bit, 4 x16 parts) ----------------------------------------------------
    wire [63:0] ddr4_dq;
    wire [7:0]  ddr4_dqs_c, ddr4_dqs_t, ddr4_dm_dbi_n;
    wire [16:0] ddr4_addr;
    wire [1:0]  ddr4_ba;
    wire [0:0]  ddr4_bg, ddr4_cs_n, ddr4_cke, ddr4_odt, ddr4_ck_t, ddr4_ck_c;
    wire        ddr4_act_n, ddr4_reset_n;

    // ---- DUT ---------------------------------------------------------------------------------
    defparam u_dut.u_automute.FLUSH_CYCLES       = 26'd400;
    defparam u_dut.u_automute.SETTLE_CYCLES      = 26'd200;
    defparam u_dut.u_automute.SWITCH_CYCLES      = 26'd200;
    defparam u_dut.u_automute.RAIL_SETTLE_CYCLES = 26'd600;

    vu13p_dac_top #(
        .NUM_MACS          (NUM_MACS),
        .TAPS_PER_PHASE    (TAPS_PER_PHASE),
        .MUTE_DELAY_CYCLES (2000)
    ) u_dut (
        .clk_200m_p     (clk_200m),
        .clk_200m_n     (~clk_200m),
        .mclk_p         (mclk),
        .mclk_n         (~mclk),
        .clk_sel        (clk_sel),
        .ext_rst_n      (ext_rst_n),
        .test_select_n  (1'b1), .test_step_n(1'b1), .pg_all(1'b1), .test_led(),
        .i2s_bclk       (i2s_bclk),
        .i2s_lrclk      (i2s_lrclk),
        .i2s_data       (i2s_data),
        .spi_sclk       (spi_sclk),
        .spi_cs_n       (spi_cs_n),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .fpga_irq_n     (fpga_irq_n),
        .relay_line_mute(relay_line_mute),
        .relay_hp_mute  (relay_hp_mute),
        .relay_hp_rails (relay_hp_rails),
        .relay_level    (relay_level),
        .led_status     (led_status),
        .led_debug      (led_debug),
        .qspi1_cs_n     (qspi1_cs_n),
        .qspi1_dq       (qspi1_dq),
        .cf_sck         (cf_sck),
        .cf_cs_n        (cf_cs_n),
        .cf_dq          (cf_dq),
        .cascode_l      (cascode_l),
        .cascode_r      (cascode_r),
        .ddr4_clkref_p  (clk_ref),
        .ddr4_clkref_n  (~clk_ref),
        .ddr4_dq        (ddr4_dq),
        .ddr4_dqs_c     (ddr4_dqs_c),
        .ddr4_dqs_t     (ddr4_dqs_t),
        .ddr4_dm_dbi_n  (ddr4_dm_dbi_n),
        .ddr4_addr      (ddr4_addr),
        .ddr4_ba        (ddr4_ba),
        .ddr4_bg        (ddr4_bg),
        .ddr4_cs_n      (ddr4_cs_n),
        .ddr4_cke       (ddr4_cke),
        .ddr4_odt       (ddr4_odt),
        .ddr4_act_n     (ddr4_act_n),
        .ddr4_ck_t      (ddr4_ck_t),
        .ddr4_ck_c      (ddr4_ck_c),
        .ddr4_reset_n   (ddr4_reset_n)
    );

    // ---- Micron DDR4 model: 1 rank, 4 x16 parts (mirrors the ddr4_0 example sim_tb_top) ------
    bit  en_model = 0;
    tri  model_enable = en_model;

    // WR/RD commands: mask A11/A12/A13 (AP/BC) as the reference TB does
    logic [16:0] adr_mod;
    always_comb begin
        if (ddr4_act_n && (ddr4_addr[16:14] == 3'b100 || ddr4_addr[16:14] == 3'b101))
            adr_mod = ddr4_addr & 17'h1C7FF;
        else
            adr_mod = ddr4_addr;
    end

    DDR4_if #(.CONFIGURED_DQ_BITS(16)) iDDR4[0:3]();

    genvar i, s;
    generate
        for (i = 0; i < 4; i++) begin : g_mem
            ddr4_model #(
                .CONFIGURED_DQ_BITS (16),
                .CONFIGURED_DENSITY (_16G)
            ) u_mem (
                .model_enable (model_enable),
                .iDDR4        (iDDR4[i])
            );
            for (s = 0; s < 16; s++) begin : g_dq
                short bidiDQ(iDDR4[i].DQ[s], ddr4_dq[s + i*16]);
            end
            short bidiDQS0 (iDDR4[i].DQS_t[0], ddr4_dqs_t[2*i]);
            short bidiDQS0_(iDDR4[i].DQS_c[0], ddr4_dqs_c[2*i]);
            short bidiDM0  (iDDR4[i].DM_n[0],  ddr4_dm_dbi_n[2*i]);
            short bidiDQS1 (iDDR4[i].DQS_t[1], ddr4_dqs_t[2*i+1]);
            short bidiDQS1_(iDDR4[i].DQS_c[1], ddr4_dqs_c[2*i+1]);
            short bidiDM1  (iDDR4[i].DM_n[1],  ddr4_dm_dbi_n[2*i+1]);

            assign iDDR4[i].BG        = ddr4_bg;
            assign iDDR4[i].BA        = ddr4_ba;
            assign iDDR4[i].ADDR_17   = 1'b0;
            assign iDDR4[i].ADDR      = adr_mod[13:0];
            assign iDDR4[i].CS_n      = ddr4_cs_n[0];
            assign iDDR4[i].CK        = {ddr4_ck_t[0], ddr4_ck_c[0]};
            assign iDDR4[i].ACT_n     = ddr4_act_n;
            assign iDDR4[i].RAS_n_A16 = adr_mod[16];
            assign iDDR4[i].CAS_n_A15 = adr_mod[15];
            assign iDDR4[i].WE_n_A14  = adr_mod[14];
            assign iDDR4[i].CKE       = ddr4_cke[0];
            assign iDDR4[i].ODT       = ddr4_odt[0];
            assign iDDR4[i].PARITY    = 1'b0;
            assign iDDR4[i].TEN       = 1'b0;
            assign iDDR4[i].ZQ        = 1'b1;
            assign iDDR4[i].PWR       = 1'b1;
            assign iDDR4[i].VREF_CA   = 1'b1;
            assign iDDR4[i].VREF_DQ   = 1'b1;
            assign iDDR4[i].RESET_n   = ddr4_reset_n;
        end
    endgenerate

    // ---- Behavioral SPI flash (Flash 1) — mode 0, 4-byte addresses (from tb_qspi_subsys) -----
    // SCK is the STARTUPE3 USRCCLKO (CCLK config pin, not a top port): tap it in the DUT.
    wire flash_sck  = u_dut.qspi_sck;
    wire flash_cs_n = qspi1_cs_n;
    wire flash_mosi = qspi1_dq[0];
    logic miso_r = 0;
    assign qspi1_dq[1] = miso_r;

    logic [7:0]  flash_mem [int unsigned];   // sparse; erased = 8'hFF
    logic [7:0]  f_shift, f_opcode, f_out_byte;
    int          f_bitcnt, f_phase, f_addr_bytes, f_out_bit;
    logic [31:0] f_addr;

    always @(negedge flash_cs_n) begin
        f_bitcnt = 0; f_phase = 0; f_out_bit = 7;
    end

    always @(posedge flash_sck) begin
        if (!flash_cs_n) begin
            f_shift  = {f_shift[6:0], flash_mosi};
            f_bitcnt = f_bitcnt + 1;
            if (f_bitcnt % 8 == 0) begin
                case (f_phase)
                    0: begin
                        f_opcode = f_shift;
                        f_addr   = 0;
                        case (f_opcode)
                            8'h13, 8'h12, 8'hDC: begin f_phase = 1; f_addr_bytes = 4; end
                            default:             f_phase = 2;
                        endcase
                    end
                    1: begin
                        f_addr       = {f_addr[23:0], f_shift};
                        f_addr_bytes = f_addr_bytes - 1;
                        if (f_addr_bytes == 0) f_phase = 2;
                    end
                    default: ;
                endcase
            end
        end
    end

    always @(negedge flash_sck) begin
        if (!flash_cs_n && f_phase == 2 && f_opcode != 8'h12) begin
            if (f_out_bit == 7) begin
                if (f_opcode == 8'h05)      f_out_byte = 8'h00;           // status: not busy
                else if (f_opcode == 8'h13) begin
                    f_out_byte = flash_mem.exists(f_addr) ? flash_mem[f_addr] : 8'hFF;
                    f_addr     = f_addr + 1;
                end else f_out_byte = 8'hFF;
            end
            miso_r    = f_out_byte[f_out_bit];
            f_out_bit = (f_out_bit == 0) ? 7 : f_out_bit - 1;
        end
    end

    // ---- Boot image builder --------------------------------------------------------------------
    function automatic logic [31:0] crc32_calc(input int base, input int len);
        logic [31:0] c = 32'hFFFFFFFF;
        for (int k = 0; k < len; k++) begin
            c = c ^ {24'd0, flash_mem[base + k]};
            for (int b = 0; b < 8; b++)
                c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        end
        return c ^ 32'hFFFFFFFF;
    endfunction

    task automatic put32(input int addr, input logic [31:0] v);
        flash_mem[addr]   = v[7:0];
        flash_mem[addr+1] = v[15:8];
        flash_mem[addr+2] = v[23:16];
        flash_mem[addr+3] = v[31:24];
    endtask

    task automatic put_header(input int fofs, input logic [31:0] dest, input int len);
        put32(fofs,      32'h42464443);          // "BFDC"
        put32(fofs + 4,  dest);
        put32(fofs + 8,  32'(len));
        put32(fofs + 12, crc32_calc(fofs + 16, len));
    endtask

    localparam int REC_A = 0;                    // directory record
    localparam int REC_B = REC_A + 16 + 64;      // bank record

    task automatic build_boot_image;
        int p;
        // --- rec A payload: directory entry 0 + all-zero terminator (2 x 32 B)
        p = REC_A + 16;
        for (int k = 0; k < 64; k++) flash_mem[p + k] = 8'h00;
        flash_mem[p + 0] = FILT_ID[7:0];
        flash_mem[p + 1] = FILT_ID[15:8];
        flash_mem[p + 2] = 8'd1;                 // phase_type
        flash_mem[p + 3] = 8'd1;                 // metadata 1 = 44.1k-family; reset stream rate
        put32(p + 4,  32'(16 * NUM_MACS * TAPS_PER_PHASE));   // tap_count
        put32(p + 8,  BANK_DDR4 >> 4);           // ddr4_offset (16 B units)
        put32(p + 12, BANK_SIZE);                // payload_bytes
        put32(p + 16, 32'd5000);                 // latency_us (ignored by RTL)
        put_header(REC_A, DIR_BASE_ADDR, 64);
        // --- rec B payload: coefficient bank, word k = k (MAC-major layout)
        p = REC_B + 16;
        for (int k = 0; k < NUM_MACS * COEF_DEPTH; k++)
            put32(p + 4*k, 32'(k));
        put_header(REC_B, BANK_DDR4, int'(BANK_SIZE));
        // chain end: flash left erased (0xFF) after rec B
    endtask

    // ---- SPI master (40-bit frame + CRC-8 0x07, ~10 MHz) ---------------------------------------
    function automatic [7:0] crc8_word(input [31:0] w);
        logic [7:0] c = 8'h00;
        for (int k = 31; k >= 0; k--)
            c = ((w[k] ^ c[7]) == 1'b1) ? ({c[6:0], 1'b0} ^ 8'h07) : {c[6:0], 1'b0};
        return c;
    endfunction

    task automatic spi_frame(input [39:0] frame, output [31:0] captured);
        captured = '0;
        spi_cs_n = 0; spi_sclk = 0; spi_mosi = 0;
        repeat (8) @(posedge clk_200m);
        for (int k = 39; k >= 0; k--) begin
            spi_mosi = frame[k];
            repeat (4) @(posedge clk_200m);
            spi_sclk = 1;
            repeat (2) @(posedge clk_200m);
            if (k >= 8) captured[k-8] = spi_miso;
            repeat (2) @(posedge clk_200m);
            spi_sclk = 0;
        end
        repeat (4) @(posedge clk_200m);
        spi_cs_n = 1; spi_mosi = 0;
        repeat (8) @(posedge clk_200m);
    endtask

    task automatic spi_write(input [6:0] addr, input [23:0] data);
        logic [31:0] payload, dummy;
        payload = {1'b0, addr, data};
        spi_frame({payload, crc8_word(payload)}, dummy);
    endtask

    task automatic spi_read(input [6:0] addr, output [31:0] rdata);
        logic [31:0] payload, dummy;
        payload = {1'b1, addr, 24'h0};
        spi_frame({payload, crc8_word(payload)}, dummy);    // read command
        payload = {1'b0, 7'h00, 24'h0};
        spi_frame({payload, crc8_word(payload)}, rdata);    // NOP clocks out the response
    endtask

    // ---- Monitors -----------------------------------------------------------------------------
    int total_coef_writes = 0;
    int coef_data_errors  = 0;
    always @(posedge u_dut.dsp_clk) if (u_dut.coef_we) begin
        total_coef_writes++;
        if (u_dut.coef_wdata !== 18'((int'(u_dut.coef_wmac) * COEF_DEPTH + int'(u_dut.coef_waddr)) & 32'h3FFFF)) begin
            coef_data_errors++;
            if (coef_data_errors <= 5)
                $display("[%0t] COEF DATA MISMATCH mac=%0d addr=%0d got=%0h",
                         $time, u_dut.coef_wmac, u_dut.coef_waddr, u_dut.coef_wdata);
        end
    end

    int axi_wr_bursts = 0, axi_rd_bursts = 0;
    always @(posedge u_dut.ddr4_ui_clk) begin
        if (u_dut.axi_awvalid && u_dut.axi_awready) axi_wr_bursts++;
        if (u_dut.axi_arvalid && u_dut.axi_arready) axi_rd_bursts++;
    end

`ifdef TB_AXI_TRACE
    // 128-bit side (boot loader / coef loader) and 512-bit side (ddr4_0) of axi_dwc_coef.
    // Every beat: first data word only. Enough to see address/ordering faults.
    always @(posedge u_dut.ddr4_ui_clk) begin
        if (u_dut.axi_awvalid && u_dut.axi_awready)
            $display("[AXI128 AW @%0t] addr=%08h len=%0d", $time, u_dut.axi_awaddr, u_dut.axi_awlen);
        if (u_dut.axi_wvalid && u_dut.axi_wready)
            $display("[AXI128 W  @%0t] w0=%08h strb=%04h last=%0d", $time, u_dut.axi_wdata[31:0], u_dut.axi_wstrb, u_dut.axi_wlast);
        if (u_dut.axi_arvalid && u_dut.axi_arready)
            $display("[AXI128 AR @%0t] addr=%08h len=%0d", $time, u_dut.axi_araddr, u_dut.axi_arlen);
        if (u_dut.axi_rvalid && u_dut.axi_rready)
            $display("[AXI128 R  @%0t] w0=%08h last=%0d", $time, u_dut.axi_rdata[31:0], u_dut.axi_rlast);
        if (u_dut.u_ddr4_if.mig_awvalid && u_dut.u_ddr4_if.mig_awready)
            $display("[AXI512 AW @%0t] addr=%09h len=%0d", $time, u_dut.u_ddr4_if.mig_awaddr, u_dut.u_ddr4_if.mig_awlen);
        if (u_dut.u_ddr4_if.mig_wvalid && u_dut.u_ddr4_if.mig_wready)
            $display("[AXI512 W  @%0t] w0=%08h w4=%08h w8=%08h w12=%08h strb=%016h last=%0d", $time,
                     u_dut.u_ddr4_if.mig_wdata[31:0], u_dut.u_ddr4_if.mig_wdata[159:128],
                     u_dut.u_ddr4_if.mig_wdata[287:256], u_dut.u_ddr4_if.mig_wdata[415:384],
                     u_dut.u_ddr4_if.mig_wstrb, u_dut.u_ddr4_if.mig_wlast);
        if (u_dut.u_ddr4_if.mig_arvalid && u_dut.u_ddr4_if.mig_arready)
            $display("[AXI512 AR @%0t] addr=%09h len=%0d", $time, u_dut.u_ddr4_if.mig_araddr, u_dut.u_ddr4_if.mig_arlen);
        if (u_dut.u_ddr4_if.mig_rvalid && u_dut.u_ddr4_if.mig_rready)
            $display("[AXI512 R  @%0t] w0=%08h w4=%08h w8=%08h w12=%08h last=%0d", $time,
                     u_dut.u_ddr4_if.mig_rdata[31:0], u_dut.u_ddr4_if.mig_rdata[159:128],
                     u_dut.u_ddr4_if.mig_rdata[287:256], u_dut.u_ddr4_if.mig_rdata[415:384],
                     u_dut.u_ddr4_if.mig_rlast);
    end
`endif

    // ---- Test helpers -------------------------------------------------------------------------
    int errors = 0;
    task automatic check(input string name, input longint got, input longint exp);
        if (got !== exp) begin
            $display("FAIL: %s got=%0d exp=%0d", name, got, exp);
            errors++;
        end else
            $display("PASS: %s = %0d", name, got);
    endtask

    // Wait for a hierarchical level with a timeout in us (200 MHz polls)
    task automatic wait_level(input string what, ref logic sig, input int timeout_us, output bit ok);
        int t = 0;
        while (!sig && t < timeout_us * 200) begin
            @(posedge clk_200m); t++;
        end
        ok = sig;
        if (ok) $display("[%0t] %s", $time, what);
        else    $display("[%0t] TIMEOUT waiting for %s", $time, what);
    endtask

    // ---- Sequence -----------------------------------------------------------------------------
    logic [31:0] rd;
    bit ok;

    initial begin
        $display("=== TB_VU13P_MIG: real ddr4_0 (BFM) + Micron model, NUM_MACS=%0d TPP=%0d bank=%0d B ===",
                 NUM_MACS, TAPS_PER_PHASE, BANK_SIZE);
        build_boot_image();

        ext_rst_n = 0;
        #200ns en_model = 1'b1;
        repeat (100) @(posedge clk_200m);
        ext_rst_n = 1;

        // T1: MIG calibration
        $display("\n--- T1: MIG calibration ---");
        wait_level("init_calib_complete", u_dut.ddr4_init_calib_complete, 3000, ok);
        check("T1 calib complete", ok, 1);
        if (!ok) begin $display("TB_FAIL: no DDR4 — abort"); $finish; end
        repeat (200) @(posedge clk_200m);
        check("T1 led_debug[2] = calib", led_debug[2], 1);

        // T2: autonomous boot
        $display("\n--- T2: QSPI boot -> DDR4 ---");
        wait_level("boot_done", u_dut.boot_done, 20000, ok);
        check("T2 boot_done",      ok, 1);
        check("T2 boot_ok",        u_dut.boot_ok, 1);
        check("T2 crc_fail",       u_dut.boot_crc_fail, 0);
        check("T2 axi_fail",       u_dut.boot_axi_fail, 0);
        check("T2 record_count",   u_dut.boot_record_count, 2);
        check("T2 AXI write bursts", axi_wr_bursts, 1 + int'(BANK_SIZE) / 256);  // 64 B dir + 4 KB bank, 256 B/burst
        spi_read(7'h1A, rd);
        $display("[%0t] BOOT_STATUS 0x1A = %h", $time, rd);
        check("T2 0x1A boot_ok",   rd[2], 1);
        check("T2 0x1A boot_done", rd[1], 1);

        // T3: list commit -> directory load -> FIR bank
        $display("\n--- T3: filter list commit -> load by ID %h ---", FILT_ID);
        spi_write(7'h08, 24'h000001);                      // clear list
        spi_write(7'h09, {8'h00, FILT_ID});                // append
        spi_write(7'h08, 24'h000002);                      // commit -> select entry 0
        wait_level("bank_valid", u_dut.bank_valid, 5000, ok);
        check("T3 bank_valid",        ok, 1);
        repeat (400) @(posedge clk_200m);
        check("T3 coef writes",       total_coef_writes, NUM_MACS * COEF_DEPTH);
        check("T3 coef data errors",  coef_data_errors, 0);
        check("T3 coef_load_err",     u_dut.coef_load_err, 0);
        check("T3 AXI read bursts",   axi_rd_bursts > 0, 1);
        spi_read(7'h13, rd);
        $display("[%0t] COEF_STATUS 0x13 = %h", $time, rd);
        check("T3 0x13 bank_valid",   rd[12], 1);
        spi_read(7'h11, rd);
        check("T3 sticky[6] clear",   rd[6], 0);

        // T4: unknown ID
        $display("\n--- T4: FILTER_SELECT_ID %h (not in directory) ---", FILT_MISSING);
        spi_write(7'h17, {8'h00, FILT_MISSING});
        wait_level("coef_load_err", u_dut.coef_load_err, 5000, ok);
        check("T4 load_err",          ok, 1);
        repeat (2000) @(posedge clk_200m);                 // edge sync into SPI domain
        spi_read(7'h11, rd);
        check("T4 sticky[6]",         rd[6], 1);
        spi_read(7'h1C, rd);
        $display("[%0t] CMD_ERR_INFO 0x1C = %h", $time, rd);
        check("T4 reason NOTFOUND",   rd[3:0], 4'hA);
        check("T4 bank_valid held",   u_dut.bank_valid, 1);
        check("T4 no extra writes",   total_coef_writes, NUM_MACS * COEF_DEPTH);

        $display("\n========================================");
        if (errors == 0) $display("TB_PASS: tb_vu13p_mig all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $display("========================================");
        $finish;
    end

endmodule
