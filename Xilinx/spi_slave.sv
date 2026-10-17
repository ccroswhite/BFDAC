`timescale 1ns / 1ps

module spi_slave (
    input  logic        clk,
    input  logic        rst_n,
    
    // SPI Bus (Asynchronous from ARM)
    // Capture uses 3-stage synchronizers on clk. Max SPI_SCLK is roughly
    // clk/4. 49.152 MHz clk -> ~12 MHz SPI; 200 MHz clk -> ~50 MHz SPI.
    // If 125 MHz SPI bus is required, a DDR or ISERDES capture path is needed.
    input  logic        spi_sclk,
    input  logic        spi_cs_n,
    input  logic        spi_mosi,
    output logic        spi_miso,

    // Internal Synchronous Interface
    input  logic [31:0] tx_data_in,
    output logic [31:0] data_out,
    output logic        data_valid,
    output logic        crc_err_pulse,
    output logic        frame_err_pulse  // CS rose with a nonzero bit count != 40
);

    // =========================================================
    // 1. CDC Synchronizers 
    // =========================================================
    (* ASYNC_REG = "TRUE" *) logic [2:0] sclk_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] cs_n_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] mosi_sync;

    always_ff @(posedge clk) begin
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
    // 3. Shift Register, Counter, and CRC-8
    // =========================================================
    // Total Frame: 40 bits (32-bit Payload + 8-bit CRC)
    logic [39:0] shift_reg;
    logic [5:0]  bit_cnt;
    logic [7:0]  calc_crc;
    logic        inv;

    // CRC-8 Polynomial: x^8 + x^2 + x + 1
    assign inv = mosi_val ^ calc_crc[7];

    // CRC-8 helper function: same polynomial / left-shift implementation as the
    // bit-serial RX engine above. Used to compute the TX CRC over the 32-bit payload.
    function automatic [7:0] crc8_byte(input [7:0] data, input [7:0] seed);
        logic [7:0] crc_tmp;
        crc_tmp = seed;
        for (int i = 7; i >= 0; i--) begin
            if ((data[i] ^ crc_tmp[7]) == 1'b1)
                crc_tmp = {crc_tmp[6:0], 1'b0} ^ 8'h07;
            else
                crc_tmp = {crc_tmp[6:0], 1'b0};
        end
        return crc_tmp;
    endfunction

    // Compute CRC over tx_data_in (MSB-first, same byte order as shift-out)
    logic [7:0] tx_crc;
    assign tx_crc = crc8_byte(tx_data_in[7:0],
                      crc8_byte(tx_data_in[15:8],
                        crc8_byte(tx_data_in[23:16],
                          crc8_byte(tx_data_in[31:24], 8'h00))));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shift_reg     <= '0;
            bit_cnt       <= '0;
            calc_crc      <= 8'h00;
            data_valid      <= 1'b0;
            crc_err_pulse   <= 1'b0;
            frame_err_pulse <= 1'b0;
            data_out        <= '0;
        end else begin
            data_valid      <= 1'b0;
            crc_err_pulse   <= 1'b0;
            frame_err_pulse <= 1'b0;

            if (cs_n_fall) begin
                bit_cnt  <= '0;
                calc_crc <= 8'h00; // Reset CRC engine
                // Pre-load data to send with valid CRC-8 over the 32-bit payload.
                shift_reg <= {tx_data_in, tx_crc};
            end else if (cs_n_active) begin
                if (sclk_rise) begin
                    shift_reg <= {shift_reg[38:0], mosi_val};
                    // Saturate: a 64+40-clock overrun must not alias to a
                    // valid count of 40 after the 6-bit wrap.
                    if (bit_cnt != 6'd63)
                        bit_cnt <= bit_cnt + 1;

                    // Calculate CRC only over the first 32 bits
                    if (bit_cnt < 32) begin
                        calc_crc[7] <= calc_crc[6];
                        calc_crc[6] <= calc_crc[5];
                        calc_crc[5] <= calc_crc[4];
                        calc_crc[4] <= calc_crc[3];
                        calc_crc[3] <= calc_crc[2];
                        calc_crc[2] <= calc_crc[1] ^ inv;
                        calc_crc[1] <= calc_crc[0] ^ inv;
                        calc_crc[0] <= inv;
                    end
                end
            end else if (cs_n_rise) begin
                if (bit_cnt == 40) begin
                    // Validate CRC byte (bits 7:0 of shift register)
                    if (calc_crc == shift_reg[7:0]) begin
                        data_out   <= shift_reg[39:8]; // Expose the 32-bit payload
                        data_valid <= 1'b1;
                    end else begin
                        crc_err_pulse <= 1'b1;
                    end
                end else if (bit_cnt != 0) begin
                    // Wrong-length frame (runt or overrun): discard + flag.
                    // bit_cnt == 0 (CS pulse with no clocks) is treated as a
                    // CS glitch, not an error.
                    frame_err_pulse <= 1'b1;
                end
            end
        end
    end

    // =========================================================
    // 4. MISO Driving
    // =========================================================
    logic miso_reg;
    
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            miso_reg <= 1'b0;
        end else if (cs_n_fall) begin
            miso_reg <= tx_data_in[31]; 
        end else if (cs_n_active && sclk_fall) begin
            miso_reg <= shift_reg[39]; 
        end
    end

    assign spi_miso = cs_n_active ? miso_reg : 1'b0;

endmodule