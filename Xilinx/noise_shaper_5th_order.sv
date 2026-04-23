`timescale 1ns / 1ps

module noise_shaper_5th_order #(
    parameter int INPUT_WIDTH = 48, // Now accepting the upper 48 bits of the 96-bit FIR
    parameter int FRAC_WIDTH  = 42  // Bits discarded
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    enable,

    input  logic signed [INPUT_WIDTH-1:0] data_in, 
    
    // Unsigned 0 to 32 physical drive for the DEM Mapper
    output logic [5:0]              dem_drive_out 
);

    // =================================---------------------------------------
    // Dither Injection
    // =================================---------------------------------------
    logic signed [FRAC_WIDTH-1:0] dither_val;
    
    tpdf_dither_gen #(.DITHER_WIDTH(FRAC_WIDTH)) u_dither (
        .clk(clk), .rst_n(rst_n), .enable(enable), .tpdf_out(dither_val)
    );

    // =================================---------------------------------------
    // 5th Order Integrator Chain (Mapped to DSPs)
    // =================================---------------------------------------
    // We add margin bits to prevent internal overflow during extreme transients
    localparam int INT_WIDTH = INPUT_WIDTH + 6; 
    
    (* use_dsp = "yes" *) logic signed [INT_WIDTH-1:0] int1, int2, int3, int4, int5;
    logic signed [INT_WIDTH-1:0] quantizer_error;
    logic signed [INT_WIDTH-1:0] data_in_extended;

    // Shift audio to center around physical 16 (midpoint of 32 resistors)
    assign data_in_extended = $signed(data_in) + $signed({7'd16, {FRAC_WIDTH{1'b0}}});

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            int1 <= '0; int2 <= '0; int3 <= '0; int4 <= '0; int5 <= '0;
        end else if (enable) begin
            // 5 Cascaded Integrators fed by the global quantization error
            // Vivado absorbs these into DSP P-registers
            int1 <= data_in_extended - quantizer_error + int1;
            int2 <= int1 - quantizer_error + int2;
            int3 <= int2 - quantizer_error + int3;
            int4 <= int3 - quantizer_error + int4;
            int5 <= int4 - quantizer_error + int5;
        end
    end

    // =================================---------------------------------------
    // Quantizer & Error Calculation
    // =================================---------------------------------------
    logic signed [INT_WIDTH-1:0] modulator_out;
    logic signed [INT_WIDTH-1:0] dithered_out;
    
    always_comb begin
        // Inject dither into the final integrator stage
        dithered_out = int5 + $signed(dither_val);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dem_drive_out   <= 6'd16; 
            quantizer_error <= '0;
        end else if (enable) begin
            
            // Hard Limit to Array Bounds [0 to 32]
            if (dithered_out[INT_WIDTH-1 : FRAC_WIDTH] > 32) begin
                dem_drive_out   <= 6'd32;
                quantizer_error <= $signed({8'd32, {FRAC_WIDTH{1'b0}}});
            end 
            else if (dithered_out[INT_WIDTH-1] == 1'b1) begin // Negative
                dem_drive_out   <= 6'd0;
                quantizer_error <= '0;
            end 
            else begin
                dem_drive_out   <= dithered_out[FRAC_WIDTH+5 : FRAC_WIDTH];
                // The error fed back is the actual quantized output representing physical resistors
                quantizer_error <= $signed({ 2'b00, dithered_out[FRAC_WIDTH+5 : FRAC_WIDTH], {FRAC_WIDTH{1'b0}} });
            end
            
        end
    end

endmodule