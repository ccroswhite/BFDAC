`timescale 1ns / 1ps

module tb_noise_shaper();

    // =================================---------------------------------------
    // 1. Parameters 
    // =================================---------------------------------------
    localparam int INPUT_WIDTH = 64; 
    localparam int FRAC_WIDTH  = 42;
    localparam int OUT_WIDTH   = 9;
    localparam real CLK_PERIOD = 2.8; 

    // =================================---------------------------------------
    // 2. DUT Signals
    // =================================---------------------------------------
    logic clk = 0;
    logic rst_n = 0;
    logic enable = 1;
    
    logic signed [INPUT_WIDTH-1:0] data_in = '0;
    logic signed [FRAC_WIDTH-1:0]  dither_in = '0;
    logic [OUT_WIDTH-1:0]          dem_drive_out;

    // =================================---------------------------------------
    // 3. File I/O Variables
    // =================================---------------------------------------
    int fd;                   
    int scan_ret;             
    logic [63:0] read_data;
    logic [41:0] read_dither;
    logic [8:0]  read_expected;
    
    // The 1-Cycle Pipeline Matcher!
    logic [8:0]  expected_delay; 

    int error_count  = 0;
    int sample_count = 0;

    // =================================---------------------------------------
    // 4. Clock Generation
    // =================================---------------------------------------
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // =================================---------------------------------------
    // 5. Instantiate the DUT
    // =================================---------------------------------------
    noise_shaper_5th_order #(
        .INPUT_WIDTH(INPUT_WIDTH),
        .FRAC_WIDTH(FRAC_WIDTH),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .enable       (enable),
        .data_in      (data_in),
        .dither_in    (dither_in),
        .dem_drive_out(dem_drive_out)
    );

    // =================================---------------------------------------
    // 6. The Master Simulation Thread
    // =================================---------------------------------------
    initial begin
        fd = $fopen("/Users/ccros/src/BFDAC/Xilinx/Testbench/golden_vectors.txt", "r");
        if (!fd) begin
            $fatal(1, "ERROR: Could not open golden_vectors.txt.");
        end

        // Hard Reset: Keep it asserted to prevent garbage data!
        rst_n = 0;
        data_in = '0;
        dither_in = '0;
        expected_delay = 9'h080; // Default silence
        #(CLK_PERIOD * 5);

        $display("---------------------------------------------------------");
        $display("Starting Final Verification (Sync Reset + 1-Cycle Latency)...");
        $display("---------------------------------------------------------");

        // Loop through the text file until the end
        while (!$feof(fd)) begin
            
            // 1. Setup Data on the Falling Edge
            @(negedge clk); 
            scan_ret = $fscanf(fd, "%h %h %h\n", read_data, read_dither, read_expected);
            
            if (scan_ret == 3) begin
                data_in   = read_data;
                dither_in = read_dither;
                sample_count++;
            end

            // 2. Drop Reset exactly when the first sample is present
            if (sample_count == 1) begin
                rst_n = 1;
            end

            // 3. Wait for the rising edge to clock the registers
            @(posedge clk);
            #0.1; 

            // 4. Verify the RTL against the DELAYED expected value from the previous cycle
            if (sample_count > 1 && rst_n == 1) begin
                if (dem_drive_out !== expected_delay) begin
                    // Notice we print sample_count - 1, because we are verifying the previous sample
                    $display("ERROR at Sample %0d: Expected %h, Got %h", sample_count - 1, expected_delay, dem_drive_out);
                    error_count++;
                    
                    if (error_count > 10) begin
                        $fatal(1, "Too many mathematical errors. Aborting simulation.");
                    end
                end
            end
            
            // 5. Shift the current expected value into the delay register for the NEXT cycle's check
            expected_delay = read_expected;
        end

        $fclose(fd);

        $display("---------------------------------------------------------");
        if (error_count == 0) begin
            $display("SUCCESS! %0d samples verified flawlessly.", sample_count);
            $display("The RTL is mathematically perfect.");
        end else begin
            $display("FAILED with %0d errors.", error_count);
        end
        $display("---------------------------------------------------------");
        
        $finish;
    end

endmodule