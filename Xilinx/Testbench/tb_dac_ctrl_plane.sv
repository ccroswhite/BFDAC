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
    logic mgr_busy = 0, coef_load_done = 1, i2s_err = 0, switch_busy = 0;
    logic clk_locked = 1, ddr4_init_calib_complete = 1;
    logic line_mute_status = 0, hp_mute_status = 0;
    logic [3:0] current_bank_id = 4'h0;

    // DUT outputs
    logic [31:0] sys_volume;
    logic        base_rate_sel, clk_source_sel;
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;
    logic [15:0] filter_id, filter_next_id;
    logic        filter_load_req, video_mode;
    logic        spi_unmute, fpga_irq_n;
    logic        level_switch_req, outsel_switch_req, outsel_target;
    logic [1:0]  level_target;

    dac_ctrl_plane dut (
        .clk(clk), .ext_rst_n(ext_rst_n),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .level_switch_req(level_switch_req), .level_target(level_target),
        .outsel_switch_req(outsel_switch_req), .outsel_target(outsel_target),
        .mgr_busy(mgr_busy), .coef_load_done(coef_load_done),
        .current_bank_id(current_bank_id), .i2s_err(i2s_err),
        .switch_busy(switch_busy), .clk_locked(clk_locked),
        .ddr4_init_calib_complete(ddr4_init_calib_complete),
        .line_mute_status(line_mute_status), .hp_mute_status(hp_mute_status),
        .sys_volume(sys_volume), .base_rate_sel(base_rate_sel),
        .clk_source_sel(clk_source_sel),
        .coef_bank_id(coef_bank_id), .coef_load_start(coef_load_start),
        .filter_id(filter_id), .filter_next_id(filter_next_id),
        .filter_load_req(filter_load_req), .video_mode(video_mode),
        .spi_unmute(spi_unmute), .fpga_irq_n(fpga_irq_n)
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
            #50 spi_sclk = 0;   // falling edge: DUT shifts out
        end
        #100;
        spi_cs_n = 1;
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

        // T1: empty-list select must not fire a load
        spi_write(7'h0A, 24'h010000);   // advance on empty list
        check("T1 no load on empty list", load_req_count, 0);

        // T2: clear, append 3, verify status
        spi_write(7'h08, 24'h000001);
        spi_write(7'h09, 24'h000101);
        spi_write(7'h09, 24'h000202);
        spi_write(7'h09, 24'h000303);
        spi_read (7'h16, rd);
        check("T2 list status", rd, {22'd0, 1'b0, 5'd3, 4'd0});

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
        check("T5 status w/ video", rd, {22'd0, 1'b1, 5'd3, 4'd0});

        // T6: out-of-range explicit index clamps to 0
        spi_write(7'h0A, 24'h00000F);
        check("T6 clamped filter_id", filter_id, 32'h0101);

        // T7: fill to 16 entries, 17th append ignored
        spi_write(7'h08, 24'h000001);
        for (int k = 0; k < 17; k++)
            spi_write(7'h09, 24'h001000 + k[15:0]);
        spi_read (7'h16, rd);
        check("T7 list capped at 16", rd[8:4], 5'd16);
        // advance from 15 wraps to 0 at full length
        spi_write(7'h0A, 24'h00000F);      // select 15
        check("T7 idx15 id", filter_id, 32'h100F);
        spi_write(7'h0A, 24'h010000);      // advance -> wrap
        check("T7 full-list wrap id", filter_id, 32'h1000);

        if (errors == 0) $display("TB_PASS: tb_dac_ctrl_plane all tests passed");
        else             $display("TB_FAIL: %0d errors", errors);
        $finish;
    end

endmodule
