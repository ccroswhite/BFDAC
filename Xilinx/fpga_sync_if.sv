`timescale 1ns / 1ps

// fpga_sync_if — Inter-FPGA frame synchronisation interface.
//
// When frame_master=1 (FPGA-A / Left channel):
//   - Drives frame_sync_p/n as LVDS output via OBUFDS.
//   - Asserts sync_out for exactly one dsp_clk cycle each time
//     new_sample_valid pulses (i.e. 48 kHz rate).
//   - frame_sync_in_p/n pins are left undriven; tie IBUFDS output to zero.
//
// When frame_master=0 (FPGA-B / Right channel):
//   - Receives frame_sync_p/n via IBUFDS + 2-FF CDC into dsp_clk.
//   - Produces sync_in_pulse — a single dsp_clk-domain rising-edge pulse
//     that the top level uses as new_sample_valid for the DSP core.
//   - OBUFDS is present but its input is held 0 (no contention).
//
// Both OBUFDS and IBUFDS are always instantiated so the port list and
// pin assignments are identical on every board — only the logic is gated.
//
// XDC required:
//   set_property IOSTANDARD LVDS [get_ports frame_sync_*]
//   set_false_path -to [get_cells -hierarchical *sync_meta_reg*]

module fpga_sync_if (
    input  logic clk,           // dsp_clk
    input  logic rst_n,

    // Role (from dac_role_cfg, clk_49m -> registered into dsp_clk via false-path)
    input  logic frame_master,  // 1=TX master, 0=RX slave

    // From I2S ingress (master only)
    input  logic new_sample_valid,

    // To DSP core (slave only — replaces new_sample_valid)
    output logic sync_in_pulse,

    // Physical LVDS pins (always present on both FPGAs)
    output logic frame_sync_p,
    output logic frame_sync_n,
    input  logic frame_sync_in_p,
    input  logic frame_sync_in_n
);

    // =========================================================================
    // 1. TX path — active on master only
    // =========================================================================
    // One-cycle pulse out on new_sample_valid, held 0 otherwise.
    logic sync_tx;
    always_ff @(posedge clk) begin
        if (!rst_n)
            sync_tx <= 1'b0;
        else
            sync_tx <= frame_master ? new_sample_valid : 1'b0;
    end

    // OBUFDS always instantiated; drives 0 on slave (no pin contention —
    // the other FPGA's OBUFDS is tristated by holding its input 0).
    OBUFDS u_obufds (
        .I  (sync_tx),
        .O  (frame_sync_p),
        .OB (frame_sync_n)
    );

    // =========================================================================
    // 2. RX path — active on slave only
    //    IBUFDS always present; 2-FF CDC synchroniser; rising-edge detect.
    // =========================================================================
    logic sync_rx_raw;
    IBUFDS u_ibufds (
        .I  (frame_sync_in_p),
        .IB (frame_sync_in_n),
        .O  (sync_rx_raw)
    );

    (* ASYNC_REG = "TRUE" *) logic sync_meta, sync_sync, sync_prev;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sync_meta <= 1'b0;
            sync_sync <= 1'b0;
            sync_prev <= 1'b0;
        end else begin
            sync_meta <= sync_rx_raw;
            sync_sync <= sync_meta;
            sync_prev <= sync_sync;
        end
    end

    // Rising-edge detect, gated off on master (master uses new_sample_valid directly)
    assign sync_in_pulse = (~frame_master) & sync_sync & ~sync_prev;

endmodule
