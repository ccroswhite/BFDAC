`timescale 1ns / 1ps

// =============================================================================
// QSPI Boot Loader (2026-08-22 ruling: FPGA boots on its own)
//
// Autonomous after configuration: once STARTUPE3.EOS and the MIG's
// init_calib_complete are both up, walks the coefficient record chain and
// stages every record into DDR4, CRC-checked. No ARM involvement;
// coef_ready gates the FIR coefficient loader (dac_coef_subsys filter loads).
//
// Boot source (2026-10-05, bom item 18a): with BOOT_FROM_CARRIER = 1 the chain
// is read from the carrier coefficient flash first (rd_target = 1). If the
// very first header there carries no magic (device absent, erased or
// unprogrammed) the loader restarts once from SoM Flash 1 (rd_target = 0).
// boot_src reports which device the chain came from. A magic mismatch AFTER
// at least one record is the normal end-of-chain on either device.
//
// Flash record format (16-byte header, little-endian fields, packed records):
//   [0]  magic     32'h42464443 ("BFDC")  — 32'hFFFFFFFF (erased) = end chain
//   [4]  dest_addr 32-bit DDR4 BYTE address (16-byte aligned)
//   [8]  length    32-bit payload bytes (multiple of 16, > 0)
//   [12] crc32     IEEE 802.3 (reflected, init 0xFFFFFFFF, final XOR) over
//                  the payload bytes
//   [16] payload...            next record follows immediately after
//
// Domains: flash side (qspi_flash_ctrl stream) = clk (200 MHz ctrl clock);
// AXI write master = ui_clk (MIG, 300 MHz). Payload crosses on a 16-deep
// 128-bit gray-pointer async FIFO; per-record job/done use toggle handshakes.
// =============================================================================
module qspi_boot_loader #(
    parameter logic [31:0] MAGIC             = 32'h42464443,
    parameter bit          BOOT_FROM_CARRIER = 1'b1
) (
    // --- clk (ctrl, 200 MHz) domain -------------------------------------------
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,          // level: EOS && init_calib_complete (synced)

    // qspi_flash_ctrl streaming port
    output logic        rd_req,
    output logic        rd_target,      // 0 = SoM Flash 1, 1 = carrier flash
    output logic [31:0] rd_addr,
    output logic [23:0] rd_len,
    output logic        rd_stall,
    input  logic        rd_active,
    input  logic [7:0]  rd_byte,
    input  logic        rd_byte_valid,
    input  logic        rd_done,

    // Status (clk domain, quasi-static once boot_done)
    output logic        boot_done,
    output logic        boot_ok,        // all records staged, CRCs pass
    output logic        crc_fail,
    output logic        axi_fail,
    output logic [7:0]  record_count,
    output logic        boot_src,       // device the chain was read from (== rd_target)

    // --- ui_clk (MIG) domain ---------------------------------------------------
    input  logic        ui_clk,
    input  logic        ui_rst,         // active high (ui_clk_sync_rst)

    // AXI4 write master (128-bit, to dac_ddr4_if)
    output logic [29:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [127:0] m_axi_wdata,
    output logic [15:0]  m_axi_wstrb,
    output logic         m_axi_wlast,
    output logic         m_axi_wvalid,
    input  logic         m_axi_wready,
    input  logic [1:0]   m_axi_bresp,
    input  logic         m_axi_bvalid,
    output logic         m_axi_bready
);

    localparam int BURST_BEATS = 16;   // 16 x 16 B = 256 B per AXI burst

    // =========================================================================
    // Async FIFO: 16 x 128b, clk -> ui_clk, gray-coded pointers
    // =========================================================================
    logic [127:0] fifo_mem [0:15];
    logic [4:0]   wptr_bin, rptr_bin;                  // 1 extra bit for full
    logic [4:0]   wptr_gray, rptr_gray;
    (* ASYNC_REG = "TRUE" *) logic [4:0] wptr_gray_ui1, wptr_gray_ui2;
    (* ASYNC_REG = "TRUE" *) logic [4:0] rptr_gray_c1,  rptr_gray_c2;

    function automatic logic [4:0] bin2gray(input logic [4:0] b);
        return b ^ (b >> 1);
    endfunction
    function automatic logic [4:0] gray2bin(input logic [4:0] g);
        logic [4:0] b;
        b[4] = g[4];
        for (int i = 3; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    logic fifo_full, fifo_empty;
    logic fifo_we;
    logic [127:0] fifo_wdata;

    assign fifo_full = (bin2gray(wptr_bin + 5'd1) == rptr_gray_c2);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr_bin  <= '0;
            wptr_gray <= '0;
        end else if (fifo_we && !fifo_full) begin
            fifo_mem[wptr_bin[3:0]] <= fifo_wdata;
            wptr_bin  <= wptr_bin + 5'd1;
            wptr_gray <= bin2gray(wptr_bin + 5'd1);
        end
        {rptr_gray_c2, rptr_gray_c1} <= {rptr_gray_c1, rptr_gray};
    end

    logic fifo_re;
    logic [127:0] fifo_rdata;
    assign fifo_empty = (rptr_gray == wptr_gray_ui2);
    assign fifo_rdata = fifo_mem[rptr_bin[3:0]];

    always_ff @(posedge ui_clk) begin
        if (ui_rst) begin
            rptr_bin  <= '0;
            rptr_gray <= '0;
        end else if (fifo_re && !fifo_empty) begin
            rptr_bin  <= rptr_bin + 5'd1;
            rptr_gray <= bin2gray(rptr_bin + 5'd1);
        end
        {wptr_gray_ui2, wptr_gray_ui1} <= {wptr_gray_ui1, wptr_gray};
    end

    // Stall the flash stream when the FIFO is nearly full (2-word headroom
    // for the byte->word packer in flight). REGISTERED (2026-08-23, f12 WNS
    // path): gray2bin + subtract + compare was combinational from the
    // rptr_gray_c2 sync FFs into the flash_ctrl byte FSM (5 LUT levels,
    // route-dominated, -74 ps). One clk of stall latency is harmless: stall
    // acts at byte boundaries (~16 clk/byte from flash) and the >=13
    // threshold keeps 3 words of headroom vs the 2 required.
    logic [4:0] wlevel;
    assign wlevel = wptr_bin - gray2bin(rptr_gray_c2);
    always_ff @(posedge clk) begin
        if (!rst_n) rd_stall <= 1'b0;
        else        rd_stall <= (wlevel >= 5'd13);
    end

    // =========================================================================
    // Job handshake clk -> ui_clk: {dest_addr, word_count} per record
    // =========================================================================
    logic        job_toggle;                  // clk domain
    (* ASYNC_REG = "TRUE" *) logic [2:0] job_sync_ui;
    logic        job_pulse_ui;
    logic [29:0] job_addr;                    // stable when toggle flips
    logic [23:0] job_words;                   // 128-bit words

    logic        done_toggle_ui;              // ui_clk domain
    (* ASYNC_REG = "TRUE" *) logic [2:0] done_sync_c;
    logic        done_pulse_c;
    logic        job_err_ui;                  // sticky per job, sampled at done

    always_ff @(posedge ui_clk) job_sync_ui <= {job_sync_ui[1:0], job_toggle};
    assign job_pulse_ui = job_sync_ui[2] ^ job_sync_ui[1];

    always_ff @(posedge clk) done_sync_c <= {done_sync_c[1:0], done_toggle_ui};
    assign done_pulse_c = done_sync_c[2] ^ done_sync_c[1];

    // job_err is quasi-static at the done toggle; 2-FF resample
    (* ASYNC_REG = "TRUE" *) logic [1:0] job_err_sync;
    always_ff @(posedge clk) job_err_sync <= {job_err_sync[0], job_err_ui};

    // =========================================================================
    // Flash-side FSM (clk domain): header parse, CRC32, byte->word pack
    // =========================================================================
    typedef enum logic [2:0] {
        F_WAIT, F_HDR_REQ, F_HDR_RX, F_EVAL,
        F_PAY_REQ, F_PAY_RX, F_JOB_WAIT, F_DONE
    } fstate_t;
    fstate_t fst;

    logic [31:0] cur_addr;          // flash byte address
    logic        fallback_done;     // carrier -> SoM Flash 1 retry used
    logic [127:0] hdr_acc;          // 16 header bytes
    logic [4:0]  hdr_cnt;
    logic [31:0] rec_dest, rec_len, rec_crc;
    logic [31:0] crc;
    logic [3:0]  pack_cnt;
    logic [127:0] pack_sr;

    // CRC32 (IEEE 802.3, reflected): process one byte
    function automatic logic [31:0] crc32_byte(input logic [31:0] c, input logic [7:0] d);
        logic [31:0] x;
        x = c ^ {24'd0, d};
        for (int i = 0; i < 8; i++)
            x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
        return x;
    endfunction

    assign fifo_wdata = pack_sr;
    assign boot_src   = rd_target;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fst          <= F_WAIT;
            rd_req       <= 1'b0;
            rd_target    <= BOOT_FROM_CARRIER;
            fallback_done <= 1'b0;
            rd_addr      <= '0;
            rd_len       <= '0;
            cur_addr     <= '0;
            hdr_cnt      <= '0;
            hdr_acc      <= '0;
            crc          <= '0;
            pack_cnt     <= '0;
            pack_sr      <= '0;
            fifo_we      <= 1'b0;
            job_toggle   <= 1'b0;
            job_addr     <= '0;
            job_words    <= '0;
            boot_done    <= 1'b0;
            boot_ok      <= 1'b0;
            crc_fail     <= 1'b0;
            axi_fail     <= 1'b0;
            record_count <= '0;
            rec_dest     <= '0;
            rec_len      <= '0;
            rec_crc      <= '0;
        end else begin
            fifo_we <= 1'b0;

            case (fst)
                F_WAIT: if (start) begin
                    cur_addr      <= 32'd0;
                    rd_target     <= BOOT_FROM_CARRIER;
                    fallback_done <= 1'b0;
                    fst           <= F_HDR_REQ;
                end

                F_HDR_REQ: begin
                    rd_addr <= cur_addr;
                    rd_len  <= 24'd16;
                    rd_req  <= 1'b1;
                    hdr_cnt <= '0;
                    if (rd_active) fst <= F_HDR_RX;
                end

                F_HDR_RX: begin
                    if (rd_byte_valid) begin
                        hdr_acc <= {rd_byte, hdr_acc[127:8]};  // little-endian pack
                        hdr_cnt <= hdr_cnt + 5'd1;
                    end
                    if (rd_done) begin
                        rd_req <= 1'b0;
                        fst    <= F_EVAL;
                    end
                end

                F_EVAL: begin
                    // hdr_acc = {crc32, length, dest_addr, magic} (LE fields)
                    // Parse is the if-true branch so an unknown header (absent
                    // carrier device -> floating MISO in sim) falls into the
                    // fallback / end-of-chain branch rather than parsing.
                    if (hdr_acc[31:0] == MAGIC) begin
                        rec_dest <= hdr_acc[63:32];
                        rec_len  <= hdr_acc[95:64];
                        rec_crc  <= hdr_acc[127:96];
                        crc      <= 32'hFFFFFFFF;
                        pack_cnt <= '0;
                        // Launch the ui_clk write job for this record
                        job_addr   <= hdr_acc[61:32];              // byte addr, 30-bit
                        job_words  <= hdr_acc[95:68];              // len/16 words
                        job_toggle <= ~job_toggle;
                        fst        <= F_PAY_REQ;
                    end else if (rd_target && record_count == 8'd0 && !fallback_done) begin
                        // Carrier flash has no chain: retry once from SoM Flash 1
                        fallback_done <= 1'b1;
                        rd_target     <= 1'b0;
                        cur_addr      <= 32'd0;
                        fst           <= F_HDR_REQ;
                    end else begin
                        // End of chain (erased flash or any non-magic)
                        boot_ok   <= !crc_fail && !axi_fail && (record_count != 0);
                        boot_done <= 1'b1;
                        fst       <= F_DONE;
                    end
                end

                F_PAY_REQ: begin
                    rd_addr <= cur_addr + 32'd16;
                    rd_len  <= rec_len[23:0];
                    rd_req  <= 1'b1;
                    if (rd_active) fst <= F_PAY_RX;
                end

                F_PAY_RX: begin
                    if (rd_byte_valid) begin
                        crc      <= crc32_byte(crc, rd_byte);
                        pack_sr  <= {rd_byte, pack_sr[127:8]};
                        if (pack_cnt == 4'd15) begin
                            fifo_we  <= 1'b1;   // pack_sr completes this cycle
                            pack_cnt <= 4'd0;
                        end else begin
                            pack_cnt <= pack_cnt + 4'd1;
                        end
                    end
                    if (rd_done) begin
                        rd_req <= 1'b0;
                        if ((crc ^ 32'hFFFFFFFF) != rec_crc) crc_fail <= 1'b1;
                        fst <= F_JOB_WAIT;
                    end
                end

                F_JOB_WAIT: if (done_pulse_c) begin
                    if (job_err_sync[1]) axi_fail <= 1'b1;
                    record_count <= record_count + 8'd1;
                    cur_addr     <= cur_addr + 32'd16 + rec_len;
                    fst          <= F_HDR_REQ;
                end

                F_DONE: ;  // terminal; status registers hold

                default: fst <= F_WAIT;
            endcase
        end
    end

    // =========================================================================
    // AXI write master (ui_clk domain): drains FIFO in 16-beat bursts
    // =========================================================================
    typedef enum logic [2:0] { W_IDLE, W_ADDR, W_DATA, W_RESP, W_NOTIFY } wstate_t;
    wstate_t wst;

    logic [29:0] w_addr;
    logic [23:0] w_words_left;
    logic [4:0]  w_beats_left;    // beats remaining in the current burst
    logic [4:0]  w_burst_beats;

    assign m_axi_awsize  = 3'b100;   // 16 bytes/beat
    assign m_axi_awburst = 2'b01;    // INCR
    assign m_axi_wstrb   = 16'hFFFF;
    assign m_axi_bready  = 1'b1;
    assign m_axi_wdata   = fifo_rdata;

    assign fifo_re = (wst == W_DATA) && m_axi_wvalid && m_axi_wready;
    assign m_axi_wvalid = (wst == W_DATA) && !fifo_empty;
    assign m_axi_wlast  = (wst == W_DATA) && (w_beats_left == 5'd1);

    always_ff @(posedge ui_clk) begin
        if (ui_rst) begin
            wst            <= W_IDLE;
            m_axi_awvalid  <= 1'b0;
            m_axi_awaddr   <= '0;
            m_axi_awlen    <= '0;
            w_addr         <= '0;
            w_words_left   <= '0;
            w_beats_left   <= '0;
            w_burst_beats  <= '0;
            done_toggle_ui <= 1'b0;
            job_err_ui     <= 1'b0;
        end else begin
            case (wst)
                W_IDLE: if (job_pulse_ui) begin
                    w_addr       <= job_addr;      // stable: toggle-synced bus
                    w_words_left <= job_words;
                    job_err_ui   <= 1'b0;
                    wst          <= W_ADDR;
                end

                W_ADDR: begin
                    if (w_words_left == 0) begin
                        done_toggle_ui <= ~done_toggle_ui;
                        wst            <= W_IDLE;
                    end else begin
                        w_burst_beats <= (w_words_left >= BURST_BEATS[23:0])
                                         ? 5'(BURST_BEATS) : w_words_left[4:0];
                        m_axi_awaddr  <= w_addr;
                        m_axi_awlen   <= (w_words_left >= BURST_BEATS[23:0])
                                         ? 8'(BURST_BEATS - 1)
                                         : 8'(w_words_left[4:0] - 5'd1);
                        m_axi_awvalid <= 1'b1;
                        wst           <= W_DATA;
                        w_beats_left  <= (w_words_left >= BURST_BEATS[23:0])
                                         ? 5'(BURST_BEATS) : w_words_left[4:0];
                    end
                end

                W_DATA: begin
                    if (m_axi_awvalid && m_axi_awready) m_axi_awvalid <= 1'b0;
                    if (m_axi_wvalid && m_axi_wready) begin
                        w_beats_left <= w_beats_left - 5'd1;
                        if (w_beats_left == 5'd1) wst <= W_RESP;
                    end
                end

                W_RESP: if (m_axi_bvalid) begin
                    if (m_axi_bresp != 2'b00) job_err_ui <= 1'b1;
                    w_addr       <= w_addr + 30'(w_burst_beats) * 30'd16;
                    w_words_left <= w_words_left - 24'(w_burst_beats);
                    wst          <= W_ADDR;
                end

                default: wst <= W_IDLE;
            endcase
        end
    end

endmodule
