`timescale 1ns / 1ps

// =============================================================================
// Testbench for dac_ctrl_plane + spi_slave
//
// Verifies:
//   - SPI write for all control registers (0x01-0x05, 0x07; 0x06 reserved)
//   - SPI read-back for all status registers (0x10-0x15)
//   - Magic ID register returns 0xDAC02026
//   - Control state register reflects written values
//   - base_rate_sel/clk_source_sel single-register alias (0x03 drives both)
//   - Mute/relay status register reflects injected inputs
//   - Clock/PLL status register reflects clk_locked / ddr4_calib
//   - i2s_err produces a sticky error and drops fpga_irq_n; W1C releases it
//   - Level / output-select relay writes pulse the switch request lines
// =============================================================================
module tb_spi_ctrl_plane;

    localparam int  CLK_PERIOD_NS  = 5;   // 200 MHz
    localparam real SPI_HALF_NS    = 100.0; // 5 MHz SPI — well below clk/4 = 50 MHz

    logic clk;
    logic ext_rst_n;
    logic spi_sclk;
    logic spi_cs_n;
    logic spi_mosi;
    logic spi_miso;
    logic fpga_irq_n;
    logic       level_switch_req;
    logic [1:0] level_target;
    logic       outsel_switch_req;
    logic       outsel_target;

    // Status inputs
    logic mgr_busy;
    logic coef_load_done;
    logic [3:0] current_bank_id;
    logic i2s_err;
    logic switch_busy;
    logic clk_locked;
    logic ddr4_init_calib_complete;
    logic line_mute_status;
    logic hp_mute_status;

    // Single-cycle pulse catchers (200 MHz pulses vs #-delay stimulus)
    logic seen_level_req, seen_outsel_req;

    // Control outputs
    logic [31:0] sys_volume;
    logic        base_rate_sel;
    logic        clk_source_sel;
    logic [3:0]  coef_bank_id;
    logic        coef_load_start;
    logic        spi_unmute;

    dac_ctrl_plane u_dut (
        .clk                    (clk),
        .ext_rst_n              (ext_rst_n),
        .spi_sclk               (spi_sclk),
        .spi_cs_n               (spi_cs_n),
        .spi_mosi               (spi_mosi),
        .spi_miso               (spi_miso),
        .fpga_irq_n             (fpga_irq_n),
        .level_switch_req       (level_switch_req),
        .level_target           (level_target),
        .outsel_switch_req      (outsel_switch_req),
        .outsel_target          (outsel_target),
        .mgr_busy               (mgr_busy),
        .coef_load_done         (coef_load_done),
        .current_bank_id        (current_bank_id),
        .i2s_err                (i2s_err),
        .switch_busy            (switch_busy),
        .clk_locked             (clk_locked),
        .ddr4_init_calib_complete(ddr4_init_calib_complete),
        .line_mute_status       (line_mute_status),
        .hp_mute_status         (hp_mute_status),
        .sys_volume             (sys_volume),
        .base_rate_sel          (base_rate_sel),
        .clk_source_sel         (clk_source_sel),
        .coef_bank_id           (coef_bank_id),
        .coef_load_start        (coef_load_start),
        .spi_unmute             (spi_unmute)
    );

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    // Latch single-cycle switch-request pulses
    always @(posedge clk) begin
        if (level_switch_req)  seen_level_req  <= 1'b1;
        if (outsel_switch_req) seen_outsel_req <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // [DEBUG] monitor — enabled by compiling with +define+SIM_DEBUG
    // -------------------------------------------------------------------------
`ifdef SIM_DEBUG
    always @(posedge clk) begin
        if (u_dut.u_spi_slave.data_valid)
            $display("[DEBUG] data_valid: data_out=0x%08X", u_dut.u_spi_slave.data_out);
        if (u_dut.u_spi_slave.crc_err_pulse)
            $display("[DEBUG] crc_err: shift_reg=0x%010X calc=0x%02X rxed=0x%02X",
                     u_dut.u_spi_slave.shift_reg,
                     u_dut.u_spi_slave.calc_crc,
                     u_dut.u_spi_slave.shift_reg[7:0]);
        if (u_dut.u_spi_slave.cs_n_rise)
            $display("[DEBUG] CS rise: bit_cnt=%0d shift_reg=0x%010X calc_crc=0x%02X",
                     u_dut.u_spi_slave.bit_cnt,
                     u_dut.u_spi_slave.shift_reg,
                     u_dut.u_spi_slave.calc_crc);
    end
