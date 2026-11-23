`timescale 1ns / 1ps

// Two 32-bit I2S slots, upper 24 bits used. Clocks continue without source_valid.
// Return DATA is captured in dsp_clk using delayed, tagged launch events.
// rx_trim adds DSP cycles to the nominal half-bit sampling position. It is
// changed only while muted and must be qualified against isolator/AP timing.
//
// DUAL SOURCE (2026-11-20): i2s_data = XMOS stream, i2s_data2 = AP McASP0
// stream — both slave-TX on the shared FPGA-generated BCLK/LRCLK (Option A).
// Each source pin has a dedicated 2-FF ASYNC_REG chain and src_sel muxes the
// SYNCHRONIZED outputs inside dsp_clk; a select change flushes the pipeline
// and re-arms framing, so the first sample of the new source is always a
// complete frame (no torn words). rx_trim is per-source from the register
// map (the two return paths have different isolator channels + serializers).
// The control plane mutes across the switch.
module i2s_master_ingress (
    input logic dsp_clk, cell_clk, rst_n, enable, source_valid,
    input logic [1:0] rate_shift,
    input logic [4:0] rx_trim,
    input logic src_sel,
    input logic i2s_data, i2s_data2,
    output logic i2s_bclk, i2s_lrclk,
    output logic [23:0] audio_l, audio_r,
    output logic new_sample, i2s_err, transport_fault, audio_frame_ready
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] cell_reset, enable_cell;
    logic [3:0] half_count;
    logic [5:0] next_bit, launch_bit;
    logic launch_toggle;
    wire [3:0] half_period = 4'd8 >> rate_shift;

    always_ff @(posedge cell_clk or negedge rst_n) begin
        if (!rst_n) begin cell_reset <= 0; enable_cell <= 0; end
        else begin
            cell_reset <= {cell_reset[0], 1'b1};
            enable_cell <= {enable_cell[0], enable};
        end
    end
    always_ff @(posedge cell_clk or negedge rst_n) begin
        if (!rst_n) begin
            half_count <= 0; next_bit <= 63; launch_bit <= 63;
            launch_toggle <= 0; i2s_bclk <= 0; i2s_lrclk <= 1;
        end else if (!cell_reset[1] || !enable_cell[1]) begin
            half_count <= 0; next_bit <= 63; launch_bit <= 63;
            launch_toggle <= 0; i2s_bclk <= 0; i2s_lrclk <= 1;
        end else if (half_count == half_period - 1) begin
            half_count <= 0;
            i2s_bclk <= ~i2s_bclk;
            if (i2s_bclk) begin
                launch_bit <= next_bit;
                launch_toggle <= ~launch_toggle;
                next_bit <= next_bit + 1'b1;
                if (next_bit == 63) i2s_lrclk <= 0;
                if (next_bit == 31) i2s_lrclk <= 1;
            end
        end else half_count <= half_count + 1'b1;
    end

    (* ASYNC_REG = "TRUE" *) logic [2:0] launch_sync;
    (* ASYNC_REG = "TRUE" *) logic [1:0] data_sync, data2_sync, enable_sync, valid_sync, sel_sync;
    (* ASYNC_REG = "TRUE" *) logic [4:0] trim_meta, trim_sync;
    logic [4:0] trim_applied;
    logic sel_applied;
    // Max capture delay: rate_shift=0 gives 46 + rx_trim[4:0](max 31) = 77
    localparam int PIPE_DEPTH = 78;
    logic [PIPE_DEPTH-1:0] sample_pipe;
    // Stage 0 is the CDC capture point for the cell_clk launch_bit bus and is
    // named in the XDC; KEEP/shreg_extract=no prevents Vivado folding it into
    // an SRL32 with stages 1..77 (SRLs have poor CDC characteristics and would
    // break the get_cells pattern). tag_pipe[0] is left unused.
    (* KEEP = "TRUE", shreg_extract = "no" *) logic [5:0] tag_pipe_0;
    logic [5:0] tag_pipe [PIPE_DEPTH];
    logic [31:0] serial_word;
    logic [23:0] left_word;
    logic [5:0] expected_bit;
    logic frame_armed, cadence_fault;
    logic [13:0] watchdog;
    logic [6:0] delay_cycles;
    wire launch_event = launch_sync[2] ^ launch_sync[1];
    wire capture = sample_pipe[delay_cycles];
    wire [5:0] capture_bit = (delay_cycles == 0) ? tag_pipe_0 : tag_pipe[delay_cycles];
    // Source mux AFTER the per-pin synchronizers: muxing async pins ahead of
    // data_sync[0] would put a cross-domain control net in front of the
    // metastability stage (glitch can carry the wrong source's bit).
    wire data_bit = sel_sync[1] ? data2_sync[1] : data_sync[1];
    wire [31:0] shifted_word = {serial_word[30:0], data_bit};
    wire [13:0] watchdog_limit = (14'd11704 >> rate_shift) + 14'd128;
    assign i2s_err = !valid_sync[1] || cadence_fault;
    assign transport_fault = cadence_fault;

    always_comb begin
        case (rate_shift)
            0: delay_cycles = 7'd46 + {2'd0, trim_applied};
            1: delay_cycles = 7'd23 + {2'd0, trim_applied};
            2: delay_cycles = 7'd11 + {2'd0, trim_applied};
            3: delay_cycles = 7'd6  + {2'd0, trim_applied};
        endcase
    end
    always_ff @(posedge dsp_clk or negedge rst_n) begin
        if (!rst_n) begin
            launch_sync <= 0; data_sync <= 0; data2_sync <= 0;
            enable_sync <= 0; valid_sync <= 0;
            sel_sync <= 0; sel_applied <= 0;
            trim_meta <= 0; trim_sync <= 0; trim_applied <= 0;
            tag_pipe_0 <= 0;
            sample_pipe <= 0; serial_word <= 0; left_word <= 0;
            expected_bit <= 0; frame_armed <= 0; cadence_fault <= 0;
            watchdog <= 0; audio_l <= 0; audio_r <= 0; new_sample <= 0;
            audio_frame_ready <= 0;
            for (int i = 0; i < PIPE_DEPTH; i++) tag_pipe[i] <= 0;
        end else begin
            launch_sync <= {launch_sync[1:0], launch_toggle};
            sel_sync <= {sel_sync[0], src_sel};
            data_sync  <= {data_sync[0],  i2s_data};
            data2_sync <= {data2_sync[0], i2s_data2};
            enable_sync <= {enable_sync[0], enable};
            valid_sync <= {valid_sync[0], source_valid};
            trim_meta <= rx_trim;
            trim_sync <= trim_meta;
            new_sample <= 0;
            sample_pipe <= {sample_pipe[PIPE_DEPTH-2:0], launch_event};
            if (launch_event) tag_pipe_0 <= launch_bit;
            tag_pipe[1] <= tag_pipe_0;
            for (int i = 2; i < PIPE_DEPTH; i++) tag_pipe[i] <= tag_pipe[i-1];
            if (!enable_sync[1]) begin
                sample_pipe <= 0; frame_armed <= 0; expected_bit <= 0;
                watchdog <= 0; cadence_fault <= 0;
                audio_frame_ready <= 0;
                audio_l <= 0; audio_r <= 0;
            end else begin
                if (watchdog < watchdog_limit) watchdog <= watchdog + 1'b1;
                else cadence_fault <= 1;
                if (capture) begin
                    serial_word <= shifted_word;
                    if (capture_bit == 0 && !frame_armed) begin
                        frame_armed <= 1;
                        expected_bit <= 1;
                    end else if (frame_armed) begin
                        if (capture_bit != expected_bit) cadence_fault <= 1;
                        expected_bit <= capture_bit + 1'b1;
                    end
                    if (capture_bit == 31) left_word <= shifted_word[31:8];
                    if (capture_bit == 63 && frame_armed) begin
                        audio_l <= valid_sync[1] ? left_word : 24'd0;
                        audio_r <= valid_sync[1] ? shifted_word[31:8] : 24'd0;
                        new_sample <= 1;
                        if (valid_sync[1]) audio_frame_ready <= 1;
                        watchdog <= 0;
                    end
                end
            end
            if (trim_sync != trim_applied || sel_sync[1] != sel_applied) begin
                // Quasi-static bus: a per-bit skew during a multi-bit trim
                // change can compare-mismatch on a transient value, but the
                // compare self-corrects next cycle and every apply flushes +
                // re-arms anyway — converges within ~1 dsp_clk of the bus
                // settling. Trim only changes while muted per contract.
                trim_applied <= trim_sync;
                sel_applied <= sel_sync[1];
                sample_pipe <= 0;
                frame_armed <= 0;
                expected_bit <= 0;
                watchdog <= 0;
                cadence_fault <= 0;
                new_sample <= 0;
                audio_frame_ready <= 0;
            end
        end
    end
endmodule
