`timescale 1ns / 1ps

module tb_noise_shaper();

    localparam int INPUT_WIDTH = 64; 
    localparam int FRAC_WIDTH  = 42;
    localparam int OUT_WIDTH   = 9;
    localparam real CLK_PERIOD = 2.8; 

    logic clk = 0;
    logic rst_n = 0;
    logic enable = 1;
    
    logic signed [INPUT_WIDTH-1:0] data_in = '0;
    logic signed [FRAC_WIDTH-1:0]  dither_in = '0;
    logic [OUT_WIDTH-1:0]          dem_drive_out;

    int fd, scan_ret, error_count = 0, sample_count = 0;             
    logic [63:0] read_data;
    logic [41:0] read_dither;
    logic [8:0]  read_expected;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    noise_shaper_5th_order #(
        .INPUT_WIDTH(INPUT_WIDTH), .FRAC_WIDTH(FRAC_WIDTH), .OUT_WIDTH(OUT_WIDTH)
    ) u_dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .data_in(data_in), .dither_in(dither_in), .dem_drive_out(dem_drive_out)
    );

    initial begin
        fd = $fopen("/Users/ccros/src/BFDAC/Xilinx/Testbench/golden_vectors.txt", "r");
        if (!fd) $fatal(1, "ERROR: Could not open golden_vectors.txt.");

        // Hard Reset Lock
        rst_n = 0;
        data_in = '0;
        dither_in = '0;
        #(CLK_PERIOD * 5);

        $display("---------------------------------------------------------");
        $display("Final Verification (1-Cycle Latency, Sync-Reset)");
        $display("---------------------------------------------------------");

        while (!$feof(fd)) begin
            
            // 1. Setup Data on the Falling Edge
            @(negedge clk); 
            scan_ret = $fscanf(fd, "%h %h %h\n", read_data, read_dither, read_expected);
            
            if (scan_ret == 3) begin
                data_in   = read_data;
                dither_in = read_dither;
                sample_count++;
            end

            // Drop Reset exactly when the first sample hits the pins
            if (sample_count == 1) rst_n = 1;

            // 2. Wait for the rising edge to clock the data into the RTL's input register
            @(posedge clk);
            
            // 3. Wait a fraction of a cycle for the combinational math to resolve
            #0.1; 

            // 4. Verify the output against the Expected value for the sample we just clocked in
            if (sample_count > 0 && rst_n == 1) begin
                if (dem_drive_out !== read_expected) begin
                    $display("ERROR at Sample %0d: Expected %h, Got %h", sample_count, read_expected, dem_drive_out);
                    error_count++;
                    if (error_count > 10) $fatal(1, "Too many mathematical errors.");
                end
            end
        end

        $fclose(fd);

        $display("---------------------------------------------------------");
        if (error_count == 0) $display("SUCCESS! %0d samples verified flawlessly.", sample_count);
        else $display("FAILED with %0d errors.", error_count);
        $display("---------------------------------------------------------");
        
        $finish;
    end

endmodule