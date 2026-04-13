`timescale 1ns / 1ps

module i2s_rx #(
    parameter int DATA_WIDTH = 32 // The bit depth of the audio channel
)(
    input  logic                  clk,         // High-speed system clock
    input  logic                  rst_n,       // Active-low system reset

    // I2S Interface
    input  logic                  i2s_bclk,    // Bit Clock
    input  logic                  i2s_lrclk,   // Word Select (Low = Left, High = Right)
    input  logic                  i2s_data,    // Serial audio data

    // Output Data Interface
    output logic [DATA_WIDTH-1:0] left_data,   // Fully received left channel word
    output logic [DATA_WIDTH-1:0] right_data,  // Fully received right channel word
    output logic                  data_valid   // Indicates stereo frame is complete
);

    // 2-stage synchronizer signals
    logic sync_bclk_meta,  sync_bclk;
    logic sync_lrclk_meta, sync_lrclk;
    logic sync_data_meta,  sync_data;

    // Edge Detection Memory
    logic sync_bclk_prev;
    logic sync_lrclk_prev;

    // Pulse strictly restricted to system clock regime
    logic bclk_rising_edge;
    assign bclk_rising_edge = (sync_bclk == 1'b1) && (sync_bclk_prev == 1'b0);

    // Shift Register and State Tracking
    logic [DATA_WIDTH-1:0] shift_reg;
    logic [7:0]            bit_cnt; // Ensures safe accumulation up to 255 depths

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Synchronizers reset
            sync_bclk_meta  <= 1'b0;
            sync_bclk       <= 1'b0;
            sync_lrclk_meta <= 1'b0;
            sync_lrclk      <= 1'b0;
            sync_data_meta  <= 1'b0;
            sync_data       <= 1'b0;

            sync_bclk_prev  <= 1'b0;
            sync_lrclk_prev <= 1'b0;

            // Functional logic reset
            shift_reg       <= '0;
            bit_cnt         <= '0;

            left_data       <= '0;
            right_data      <= '0;
            data_valid      <= 1'b0;
        end else begin
            // 1. Double-flop synchronizers completely isolating external clock regimes
            sync_bclk_meta  <= i2s_bclk;
            sync_bclk       <= sync_bclk_meta;
            
            sync_lrclk_meta <= i2s_lrclk;
            sync_lrclk      <= sync_lrclk_meta;
            
            sync_data_meta  <= i2s_data;
            sync_data       <= sync_data_meta;

            // 2. Continuous tracking
            sync_bclk_prev  <= sync_bclk;

            // Default valid off - pulses for 1 cycle when right channel fully processes
            data_valid <= 1'b0;

            // 3. Oversampled functional evaluation ONLY on detected BCLK peaks
            if (bclk_rising_edge) begin
                sync_lrclk_prev <= sync_lrclk;

                if (sync_lrclk != sync_lrclk_prev) begin
                    // ---- CHANNEL TRANSITION DETECTED ----
                    // Handled precisely at the first rising BCLK after the Word Select flip.
                    // This elegantly covers the 1-bit I2S delay where the MSB relies on the NEXT cycle.
                    
                    // Latch fully compiled data:
                    // If true frame slot exactly equals DATA_WIDTH, the LSB lands explicitly on this edge.
                    if (bit_cnt == 8'd1) begin
                        if (sync_lrclk_prev == 1'b0) begin
                            left_data <= {shift_reg[DATA_WIDTH-2:0], sync_data};
                        end else begin
                            right_data <= {shift_reg[DATA_WIDTH-2:0], sync_data};
                            data_valid <= 1'b1;
                        end
                    end 
                    // If frame slot > DATA_WIDTH, the remaining padding bits are naturally omitted.
                    // The shift_reg has cleanly protected the MSB-aligned elements without overflow.
                    else begin
                        if (sync_lrclk_prev == 1'b0) begin
                            left_data <= shift_reg;
                        end else begin
                            right_data <= shift_reg;
                            data_valid <= 1'b1;
                        end
                    end

                    // Initialize the sequence for the new channel on the subsequent rising edge
                    bit_cnt <= DATA_WIDTH[7:0]; 
                end else begin
                    // ---- I2S SHIFTING ----
                    // Consume incoming datastream natively keeping MSB securely at the top
                    if (bit_cnt > 0) begin
                        shift_reg <= {shift_reg[DATA_WIDTH-2:0], sync_data};
                        bit_cnt <= bit_cnt - 8'd1;
                    end
                end
            end
        end
    end

endmodule
