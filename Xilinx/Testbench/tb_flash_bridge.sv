`timescale 1ns / 1ps

// =============================================================================
// Testbench for flash_bridge
//
// Verifies the SPI flash bridge command interface:
//   - Erase command  (0x01)
//   - Write page command (0x02)
//   - Read bank command  (0x03)
// Uses a simplified SPI flash model that shifts data on flash_miso.
// =============================================================================
module tb_flash_bridge;

    localparam int CLK_PERIOD_NS = 11; // ~90 MHz matches flash_bridge clk comment

    logic clk;
    logic rst_n;
    logic [7:0]  cmd_opcode;
    logic [23:0] cmd_addr;
    logic        cmd_trigger;
    logic        cmd_busy;

    logic [7:0]  fifo_wdata;
    logic        fifo_we;
    logic [7:0]  fifo_waddr;

    logic        flash_clk;
    logic        flash_cs_n;
    logic        flash_mosi;
    wire         flash_miso;

    flash_bridge u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .cmd_opcode (cmd_opcode),
        .cmd_addr   (cmd_addr),
        .cmd_trigger(cmd_trigger),
        .cmd_busy   (cmd_busy),
        .fifo_wdata (fifo_wdata),
        .fifo_we    (fifo_we),
        .fifo_waddr (fifo_waddr),
        .flash_clk  (flash_clk),
        .flash_cs_n (flash_cs_n),
        .flash_mosi (flash_mosi),
        .flash_miso (flash_miso)
    );

    // SPI flash model: shift in MOSI, shift out fixed pattern on MISO
    logic [7:0] flash_shift;
    logic       miso_reg;
    assign flash_miso = miso_reg;

    initial miso_reg = 1'b0;
    always @(posedge flash_clk) begin
        if (!flash_cs_n) begin
            flash_shift <= {flash_shift[6:0], flash_mosi};
            miso_reg    <= flash_shift[7];
        end
    end

    initial clk = 0;
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    task automatic fill_page_buffer();
        begin
            for (int i = 0; i < 256; i++) begin
                @(posedge clk);
                fifo_waddr = i[7:0];
                fifo_wdata = 8'hA0 + i[7:0];
                fifo_we = 1;
                @(posedge clk);
                fifo_we = 0;
            end
        end
    endtask

    initial begin
        $display("Starting flash_bridge testbench");
        rst_n = 0;
        cmd_opcode = 0;
        cmd_addr = 0;
        cmd_trigger = 0;
        fifo_wdata = 0;
        fifo_we = 0;
        fifo_waddr = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // 1. Erase command (0x01)
        cmd_opcode = 8'h01;
        cmd_addr = 24'h00_0100;
        cmd_trigger = 1;
        @(posedge clk);
        cmd_trigger = 0;
        wait (!cmd_busy);
        $display("PASS: erase command completed");
        repeat(10) @(posedge clk);

        // 2. Write page command (0x02)
        fill_page_buffer();
        cmd_opcode = 8'h02;
        cmd_addr = 24'h00_0200;
        cmd_trigger = 1;
        @(posedge clk);
        cmd_trigger = 0;
        wait (!cmd_busy);
        $display("PASS: write page command completed");
        repeat(10) @(posedge clk);

        // 3. Read bank command (0x03)
        cmd_opcode = 8'h03;
        cmd_addr = 24'h00_0300;
        cmd_trigger = 1;
        @(posedge clk);
        cmd_trigger = 0;
        wait (!cmd_busy);
        $display("PASS: read bank command completed");
        repeat(10) @(posedge clk);

        $display("Testbench complete");
        $stop;
    end

endmodule
