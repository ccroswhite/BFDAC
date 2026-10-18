`timescale 1ns / 1ps

// =============================================================================
// tb_qspi_subsys — qspi_flash_ctrl + qspi_boot_loader chain:
//   T1: autonomous boot — two good records staged into the AXI memory model,
//       CRC pass, correct dest addresses/data, record_count = 2
//   T2: bad-CRC record — crc_fail asserted, boot_ok = 0 (separate reset run)
//   T3: ARM page program + read back (erase, program, read, verify 256 B)
//   T4: target select — Flash 0 ops assert sel_flash0
//   T5: carrier boot (2026-10-05, bom 18a) — chain on carrier chip 0 boots
//       with boot_src = 1; T1/T2 implicitly cover the fallback (empty carrier
//       -> SoM Flash 1, boot_src = 0)
//   T6: ARM program/read on carrier chip 1 (addr 0x1000_0000 -> cf_cs_sel 1,
//       device sees 0x0000_0000) at the 25 MHz carrier rate
// Flash model: mode-0 SPI slave, 4-byte-address command set (13/12/DC/06/05),
// one sparse memory keyed by {device, address}; device = sel_target for the
// SoM parts, 4 + cf_cs_sel for the carrier chips.
// =============================================================================
module tb_qspi_subsys;

    logic clk = 0, ui_clk = 0;
    always #2.5   clk    = ~clk;      // 200 MHz
    always #1.667 ui_clk = ~ui_clk;   // 300 MHz
    logic rst_n = 0, ui_rst = 1;

    // DUT wires
    logic [7:0]  cmd_opcode = '0, buf_wdata = '0, buf_waddr = '0, buf_raddr = '0, buf_rdata;
    logic [1:0]  cmd_target = '0;
    logic        cmd_trigger = 0, cmd_busy, buf_we = 0;
    logic [31:0] cmd_addr = '0;
    logic        rd_req, rd_target, rd_active, rd_byte_valid, rd_done, rd_stall;
    logic [31:0] rd_addr;
    logic [23:0] rd_len;
    logic [7:0]  rd_byte;
    logic        spi_sck, spi_cs_n, spi_mosi, sel_flash0, spi_miso;
    logic [1:0]  sel_target, cf_cs_sel;
    logic        start = 0, boot_done, boot_ok, crc_fail, axi_fail, format_fail, boot_src;
    logic [7:0]  record_count;

    logic [29:0] awaddr;
    logic [7:0]  awlen;
    logic [2:0]  awsize;
    logic [1:0]  awburst;
    logic        awvalid, awready;
    logic [127:0] wdata;
    logic [15:0]  wstrb;
    logic         wlast, wvalid, wready;
    logic [1:0]   bresp;
    logic         bvalid, bready;

    qspi_flash_ctrl u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cmd_opcode(cmd_opcode), .cmd_target(cmd_target), .cmd_addr(cmd_addr),
        .cmd_trigger(cmd_trigger), .cmd_busy(cmd_busy),
        .buf_wdata(buf_wdata), .buf_we(buf_we), .buf_waddr(buf_waddr),
        .buf_raddr(buf_raddr), .buf_rdata(buf_rdata),
        .rd_req(rd_req), .rd_target(rd_target), .rd_addr(rd_addr), .rd_len(rd_len),
        .rd_stall(rd_stall),
        .rd_active(rd_active), .rd_byte(rd_byte), .rd_byte_valid(rd_byte_valid),
        .rd_done(rd_done),
        .spi_sck(spi_sck), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .sel_target(sel_target), .sel_flash0(sel_flash0), .cf_cs_sel(cf_cs_sel),
        .spi_miso(spi_miso)
    );

    qspi_boot_loader u_loader (
        .clk(clk), .rst_n(rst_n), .start(start),
        .rd_req(rd_req), .rd_target(rd_target), .rd_addr(rd_addr), .rd_len(rd_len),
        .rd_stall(rd_stall),
        .rd_active(rd_active), .rd_byte(rd_byte), .rd_byte_valid(rd_byte_valid),
        .rd_done(rd_done),
        .boot_done(boot_done), .boot_ok(boot_ok), .crc_fail(crc_fail),
        .axi_fail(axi_fail), .format_fail(format_fail),
        .record_count(record_count), .boot_src(boot_src),
        .ui_clk(ui_clk), .ui_rst(ui_rst),
        .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize),
        .m_axi_awburst(awburst), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready)
    );

    // =========================================================================
    // Behavioral SPI flash model (mode 0, 4-byte addresses), device-indexed
    // =========================================================================
    localparam int DEV_SOM1 = 0, DEV_SOM0 = 1, DEV_CF0 = 4;   // carrier chip n = 4+n
    logic [7:0] flash_mem [longint unsigned];   // sparse, key = {dev, addr}
    int         f_dev;                          // device latched at CS fall

    function automatic longint unsigned mkey(input int dev, input logic [31:0] a);
        return (longint'(dev) << 32) | longint'(a);
    endfunction
    function automatic int cur_dev();
        return (sel_target == 2'd2) ? DEV_CF0 + int'(cf_cs_sel) : int'(sel_target);
    endfunction

    logic [7:0]  f_shift;
    int          f_bitcnt;
    logic [7:0]  f_opcode;
    logic [31:0] f_addr;
    int          f_phase;      // 0=opcode 1=addr 2=data
    int          f_addr_bytes;
    logic [7:0]  f_out_byte;
    int          f_out_bit;
    logic        f_wip = 0;
    logic [7:0]  f_status;

    assign f_status = {7'd0, f_wip};

    // MISO: present MSB-first output byte (updated on falling edge)
    logic miso_r = 0;
    assign spi_miso = miso_r;

    always @(negedge spi_cs_n) begin
        f_bitcnt = 0; f_phase = 0; f_out_bit = 7; f_dev = cur_dev();
    end

    always @(posedge spi_sck) begin
        if (!spi_cs_n) begin
            f_shift  = {f_shift[6:0], spi_mosi};
            f_bitcnt = f_bitcnt + 1;
            if (f_bitcnt % 8 == 0) begin
                case (f_phase)
                    0: begin
                        f_opcode = f_shift;
                        f_addr   = 0;
                        case (f_opcode)
                            8'h13, 8'h12, 8'hDC: begin f_phase = 1; f_addr_bytes = 4; end
                            8'h05:               begin f_phase = 2; end
                            8'h06:               ; // WREN — no payload
                            default:             f_phase = 2;
                        endcase
                    end
                    1: begin
                        f_addr = {f_addr[23:0], f_shift};
                        f_addr_bytes = f_addr_bytes - 1;
                        if (f_addr_bytes == 0) begin
                            f_phase = 2;
                            if (f_opcode == 8'hDC) begin
                                for (int unsigned i = 0; i < 65536; i++)
                                    flash_mem[mkey(f_dev, {f_addr[31:16], 16'h0} + i)] = 8'hFF;
                                f_wip = 1;
                                fork begin #2000; f_wip = 0; end join_none
                            end
                        end
                    end
                    2: begin
                        if (f_opcode == 8'h12) begin
                            flash_mem[mkey(f_dev, f_addr)] = f_shift;
                            f_addr = {f_addr[31:8], f_addr[7:0] + 8'd1}; // page wrap
                            f_wip  = 1;
                            fork begin #1000; f_wip = 0; end join_none
                        end
                    end
                endcase
            end
        end
    end

    // Output path: on falling SCK edge present next bit of the current byte
    always @(negedge spi_sck) begin
        if (!spi_cs_n && f_phase == 2 && f_opcode != 8'h12) begin
            if (f_out_bit == 7) begin
                if (f_opcode == 8'h05)      f_out_byte = f_status;
                else if (f_opcode == 8'h13) begin
                    f_out_byte = flash_mem.exists(mkey(f_dev, f_addr)) ? flash_mem[mkey(f_dev, f_addr)] : 8'hFF;
                    f_addr     = f_addr + 1;
                end else f_out_byte = 8'hFF;
            end
            miso_r    = f_out_byte[f_out_bit];
            f_out_bit = (f_out_bit == 0) ? 7 : f_out_bit - 1;
        end
    end

    // =========================================================================
    // AXI memory model (ui_clk)
    // =========================================================================
    logic [127:0] axi_mem [int unsigned];   // word-addressed (byte_addr/16)
    logic [29:0]  a_addr;
    int           a_beats;
    logic         a_active = 0;
    logic         stall_axi_w = 0;

    assign awready = !a_active;
    assign wready  = a_active && !stall_axi_w;

    always @(posedge ui_clk) begin
        bvalid <= bvalid && !bready ? bvalid : 1'b0;
        if (awvalid && awready) begin
            a_addr   <= awaddr;
            a_beats  <= awlen + 1;
            a_active <= 1;
        end
        if (wvalid && wready && a_active) begin
            axi_mem[a_addr >> 4] = wdata;   // blocking: xsim assoc-array limit
            a_addr  <= a_addr + 30'd16;
            a_beats <= a_beats - 1;
            if (wlast) begin
                a_active <= 0;
                bresp    <= 2'b00;
                bvalid   <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Record image builder
    // =========================================================================
    function automatic logic [31:0] crc32_calc(input int dev, input int base, input int len);
        logic [31:0] c = 32'hFFFFFFFF;
        for (int i = 0; i < len; i++) begin
            c = c ^ {24'd0, flash_mem[mkey(dev, base + i)]};
            for (int b = 0; b < 8; b++)
                c = c[0] ? (c >> 1) ^ 32'hEDB88320 : (c >> 1);
        end
        return c ^ 32'hFFFFFFFF;
    endfunction

    task automatic put32(input int dev, input int addr, input logic [31:0] v);
        flash_mem[mkey(dev, addr)]   = v[7:0];
        flash_mem[mkey(dev, addr+1)] = v[15:8];
        flash_mem[mkey(dev, addr+2)] = v[23:16];
        flash_mem[mkey(dev, addr+3)] = v[31:24];
    endtask

    // Builds a record on device 'dev' at flash offset 'fofs' -> DDR4 'dest'
    task automatic build_record(input int dev, input int fofs, input logic [31:0] dest,
                                input int len, input bit corrupt);
        logic [31:0] c;
        for (int i = 0; i < len; i++)
            flash_mem[mkey(dev, fofs + 16 + i)] = 8'((fofs >> 4) + i * 7 + 3);
        c = crc32_calc(dev, fofs + 16, len);
        if (corrupt) c = c ^ 32'h1;
        put32(dev, fofs,      32'h42464443);
        put32(dev, fofs + 4,  dest);
        put32(dev, fofs + 8,  len);
        put32(dev, fofs + 12, c);
    endtask

    int errors = 0;

    task automatic reset_all;
        rst_n = 0; ui_rst = 1; start = 0;
        stall_axi_w = 0;
        flash_mem.delete(); axi_mem.delete();
        repeat (10) @(posedge clk);
        rst_n = 1; ui_rst = 0;
        repeat (10) @(posedge clk);
    endtask

    task automatic wait_boot(input int timeout_us);
        int t = 0;
        start = 1;
        while (!boot_done && t < timeout_us * 200) begin
            @(posedge clk); t++;
        end
        if (!boot_done) begin
            $display("FAIL: boot timeout");
            errors++;
        end
    endtask

    task automatic check_word(input logic [31:0] dest, input int widx, input int fofs);
        logic [127:0] exp;
        for (int b = 0; b < 16; b++)
            exp[b*8 +: 8] = 8'((fofs >> 4) + (widx*16 + b) * 7 + 3);
        if (!axi_mem.exists((dest >> 4) + widx) ||
            axi_mem[(dest >> 4) + widx] !== exp) begin
            if (errors < 5)
                $display("FAIL: DDR4 word %0d @dest %h mismatch", widx, dest);
            errors++;
        end
    endtask

    task automatic test_fifo_backpressure;
        int t;
        $display("--- T7: QSPI stream pauses with an AXI-stalled 16-word FIFO ---");
        reset_all();
        build_record(DEV_SOM1, 0, 32'h0000_1000, 2048, 0);
        stall_axi_w = 1;
        start = 1;
        t = 0;
        while (!rd_stall && t < 100_000) begin
            @(posedge clk);
            t++;
        end
        if (!rd_stall) begin
            $display("FAIL T7: rd_stall did not assert before FIFO filled");
            errors++;
        end else begin
            repeat (20) @(posedge clk);
            if (spi_sck !== 1'b0 || !rd_stall || u_loader.fifo_full) begin
                $display("FAIL T7: stalled bus did not hold safely (sck=%b stall=%b full=%b)",
                         spi_sck,rd_stall,u_loader.fifo_full);
                errors++;
            end
        end
        stall_axi_w = 0;
        wait_boot(2000);
        if (!(boot_ok && !crc_fail && !axi_fail && record_count == 1)) begin
            $display("FAIL T7: boot did not recover after AXI backpressure");
            errors++;
        end
        for (int w = 0; w < 128; w++) check_word(32'h0000_1000,w,0);
        $display("T7 QSPI FIFO backpressure: %s", errors ? "FAIL" : "PASS");
    endtask

    task automatic test_bad_record_header(input logic [31:0] dest,
                                          input int len,
                                          input string label);
        reset_all();
        build_record(DEV_SOM1,0,dest,len,0);
        wait_boot(2000);
        if (!(boot_done && format_fail && !boot_ok && !crc_fail && !axi_fail &&
              record_count == 0 && axi_mem.num() == 0)) begin
            $display("FAIL T8 %s: done=%b format=%b ok=%b records=%0d",
                     label,boot_done,format_fail,boot_ok,record_count);
            errors++;
        end
    endtask

    initial begin
        // --- T1: two good records on SoM Flash 1 (carrier empty -> fallback) --
        reset_all();
        build_record(DEV_SOM1, 0,   32'h0000_1000, 256, 0);  // rec A: 256 B
        build_record(DEV_SOM1, 272, 32'h0002_0000, 64,  0);  // rec B: 64 B (272 = 16+256)
        wait_boot(2000);
        if (!(boot_ok && !crc_fail && !axi_fail && record_count == 2 && boot_src == 1'b0)) begin
            $display("FAIL T1: ok=%b crc=%b axi=%b cnt=%0d src=%b",
                     boot_ok, crc_fail, axi_fail, record_count, boot_src);
            errors++;
        end
        for (int w = 0; w < 16; w++) check_word(32'h0000_1000, w, 0);
        for (int w = 0; w < 4;  w++) check_word(32'h0002_0000, w, 272);
        $display("T1 autonomous boot (2 records): %s", errors ? "FAIL" : "PASS");

        // --- T2: bad CRC ----------------------------------------------------
        reset_all();
        build_record(DEV_SOM1, 0, 32'h0000_1000, 64, 1);     // corrupted
        wait_boot(2000);
        if (!(boot_done && crc_fail && !boot_ok)) begin
            $display("FAIL T2: done=%b crc=%b ok=%b", boot_done, crc_fail, boot_ok);
            errors++;
        end
        $display("T2 bad-CRC record: %s", errors ? "FAIL" : "PASS");

        // --- T3: ARM erase + program + read back ----------------------------
        reset_all();                                     // no records: boot ends fast
        wait_boot(2000);
        // erase sector 1
        @(posedge clk); cmd_addr <= 32'h0001_0000; cmd_opcode <= 8'h01;
        cmd_target <= 0; cmd_trigger <= 1; @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy); wait (!cmd_busy);
        // fill page buffer, program at 0x0001_0000
        for (int i = 0; i < 256; i++) begin
            @(posedge clk); buf_waddr <= 8'(i); buf_wdata <= 8'(i ^ 8'h5A); buf_we <= 1;
        end
        @(posedge clk); buf_we <= 0;
        @(posedge clk); cmd_opcode <= 8'h02; cmd_trigger <= 1;
        @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy); wait (!cmd_busy);
        // read back
        @(posedge clk); cmd_opcode <= 8'h03; cmd_trigger <= 1;
        @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy); wait (!cmd_busy);
        for (int i = 0; i < 256; i++) begin
            @(posedge clk); buf_raddr <= 8'(i);
            repeat (2) @(posedge clk);
            if (buf_rdata !== 8'(i ^ 8'h5A)) begin
                if (errors < 5) $display("FAIL T3: byte %0d = %h", i, buf_rdata);
                errors++;
            end
        end
        $display("T3 ARM erase/program/read: %s", errors ? "FAIL" : "PASS");

        // --- T4: Flash 0 target select --------------------------------------
        @(posedge clk); cmd_target <= 1; cmd_opcode <= 8'h03;
        cmd_addr <= 32'h0; cmd_trigger <= 1; @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy);
        repeat (10) @(posedge clk);
        if (sel_flash0 !== 1'b1) begin
            $display("FAIL T4: sel_flash0 not asserted for target 1");
            errors++;
        end
        wait (!cmd_busy);

        // --- T5: boot from the carrier flash (chip 0) -----------------------
        reset_all();
        build_record(DEV_CF0, 0,   32'h0000_3000, 128, 0);
        build_record(DEV_CF0, 144, 32'h0004_0000, 32,  0);   // 144 = 16+128
        wait_boot(4000);                                     // 25 MHz carrier rate
        if (!(boot_ok && !crc_fail && !axi_fail && record_count == 2 && boot_src == 1'b1)) begin
            $display("FAIL T5: ok=%b crc=%b axi=%b cnt=%0d src=%b",
                     boot_ok, crc_fail, axi_fail, record_count, boot_src);
            errors++;
        end
        for (int w = 0; w < 8; w++) check_word(32'h0000_3000, w, 0);
        for (int w = 0; w < 2; w++) check_word(32'h0004_0000, w, 144);
        $display("T5 carrier boot (2 records, boot_src=1): %s", errors ? "FAIL" : "PASS");

        // --- T6: ARM erase/program/read on carrier chip 1 -------------------
        // addr[29:28] = 1 selects chip 1; the device must see 0x0000_0000.
        @(posedge clk); cmd_addr <= 32'h1000_0000; cmd_opcode <= 8'h01;
        cmd_target <= 2'd2; cmd_trigger <= 1; @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy);
        repeat (10) @(posedge clk);
        if (sel_target !== 2'd2 || cf_cs_sel !== 2'd1) begin
            $display("FAIL T6: sel_target=%0d cf_cs_sel=%0d", sel_target, cf_cs_sel);
            errors++;
        end
        wait (!cmd_busy);
        for (int i = 0; i < 256; i++) begin
            @(posedge clk); buf_waddr <= 8'(i); buf_wdata <= 8'(i ^ 8'hC3); buf_we <= 1;
        end
        @(posedge clk); buf_we <= 0;
        @(posedge clk); cmd_opcode <= 8'h02; cmd_trigger <= 1;
        @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy); wait (!cmd_busy);
        // the model must hold the page under device address 0 on chip 1
        if (!flash_mem.exists(mkey(DEV_CF0 + 1, 32'h0)) ||
            flash_mem[mkey(DEV_CF0 + 1, 32'h0)] !== 8'hC3) begin
            $display("FAIL T6: page not at chip1/addr0 (28-bit address masking)");
            errors++;
        end
        @(posedge clk); cmd_opcode <= 8'h03; cmd_trigger <= 1;
        @(posedge clk); cmd_trigger <= 0;
        wait (cmd_busy); wait (!cmd_busy);
        for (int i = 0; i < 256; i++) begin
            @(posedge clk); buf_raddr <= 8'(i);
            repeat (2) @(posedge clk);
            if (buf_rdata !== 8'(i ^ 8'hC3)) begin
                if (errors < 5) $display("FAIL T6: byte %0d = %h", i, buf_rdata);
                errors++;
            end
        end
        $display("T6 carrier chip-1 ARM erase/program/read: %s", errors ? "FAIL" : "PASS");

        // --- T7: a long payload under sustained DDR backpressure ------------
        test_fifo_backpressure();

        // --- T8: reject addresses/lengths that cannot be staged by this AXI --
        $display("--- T8: reject unsupported record address/length geometry ---");
        test_bad_record_header(32'h4000_1000,64,"dest above 1 GiB");
        test_bad_record_header(32'h3FFF_FFE0,64,"range crosses 1 GiB");
        test_bad_record_header(32'h0000_1001,64,"unaligned destination");
        test_bad_record_header(32'h0000_1000,65,"unaligned payload length");

        if (errors == 0) $display("ALL TESTS PASS (tb_qspi_subsys)");
        else             $display("TESTS FAILED: %0d errors (tb_qspi_subsys)", errors);
        $finish;
    end

endmodule
