`timescale 1ns / 1ps

module spi_slave #(
    parameter int WORD_WIDTH = 16
)(
    input  logic                  clk,         // High-speed system clock
    input  logic                  rst_n,       // Active-low system reset

    input  logic                  spi_sclk,    // SPI clock from master
    input  logic                  spi_cs_n,    // Active-low chip select from master
    input  logic                  spi_mosi,    // Master Out, Slave In

    output logic                  spi_miso,    // Master In, Slave Out
    output logic [WORD_WIDTH-1:0] data_out,    // Fully received word
    output logic                  data_valid   // Pulse indicating data_out is valid
);

    // 2-stage synchronizer signals
    logic sync_sclk_meta, sync_sclk;
    logic sync_cs_n_meta, sync_cs_n;
    logic sync_mosi_meta, sync_mosi;

    // Previous state signals for edge detection
    logic sync_sclk_prev;
    logic sync_cs_n_prev;

    // Shift register
    logic [WORD_WIDTH-1:0] shift_reg;

    // Edge detections using continuous assignment based on synchronized signals
    logic sclk_rising_edge;
    logic sclk_falling_edge;
    logic cs_n_rising_edge;
    logic cs_n_falling_edge;

    assign sclk_rising_edge  = (sync_sclk == 1'b1) && (sync_sclk_prev == 1'b0);
    assign sclk_falling_edge = (sync_sclk == 1'b0) && (sync_sclk_prev == 1'b1);
    assign cs_n_rising_edge  = (sync_cs_n == 1'b1) && (sync_cs_n_prev == 1'b0);
    assign cs_n_falling_edge = (sync_cs_n == 1'b0) && (sync_cs_n_prev == 1'b1);

    // Sequential Logic operating entirely on high-speed system clk
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset synchronizers and internal states
            sync_sclk_meta <= 1'b0;
            sync_sclk      <= 1'b0;
            
            sync_cs_n_meta <= 1'b1;
            sync_cs_n      <= 1'b1;
            
            sync_mosi_meta <= 1'b0;
            sync_mosi      <= 1'b0;
            
            sync_sclk_prev <= 1'b0;
            sync_cs_n_prev <= 1'b1;

            shift_reg      <= '0;
            data_out       <= '0;
            data_valid     <= 1'b0;
            spi_miso       <= 1'b0;
        end else begin
            // 1. Double-flop synchronizers to bring signals safely into clk domain
            sync_sclk_meta <= spi_sclk;
            sync_sclk      <= sync_sclk_meta;
            
            sync_cs_n_meta <= spi_cs_n;
            sync_cs_n      <= sync_cs_n_meta;
            
            sync_mosi_meta <= spi_mosi;
            sync_mosi      <= sync_mosi_meta;
            
            // 2. Maintain history for edge detection
            sync_sclk_prev <= sync_sclk;
            sync_cs_n_prev <= sync_cs_n;

            // Default valid logic - will pulse high only on CS_n rising edge
            data_valid <= 1'b0;

            // Transaction completion
            if (cs_n_rising_edge) begin
                data_out   <= shift_reg;
                data_valid <= 1'b1;
            end

            // 3. SPI Protocol Logic (Mode 0)
            if (cs_n_falling_edge) begin
                // Prepare first MISO bit when chip select is initially asserted
                spi_miso <= shift_reg[WORD_WIDTH-1];
            end else if (!sync_cs_n) begin
                // While chip is selected:
                if (sclk_rising_edge) begin
                    // Sample MOSI into LSB on SCLK rising edge
                    shift_reg <= {shift_reg[WORD_WIDTH-2:0], sync_mosi};
                end
                
                if (sclk_falling_edge) begin
                    // Shift the next bit onto MISO on SCLK falling edge
                    spi_miso <= shift_reg[WORD_WIDTH-1];
                end
            end else begin
                // Keep MISO low (or could be set to High-Z at the top level)
                spi_miso <= 1'b0;
            end
        end
    end

endmodule
