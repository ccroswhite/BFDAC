`timescale 1ns / 1ps

// =============================================================================
// Testbench for i2c_master
//
// Verifies a single-byte write transaction: START -> dev_addr+W -> reg_addr ->
// data -> STOP. Uses a pull-up model on SDA and a slave state machine that
// ACKs each byte. Also checks SCL high/low periods meet the I2C fast-mode spec.
// =============================================================================
module tb_i2c_master;

    localparam int CLK_PERIOD_NS = 5; // 200 MHz
    localparam int T_HIGH_MIN_NS = 600;  // I2C fast-mode min tHIGH
    localparam int T_LOW_MIN_NS  = 1300; // I2C fast-mode min tLOW

    logic clk;
    logic rst_n;
    logic [6:0] dev_addr;
    logic [7:0] reg_addr;
    logic [3:0] txn_len;
    logic [7:0] wdata_buf [0:7];
    logic       read;
    logic [7:0] rdata;
    logic       trigger;
    logic       busy;
    logic       ack_error;
    logic       done_pulse;
    wire        i2c_scl;
    wire        i2c_sda;

    int scl_low_time;
    int scl_high_time;
    int prev_scl_time;
    int errors;

    // Pull-up on SDA and SCL (open-drain buses)
    pullup(i2c_sda);
    pullup(i2c_scl);

    i2c_master u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .dev_addr   (dev_addr),
        .reg_addr   (reg_addr),
        .txn_len    (txn_len),
        .wdata_buf  (wdata_buf),
        .read       (read),
        .trigger    (trigger),
        .busy       (busy),
        .ack_error  (ack_error),
        .done_pulse (done_pulse),
        .rdata      (rdata),
        .i2c_scl_in (i2c_scl),
        .i2c_scl_out(i2c_scl),
        .i2c_sda    (i2c_sda)
    );

    // Slave model: ACKs every byte; for read transactions it drives the data
    // byte after the repeated START. For the read data byte the master sends
    // NACK, so the slave releases SDA during that 9th bit.
    logic       slave_sda_drive;
    logic       slave_sda_out;
    logic [3:0] bit_cnt;
    logic [1:0] byte_cnt;
    logic [7:0] slave_read_data;
    logic       read_mode;

    assign i2c_sda = (slave_sda_drive && !slave_sda_out) ? 1'b0 : 1'bz;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD_NS/2) clk = ~clk;
    end

    // Drive SDA on negedge SCL so it is stable for the next high period.
    always_ff @(negedge i2c_scl or negedge rst_n) begin
        if (!rst_n) begin
            slave_sda_drive <= 1'b0;
            slave_sda_out   <= 1'b1;
        end else if (read_mode && byte_cnt == 3) begin
            // Read data byte: drive MSB first, then release for the master's NACK
            if (bit_cnt < 8) begin
                slave_sda_drive <= 1'b1;
                slave_sda_out   <= slave_read_data[7 - bit_cnt];
            end else begin
                slave_sda_drive <= 1'b0;
            end
        end else if (bit_cnt == 8) begin
            // ACK bit
            slave_sda_drive <= 1'b1;
            slave_sda_out   <= 1'b0;
        end else begin
            slave_sda_drive <= 1'b0;
        end
    end

    // Count bits/bytes on posedge SCL
    always_ff @(posedge i2c_scl or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt  <= '0;
            byte_cnt <= '0;
        end else begin
            bit_cnt <= bit_cnt + 1'b1;
            if (bit_cnt == 8) begin
                bit_cnt  <= 4'd0;
                byte_cnt <= byte_cnt + 1'b1;
            end
        end
    end

    // Optional slave clock stretching: drive SCL low during the first ACK of a write transaction.
    logic       stretch_en;
    logic       stretch_active;
    logic       stretch_done;
    logic [15:0] stretch_cnt;
    assign i2c_scl = (stretch_active) ? 1'b0 : 1'bz;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || !busy) begin
            stretch_active <= 1'b0;
            stretch_done   <= 1'b0;
            stretch_cnt    <= '0;
        end else if (stretch_en && !read_mode && byte_cnt == 0 && bit_cnt == 8 &&
                     !stretch_active && !stretch_done) begin
            stretch_active <= 1'b1;
            stretch_done   <= 1'b1;
            stretch_cnt    <= 16'd500; // 2.5 us extra hold on a 200 MHz clock
        end else if (stretch_active && stretch_cnt > 0) begin
            stretch_cnt <= stretch_cnt - 1'b1;
        end else if (stretch_active && stretch_cnt == 0) begin
            stretch_active <= 1'b0;
        end
    end

    // SCL timing checks
    always @(i2c_scl) begin
        if (i2c_scl === 1'b0) begin
            scl_high_time = $time - prev_scl_time;
            if (scl_high_time > 0 && scl_high_time < T_HIGH_MIN_NS) begin
                $display("FAIL: tHIGH = %0d ns < %0d ns", scl_high_time, T_HIGH_MIN_NS);
                errors = errors + 1;
            end
            prev_scl_time = $time;
        end else if (i2c_scl === 1'b1) begin
            scl_low_time = $time - prev_scl_time;
            if (scl_low_time > 0 && scl_low_time < T_LOW_MIN_NS) begin
                $display("FAIL: tLOW = %0d ns < %0d ns", scl_low_time, T_LOW_MIN_NS);
                errors = errors + 1;
            end
            prev_scl_time = $time;
        end
    end

    initial begin
        $display("Starting i2c_master testbench");
        rst_n   = 0;
        trigger = 0;
        read    = 0;
        read_mode = 0;
        dev_addr = 7'h48;
        reg_addr = 8'h00;
        wdata_buf[0] = 8'hA5;
        wdata_buf[1] = 8'hB6;
        wdata_buf[2] = 8'hC7;
        wdata_buf[3] = 8'hD8;
        txn_len      = 4'd1;
        slave_read_data = 8'h5A;
        stretch_en = 0;
        errors = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // ---------------------------------------------------------
        // Test 1: single-byte write
        // ---------------------------------------------------------
        $display("Test 1: I2C single-byte write transaction");
        read      = 0;
        txn_len   = 4'd1;
        read_mode = 0;
        bit_cnt   = 0;
        byte_cnt  = 0;
        trigger   = 1;
        @(posedge clk);
        trigger   = 0;

        wait(done_pulse);
        repeat(5) @(posedge clk);

        if (ack_error || errors > 0)
            $display("FAIL: I2C single-byte write transaction or timing check failed");
        else
            $display("PASS: I2C single-byte write transaction completed and timing met spec");

        // ---------------------------------------------------------
        // Test 2: multi-byte write
        // ---------------------------------------------------------
        $display("Test 2: I2C multi-byte write transaction");
        read      = 0;
        txn_len   = 4'd4;
        read_mode = 0;
        bit_cnt   = 0;
        byte_cnt  = 0;
        trigger   = 1;
        @(posedge clk);
        trigger   = 0;

        wait(done_pulse);
        repeat(5) @(posedge clk);

        if (ack_error || errors > 0)
            $display("FAIL: I2C multi-byte write transaction or timing check failed");
        else
            $display("PASS: I2C multi-byte write transaction completed and timing met spec");

        // ---------------------------------------------------------
        // Test 3: single-byte read
        // ---------------------------------------------------------
        $display("Test 3: I2C read transaction");
        read      = 1;
        txn_len   = 4'd1;
        read_mode = 1;
        bit_cnt   = 0;
        byte_cnt  = 0;
        trigger   = 1;
        @(posedge clk);
        trigger   = 0;

        wait(done_pulse);
        repeat(5) @(posedge clk);

        if (ack_error || errors > 0)
            $display("FAIL: I2C read transaction or timing check failed");
        else if (rdata !== slave_read_data)
            $display("FAIL: I2C read data mismatch: rdata=0x%02X expected=0x%02X", rdata, slave_read_data);
        else
            $display("PASS: I2C read transaction completed and rdata=0x%02X", rdata);

        // ---------------------------------------------------------
        // Test 4: single-byte write with slave clock stretching
        // ---------------------------------------------------------
        $display("Test 4: I2C write transaction with clock stretching");
        read      = 0;
        txn_len   = 4'd1;
        read_mode = 0;
        stretch_en = 1;
        bit_cnt   = 0;
        byte_cnt  = 0;
        trigger   = 1;
        @(posedge clk);
        trigger   = 0;

        wait(done_pulse);
        repeat(5) @(posedge clk);

        if (ack_error || errors > 0)
            $display("FAIL: I2C write with clock stretching failed");
        else
            $display("PASS: I2C write with clock stretching completed and timing met spec");

        $display("Testbench complete");
        $stop;
    end

endmodule
