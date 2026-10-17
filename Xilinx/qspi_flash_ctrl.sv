`timescale 1ns / 1ps

// =============================================================================
// QSPI Flash Controller (2026-08-22, Steps 2+3 of the flash/DDR4 wiring plan)
//
// Single x1-SPI engine shared by ALL flash devices:
//   target 0 = SoM Flash 1 (128 MiB coefficient store) — dedicated bank-65 pins
//   target 1 = SoM Flash 0 (bitstream/config)          — via STARTUPE3 (FCSBO/DO/DI)
//   target 2 = carrier coefficient flash (bom item 18/18a, 2026-10-05):
//              1..4 x MT25QU02G (2 Gb = 256 MiB each) on one shared bus,
//              bank-70 user IOs, user-IO forwarded SCK (NOT the CCLK).
//              addr[29:28] selects the chip (cf_cs_sel), addr[27:0] goes to
//              the device. A single op must not straddle a 256 MiB boundary
//              (the image layout tool guarantees this; records are <= 12 MB).
//   target 3 = reserved (aliased to 2 so a stray register value cannot hang)
// SCK for targets 0/1 is the shared CCLK (STARTUPE3.USRCCLKO); the top level
// forwards spi_sck to the carrier pin only while sel_target == 2. The carrier
// runs at SCK = clk/8 = 25 MHz (CF_CKDIV_LOG2) for MISO t_CLQV margin over the
// connector + carrier trace; the SoM targets stay at clk/4 = 50 MHz. Only the
// selected CS is ever asserted. Pin muxing lives in the top level.
//
// Supersedes flash_bridge.sv:
//   - 4-byte address opcodes (0x13 READ / 0x12 PP / 0xDC ERASE64K) — both
//     flashes exceed 16 MB (VU13P bin ~90 MB class; 5M-tap coef sets ~12 MB
//     per filter), so 3-byte addressing is insufficient.
//   - clk_200m native (ctrl plane domain; flash_bridge assumed 90 MHz).
//   - Adds a streaming read port for qspi_boot_loader (priority master,
//     locks out ARM commands while active; SCK pauses when the consumer
//     back-pressures via rd_stall).
//
// ARM command set (cmd_opcode):
//   0x01 = Erase 64 KB sector   (WREN -> 0xDC+A32 -> poll WIP)
//   0x02 = Program 256 B page   (WREN -> 0x12+A32+page_buffer -> poll WIP)
//   0x03 = Read 256 B page      (0x13+A32 -> read_buffer)
// SCK = clk/4 = 50 MHz (mode 0).
//
// Watchdog (2026-08-28): ARM commands are aborted (CS deasserted, busy
// released, cmd_err pulsed) if not complete within WDT_CYCLES. Default
// 2^30 clk = ~5.4 s @ 200 MHz, covering the 3 s datasheet-max 64 KB sector
// erase. Boot streaming reads are NOT covered (the boot loader reports its
// own CRC/AXI status; a dead flash at boot shows as boot_done=0).
// =============================================================================
module qspi_flash_ctrl #(
    parameter int unsigned WDT_CYCLES    = 32'h4000_0000, // ~5.4 s @ 200 MHz
    parameter int unsigned CF_CKDIV_LOG2 = 3              // carrier SCK = clk / 2^N (3 -> 25 MHz)
)(
    input  logic        clk,           // 200 MHz ctrl clock
    input  logic        rst_n,

    // --- ARM command interface (ctrl plane registers) ------------------------
    input  logic [7:0]  cmd_opcode,
    input  logic [1:0]  cmd_target,    // 0 = SoM Flash 1, 1 = SoM Flash 0, 2 = carrier
    input  logic [31:0] cmd_addr,
    input  logic        cmd_trigger,   // single-cycle pulse
    output logic        cmd_busy,
    output logic        cmd_err,       // single-cycle pulse: watchdog abort

    // Page buffer (ARM writes bytes before a 0x02 program)
    input  logic [7:0]  buf_wdata,
    input  logic        buf_we,
    input  logic [7:0]  buf_waddr,
    // Read buffer (ARM reads bytes after a 0x03 read)
    input  logic [7:0]  buf_raddr,
    output logic [7:0]  buf_rdata,

    // --- Boot loader streaming read port (priority master) -------------------
    input  logic        rd_req,        // level: start streaming read
    input  logic        rd_target,     // 0 = SoM Flash 1, 1 = carrier flash
    input  logic [31:0] rd_addr,
    input  logic [23:0] rd_len,        // bytes
    input  logic        rd_stall,      // consumer back-pressure (pauses SCK)
    output logic        rd_active,     // engine owns the bus for the stream
    output logic [7:0]  rd_byte,
    output logic        rd_byte_valid, // one clk pulse per received byte
    output logic        rd_done,       // one clk pulse at stream end

    // --- SPI pins (muxed to the selected target in the top level) ------------
    output logic        spi_sck,
    output logic        spi_cs_n,
    output logic        spi_mosi,
    output logic [1:0]  sel_target,    // which device owns the bus (see header)
    output logic        sel_flash0,    // 1 = drive Flash 0 via STARTUPE3 (== sel_target == 1)
    output logic [1:0]  cf_cs_sel,     // carrier chip index (addr[29:28]) for the current op
    input  logic        spi_miso
);

    localparam logic [1:0] TGT_SOM1    = 2'd0;
    localparam logic [1:0] TGT_SOM0    = 2'd1;
    localparam logic [1:0] TGT_CARRIER = 2'd2;

    assign sel_flash0 = (sel_target == TGT_SOM0);

    // Carrier device address: top 4 bits are chip select / unused, the device
    // sees 28 bits. SoM targets pass the full 32-bit address through.
    function automatic logic [31:0] dev_addr(input logic [1:0] tgt, input logic [31:0] a);
        return (tgt == TGT_CARRIER) ? {4'd0, a[27:0]} : a;
    endfunction

    // Buffers
    logic [7:0] page_buffer [0:255];
    logic [7:0] read_buffer [0:255];

    always_ff @(posedge clk)
        if (buf_we) page_buffer[buf_waddr] <= buf_wdata;
    always_ff @(posedge clk)
        buf_rdata <= read_buffer[buf_raddr];

    // ------------------------------------------------------------------------
    // Bit engine: mode-0 SPI, SCK = clk/4. One "op" = CS low, shift tx_bits
    // header bits (MSB first), then either shift page bytes out (program) or
    // clock rx_bytes in (read), then CS high. WIP polling handled by the FSM
    // as separate short ops.
    // ------------------------------------------------------------------------
    typedef enum logic [3:0] {
        IDLE,
        A_WREN, A_ERASE, A_PROG, A_READ,      // ARM ops
        A_POLL,                                // RDSR WIP loop
        B_READ,                                // boot stream
        GAP                                    // CS-high inter-op gap
    } state_t;
    state_t state, post_gap;

    logic [39:0] hdr_sr;          // opcode(8) + addr(32)
    logic [5:0]  hdr_bits;        // header bits remaining
    logic [23:0] data_bytes;      // payload bytes remaining
    logic [2:0]  bit_cnt;         // bit within byte (7..0)
    logic [7:0]  rx_sr, tx_byte;
    logic [7:0]  buf_ptr;         // page/read buffer index
    logic        dir_write;       // 1 = payload from page_buffer
    logic        capture_rx;      // payload rx goes to read_buffer / stream
    logic        polling;         // current op is RDSR
    logic [1:0]  ckdiv;
    logic        sck_int;
    logic        stream_mode;     // rx bytes go to rd_byte port
    logic        data_phase;      // the current SCK pulse carries a DATA bit
                                  // (guards rx: the last header rising edge
                                  // must not be sampled as data)

    // SCK enable: SoM targets advance the engine every 2 clks (half SCK period
    // = 10 ns, SCK 50 MHz); the carrier target every 2^(CF_CKDIV_LOG2-1) clks.
    logic tick;
    logic [CF_CKDIV_LOG2-2:0] cf_div;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ckdiv  <= '0;
            cf_div <= '0;
        end else begin
            ckdiv  <= ckdiv + 2'd1;
            cf_div <= cf_div + 1'b1;
        end
    end
    assign tick = (sel_target == TGT_CARRIER) ? (&cf_div) : ckdiv[0];

    // Pause the stream (hold SCK low between bytes) on consumer back-pressure
    logic pause;
    assign pause = stream_mode && rd_stall && (bit_cnt == 3'd7) && !sck_int;

    // Command watchdog: counts while an ARM command is in flight; a hung or
    // absent flash (WIP never clears, MISO dead) aborts instead of wedging
    // cmd_busy forever.
    logic [31:0] wdt_cnt;
    logic        wdt_abort;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wdt_cnt   <= '0;
            wdt_abort <= 1'b0;
        end else begin
            wdt_abort <= 1'b0;
            if (!cmd_busy)
                wdt_cnt <= '0;
            else begin
                wdt_cnt <= wdt_cnt + 32'd1;
                if (wdt_cnt == WDT_CYCLES - 1)
                    wdt_abort <= 1'b1;
            end
        end
    end

    logic        op_start;        // FSM pulses to launch an op
    logic        op_busy;
    logic [39:0] op_hdr;
    logic [5:0]  op_hdr_bits;
    logic [23:0] op_bytes;
    logic        op_write, op_capture, op_stream;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            op_busy       <= 1'b0;
            sck_int       <= 1'b0;
            spi_mosi      <= 1'b0;
            spi_cs_n      <= 1'b1;
            rd_byte_valid <= 1'b0;
            bit_cnt       <= 3'd7;
            hdr_sr        <= '0;
            hdr_bits      <= '0;
            data_bytes    <= '0;
            buf_ptr       <= '0;
            rx_sr         <= '0;
            tx_byte       <= '0;
            dir_write     <= 1'b0;
            capture_rx    <= 1'b0;
            stream_mode   <= 1'b0;
            data_phase    <= 1'b0;
        end else begin
            rd_byte_valid <= 1'b0;
            if (wdt_abort && !stream_mode) begin
                // Watchdog abort: kill the in-flight ARM op, deselect flash
                op_busy  <= 1'b0;
                spi_cs_n <= 1'b1;
                sck_int  <= 1'b0;
            end else if (op_start) begin
                op_busy     <= 1'b1;
                spi_cs_n    <= 1'b0;
                sck_int     <= 1'b0;
                hdr_sr      <= op_hdr;
                hdr_bits    <= op_hdr_bits;
                data_bytes  <= op_bytes;
                dir_write   <= op_write;
                capture_rx  <= op_capture;
                stream_mode <= op_stream;
                bit_cnt     <= 3'd7;
                buf_ptr     <= '0;
                data_phase  <= 1'b0;
            end else if (op_busy && tick && !pause) begin
                if (!sck_int) begin
                    // SCK low phase: present next MOSI bit
                    if (hdr_bits != 0) begin
                        spi_mosi   <= hdr_sr[39];
                        hdr_sr     <= {hdr_sr[38:0], 1'b0};
                        hdr_bits   <= hdr_bits - 6'd1;
                        data_phase <= 1'b0;
                        sck_int    <= 1'b1;
                    end else if (data_bytes != 0) begin
                        data_phase <= 1'b1;
                        if (dir_write) begin
                            if (bit_cnt == 3'd7) tx_byte <= page_buffer[buf_ptr];
                            spi_mosi <= (bit_cnt == 3'd7) ? page_buffer[buf_ptr][7]
                                                          : tx_byte[bit_cnt];
                        end else begin
                            spi_mosi <= 1'b0;
                        end
                        sck_int <= 1'b1;
                    end else begin
                        // op complete
                        spi_cs_n <= 1'b1;
                        op_busy  <= 1'b0;
                    end
                end else begin
                    // SCK high phase: sample MISO, advance counters
                    sck_int <= 1'b0;
                    if (data_phase && data_bytes != 0) begin
                        rx_sr <= {rx_sr[6:0], spi_miso};
                        if (bit_cnt == 3'd0) begin
                            bit_cnt    <= 3'd7;
                            data_bytes <= data_bytes - 24'd1;
                            if (capture_rx) begin
                                if (stream_mode) begin
                                    rd_byte       <= {rx_sr[6:0], spi_miso};
                                    rd_byte_valid <= 1'b1;
                                end else begin
                                    read_buffer[buf_ptr] <= {rx_sr[6:0], spi_miso};
                                end
                            end
                            if (dir_write || !stream_mode)
                                buf_ptr <= buf_ptr + 8'd1;
                        end else begin
                            bit_cnt <= bit_cnt - 3'd1;
                        end
                    end
                end
            end
        end
    end

    assign spi_sck = sck_int;

    // ------------------------------------------------------------------------
    // Command FSM: sequences WREN / op / WIP-poll chains, arbitration.
    // Boot stream has absolute priority and Flash 1 (coef) only.
    // ------------------------------------------------------------------------
    logic [3:0] gap_cnt;
    logic       wip;
    logic       rd_req_d;    // edge detect: a new stream needs a fresh rising edge

    assign wip = rx_sr[0];   // last RDSR byte, bit0 = write-in-progress

    always_ff @(posedge clk) begin
        if (!rst_n) rd_req_d <= 1'b0;
        else        rd_req_d <= rd_req;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state      <= IDLE;
            post_gap   <= IDLE;
            cmd_busy   <= 1'b0;
            rd_active  <= 1'b0;
            rd_done    <= 1'b0;
            sel_target <= TGT_SOM1;
            cf_cs_sel  <= 2'd0;
            op_start   <= 1'b0;
            op_hdr     <= '0;
            op_hdr_bits<= '0;
            op_bytes   <= '0;
            op_write   <= 1'b0;
            op_capture <= 1'b0;
            op_stream  <= 1'b0;
            gap_cnt    <= '0;
            polling    <= 1'b0;
            cmd_err    <= 1'b0;
        end else begin
            op_start <= 1'b0;
            rd_done  <= 1'b0;
            cmd_err  <= 1'b0;

            if (wdt_abort) begin
                // Watchdog abort: release busy, flag error, return to IDLE
                state    <= IDLE;
                cmd_busy <= 1'b0;
                polling  <= 1'b0;
                cmd_err  <= 1'b1;
            end else
            case (state)
                IDLE: begin
                    cmd_busy  <= 1'b0;
                    rd_active <= 1'b0;
                    if (rd_req && !rd_req_d) begin
                        // Boot loader streaming read (SoM Flash 1 or carrier)
                        rd_active   <= 1'b1;
                        sel_target  <= rd_target ? TGT_CARRIER : TGT_SOM1;
                        cf_cs_sel   <= rd_addr[29:28];
                        op_hdr      <= {8'h13, dev_addr(rd_target ? TGT_CARRIER : TGT_SOM1, rd_addr)};
                        op_hdr_bits <= 6'd40;
                        op_bytes    <= rd_len;
                        op_write    <= 1'b0;
                        op_capture  <= 1'b1;
                        op_stream   <= 1'b1;
                        op_start    <= 1'b1;
                        state       <= B_READ;
                    end else if (cmd_trigger) begin
                        cmd_busy   <= 1'b1;
                        sel_target <= (cmd_target == 2'd3) ? TGT_CARRIER : cmd_target;
                        cf_cs_sel  <= cmd_addr[29:28];
                        case (cmd_opcode)
                            8'h01, 8'h02: begin
                                // WREN first
                                op_hdr      <= {8'h06, 32'd0};
                                op_hdr_bits <= 6'd8;
                                op_bytes    <= '0;
                                op_write    <= 1'b0;
                                op_capture  <= 1'b0;
                                op_stream   <= 1'b0;
                                op_start    <= 1'b1;
                                state       <= A_WREN;
                            end
                            8'h03: begin
                                op_hdr      <= {8'h13, dev_addr((cmd_target == 2'd3) ? TGT_CARRIER : cmd_target, cmd_addr)};
                                op_hdr_bits <= 6'd40;
                                op_bytes    <= 24'd256;
                                op_write    <= 1'b0;
                                op_capture  <= 1'b1;
                                op_stream   <= 1'b0;
                                op_start    <= 1'b1;
                                state       <= A_READ;
                            end
                            default: ;  // unknown opcode ignored
                        endcase
                    end
                end

                A_WREN: if (!op_busy && !op_start) begin
                    gap_cnt  <= 4'd8;
                    post_gap <= (cmd_opcode == 8'h01) ? A_ERASE : A_PROG;
                    state    <= GAP;
                end

                A_ERASE: if (!op_busy && !op_start) begin
                    gap_cnt  <= 4'd8;
                    post_gap <= A_POLL;
                    polling  <= 1'b0;
                    state    <= GAP;
                end

                A_PROG: if (!op_busy && !op_start) begin
                    gap_cnt  <= 4'd8;
                    post_gap <= A_POLL;
                    polling  <= 1'b0;
                    state    <= GAP;
                end

                A_POLL: if (!op_busy && !op_start) begin
                    if (polling && !wip) begin
                        state <= IDLE;             // program/erase complete
                    end else begin
                        polling  <= 1'b1;
                        gap_cnt  <= 4'd8;
                        post_gap <= A_POLL;
                        state    <= GAP;
                    end
                end

                A_READ: if (!op_busy && !op_start) state <= IDLE;

                B_READ: if (!op_busy && !op_start) begin
                    rd_done <= 1'b1;
                    state   <= IDLE;
                end

                GAP: begin
                    // CS-high recovery gap, then launch the queued op
                    if (gap_cnt != 0) gap_cnt <= gap_cnt - 4'd1;
                    else begin
                        case (post_gap)
                            A_ERASE: begin
                                op_hdr      <= {8'hDC, dev_addr(sel_target, cmd_addr)};
                                op_hdr_bits <= 6'd40;
                                op_bytes    <= '0;
                                op_write    <= 1'b0;
                                op_capture  <= 1'b0;
                            end
                            A_PROG: begin
                                op_hdr      <= {8'h12, dev_addr(sel_target, cmd_addr)};
                                op_hdr_bits <= 6'd40;
                                op_bytes    <= 24'd256;
                                op_write    <= 1'b1;
                                op_capture  <= 1'b0;
                            end
                            A_POLL: begin
                                op_hdr      <= {8'h05, 32'd0};
                                op_hdr_bits <= 6'd8;
                                op_bytes    <= 24'd1;
                                op_write    <= 1'b0;
                                op_capture  <= 1'b0;
                            end
                            default: ;
                        endcase
                        op_stream <= 1'b0;
                        op_start  <= 1'b1;
                        state     <= post_gap;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
