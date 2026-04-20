`timescale 1ns / 1ps

module flash_bridge (
    input  logic        clk,          // 90MHz DSP Clock
    input  logic        rst_n,

    // ARM Command Interface
    input  logic [7:0]  cmd_opcode,   // 0x01=Erase 64K, 0x02=Write Page, 0x03=Read Bank
    input  logic [23:0] cmd_addr,
    input  logic        cmd_trigger,
    output logic        cmd_busy,

    // ARM Data FIFO Interface (256-Byte Page Buffer)
    input  logic [7:0]  fifo_wdata,
    input  logic        fifo_we,
    input  logic [7:0]  fifo_waddr,   // 0 to 255

    // Physical Flash Pins
    output logic        flash_clk,    // 45MHz Shift Clock
    output logic        flash_cs_n,
    output logic        flash_mosi,
    input  logic        flash_miso
);

    // 256-Byte Page Buffer
    logic [7:0] page_buffer [0:255];
    always_ff @(posedge clk) begin
        if (fifo_we) page_buffer[fifo_waddr] <= fifo_wdata;
    end

    // 45 MHz Clock Divider
    logic clk_en_45m;
    logic clk_div;
    always_ff @(posedge clk) begin
        if (!rst_n) clk_div <= 1'b0;
        else        clk_div <= ~clk_div;
    end
    assign clk_en_45m = clk_div;

    // FSM States
    typedef enum logic [3:0] {
        IDLE,
        WREN_CMD, WREN_WAIT,
        EXEC_CMD, EXEC_WAIT,
        STATUS_CMD, STATUS_WAIT, STATUS_EVAL,
        DONE
    } state_t;
    state_t state;

    // SPI Transactor Logic
    logic [31:0] header_data; // Driven by FSM
    logic [8:0]  bit_count; 
    logic        spi_start;
    logic        spi_busy;
    logic [7:0]  spi_rx_data;
    logic        target_is_write;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= IDLE;
            cmd_busy        <= 1'b0;
            flash_cs_n      <= 1'b1;
            spi_start       <= 1'b0;
            target_is_write <= 1'b0;
            header_data     <= '0;
        end else if (clk_en_45m) begin
            spi_start <= 1'b0;

            case (state)
                IDLE: begin
                    if (cmd_trigger) begin
                        cmd_busy <= 1'b1;
                        if (cmd_opcode == 8'h01 || cmd_opcode == 8'h02) begin
                            state <= WREN_CMD;
                            target_is_write <= (cmd_opcode == 8'h02);
                        end else begin
                            state <= EXEC_CMD;
                        end
                    end else begin
                        cmd_busy <= 1'b0;
                    end
                end

                WREN_CMD: begin
                    flash_cs_n  <= 1'b0;
                    header_data <= {8'h06, 24'd0}; 
                    bit_count   <= 9'd8;
                    spi_start   <= 1'b1;
                    state       <= WREN_CMD;
                    if (spi_start) state <= WREN_WAIT;
                end

                WREN_WAIT: begin
                    if (!spi_busy && !spi_start) begin
                        flash_cs_n <= 1'b1;
                        state      <= EXEC_CMD;
                    end
                end

                EXEC_CMD: begin
                    flash_cs_n <= 1'b0;
                    if (target_is_write) header_data <= {8'h02, cmd_addr}; 
                    else                 header_data <= {8'hD8, cmd_addr}; 
                    
                    bit_count <= target_is_write ? 9'd2056 : 9'd32; 
                    spi_start <= 1'b1;
                    state     <= EXEC_CMD;
                    if (spi_start) state <= EXEC_WAIT;
                end

                EXEC_WAIT: begin
                    if (!spi_busy && !spi_start) begin
                        flash_cs_n <= 1'b1;
                        if (target_is_write || cmd_opcode == 8'h01) state <= STATUS_CMD;
                        else state <= DONE;
                    end
                end

                STATUS_CMD: begin
                    flash_cs_n  <= 1'b0;
                    header_data <= {8'h05, 24'd0}; 
                    bit_count   <= 9'd16;          
                    spi_start   <= 1'b1;
                    state       <= STATUS_CMD;
                    if (spi_start) state <= STATUS_WAIT;
                end

                STATUS_WAIT: begin
                    if (!spi_busy && !spi_start) begin
                        flash_cs_n <= 1'b1;
                        state      <= STATUS_EVAL;
                    end
                end

                STATUS_EVAL: begin
                    if (spi_rx_data[0] == 1'b1) state <= STATUS_CMD; 
                    else                        state <= DONE;
                end

                DONE: begin
                    cmd_busy <= 1'b0;
                    state    <= IDLE;
                end
            endcase
        end
    end

    // Low-Level SPI Shift Engine (45MHz)
    logic [8:0]  tx_bits_left;
    logic [7:0]  byte_count;
    logic [31:0] shift_reg; // Driven exclusively by Shift Engine

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            flash_clk    <= 1'b0;
            flash_mosi   <= 1'b0;
            spi_busy     <= 1'b0;
            tx_bits_left <= '0;
            byte_count   <= '0;
            shift_reg    <= '0;
        end else if (clk_en_45m) begin
            if (spi_start) begin
                tx_bits_left <= bit_count;
                spi_busy     <= 1'b1;
                byte_count   <= '0;
                flash_clk    <= 1'b0;
                shift_reg    <= header_data; // Load payload from FSM
            end else if (spi_busy) begin
                flash_clk <= ~flash_clk;
                
                if (!flash_clk) begin // Falling Edge: Shift MOSI
                    if (tx_bits_left > 0) begin
                        if (tx_bits_left > (bit_count - 32)) begin
                            // Shift Header
                            flash_mosi <= shift_reg[31];
                            shift_reg  <= {shift_reg[30:0], 1'b0};
                        end else begin
                            // Shift Payload Data
                            flash_mosi <= page_buffer[byte_count][(tx_bits_left - 1) % 8];
                            if ((tx_bits_left - 1) % 8 == 0) byte_count <= byte_count + 1;
                        end
                        tx_bits_left <= tx_bits_left - 1;
                    end else begin
                        spi_busy <= 1'b0;
                    end
                end else begin // Rising Edge: Sample MISO
                    spi_rx_data <= {spi_rx_data[6:0], flash_miso};
                end
            end
        end
    end

endmodule