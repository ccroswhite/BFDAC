`timescale 1ns / 1ps

module spi_slave #(
    parameter int WORD_WIDTH = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,
    
    // SPI Bus (Asynchronous from ARM)
    input  logic                    spi_sclk,
    input  logic                    spi_cs_n,
    input  logic                    spi_mosi,
    output logic                    spi_miso,
    
    // Internal Synchronous Interface
    output logic [WORD_WIDTH-1:0]   data_out,
    output logic                    data_valid
);

    // =========================================================
    // 1. CDC Synchronizers (Double Flopping)
    // =========================================================
    logic [2:0] sclk_sync;
    logic [2:0] cs_n_sync;
    logic [1:0] mosi_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_sync <= 3'b000;
            cs_n_sync <= 3'b111;
            mosi_sync <= 2'b00;
        end else begin
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            cs_n_sync <= {cs_n_sync[1:0], spi_cs_n};
            mosi_sync <= {mosi_sync[0], spi_mosi};
        end
    end

    // =========================================================
    // 2. Edge Detection
    // =========================================================
    logic sclk_rise, sclk_fall;
    logic cs_n_fall, cs_n_rise;
    logic cs_n_active;
    logic mosi_val;

    assign sclk_rise   = (sclk_sync[2:1] == 2'b01);
    assign sclk_fall   = (sclk_sync[2:1] == 2'b10);
    assign cs_n_fall   = (cs_n_sync[2:1] == 2'b10);
    assign cs_n_rise   = (cs_n_sync[2:1] == 2'b01);
    assign cs_n_active = ~cs_n_sync[1]; 
    assign mosi_val    = mosi_sync[1];

    // =========================================================
    // 3. Shift Register and Counter
    // =========================================================
    logic [WORD_WIDTH-1:0] shift_reg;
    logic [$clog2(WORD_WIDTH):0] bit_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg  <= '0;
            bit_cnt    <= '0;
            data_valid <= 1'b0;
            data_out   <= '0;
        end else begin
            data_valid <= 1'b0; // Default pulse low

            if (cs_n_fall) begin
                // Reset counter at start of transaction
                bit_cnt <= '0;
            end else if (cs_n_active) begin
                // Shift in on rising edge (SPI Mode 0)
                if (sclk_rise) begin
                    shift_reg <= {shift_reg[WORD_WIDTH-2:0], mosi_val};
                    bit_cnt   <= bit_cnt + 1;
                end
            end else if (cs_n_rise) begin
                // Validate data if we received the exact expected number of bits
                if (bit_cnt == WORD_WIDTH) begin
                    data_out   <= shift_reg;
                    data_valid <= 1'b1;
                end
            end
        end
    end

    // =========================================================
    // 4. MISO Driving
    // =========================================================
    logic miso_reg;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            miso_reg <= 1'b0;
        end else if (cs_n_fall) begin
            miso_reg <= shift_reg[WORD_WIDTH-1]; // Pre-load MSB on CS fall
        end else if (cs_n_active && sclk_fall) begin
            miso_reg <= shift_reg[WORD_WIDTH-1]; // Shift out on falling edge
        end
    end

    assign spi_miso = cs_n_active ? miso_reg : 1'b0;

endmodule