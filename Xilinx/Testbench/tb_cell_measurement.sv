`timescale 1ns / 1ps
`include "spi_regs.svh"

module tb_cell_measurement;
    logic ctrl_clk = 0, dsp_clk = 0, cell_clk = 0;
    logic rst_n = 0, safe = 1;
    logic spi_sclk = 0, spi_cs_n = 1, spi_mosi = 0;
    wire spi_miso, unmute;
    wire [1:0][7:0] cfg;
    wire [1:0] req, ack;
    wire [63:0] out_l, out_r;
    logic [31:0] rd;
    logic [63:0] base, stepped;
    int pulses;
    logic button1 = 1, button2 = 1;
    wire manual_busy, manual_led, manual_req, manual_ack, manual_ready, manual_available;
    wire [10:0] manual_cmd;
    wire [31:0] manual_status;
    bench_test_controller #(.CLK_HZ(120), .DEBOUNCE_CYCLES(4), .SELECT_CYCLES(360), .CANCEL_CYCLES(240)) ui (
        .clk(ctrl_clk), .rst_n(rst_n), .select_n(button1), .step_n(button2),
        .available(manual_available), .ready(manual_ready), .healthy(safe), .rate_48(1'b1),
        .cmd_req(manual_req), .cmd_ack(manual_ack), .cmd(manual_cmd),
        .busy(manual_busy), .led(manual_led), .status(manual_status)
    );

    always #2.5 ctrl_clk = ~ctrl_clk;
    always #1.4 dsp_clk = ~dsp_clk;
    always #8.0 cell_clk = ~cell_clk;

    dac_ctrl_plane ctrl (
        .clk(ctrl_clk), .ext_rst_n(rst_n),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .line_mute_status(!safe), .hp_mute_status(1'b0), .switch_busy(1'b0),
        .clk_locked(1'b1), .ddr4_init_calib_complete(1'b1),
        .coef_load_err(1'b0), .coef_load_err_code(3'b0), .i2s_err(1'b0),
        .boot_crc_fail(1'b0), .boot_axi_fail(1'b0), .flash_cmd_err(1'b0),
        .spi_unmute(unmute), .cell_test_cfg(cfg), .cell_test_req(req), .cell_test_ack(ack),
        .bench_busy(manual_busy), .bench_available(manual_available), .bench_status(manual_status)
    );

    dac_dsp_core #(.NUM_MACS(4), .TAPS_PER_PHASE(16), .CELL_TEST_MUTE_CYCLES(4096)) core (
        .dsp_clk(dsp_clk), .cell_clk(cell_clk), .sys_rst_n(rst_n),
        .audio_l(24'd0), .audio_r(24'd0), .new_sample(1'b0), .force_zero(1'b1),
        .coef_we(1'b0), .coef_waddr(8'd0), .coef_wdata(18'd0), .coef_wmac(2'b0),
        .bank_select(1'b0), .bank_load_target(1'b0), .sys_volume(32'd0),
        .boot_envelope_gain(16'd0), .dpd_enable(1'b0), .dpd_cal_data('0),
        .cell_test_cfg(cfg), .cell_test_req(req), .cell_test_ack(ack), .cell_test_safe(safe),
        .bench_cmd(manual_cmd), .bench_req(manual_req), .bench_ack(manual_ack), .bench_ready(manual_ready),
        .cascode_l(out_l), .cascode_r(out_r)
    );

    function automatic [7:0] crc8(input [31:0] data);
        logic [7:0] c = 0;
        for (int i = 31; i >= 0; i--)
            c = {c[6:0], 1'b0} ^ ((data[i] ^ c[7]) ? 8'h07 : 8'h00);
        return c;
    endfunction

    function automatic [63:0] baseline(input int cell_index);
        logic [63:0] mask = 0;
        for (int i = 1; i <= 32; i++) mask[(cell_index + i) % 64] = 1;
        return mask;
    endfunction

    task automatic frame(input [31:0] payload, output [31:0] result);
        logic [39:0] tx, rx;
        tx = {payload, crc8(payload)};
        rx = 0;
        spi_cs_n = 0;
        #100;
        for (int i = 39; i >= 0; i--) begin
            spi_mosi = tx[i];
            #50 spi_sclk = 1;
            rx = {rx[38:0], spi_miso};
            #50 spi_sclk = 0;
        end
        #100 spi_cs_n = 1;
        #200;
        result = rx[39:8];
    endtask

    task automatic wr(input [6:0] addr, input [23:0] data);
        logic [31:0] discard;
        frame({1'b0, addr, data}, discard);
    endtask

    task automatic read_reg(input [6:0] addr, output [31:0] data);
        logic [31:0] discard;
        frame({1'b1, addr, 24'd0}, discard);
        frame({1'b0, 7'd0, 24'd0}, data);
    endtask

    task automatic check_patterns(input [63:0] expected_l, input [63:0] expected_r);
        int run_length, total_high;
        repeat (24) @(negedge cell_clk);
        while (out_l != 0 || out_r != 0) @(negedge cell_clk);
        run_length = 0;
        total_high = 0;
        for (int i = 0; i < 80; i++) begin
            @(negedge cell_clk);
            if (out_l != 0 || out_r != 0) begin
                if (out_l !== expected_l || out_r !== expected_r)
                    $fatal(1, "pattern mismatch L=%h R=%h expected L=%h R=%h", out_l, out_r, expected_l, expected_r);
                run_length++;
                total_high++;
            end else if (run_length != 0) begin
                if (run_length != 6) $fatal(1, "RTZ pulse width %0d, expected 6", run_length);
                run_length = 0;
            end
        end
        if (total_high != 60) $fatal(1, "RTZ high cycles %0d/80, expected 60", total_high);
        pulses++;
    endtask

    task automatic button_press(input bit step_button);
        if (step_button) button2 = 0; else button1 = 0;
        repeat(12) @(negedge ctrl_clk);
        if (step_button) button2 = 1; else button1 = 1;
        repeat(12) @(negedge ctrl_clk);
    endtask

    task automatic manual_hold(input int mode, input int ch, input int s);
        for (int n = 0; n < 10000 && ui.state != ui.HOLD; n++) @(negedge ctrl_clk);
        if (ui.state != ui.HOLD || manual_cmd !== {1'b1, 7'(s), 1'(ch), 2'(mode)} || unmute)
            $fatal(1, "manual integration state/mute %h", manual_cmd);
    endtask

    task automatic measure_dc(input int ch, input int s);
        real mean_l, mean_r, target;
        int frames;
        mean_l = 0; mean_r = 0; frames = 0;
        repeat(2048) @(negedge cell_clk);
        while (frames < 4096) begin
            @(posedge cell_clk); #0.1;
            if (core.cell_capture_en) begin
                mean_l += $countones(core.cell_cap_l);
                mean_r += $countones(core.cell_cap_r);
                frames++;
            end
        end
        mean_l /= frames; mean_r /= frames;
        case(s)
            0: target = 32.0;
            1: target = 33.0;
            2: target = 31.0;
            3: target = 36.0;
            4: target = 28.0;
        endcase
        if (mean_l < (ch ? 32.0 : target)-0.05 || mean_l > (ch ? 32.0 : target)+0.05 ||
            mean_r < (ch ? target : 32.0)-0.05 || mean_r > (ch ? target : 32.0)+0.05)
            $fatal(1, "manual DC through NS/DEM L=%f R=%f ch=%0d step=%0d",mean_l,mean_r,ch,s);
    endtask

    initial begin
        #100 rst_n = 1;
        wr(`SPI_W_UNMUTE, 24'd1);
        wr(`SPI_W_CELL_TEST_L, 24'h80);
        if (cfg !== 16'd0) $fatal(1, "diagnostics accepted while unmute requested");
        read_reg(`SPI_R_CMD_ERR_INFO, rd);
        if (rd[3:0] != `SPI_ERR_TEST_UNSAFE) $fatal(1, "missing unsafe-command error");
        wr(`SPI_W_UNMUTE, 24'd0);
        safe = 0;
        wr(`SPI_W_CELL_TEST_R, 24'hbf);
        if (cfg !== 16'd0) $fatal(1, "diagnostics accepted before relay release");
        safe = 1;
        wr(`SPI_W_CELL_TEST_L, 24'h80);
        if (req[0] === ack[0]) $fatal(1, "enable did not wait for safe-mute interval");
        if (out_l !== 0 || out_r !== 0) $fatal(1, "diagnostic output before relay release delay");
        wr(`SPI_W_CELL_TEST_L, 24'hff);
        if (cfg[0] !== 8'h80) $fatal(1, "pending command overwritten");
        read_reg(`SPI_R_CMD_ERR_INFO, rd);
        if (rd[3:0] != `SPI_ERR_TEST_BUSY) $fatal(1, "missing busy-command error");
        check_patterns(baseline(0), 64'hffffffff);
        wr(`SPI_W_CELL_TEST_L, 24'd0);

        for (int ch = 0; ch < 2; ch++) begin
            for (int idx = 0; idx < 64; idx++) begin
                base = baseline(idx);
                stepped = base | (64'h1 << idx);
                wr(ch == 0 ? `SPI_W_CELL_TEST_L : `SPI_W_CELL_TEST_R, 24'h80 | idx);
                check_patterns(ch == 0 ? base : 64'hffffffff, ch == 1 ? base : 64'hffffffff);
                wr(ch == 0 ? `SPI_W_CELL_TEST_L : `SPI_W_CELL_TEST_R, 24'hc0 | idx);
                check_patterns(ch == 0 ? stepped : 64'hffffffff, ch == 1 ? stepped : 64'hffffffff);
                if ((base ^ stepped) !== (64'h1 << idx)) $fatal(1, "test reference error");
            end
            wr(ch == 0 ? `SPI_W_CELL_TEST_L : `SPI_W_CELL_TEST_R, 24'd0);
        end

        wr(`SPI_W_CELL_TEST_L, 24'hc0);
        wr(`SPI_W_CELL_TEST_R, 24'hbf);
        check_patterns(baseline(0) | 64'h1, baseline(63));
        read_reg(`SPI_R_CELL_TEST_L, rd);
        if (rd !== 32'hc0) $fatal(1, "L readback %h", rd);
        read_reg(`SPI_R_CELL_TEST_R, rd);
        if (rd !== 32'hbf) $fatal(1, "R readback %h", rd);
        wr(`SPI_W_UNMUTE, 24'd1);
        if (unmute !== 0) $fatal(1, "unmuted during diagnostics");
        wr(`SPI_W_CELL_TEST_R, 24'h100);
        if (cfg[1] !== 8'hbf) $fatal(1, "accepted reserved bits");
        wr(`SPI_W_CELL_TEST_L, 24'd0);
        check_patterns(64'hffffffff, baseline(63));
        wr(`SPI_W_CELL_TEST_R, 24'd0);
        repeat (32) @(negedge cell_clk);
        if (out_l !== 0 || out_r !== 0) $fatal(1, "diagnostics did not exit without audio");
        force core.dem_valid_l = core.pace_tick;
        force core.dem_out_l = 64'h0123456789abcdef;
        force core.dem_out_r = 64'hfedcba9876543210;
        check_patterns(64'h0123456789abcdef, 64'hfedcba9876543210);
        release core.dem_valid_l;
        release core.dem_out_l;
        release core.dem_out_r;
        wr(`SPI_W_UNMUTE, 24'd1);
        if (unmute !== 1) $fatal(1, "normal unmute blocked after diagnostics");
        wr(`SPI_W_UNMUTE, 24'd0);
        wr(`SPI_W_CELL_TEST_L, 24'hff);
        #7 rst_n = 0;
        repeat (20) @(negedge cell_clk);
        if (cfg !== 0 || req !== 0 || ack !== 0 || out_l !== 0 || out_r !== 0)
            $fatal(1, "reset did not clear diagnostics");
        rst_n = 1;
        repeat (32) @(negedge cell_clk);
        if (out_l !== 0 || out_r !== 0) $fatal(1, "stale diagnostic replay after reset");
        wr(`SPI_W_UNMUTE, 24'd1);
        button_press(0); manual_hold(1,0,0);
        check_patterns(baseline(0), 64'hffffffff);
        button_press(1); manual_hold(1,0,1);
        check_patterns(baseline(0)|64'h1, 64'hffffffff);
        wr(`SPI_W_UNMUTE, 24'd1);
        if (unmute) $fatal(1, "SPI unmute bypassed manual interlock");
        button_press(0);
        for (int n=0; n<2000 && ui.state != ui.SELECTING; n++) @(negedge ctrl_clk);
        button_press(0); manual_hold(2,0,0);
        for (int ch=0; ch<2; ch++) begin
            for (int s=0; s<5; s++) begin
                if (ch != 0 || s != 0) button_press(1);
                manual_hold(2,ch,s); measure_dc(ch,s);
            end
        end
        button_press(1);
        repeat(1000) @(negedge ctrl_clk);
        if (manual_busy || manual_led || unmute) $fatal(1, "manual completion did not stay muted/dark");
        button_press(0); button_press(0); button_press(0); manual_hold(3,0,0);
        begin
            int lo=64, hi=0, frames=0;
            while(frames<8192) begin
                @(posedge cell_clk); #0.1;
                if(core.cell_capture_en) begin
                    if($countones(core.cell_cap_l)<lo) lo=$countones(core.cell_cap_l);
                    if($countones(core.cell_cap_l)>hi) hi=$countones(core.cell_cap_l);
                    frames++;
                end
            end
            if(lo>30 || hi<34) $fatal(1, "manual tone did not reach cascode outputs");
        end
        safe=0; repeat(1000) @(negedge ctrl_clk);
        if(manual_busy || manual_led || core.bench_active || unmute) $fatal(1, "manual fault did not abort");
        $display("TB_PASS: independent L/R cell measurement, %0d pattern windows; manual cell/DC/tone end-to-end", pulses);
        $finish;
    end

    initial begin
        #100000000;
        $fatal(1, "test timeout");
    end
endmodule
