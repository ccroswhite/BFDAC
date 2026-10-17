`timescale 1ns / 1ps
module tb_tpdf_dither_gen;
    localparam int DITHER_WIDTH = 42;
    localparam logic signed [42:0] HALF_LSB = 43'sd2199023255552;
    logic clk=0, rst_n=0, enable=0;
    wire signed [DITHER_WIDTH:0] dither_l, dither_r;
    int errors=0, equal_samples=0;
    logic signed [42:0] min_l, max_l, min_r, max_r;
    always #1 clk=~clk;

    tpdf_dither_gen #(.DITHER_WIDTH(DITHER_WIDTH)) u_l (
        .clk(clk), .rst_n(rst_n), .enable(enable), .dither_out(dither_l)
    );
    tpdf_dither_gen #(
        .DITHER_WIDTH(DITHER_WIDTH),
        .SEED1(64'hD1B5_4A32_D192_ED03),
        .SEED2(64'h94D0_49BB_1331_11EB)
    ) u_r (
        .clk(clk), .rst_n(rst_n), .enable(enable), .dither_out(dither_r)
    );

    initial begin
        min_l=0; max_l=0; min_r=0; max_r=0;
        repeat(5) @(negedge clk);
        rst_n=1;
        for (int n=0;n<4096;n++) begin
            @(negedge clk); enable=1;
            @(posedge clk); #0.01;
            if (dither_l===dither_r) equal_samples++;
            if (dither_l < -HALF_LSB) min_l=dither_l;
            if (dither_l >  HALF_LSB) max_l=dither_l;
            if (dither_r < -HALF_LSB) min_r=dither_r;
            if (dither_r >  HALF_LSB) max_r=dither_r;
            @(negedge clk); enable=0;
        end
        if (equal_samples != 0) begin
            $display("FAIL: L/R dither matched on %0d samples",equal_samples);
            errors++;
        end
        if (min_l >= -HALF_LSB || max_l <= HALF_LSB ||
            min_r >= -HALF_LSB || max_r <= HALF_LSB) begin
            $display("FAIL: TPDF range does not span beyond +/-0.5 LSB");
            errors++;
        end
        if (errors==0) $display("TB_PASS: independent full-range L/R TPDF");
        else           $display("TB_FAIL: %0d errors",errors);
        $finish;
    end
endmodule
