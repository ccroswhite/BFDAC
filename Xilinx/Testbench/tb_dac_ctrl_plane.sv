`timescale 1ns / 1ps

// Testbench: dac_ctrl_plane filter-list SPI registers (0x08-0x0B, 0x16/0x17)
// Drives real 40-bit CRC-8 SPI frames through spi_slave.
// Flow (no project):
//   xvlog -sv ..\Xilinx\spi_slave.sv ..\Xilinx\dac_ctrl_plane.sv ..\Xilinx\Testbench\tb_dac_ctrl_plane.sv
//   xelab tb_dac_ctrl_plane -s tb_ctrl
//   xsim tb_ctrl -runall

module tb_dac_ctrl_plane;

    logic clk = 0;
    logic ext_rst_n = 0;
    always #2.5 clk = ~clk;   // 200 MHz

    // Dual SPI ports: existing spi_* tasks drive the AP (full-access) port;
    // xmos_* tasks drive the XMOS (restricted) port.
    logic spi_sclk = 0, spi_cs_n = 1, spi_mosi = 0;
    logic spi_miso;
    logic xmos_sclk = 0, xmos_cs_n = 1, xmos_mosi = 0;
    logic xmos_miso;
    wire  spi_ap_irq_n;

    // DUT status inputs (benign defaults)
    logic mgr_busy = 0, bank_valid = 0, coef_load_done = 1, i2s_err = 0, switch_busy = 0;
    logic clk_locked = 1, ddr4_init_calib_complete = 1;
    logic line_mute_status = 0;
    logic [3:0] current_bank_id = 4'h0;
    logic flash_cmd_busy = 0, flash_cmd_err = 0, boot_crc_fail = 0, boot_axi_fail = 0;
    logic coef_load_err = 0;
    logic [2:0] coef_load_err_code = 3'd0;

    // DUT outputs
    logic [31:0] sys_volume;
    logic        dpd_enable;
    logic        base_rate_sel, clk_source_sel;
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;
    logic [15:0] filter_id, filter_next_id;
    logic        filter_load_req;
    logic        fpga_irq_n;
    logic        level_switch_req;
    logic [2:0]  level_target;
    logic bench_busy = 0;
    wire [1:0] cell_req;
    wire [1:0][7:0] cell_cfg;
    logic stream_busy=0, stream_clocks_ready=1, stream_fault=0;
    logic stream_audio_ready=1;
    wire [2:0] stream_request;
    wire stream_toggle, source_valid;
    // Model the stream_rate_controller FSM: applied rate follows each accepted
    // request one cycle after the toggle (real FSM applies through mute+relock).
    logic [2:0] applied_rate = 3'd0;
    logic tog_prev = 1'b0;
    always @(posedge clk) begin
        tog_prev <= stream_toggle;
        if (stream_toggle !== tog_prev) applied_rate <= stream_request;
    end
    wire [4:0] rx_trim;
    wire       src_sel, valid_sel, svalid2;
    logic cal_commit_pending=0;
    logic calibration_valid=1;
    wire cal_wr_toggle, cal_commit_toggle;

    dac_ctrl_plane dut (
        .clk(clk), .ext_rst_n(ext_rst_n),
        .spi_xmos_sclk(xmos_sclk), .spi_xmos_cs_n(xmos_cs_n),
        .spi_xmos_mosi(xmos_mosi), .spi_xmos_miso(xmos_miso),
        .spi_ap_sclk(spi_sclk), .spi_ap_cs_n(spi_cs_n),
        .spi_ap_mosi(spi_mosi), .spi_ap_miso(spi_miso),
        .spi_ap_irq_n(spi_ap_irq_n),
        .level_switch_req(level_switch_req), .level_target(level_target),
        .mgr_busy(mgr_busy), .bank_valid(bank_valid), .coef_load_done(coef_load_done),
        .current_bank_id(current_bank_id), .i2s_err(i2s_err),
        .switch_busy(switch_busy), .clk_locked(clk_locked),
        .ddr4_init_calib_complete(ddr4_init_calib_complete),
        .line_mute_status(line_mute_status),
        .flash_cmd_busy(flash_cmd_busy), .flash_cmd_err(flash_cmd_err),
        .boot_crc_fail(boot_crc_fail), .boot_axi_fail(boot_axi_fail),
        .coef_load_err(coef_load_err), .coef_load_err_code(coef_load_err_code),
        .sys_volume(sys_volume), .base_rate_sel(base_rate_sel),
        .clk_source_sel(clk_source_sel),
        .dpd_enable(dpd_enable),
        .coef_bank_id(coef_bank_id), .coef_load_start(coef_load_start),
        .filter_id(filter_id), .filter_next_id(filter_next_id),
        .filter_load_req(filter_load_req),
        .fpga_irq_n(fpga_irq_n),
        .bench_busy(bench_busy), .bench_status(32'h12345678), .bench_available(),
        .cell_test_cfg(cell_cfg), .cell_test_req(cell_req), .cell_test_ack(cell_req),
        .stream_rate_request(stream_request), .stream_rate_toggle(stream_toggle),
        .stream_source_valid(source_valid), .i2s_rx_trim(rx_trim),
        .stream_source_valid2(svalid2), .i2s_src_sel(src_sel), .stream_valid_sel(valid_sel),
        .stream_busy(stream_busy), .stream_clocks_ready(stream_clocks_ready),
        .stream_applied_rate(applied_rate), .stream_fault(stream_fault),
        .dpd_deadline_miss(1'b0),
        .stream_audio_ready(stream_audio_ready),
        .cal_commit_pending(cal_commit_pending),
        .cal_write_reject_toggle(1'b0),
        .calibration_valid(calibration_valid),
        .cal_wr_toggle(cal_wr_toggle),
        .cal_commit_toggle(cal_commit_toggle)
    );

    // Track filter_load_req pulses
    // filter_load_req is a toggle now (one flip per request, 2026-11-22) —
    // count flips, not level-high cycles. Gated on ext_rst_n so the
    // X->0 init transition can't count as phantom requests.
    int  load_req_count = 0;
    logic filter_load_req_d = 0;
    always @(posedge clk) begin
        if (ext_rst_n) begin
            filter_load_req_d <= filter_load_req;
            if (filter_load_req !== filter_load_req_d) load_req_count++;
        end
    end

    int errors = 0;

    function automatic [7:0] crc8_32(input [31:0] data);
        logic [7:0] crc = 8'h00;
        for (int i = 31; i >= 0; i--) begin
            if ((data[i] ^ crc[7]) == 1'b1) crc = {crc[6:0], 1'b0} ^ 8'h07;
            else                            crc = {crc[6:0], 1'b0};
        end
        return crc;
    endfunction

    // One 40-bit SPI frame (mode 0, ~10 MHz), captures MISO
    task automatic spi_frame(input [31:0] payload, output [31:0] miso_data);
        logic [39:0] tx;
        logic [39:0] rx;
        tx = {payload, crc8_32(payload)};
        rx = '0;
        spi_cs_n = 0;
        #100;
        for (int i = 39; i >= 0; i--) begin
            spi_mosi = tx[i];
            #50 spi_sclk = 1;   // rising edge: DUT samples
            rx = {rx[38:0], spi_miso};
            if (i == 0) begin
                #1 spi_cs_n = 1; // exercise CS rising before the final SCLK fall
                #49 spi_sclk = 0;
            end else begin
                #50 spi_sclk = 0;   // falling edge: DUT shifts out
            end
        end
        #200;                    // allow cs_n_rise processing
        miso_data = rx[39:8];
    endtask

    task automatic spi_write(input [6:0] addr, input [23:0] data);
        logic [31:0] dc;
        spi_frame({1'b0, addr, data}, dc);
    endtask

    // Read = address frame, then dummy frame carries the readback
    task automatic spi_read(input [6:0] addr, output [31:0] data);
        logic [31:0] dc;
        spi_frame({1'b1, addr, 24'd0}, dc);
        spi_frame({1'b1, addr, 24'd0}, data);
    endtask

    // XMOS-port frame driver (identical timing, xmos_* signals)
    task automatic xmos_frame(input [31:0] payload, output [31:0] miso_data);
        logic [39:0] tx;
        logic [39:0] rx;
        tx = {payload, crc8_32(payload)};
        rx = '0;
        xmos_cs_n = 0;
        #100;
        for (int i = 39; i >= 0; i--) begin
            xmos_mosi = tx[i];
            #50 xmos_sclk = 1;
            rx = {rx[38:0], xmos_miso};
            if (i == 0) begin
                #1 xmos_cs_n = 1;
                #49 xmos_sclk = 0;
            end else begin
                #50 xmos_sclk = 0;
            end
        end
        #200;
        miso_data = rx[39:8];
    endtask

    // XMOS frame with a corrupted CRC — exercises the SPI_CRC sticky path
    task automatic xmos_frame_badcrc(input [31:0] payload, output [31:0] miso_data);
        logic [39:0] tx;
        logic [39:0] rx;
        tx = {payload, crc8_32(payload) ^ 8'hA5};
        rx = '0;
        xmos_cs_n = 0;
        #100;
        for (int i = 39; i >= 0; i--) begin
            xmos_mosi = tx[i];
            #50 xmos_sclk = 1;
            rx = {rx[38:0], xmos_miso};
            if (i == 0) begin
                #1 xmos_cs_n = 1;
                #49 xmos_sclk = 0;
            end else begin
                #50 xmos_sclk = 0;
            end
        end
        #200;
        miso_data = rx[39:8];
    endtask

    task automatic xmos_write(input [6:0] addr, input [23:0] data);
        logic [31:0] dc;
        xmos_frame({1'b0, addr, data}, dc);
    endtask

    task automatic xmos_read(input [6:0] addr, output [31:0] data);
        logic [31:0] dc;
        xmos_frame({1'b1, addr, 24'd0}, dc);
        xmos_frame({1'b1, addr, 24'd0}, data);
    endtask

    task automatic check(input string name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL: %s got=0x%08h exp=0x%08h", name, got, exp);
            errors++;
        end else
            $display("PASS: %s = 0x%08h", name, got);
    endtask

    logic [31:0] rd;

    initial begin
        repeat (10) @(posedge clk);
        ext_rst_n = 1;
        repeat (10) @(posedge clk);

        spi_write(7'h01, 24'h000000);
        check("volume silence maps to zero code gain", sys_volume, 0);
        spi_write(7'h01, 24'h800000);
        check("half-scale volume maps to 14 code units", sys_volume, 32'h000E0000);
        spi_write(7'h01, 24'hFFFFFF);
        check("full-scale volume maps to 28 code units", sys_volume, 32'h001C0000);

        // T1: empty-list select must not fire a load
        spi_write(7'h0A, 24'h010000);   // advance on empty list
        check("T1 no load on empty list", load_req_count, 0);

        // T2: clear, append 3, verify status
        spi_write(7'h08, 24'h000001);
        spi_write(7'h09, 24'h000101);
        spi_write(7'h09, 24'h000202);
        spi_write(7'h09, 24'h000303);
        spi_read (7'h16, rd);
        check("T2 list status", rd, {20'd0, 1'b0, 6'd3, 5'd0});

        // T3: explicit select index 1
        spi_write(7'h0A, 24'h000001);
        check("T3 filter_id", filter_id, 32'h0202);
        check("T3 load pulses", load_req_count, 1);
        spi_read (7'h17, rd);
        check("T3 ids (next=0303 cur=0202)", rd, {16'h0303, 16'h0202});

        // T4: advance -> index 2, then advance wraps -> index 0
        spi_write(7'h0A, 24'h010000);
        check("T4 advance filter_id", filter_id, 32'h0303);
        spi_read (7'h17, rd);
        check("T4 ids (next wraps to 0101)", rd, {16'h0101, 16'h0303});
        spi_write(7'h0A, 24'h010000);
        check("T4 wrap filter_id", filter_id, 32'h0101);
        check("T4 load pulses", load_req_count, 3);

        // T5: filter-list status readback (was video_mode set + readback;
        //     DAC_MODE 0x0B retired 2026-11-15 — bit11 is now reserved 0)
        spi_read (7'h16, rd);
        check("T5 status (video bit reserved)", rd, {21'd0, 6'd3, 5'd0});

        // T6: out-of-range explicit index clamps to 0
        spi_write(7'h0A, 24'h00001F);
        check("T6 clamped filter_id", filter_id, 32'h0101);

        // T7: fill to 32 entries, 33rd append ignored
        spi_write(7'h08, 24'h000001);
        for (int k = 0; k < 33; k++)
            spi_write(7'h09, 24'h001000 + k[15:0]);
        spi_read (7'h16, rd);
        check("T7 list capped at 32", rd[10:5], 6'd32);
        check("T7 index reset by clear", rd[4:0], 5'd0);
        // random access across the full list (any filter, any time)
        spi_write(7'h0A, 24'h000010);      // select 16
        check("T7 idx16 id", filter_id, 32'h1010);
        spi_write(7'h0A, 24'h000002);      // select 2
        check("T7 idx2 id", filter_id, 32'h1002);
        spi_write(7'h0A, 24'h00001D);      // select 29
        check("T7 idx29 id", filter_id, 32'h101D);
        // advance from 31 wraps to 0 at full length
        spi_write(7'h0A, 24'h00001F);      // select 31
        check("T7 idx31 id", filter_id, 32'h101F);
        spi_write(7'h0A, 24'h010000);      // advance -> wrap
        check("T7 full-list wrap id", filter_id, 32'h1000);
        spi_read (7'h17, rd);
        check("T7 ids (next=1001 cur=1000)", rd, {16'h1001, 16'h1000});

        // T8: FILTER_SELECT_ID (0x17) loads an arbitrary directory ID,
        //     leaves the list index untouched, fires exactly one load
        begin
            int n_before = load_req_count;
            spi_write(7'h17, 24'h00BEEF);
            check("T8 select-by-ID filter_id", filter_id, 32'hBEEF);
            check("T8 one load pulse", load_req_count, n_before + 1);
            spi_read (7'h16, rd);
            check("T8 cur_index unchanged", rd[4:0], 5'd0);
            spi_read (7'h17, rd);
            check("T8 ids (next=1001 cur=BEEF)", rd, {16'h1001, 16'hBEEF});
            // list advance still works afterwards from the retained index
            spi_write(7'h0A, 24'h010000);
            check("T8 advance after by-ID", filter_id, 32'h1001);
        end

        // T9: 33rd append was rejected -> sticky[6] + CMD_ERR_INFO {0x09, FILT_FULL}
        spi_read (7'h11, rd);
        check("T9 sticky[6] set by FILT_FULL", rd[6], 1'b1);
        spi_read (7'h1C, rd);
        check("T9 CMD_ERR_INFO", rd[10:0], {7'h09, 4'h4});
        spi_write(7'h16, 24'h0000FF);
        spi_read (7'h11, rd);
        check("T9 sticky cleared", rd[7:0], 8'h00);

        // T10: FILTER_LIST_CTRL [1] = commit -> selects entry 0 (boot default,
        //      ARM policy per TODO-16); rejected FILT_EMPTY on an empty list;
        //      [0]+[1] together = clear only. 0x13[12] mirrors bank_valid.
        begin
            int n_before;
            spi_write(7'h08, 24'h000001);              // clear
            n_before = load_req_count;
            spi_write(7'h08, 24'h000002);              // commit on empty list
            check("T10 no load on empty commit", load_req_count, n_before);
            spi_read (7'h1C, rd);
            check("T10 CMD_ERR_INFO FILT_EMPTY", rd[10:0], {7'h08, 4'h5});
            spi_write(7'h16, 24'h0000FF);
            spi_write(7'h09, 24'h00A0A0);
            spi_write(7'h09, 24'h00B0B0);
            spi_write(7'h0A, 24'h000001);              // move index to 1
            check("T10 pre-commit id", filter_id, 32'hB0B0);
            n_before = load_req_count;
            spi_write(7'h08, 24'h000002);              // commit -> entry 0
            check("T10 commit id", filter_id, 32'hA0A0);
            check("T10 commit one load", load_req_count, n_before + 1);
            spi_read (7'h16, rd);
            check("T10 commit index 0", rd[4:0], 5'd0);
            n_before = load_req_count;
            spi_write(7'h08, 24'h000003);              // clear + commit = clear only
            check("T10 clear wins, no load", load_req_count, n_before);
            spi_read (7'h16, rd);
            check("T10 list cleared", rd[10:5], 6'd0);
            spi_read (7'h13, rd);
            check("T10 bank_valid=0 readback", rd[12], 1'b0);
            bank_valid = 1;
            repeat (4) @(posedge clk);
            spi_read (7'h13, rd);
            check("T10 bank_valid=1 readback", rd[12], 1'b1);
        end

        xmos_write(7'h1B, 24'd1);
        check("stream armed before local takeover", source_valid, 1);
        bench_busy = 1;
        repeat(10) @(negedge clk);
        check("local takeover disarms stream", source_valid, 0);
        xmos_write(7'h1B, 24'd1);
        check("stream arm blocked during local test", source_valid, 0);
        spi_write(7'h18, 24'h80);
        check("SPI cell config blocked during local test", cell_cfg[0], 0);
        xmos_write(7'h03, 24'd1);
        check("rate change blocked during local test", base_rate_sel, 0);
        spi_read(7'h1f, rd);
        check("local status readback", rd, 32'h12345678);
        bench_busy = 0;
        repeat(10) @(negedge clk);
        check("no automatic re-arm on local exit", source_valid, 0);
        xmos_write(7'h1B, 24'd1);
        check("explicit stream arm after exit", source_valid, 1);

        for (int r=0; r<8; r++) begin
            xmos_write(7'h1A, 24'(r));
            check("requested stream rate", stream_request, r);
            check("request clears source ready", source_valid, 0);
            check("request clears source ready", source_valid, 0);
        end
        xmos_write(7'h1A, 24'd8);
        check("unsupported rate rejected", stream_request, 7);
        stream_busy=1;
        xmos_write(7'h1A, 24'd0);
        check("busy rate request rejected", stream_request, 7);
        xmos_write(7'h1B, 24'h1D);        // arm, echo=7 == rate_req_src1
        check("source ready rejected while configuring", source_valid, 0);
        stream_busy=0;
        xmos_write(7'h1B, 24'h1D);        // arm, echo=7
        check("source ready", source_valid, 1);
        // 0x1C I2S_SRC (2026-11-20, AP-only): XMOS write -> BAD_ADDR
        xmos_write(7'h1C, 24'd31);
        check("capture trim unchanged (XMOS 0x1C denied)", rx_trim, 8);
        check("src_sel reset", src_sel, 0);
        // AP write: src_sel=1, svalid2=0, r2=0 (UNCHANGED from reset -> no
        // declare leg -> pure select, no re-rate), trims 10/12
        spi_write(7'h1C, 24'hC0A01);
        check("src_sel AP-set", src_sel, 1);
        check("capture trim -> src2 field", rx_trim, 12);
        xmos_write(7'h1B, 24'd0);
        // src_sel=0 while XMOS unarmed: NO re-rate (select != rate, 11-20 ruling);
        // r2 field=5 stored (deselected declare is inert)
        spi_write(7'h1C, 24'hC0A14);
        check("src_sel cleared", src_sel, 0);
        check("capture trim -> src1 field", rx_trim, 10);
        stream_audio_ready=0;
        xmos_write(7'h1B, 24'h1D);        // arm, echo=7 == rate_req_src1
        check("stream arm (0x1B) still works — frame-readiness gate moved to automute/top", source_valid, 1);
        stream_audio_ready=1;
        xmos_write(7'h1B, 24'd0);
        spi_read(7'h20, rd);
        check("applied stream rate status", rd[7:5], 7);
        check("requested stream rate status", rd[10:8], 7);
        check("capture trim status", rd[15:11], 10);
        check("src_sel status", rd[17], 0);
        check("svalid_ap status", rd[18], 0);
        check("rate_req_src2 status", rd[21:19], 5);
        // Select vs rate separation (2026-11-20 ruling): a bare select of an
        // UNARMED source never re-rates; the declared rate applies at ARM time.
        begin
            logic tog0;
            tog0 = stream_toggle;
            spi_write(7'h1C, 24'hC0A15);       // sel=1, svalid2=0, rate2=5 (!=applied 7)
            check("unarmed src2 select: no re-rate", stream_toggle, tog0);
            check("src_sel=1 stored", src_sel, 1);
            xmos_write(7'h1A, 24'd5);          // XMOS declares rate 5 while DESELECTED
            check("deselected declare stores only", stream_request, 7);
            check("deselected declare: no re-rate", stream_toggle, tog0);
            spi_write(7'h1C, 24'hC0A14);       // sel=0 while XMOS unarmed
            check("unarmed src1 select: no re-rate", stream_toggle, tog0);
            check("src_sel back to 0", src_sel, 0);
            xmos_write(7'h1B, 24'h15);         // arm, echo=5: req1(5)!=applied(7) -> apply
            check("arm applies declared rate (toggle)", stream_toggle, !tog0);
            check("arm consumed by triggered re-rate", source_valid, 0);
            check("applied request = src1 declared", stream_request, 5);
            // eager-declare leg: a CHANGED r2 while AP-selected is a fresh
            // declaration — fires symmetric to an XMOS RATE write (11-20 audit)
            tog0 = stream_toggle;
            spi_write(7'h1C, 24'hC0A15);       // sel=1, v2=0, r2=5 unchanged
            check("unchanged r2 select: no re-rate", stream_toggle, tog0);
            check("src_sel=1 for declare test", src_sel, 1);
            spi_write(7'h1C, 24'hC0A19);       // sel=1, v2=0, r2=6 (fresh declare)
            check("fresh AP declare applies", stream_toggle, !tog0);
            check("fresh AP declare request", stream_request, 6);
            // idempotence: same-rate rewrite invalidates but does NOT relock
            spi_write(7'h1C, 24'hC0A14);       // sel=0 unarmed -> no fire
            tog0 = stream_toggle;
            xmos_write(7'h1A, 24'd6);          // == applied 6 -> invalidate only
            check("same-rate XMOS rewrite: no relock", stream_toggle, tog0);
            xmos_write(7'h1A, 24'd7);          // != applied -> declare fires
            check("new-rate XMOS declare: relock", stream_toggle, !tog0);
            check("new-rate request", stream_request, 7);
        end
        check("valid PCM frame status", rd[16], 1);
        stream_fault=1;
        xmos_write(7'h1B, 24'h1D);        // arm, echo=7 (rejected UNSAFE anyway)
        check("fault blocks source-ready", source_valid, 0);
        begin
            logic [7:0] old_cell_cfg;
            old_cell_cfg = cell_cfg[0];
            switch_busy = 1;
            spi_write(7'h18, 24'h000080);
            check("cell test blocked while relay state is transitioning", cell_cfg[0], old_cell_cfg);
            switch_busy = 0;
            line_mute_status = 0;
            spi_write(7'h18, 24'h000080);
            check("cell test accepted while safely muted and settled", cell_cfg[0], 8'h80);
            spi_write(7'h18, 24'h000000);
            check("cell test disabled after diagnostic", cell_cfg[0], 8'h00);
        end
        begin
            logic old_wr_toggle, old_commit_toggle;
            old_wr_toggle = cal_wr_toggle;
            old_commit_toggle = cal_commit_toggle;
            cal_commit_pending = 1;
            spi_write(7'h0D, 24'h001234);
            check("calibration write blocked while pending", cal_wr_toggle, old_wr_toggle);
            spi_write(7'h0F, 24'd1);
            check("second calibration commit blocked", cal_commit_toggle, old_commit_toggle);
            spi_read(7'h1C, rd);
            check("pending calibration command reports busy", rd[3:0], 4'hC);
        end
        begin
            coef_load_err_code = 3'd4;
            #10;
            coef_load_err = 1;
            #20;
            spi_read(7'h1C, rd);
            check("AXI filter-read failure reported as detail", rd[11], 1);
            check("AXI filter-read failure reports data error", rd[3:0], 4'hB);
            coef_load_err = 0;
            #20;
        end
        cal_commit_pending=0;
        stream_fault=0;
        bank_valid=0;
        spi_write(7'h15, 24'd1);
        check("DPD enable rejected without a valid FIR bank", dpd_enable, 0);
        bank_valid=1;
        calibration_valid=0;
        spi_write(7'h15, 24'd1);
        check("DPD enable rejected before calibration commit", dpd_enable, 0);
        calibration_valid=1;
        spi_write(7'h15, 24'd1);
        check("DPD enable accepted only after calibration/filter setup", dpd_enable, 1);
        spi_read(7'h18, rd);
        check("calibration status valid bit", rd[11], 1);
        xmos_write(7'h1B, 24'h1D);        // arm, echo=7 == rate_req_src1
        spi_write(7'h15, 24'd0);
        check("DPD mode cannot change with an active AP stream", dpd_enable, 1);
        xmos_write(7'h1B, 24'd0);
        spi_write(7'h15, 24'd0);
        check("DPD disables while muted and source stopped", dpd_enable, 0);

        // ---- Dual-port SPI: XMOS restricted subset vs AP full access --------
        // T10: XMOS write to an AP-only register (FILTER_SELECT) must NOT
        //      execute — filter_id unchanged, sticky[5] BAD_ADDR flagged.
        begin
            logic [15:0] fid_before;
            fid_before = filter_id;
            spi_write(7'h16, 24'h0000FF);         // clear sticky via AP
            xmos_write(7'h0A, 24'h000001);        // XMOS tries filter select
            check("T10 denied write leaves filter_id", filter_id, fid_before);
            spi_read (7'h11, rd);
            check("T10 sticky[5] on denied write", rd[5], 1'b1);
            spi_read (7'h1C, rd);
            check("T10 CMD_ERR_INFO BAD_ADDR", rd[10:0], {7'h0A, 4'h1});
            spi_write(7'h16, 24'h0000FF);         // clean up
        end

        // T11: STREAM_VALID is XMOS-only (2026-11-15 ruling — the whole
        //      stream lifecycle is XMOS-owned; AP writes denied BAD_ADDR).
        begin
            xmos_write(7'h1B, 24'h00001D);  // arm, echo=7 == rate_req_src1
            check("T11 XMOS stream_valid write executes", source_valid, 1);
            spi_write (7'h1B, 24'h000000);          // AP write -> denied
            check("T11 AP stream_valid write denied", source_valid, 1);
            spi_read  (7'h1C, rd);
            check("T11 CMD_ERR_INFO BAD_ADDR", rd[10:0], {7'h1B, 4'h1});
            xmos_write(7'h1B, 24'h000000);          // restore via XMOS
            spi_write (7'h16, 24'h0000FF);          // clean up sticky
        end

        // T12: XMOS reads see the full register map (MAGIC readable on both).
        begin
            xmos_read(7'h10, rd);
            check("T12 XMOS reads MAGIC", rd, 32'hDAC02026);
            spi_read (7'h10, rd);
            check("T12 AP reads MAGIC",   rd, 32'hDAC02026);
        end

        // T13: last_wr_src — CTRL_STATE[6] = 1 after AP write, 0 after XMOS.
        begin
            spi_write (7'h01, 24'h000000);
            spi_read  (7'h12, rd);
            check("T13 last_wr_src=AP",   rd[6], 1'b1);
            xmos_write(7'h1B, 24'h000000);
            spi_read  (7'h12, rd);
            check("T13 last_wr_src=XMOS", rd[6], 1'b0);
        end

        // T14: STICKY_W1C is masked for XMOS (2026-11-15 ruling): it may
        //      clear its own bits {SPI_CRC[0], I2S_ERR[1], FRAME_LEN[4]} but
        //      never AP-domain bits or the CMD_ERR_INFO record. AP clears all.
        begin
            logic [31:0] dump;
            spi_write (7'h16, 24'h0000FF);          // AP clears everything
            // Set XMOS-owned bit0 (SPI_CRC on its bus) + AP-domain bit5
            // (BAD_ADDR from a denied XMOS write to AP-only VOLUME).
            xmos_frame_badcrc({1'b0, 7'h00, 24'h0}, dump);
            xmos_write(7'h01, 24'h000001);          // denied -> sticky[5]
            spi_read  (7'h11, rd);
            check("T14 sticky[0]+[5] set", {rd[5], rd[0]}, 2'b11);
            // XMOS writes 0xFF: only its own bits may clear.
            xmos_write(7'h16, 24'h0000FF);
            spi_read  (7'h11, rd);
            check("T14 XMOS W1C cleared bit0", rd[0], 1'b0);
            check("T14 XMOS W1C left bit5",    rd[5], 1'b1);
            spi_read  (7'h1C, rd);
            check("T14 CMD_ERR_INFO kept",   rd[10:0], {7'h01, 4'h1});
            // AP clears the rest.
            spi_write (7'h16, 24'h0000FF);
            spi_read  (7'h11, rd);
            check("T14 AP W1C clears all",   rd[7:0], 8'h00);
            spi_read  (7'h1C, rd);
            check("T14 AP clears ERR_INFO",  rd[10:0], 11'h0);
        end

        // ---- T15: STREAM_EVENT (0x21 W1C / 0x22 read) — stream-gate doorbells
        //      + arm-echo (2026-11-21 contract).  Layout: [0]preempt_xmos
        //      [1]preempt_ap [2]echo_mismatch [5:3]rate_req_src1 shadow.
        //      State in: sel=0, req1=7, applied=7, svalids=0.
        spi_write (7'h16, 24'h0000FF);          // AP clears sticky (IRQs deassert)
        spi_write (7'h21, 24'h000007);          // AP W1C clears all event flags
        spi_read  (7'h22, rd);
        check("T15 events cleared",        rd[2:0], 3'b000);
        check("T15 fpga_irq_n deasserted", fpga_irq_n,   1);
        check("T15 spi_ap_irq_n deasserted", spi_ap_irq_n, 1);

        // T15a: deselect doorbell — XMOS armed+selected, AP selects away.
        //       sel 0->1 closes the XMOS gate -> preempt_xmos + fpga_irq_n.
        xmos_write(7'h1B, 24'h1D);              // arm, echo=7 == req1
        check("T15a XMOS armed",       source_valid, 1);
        spi_write (7'h1C, 24'hC0A15);           // sel=1, r2=5 unchanged -> pure deselect
        spi_read  (7'h22, rd);
        check("T15a preempt_xmos set", rd[0], 1);
        check("T15a preempt_ap clear", rd[1], 0);
        check("T15a rate_req_src1 shadow", rd[5:3], 3'd7);
        check("T15a XMOS doorbell low", fpga_irq_n,   0);
        check("T15a AP doorbell quiet", spi_ap_irq_n, 1);
        // XMOS may clear ONLY its own domain {0,2} — bit1 mask test follows;
        // here only bit0 is set, so a full-mask write clears exactly it.
        xmos_write(7'h21, 24'h000007);
        spi_read  (7'h22, rd);
        check("T15a XMOS W1C cleared its flag", rd[0], 0);
        check("T15a XMOS doorbell released",    fpga_irq_n, 1);

        // T15b: reverse transition — select back to XMOS (1->0) sets
        //       preempt_ap + spi_ap_irq_n.  XMOS's svalid survived the
        //       deselect (same-rate session persists) so req1==applied
        //       means no apply — only the AP doorbell fires.
        spi_write (7'h1C, 24'hC0A14);           // sel=0, r2=5
        spi_read  (7'h22, rd);
        check("T15b preempt_ap set",   rd[1], 1);
        check("T15b AP doorbell low",  spi_ap_irq_n, 0);
        check("T15b XMOS doorbell quiet", fpga_irq_n, 1);
        spi_write (7'h21, 24'h000002);          // AP clears its bit
        spi_read  (7'h22, rd);
        check("T15b events cleared",   rd[2:0], 3'b000);
        check("T15b AP doorbell released", spi_ap_irq_n, 1);

        // T15c: any rate apply preempts BOTH sources (clock regime destroyed).
        //       Divergent XMOS 0x1A while selected: req1 7->3, applied->3.
        xmos_write(7'h1A, 24'd3);
        spi_read  (7'h22, rd);
        check("T15c apply preempts both", rd[1:0], 2'b11);
        check("T15c both doorbells low",  {spi_ap_irq_n, fpga_irq_n}, 2'b00);
        spi_write (7'h21, 24'h000007);          // clean up via AP

        // T15d: arm-echo — echo != rate_req_src1 refuses the arm + sets [2];
        //       matching echo arms normally.  req1==applied==3: plain arm.
        xmos_write(7'h1B, 24'h11);              // arm, echo=4 != req1=3
        check("T15d echo-mismatch refuses arm", source_valid, 0);
        spi_read  (7'h22, rd);
        check("T15d echo_mismatch flag", rd[2], 1);
        check("T15d XMOS doorbell low",  fpga_irq_n, 0);
        xmos_write(7'h21, 24'h000004);          // XMOS clears its echo flag
        spi_read  (7'h22, rd);
        check("T15d echo flag cleared",  rd[2], 0);
        xmos_write(7'h1B, 24'h0D);              // arm, echo=3 == req1
        check("T15d correct echo arms",  source_valid, 1);
        xmos_write(7'h1B, 24'h0);               // disarm — echo ignored

        // T15e: session-consumed preempt — svalid held through a fault
        //       auto-clear fires preempt for the source that was live.
        xmos_write(7'h1B, 24'h0D);              // arm again, echo=3
        check("T15e armed for fault test", source_valid, 1);
        stream_fault = 1;
        repeat(10) @(negedge clk);
        check("T15e fault consumed session", source_valid, 0);
        spi_read  (7'h22, rd);
        check("T15e preempt_xmos on fault", rd[0], 1);
        stream_fault = 0;
        spi_write (7'h21, 24'h000007);

        if (errors == 0) $display("TB_PASS: tb_dac_ctrl_plane all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $finish;
    end

endmodule
