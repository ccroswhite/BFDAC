`timescale 1ns / 1ps

// =============================================================================
// ILA wrapper — conditionally instantiates an Integrated Logic Analyzer
//
// When ILA_EN is defined, the module exposes a probe port and instantiates the
// Vivado ILA IP.  When ILA_EN is not defined, it compiles away to nothing.
// Use this to capture debug signals on the SPI control plane and automute
// FSM without perturbing the production build.
// =============================================================================
module ila_wrapper #(
    parameter int PROBE_WIDTH = 32
)(
    input  logic                    clk,
    input  logic [PROBE_WIDTH-1:0]  probe
);

`ifdef ILA_EN
    ila_0 u_ila (
        .clk    (clk),
        .probe0 (probe)
    );
`else
    // Null implementation when ILA is disabled
    logic _unused_ok;
    assign _unused_ok = (probe == probe) && clk;
`endif

endmodule
