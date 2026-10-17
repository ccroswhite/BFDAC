`timescale 1ns / 1ps

// Two 32-bit I2S slots, upper 24 bits used. Clocks continue without source_valid.
// Return DATA is captured in dsp_clk using delayed, tagged launch events.
// rx_trim adds DSP cycles to the nominal half-bit sampling position. It is
// changed only while muted and must be qualified against isolator/AP timing.
module i2s_master_ingress (
    input logic dsp_clk, cell_clk, rst_n, enable, source_valid,
    input logic [1:0] rate_shift,
    input logic [4:0] rx_trim,
    input logic i2s_data,
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
    (* ASYNC_REG = "TRUE" *) logic [1:0] data_sync, enable_sync, valid_sync;
    (* ASYNC_REG = "TRUE" *) logic [4:0] trim_meta, trim_sync;
    logic [4:0] trim_applied;
    logic [95:0] sample_pipe;
    logic [5:0] tag_pipe [96];
    logic [31:0] serial_word;
    logic [23:0] left_word;
    logic [5:0] expected_bit;
    logic frame_armed, cadence_fault;
    logic [13:0] watchdog;
    logic [6:0] delay_cycles;
    wire launch_event = launch_sync[2] ^ launch_sync[1];
    wire capture = sample_pipe[delay_cycles];
    wire [5:0] capture_bit = tag_pipe[delay_cycles];
    wire [31:0] shifted_word = {serial_word[30:0], data_sync[1]};
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
            launch_sync <= 0; data_sync <= 0; enable_sync <= 0; valid_sync <= 0;
            trim_meta <= 0; trim_sync <= 0; trim_applied <= 0;
            sample_pipe <= 0; serial_word <= 0; left_word <= 0;
            expected_bit <= 0; frame_armed <= 0; cadence_fault <= 0;
            watchdog <= 0; audio_l <= 0; audio_r <= 0; new_sample <= 0;
            audio_frame_ready <= 0;
            for (int i = 0; i < 96; i++) tag_pipe[i] <= 0;
        end else begin
            launch_sync <= {launch_sync[1:0], launch_toggle};
            data_sync <= {data_sync[0], i2s_data};
            enable_sync <= {enable_sync[0], enable};
            valid_sync <= {valid_sync[0], source_valid};
            trim_meta <= rx_trim;
            trim_sync <= trim_meta;
            new_sample <= 0;
            sample_pipe <= {sample_pipe[94:0], launch_event};
            if (launch_event) tag_pipe[0] <= launch_bit;
            for (int i = 1; i < 96; i++) tag_pipe[i] <= tag_pipe[i-1];
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
            if (trim_sync != trim_applied) begin
                trim_applied <= trim_sync;
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
