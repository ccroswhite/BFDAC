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

    logic spi_sclk = 0, spi_cs_n = 1, spi_mosi = 0;
    logic spi_miso;

    // DUT status inputs (benign defaults)
    logic mgr_busy = 0, bank_valid = 0, coef_load_done = 1, i2s_err = 0, switch_busy = 0;
    logic clk_locked = 1, ddr4_init_calib_complete = 1;
    logic line_mute_status = 0, hp_mute_status = 0;
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
    logic        filter_load_req, video_mode;
    logic        spi_unmute, fpga_irq_n;
    logic        level_switch_req, outsel_switch_req, outsel_target;
    logic [2:0]  level_target;
    logic bench_busy = 0;
    wire [1:0] cell_req;
    wire [1:0][7:0] cell_cfg;
    logic stream_busy=0, stream_clocks_ready=1, stream_fault=0;
    logic stream_audio_ready=1;
    wire [2:0] stream_request;
    wire stream_toggle, source_valid;
    wire [4:0] rx_trim;
    logic cal_commit_pending=0;
    logic calibration_valid=1;
    wire cal_wr_toggle, cal_commit_toggle;

    dac_ctrl_plane dut (
        .clk(clk), .ext_rst_n(ext_rst_n),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .level_switch_req(level_switch_req), .level_target(level_target),
        .outsel_switch_req(outsel_switch_req), .outsel_target(outsel_target),
        .mgr_busy(mgr_busy), .bank_valid(bank_valid), .coef_load_done(coef_load_done),
        .current_bank_id(current_bank_id), .i2s_err(i2s_err),
        .switch_busy(switch_busy), .clk_locked(clk_locked),
        .ddr4_init_calib_complete(ddr4_init_calib_complete),
        .line_mute_status(line_mute_status), .hp_mute_status(hp_mute_status),
        .flash_cmd_busy(flash_cmd_busy), .flash_cmd_err(flash_cmd_err),
        .boot_crc_fail(boot_crc_fail), .boot_axi_fail(boot_axi_fail),
        .coef_load_err(coef_load_err), .coef_load_err_code(coef_load_err_code),
        .sys_volume(sys_volume), .base_rate_sel(base_rate_sel),
        .clk_source_sel(clk_source_sel),
        .dpd_enable(dpd_enable),
        .coef_bank_id(coef_bank_id), .coef_load_start(coef_load_start),
        .filter_id(filter_id), .filter_next_id(filter_next_id),
        .filter_load_req(filter_load_req), .video_mode(video_mode),
        .spi_unmute(spi_unmute), .fpga_irq_n(fpga_irq_n),
        .bench_busy(bench_busy), .bench_status(32'h12345678), .bench_available(),
        .cell_test_cfg(cell_cfg), .cell_test_req(cell_req), .cell_test_ack(cell_req),
        .stream_rate_request(stream_request), .stream_rate_toggle(stream_toggle),
        .stream_source_valid(source_valid), .i2s_rx_trim(rx_trim),
        .stream_busy(stream_busy), .stream_clocks_ready(stream_clocks_ready),
        .stream_applied_rate(3'd5), .stream_fault(stream_fault),
        .stream_audio_ready(stream_audio_ready),
        .cal_commit_pending(cal_commit_pending),
        .cal_write_reject_toggle(1'b0),
        .calibration_valid(calibration_valid),
        .cal_wr_toggle(cal_wr_toggle),
        .cal_commit_toggle(cal_commit_toggle)
    );

    // Track filter_load_req pulses
    int load_req_count = 0;
    always @(posedge clk) if (filter_load_req) load_req_count++;

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

        // T5: video mode set + readback
        spi_write(7'h0B, 24'h000001);
        check("T5 video_mode", video_mode, 1);
        spi_read (7'h16, rd);
        check("T5 status w/ video", rd, {20'd0, 1'b1, 6'd3, 5'd0});

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

        spi_write(7'h04, 24'd1);
        check("unmute before local takeover", spi_unmute, 1);
        bench_busy = 1;
        repeat(10) @(negedge clk);
        check("local takeover latches mute", spi_unmute, 0);
        spi_write(7'h04, 24'd1);
        check("unmute blocked during local test", spi_unmute, 0);
        spi_write(7'h18, 24'h80);
        check("SPI cell config blocked during local test", cell_cfg[0], 0);
        spi_write(7'h03, 24'd1);
        check("rate change blocked during local test", base_rate_sel, 0);
        spi_read(7'h1f, rd);
        check("local status readback", rd, 32'h12345678);
        bench_busy = 0;
        repeat(10) @(negedge clk);
        check("no automatic unmute on local exit", spi_unmute, 0);
        spi_write(7'h04, 24'd1);
        check("explicit unmute after exit", spi_unmute, 1);

        for (int r=0; r<8; r++) begin
            spi_write(7'h1A, 24'(r));
            check("requested stream rate", stream_request, r);
            check("request clears unmute", spi_unmute, 0);
            check("request clears source ready", source_valid, 0);
        end
        spi_write(7'h1A, 24'd8);
        check("unsupported rate rejected", stream_request, 7);
        stream_busy=1;
        spi_write(7'h1A, 24'd0);
        check("busy rate request rejected", stream_request, 7);
        spi_write(7'h1B, 24'd1);
        check("source ready rejected while configuring", source_valid, 0);
        stream_busy=0;
        spi_write(7'h1B, 24'd1);
        check("source ready", source_valid, 1);
        spi_write(7'h1C, 24'd31);
        check("capture trim locked with active source", rx_trim, 8);
        spi_write(7'h1B, 24'd0);
        spi_write(7'h1C, 24'd31);
        check("capture trim while stopped", rx_trim, 31);
        stream_audio_ready=0;
        spi_write(7'h04, 24'd1);
        check("unmute blocked before first valid PCM frame", spi_unmute, 0);
        stream_audio_ready=1;
        spi_write(7'h04, 24'd1);
        check("unmute after clocks, bank and first valid frame", spi_unmute, 1);
        spi_write(7'h04, 24'd0);
        spi_read(7'h20, rd);
        check("applied stream rate status", rd[7:5], 5);
        check("requested stream rate status", rd[10:8], 7);
        check("capture trim status", rd[15:11], 31);
        check("valid PCM frame status", rd[16], 1);
        stream_fault=1;
        spi_write(7'h1B, 24'd1);
        check("fault blocks source-ready", source_valid, 0);
        begin
            logic [7:0] old_cell_cfg;
            old_cell_cfg = cell_cfg[0];
            switch_busy = 1;
            spi_write(7'h18, 24'h000080);
            check("cell test blocked while relay state is transitioning", cell_cfg[0], old_cell_cfg);
            switch_busy = 0;
            line_mute_status = 0;
            hp_mute_status = 0;
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
        spi_write(7'h1B, 24'd1);
        spi_write(7'h15, 24'd0);
        check("DPD mode cannot change with an active AP stream", dpd_enable, 1);
        spi_write(7'h1B, 24'd0);
        spi_write(7'h15, 24'd0);
        check("DPD disables while muted and source stopped", dpd_enable, 0);

        if (errors == 0) $display("TB_PASS: tb_dac_ctrl_plane all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $finish;
    end

endmodule
