`timescale 1ns / 1ps

module tb_noise_shaper();

    localparam int INPUT_WIDTH = 64; 
    localparam int FRAC_WIDTH  = 42;
    localparam int OUT_WIDTH   = 9;
    localparam real CLK_PERIOD = 2.8; 

    // Enable must pulse at most once per PIPE_LATENCY+1 clocks so that
    // Stage D2 commits e_z1..5 before Stage A reads them for the next sample.
    localparam int ENABLE_PERIOD = 8;  // >= PIPE_LATENCY+1; matches realistic HW rate

    logic clk = 0;
    logic rst_n = 0;
    logic enable = 0;
    
    logic signed [INPUT_WIDTH-1:0] data_in = '0;
    logic signed [FRAC_WIDTH-1:0]  dither_in = '0;
    logic [OUT_WIDTH-1:0]          dem_drive_out;

    // ENABLE_PERIOD (8) > pipeline depth (5), so D2 fires within the same
    // enable period as the input. dem_drive_out is valid at the end of enable period N
    // for input N — no latency compensation needed in the TB.

    int fd, scan_ret, error_count = 0, sample_count = 0, check_count = 0;
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
        fd = $fopen("C:/Users/ccros/src/BFDAC/Xilinx/Testbench/golden_vectors.txt", "r");
        if (!fd) $fatal(1, "ERROR: Could not open golden_vectors.txt.");

        // Hard Reset Lock
        rst_n = 0;
        data_in = '0;
        dither_in = '0;
        enable = 0;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        $display("---------------------------------------------------------");
        $display("Final Verification (5-Cycle Pipeline Latency)");
        $display("---------------------------------------------------------");

        while (!$feof(fd)) begin

            // 1. Read next vector and set up inputs before the enable pulse
            @(negedge clk);
            scan_ret = $fscanf(fd, "%h %h %h\n", read_data, read_dither, read_expected);
            if (scan_ret != 3) break;
            data_in   = read_data;
            dither_in = read_dither;
            sample_count++;

            // 2. Strobe enable for exactly one clock cycle
            @(posedge clk); enable = 1;
            @(posedge clk); enable = 0;

            // 3. Wait for the rest of the enable period (pipeline settle)
            repeat(ENABLE_PERIOD - 2) @(posedge clk);
            #0.1;

            // 4. Verify: ENABLE_PERIOD > pipeline depth, output for input N is
            //    valid at end of enable period N.
            check_count++;
            if (dem_drive_out !== read_expected) begin
                $display("ERROR at Output %0d: Expected %h, Got %h",
                         check_count, read_expected, dem_drive_out);
                error_count++;
                if (error_count > 10) $fatal(1, "Too many mathematical errors.");
            end
        end

        $fclose(fd);

        $display("---------------------------------------------------------");
        if (error_count == 0) $display("SUCCESS! %0d outputs verified.", check_count);
        else $display("FAILED with %0d errors.", error_count);
        $display("---------------------------------------------------------");

        $finish;
    end

endmodule