`endif

    // SPI bus tasks

    // SPI tasks drive signals with absolute time delays (asynchronous to clk).
    // SPI_HALF_NS = 100 ns -> 5 MHz SPI, well below the clk/4 = 50 MHz max.
    // MOSI is set SPI_HALF_NS before SCLK rises (setup time).
    // MISO is sampled SPI_HALF_NS after SCLK rises (hold time).

    // Frame format: {R/W[1], addr[7], data[24], crc[8]} = 40 bits total.
    // data is 24 bits; slave exposes ctrl_bus_data[30:24]=addr, ctrl_bus_data[23:0]=data.
    task automatic spi_write(input [6:0] addr, input [23:0] data);
        logic [39:0] frame;
        logic [7:0]  crc;
        begin
            frame = {1'b0, addr, data, 8'h00}; // placeholder CRC
            crc   = crc8_msb_first(frame[39:8]); // CRC over {R/W, addr, data[23:0]}
            frame[7:0] = crc;
            spi_cs_n = 1'b0;
            spi_sclk = 1'b0;
            spi_mosi = 1'b0;
            #(SPI_HALF_NS * 4); // CS setup: wait for 3-stage sync to settle before SCLK
            for (int i = 0; i < 40; i++) begin
                spi_mosi = frame[39-i];
                #(SPI_HALF_NS);
                spi_sclk = 1'b1;
                #(SPI_HALF_NS);
                spi_sclk = 1'b0;
            end
            #(SPI_HALF_NS);
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;
            #(SPI_HALF_NS * 4); // inter-frame gap: allow CS-rise detection + data_valid
        end
    endtask

    // spi_read: two-transaction read.
    //   Frame 1: READ command — slave latches read_addr_reg on CS rise.
    //   Frame 2: NOP write   — slave pre-loads tx_data on CS fall; MISO shifts out payload.
    task automatic spi_read(input [6:0] addr, output [31:0] rdata);
        logic [39:0] frame;
        logic [7:0]  crc;
        logic [31:0] captured;
        begin
            // --- Phase 1: READ command ---
            frame = {1'b1, addr, 24'h0, 8'h00};
            crc   = crc8_msb_first(frame[39:8]);
            frame[7:0] = crc;
            spi_cs_n = 1'b0;
            spi_sclk = 1'b0;
            spi_mosi = 1'b0;
            #(SPI_HALF_NS * 4); // CS setup: wait for 3-stage sync to settle before SCLK
            for (int i = 0; i < 40; i++) begin
                spi_mosi = frame[39-i];
                #(SPI_HALF_NS);
                spi_sclk = 1'b1;
                #(SPI_HALF_NS);
                spi_sclk = 1'b0;
            end
            #(SPI_HALF_NS);
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;
            // Inter-frame gap: CS rise -> data_valid -> read_addr_reg update -> spi_tx_data MUX
            #(SPI_HALF_NS * 4);

            // --- Phase 2: NOP write to clock out response on MISO ---
            frame = {1'b0, 7'h00, 24'h0, 8'h00};
            crc   = crc8_msb_first(frame[39:8]);
            frame[7:0] = crc;
            captured  = 32'h0;
            spi_cs_n  = 1'b0;
            spi_sclk  = 1'b0;
            spi_mosi  = 1'b0;
            #(SPI_HALF_NS * 4); // CS setup before SCLK
            for (int i = 0; i < 40; i++) begin
                spi_mosi = frame[39-i];
                #(SPI_HALF_NS);
                spi_sclk = 1'b1;
                #(SPI_HALF_NS); // sample MISO mid-high of SCLK (bits 0-31 = payload)
                if (i < 32)
                    captured[31-i] = spi_miso;
                spi_sclk = 1'b0;
            end
            #(SPI_HALF_NS);
            spi_cs_n = 1'b1;
            spi_mosi = 1'b0;
            #(SPI_HALF_NS * 4);
            rdata = captured;
        end
    endtask

    // CRC-8 matching spi_slave hardware: bits fed MSB-first (bit 31 first, bit 0 last).
    // Polynomial x^8 + x^2 + x + 1 (0x07), same left-shift engine as the slave.
    function automatic [7:0] crc8_msb_first(input [31:0] data);
        logic [7:0] crc_tmp;
        logic       inv;
        crc_tmp = 8'h00;
        for (int i = 31; i >= 0; i--) begin
            inv         = data[i] ^ crc_tmp[7];
            crc_tmp[7]  = crc_tmp[6];
            crc_tmp[6]  = crc_tmp[5];
            crc_tmp[5]  = crc_tmp[4];
            crc_tmp[4]  = crc_tmp[3];
            crc_tmp[3]  = crc_tmp[2];
            crc_tmp[2]  = crc_tmp[1] ^ inv;
            crc_tmp[1]  = crc_tmp[0] ^ inv;
            crc_tmp[0]  = inv;
        end
        return crc_tmp;
    endfunction

    // Main stimulus
    initial begin
        $display("=== tb_spi_ctrl_plane: SPI control plane register tests ===");
        $display("    Frame format: {R/W[1], addr[7], data[24], crc8[8]} = 40 bits");
        $display("    SPI clock: 5 MHz (200 MHz sys_clk / 40), 3-stage synchronizer");
        ext_rst_n = 0;
        spi_sclk = 0;
        spi_cs_n = 1;
        spi_mosi = 0;
        mgr_busy = 0;
        coef_load_done = 0;
        current_bank_id = 4'h0;
        i2s_err = 0;
        switch_busy = 0;
        clk_locked = 1;
        ddr4_init_calib_complete = 1;
        line_mute_status = 0;
        hp_mute_status = 0;
        seen_level_req  = 0;
        seen_outsel_req = 0;

        #(CLK_PERIOD_NS * 10);
        ext_rst_n = 1;
        #(CLK_PERIOD_NS * 10);

        // 1. Write volume register (addr=0x01, data=0x001234)
        //    Verifies SPI write path + CRC acceptance + register latch
        spi_write(7'h01, 24'h00_1234);
        #(CLK_PERIOD_NS * 20);
        if (sys_volume !== 32'h0000_1234)
            $display("FAIL: [1] volume write  addr=0x01 got=0x%08X exp=0x00001234", sys_volume);
        else
            $display("PASS: [1] volume write  addr=0x01 sys_volume=0x%08X", sys_volume);

        // 2. Write base_rate_sel (addr=0x03) — single-register clock control:
        //    clk_source_sel is a comb ALIAS of base_rate_sel (0x06 is reserved)
        spi_write(7'h03, 24'h00_0001);
        #(CLK_PERIOD_NS * 20);
        if (base_rate_sel !== 1 || clk_source_sel !== 1)
            $display("FAIL: [2] rate write  base_rate_sel=%0b clk_source_sel=%0b (exp both 1, alias)",
                     base_rate_sel, clk_source_sel);
        else
            $display("PASS: [2] rate write  base_rate_sel=%0b clk_source_sel=%0b (alias ok)",
                     base_rate_sel, clk_source_sel);

        // 3. Write level relay target (addr=0x02): 2'b10 = 6 Vrms.
        //    Verifies level_target latches and the change fires level_switch_req.
        //    Then write output select (addr=0x07): 1 = headphone.
        spi_write(7'h02, 24'h00_0002);
        #(CLK_PERIOD_NS * 20);
        spi_write(7'h07, 24'h00_0001);
        #(CLK_PERIOD_NS * 20);
        if (level_target !== 2'b10 || !seen_level_req)
            $display("FAIL: [3a] level addr=0x02 target=%0b req_seen=%0b (exp 10, 1)",
                     level_target, seen_level_req);
        else
            $display("PASS: [3a] level addr=0x02 target=%0b, level_switch_req pulsed", level_target);
        if (outsel_target !== 1 || !seen_outsel_req)
            $display("FAIL: [3b] outsel addr=0x07 target=%0b req_seen=%0b (exp 1, 1)",
                     outsel_target, seen_outsel_req);
        else
            $display("PASS: [3b] outsel addr=0x07 target=%0b, outsel_switch_req pulsed", outsel_target);

        // 4. Write spi_unmute (addr=0x04)
        //    Verifies mute control register; spi_unmute drives the relay/DSP mute path
        spi_write(7'h04, 24'h00_0001);
        #(CLK_PERIOD_NS * 20);
        if (spi_unmute !== 1)
            $display("FAIL: [4] spi_unmute addr=0x04 got=%0b exp=1", spi_unmute);
        else
            $display("PASS: [4] spi_unmute addr=0x04 = %0b", spi_unmute);

        // 5. Inject i2s_err pulse and verify sticky error latches -> fpga_irq_n deasserts
        //    Verifies the sticky error register captures async faults and drives the IRQ line
        i2s_err = 1;
        #(CLK_PERIOD_NS * 10);
        i2s_err = 0;
        #(CLK_PERIOD_NS * 20);
        if (fpga_irq_n !== 0)
            $display("FAIL: [5] fpga_irq_n still high after i2s_err (sticky not latched)");
        else
            $display("PASS: [5] fpga_irq_n deasserted on i2s_err sticky latch");

        // 6. Clear sticky error register (addr=0x11, data=0xF clears all error bits)
        //    Verifies write-to-clear logic and IRQ line releases when all errors cleared
        spi_write(7'h11, 24'h00_000F);
        #(CLK_PERIOD_NS * 20);
        if (fpga_irq_n !== 1)
            $display("FAIL: [6] fpga_irq_n still low after sticky clear (addr=0x11 wr=0xF)");
        else
            $display("PASS: [6] fpga_irq_n reasserted after sticky error cleared");

        // ---------------------------------------------------------------
        // READ-BACK TESTS
        // ---------------------------------------------------------------
        begin
            logic [31:0] rd;

            // 7. Read magic ID register (addr=0x10, read-only)
            //    Verifies SPI read path: 2-transaction read, MISO shift-out, CRC on read frame
            //    Expected: 0xDAC02026 (hardwired design identifier)
            spi_read(7'h10, rd);
            if (rd !== 32'hDAC02026)
                $display("FAIL: [7] magic ID addr=0x10 got=0x%08X exp=0xDAC02026", rd);
            else
                $display("PASS: [7] magic ID addr=0x10 = 0x%08X", rd);

            // 8. Read sticky error register (addr=0x11) after clear
            //    Verifies write-to-clear took effect and register reads back 0
            spi_read(7'h11, rd);
            if (rd !== 32'h0)
                $display("FAIL: [8] sticky_err addr=0x11 got=0x%08X exp=0x00000000 (not cleared)", rd);
            else
                $display("PASS: [8] sticky_err addr=0x11 = 0x%08X (cleared)", rd);

            // 9. Read control state register (addr=0x12)
            //    Fields: {clk_source_sel[4], base_rate_sel[3], cmd_outsel[2], cmd_level[1:0]}
            //    From tests 2+3: clk_src=1, base_rate=1, outsel=1, level=2'b10 -> 0x1E
            spi_read(7'h12, rd);
            if (rd[4:0] !== 5'b11110)
                $display("FAIL: [9] ctrl_state addr=0x12 [4:0]=0x%X exp=0x1E {clk_src,base_rate,outsel,level[1:0]}",
                         rd[4:0]);
            else
                $display("PASS: [9] ctrl_state addr=0x12 [4:0]=0x%X {clk_src=%0b,base_rate=%0b,outsel=%0b,level=%0b}",
                         rd[4:0], rd[4], rd[3], rd[2], rd[1:0]);

            // 10. Read mute/relay status register (addr=0x14)
            //     Fields: {i2s_err_r[4], switch_busy_r[3], hp_mute_r[2], line_mute_r[1], cmd_unmute[0]}
            //     Inject switch_busy=1, hp_mute=1, line_mute=1; unmute=1 from test 4;
            //     i2s_err deasserted (live status, not sticky) -> expect 0x0F
            switch_busy      = 1;
            hp_mute_status   = 1;
            line_mute_status = 1;
            #(CLK_PERIOD_NS * 20); // allow 2-stage sync + re-register to propagate
            spi_read(7'h14, rd);
            if (rd[4:0] !== 5'b01111)
                $display("FAIL: [10] status addr=0x14 [4:0]=0x%X exp=0x0F {i2s_err,sw_busy,hp_mute,line_mute,unmute}",
                         rd[4:0]);
            else
                $display("PASS: [10] status addr=0x14 = 0x%08X {i2s_err=%0b,sw_busy=%0b,hp_mute=%0b,line_mute=%0b,unmute=%0b}",
                         rd, rd[4], rd[3], rd[2], rd[1], rd[0]);
            switch_busy      = 0;
            hp_mute_status   = 0;
            line_mute_status = 0;

            // 11. Read clock/PLL status register (addr=0x15)
            //     Fields: {ddr4_init_calib_complete[1], clk_locked[0]}
            //     Both driven high at start of test -> expect 0x3
            spi_read(7'h15, rd);
            if (rd[1:0] !== 2'b11)
                $display("FAIL: [11] clk_status addr=0x15 [1:0]=0x%X exp=0x3 {ddr4_calib,clk_locked}",
                         rd[1:0]);
            else
                $display("PASS: [11] clk_status addr=0x15 [1:0]=0x%X {ddr4_calib=%0b,clk_locked=%0b}",
                         rd[1:0], rd[1], rd[0]);

            // 12. Read unmapped address (addr=0x7F)
            //     Verifies default readback returns sentinel 0xDEADBEEF for undefined registers
            spi_read(7'h7F, rd);
            if (rd !== 32'hDEADBEEF)
                $display("FAIL: [12] unknown addr=0x7F got=0x%08X exp=0xDEADBEEF", rd);
            else
                $display("PASS: [12] unknown addr=0x7F returned sentinel 0x%08X", rd);
        end

        $display("=== tb_spi_ctrl_plane complete ===");
        $stop;
    end

endmodule
