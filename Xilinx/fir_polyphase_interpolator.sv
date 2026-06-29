`timescale 1ns / 1ps

// Mono polyphase FIR interpolator — TRUE x16 polyphase interpolation.
//
// Architecture: Parameterized NUM_MACS adder-tree reduction (256 to 4096+).
//
//   Phase 1 - Audio Preload (NUM_MACS+1 = 257 cycles):
//     At new_sample_valid, sequentially read audio_bram and fill
//     audio_shreg[0..NUM_MACS-1] so that audio_shreg[m] = x[n-m].
//
//   Phase 2 - Coefficient Sweep (NUM_PHASES*TAPS_PER_PHASE cycles):
//     Each MAC m receives audio_shreg[m] = x[n-m] as a STATIC input.
//     phase_sync_d1 broadcast to all NUM_MACS simultaneously.
//     Each MAC accumulates independently (NO PCIN/PCOUT cascade).
//     preg_out[m] connects to polyphase_adder_tree for log2(NUM_MACS)-level reduction.
//
//   Shadow trigger: phase_sync_d1 + 5 (MAC pipe) + tree_levels + 1 cycles.
//   Phase window scales: 128 cycles (256 MACs) to 2048 cycles (4096 MACs) @ 44.1k/357MHz.
//
//   Phase p output: y[n*16+p] = 2 * sum_{m=0}^{NUM_MACS-1} h[p+m*16] * x[n-m]
//
//   Total cycle budget: (NUM_MACS+1) (preload) + (NUM_PHASES*TAPS_PER_PHASE) (sweep).
//   At 48 kHz / 400 MHz: ~8333 cycles available. Example: 256 MACs uses 2305 cycles (28%).
//
// Coefficient BRAMs are NOT owned here -- shared at fir_polyphase_stereo level.
module fir_polyphase_interpolator #(
    parameter int NUM_MACS        = 4096,        // Scalable: 256, 512, 1024, 2048, 4096
    parameter int DATA_WIDTH      = 24,
    parameter int COEF_WIDTH      = 18,
    parameter int ACC_WIDTH       = 48,
    parameter int NUM_PHASES      = 16,
    parameter int TAPS_PER_PHASE  = 64          // 4K MACs * 16 * 64 = 4,194,304 taps (4M)
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // Baseband Input
    input  logic                                 new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]         new_sample_data,

    // Oversampled Output
    output logic signed [ACC_WIDTH-1:0]          interpolated_out,
    output logic                                 interpolated_valid,

    // -- Coefficient input from shared BRAMs (one value per MAC per cycle) --
    input  logic signed [COEF_WIDTH-1:0]         coef_in [0:NUM_MACS-1],

    // -- Coefficient address output (to drive shared BRAM read port) --------
    output logic [$clog2(NUM_PHASES*TAPS_PER_PHASE)-1:0] coef_addr_out
);

    localparam int COEF_DEPTH = NUM_PHASES * TAPS_PER_PHASE;

    // =================================---------------------------------------
    // 1. Audio History BRAM  (single-port, depth NUM_MACS)
    //    Write: on new_sample_valid, store new_sample_data at write_ptr.
    //    Read:  during preload phase, sequential addresses write_ptr..write_ptr-(NUM_MACS-1).
    // =================================---------------------------------------
    logic [$clog2(NUM_MACS)-1:0] write_ptr;

    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram [0:NUM_MACS-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < NUM_MACS; init_i = init_i + 1)
            audio_bram[init_i] = '0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            write_ptr <= '0;
        else if (new_sample_valid)
            write_ptr <= write_ptr + $clog2(NUM_MACS)'(1);
    end

    always_ff @(posedge clk) begin
        if (new_sample_valid)
            audio_bram[write_ptr] <= new_sample_data;
    end

    // =================================---------------------------------------
    // 2. Audio Preload State Machine + Shift Register
    //
    //    States:
    //      IDLE     : waiting for new_sample_valid
    //      PRELOAD  : reading audio_bram for NUM_MACS+1 cycles, filling shreg
    //      SWEEP    : COEF_DEPTH-cycle coef sweep with frozen audio_shreg
    //
    //    Timing:
    //      Cycle 0  (IDLE → PRELOAD): new_sample_valid asserted.
    //               Audio write at write_ptr (old value, pre-increment).
    //               preload_addr <= write_ptr (old).
    //      Cycle 1..NUM_MACS: BRAM read latency = 1 cycle (single registered output).
    //               At cycle k (k=1..NUM_MACS): audio_bram_out = x[n-(k-1)].
    //               Loaded into audio_shreg[k-1].
    //      After NUM_MACS+1 cycles: audio_shreg[m] = x[n-m] for m=0..NUM_MACS-1. ✓
    //      SWEEP begins: master_coef_addr sweeps 0..COEF_DEPTH-1, phase windows fire.
    // =================================---------------------------------------
    typedef enum logic [1:0] { ST_IDLE, ST_PRELOAD, ST_SWEEP } state_t;
    state_t state;

    logic [$clog2(NUM_MACS)-1:0] preload_addr;    // BRAM read address during preload
    logic [$clog2(NUM_MACS+1)-1:0] preload_cnt;     // 0..NUM_MACS (13 bits for 4096)
    logic signed [DATA_WIDTH-1:0] bram_rd;   // registered BRAM output (1-cycle latency)

    // Registered BRAM read (1-cycle latency)
    always_ff @(posedge clk) begin
        bram_rd <= audio_bram[preload_addr];
    end

    // Audio shift register: audio_shreg[m] = x[n-m] after preload completes.
    logic signed [DATA_WIDTH-1:0] audio_shreg [0:NUM_MACS-1];

    integer shreg_i;
    initial begin
        for (shreg_i = 0; shreg_i < NUM_MACS; shreg_i = shreg_i + 1)
            audio_shreg[shreg_i] = '0;
    end

    // Preload sequencing:
    //   preload_cnt runs 0..NUM_MACS (NUM_MACS+1 total cycles in ST_PRELOAD).
    //   cnt=0 : address = write_ptr issued; no shreg write (bram_rd not valid yet).
    //   cnt=1 : bram_rd = x[n]      → shreg[0]. Next addr = write_ptr-1.
    //   cnt=2 : bram_rd = x[n-1]    → shreg[1]. Next addr = write_ptr-2.
    //   ...
    //   cnt=k : bram_rd = x[n-(k-1)]→ shreg[k-1].
    //   cnt=NUM_MACS: bram_rd = x[n-(NUM_MACS-1)] → shreg[NUM_MACS-1]. → ST_SWEEP.

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            preload_addr <= '0;
            preload_cnt  <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (new_sample_valid) begin
                        preload_addr <= write_ptr;  // x[n] at write_ptr (pre-increment)
                        preload_cnt  <= '0;
                        state        <= ST_PRELOAD;
                    end
                end

                ST_PRELOAD: begin
                    preload_cnt <= preload_cnt + 1;
                    // Issue address for the NEXT read (cnt+1 samples back)
                    if (preload_cnt < $clog2(NUM_MACS+1)'(NUM_MACS))
                        preload_addr <= write_ptr - $clog2(NUM_MACS)'(preload_cnt + 2);
                    // Write bram_rd result from the PREVIOUS address into shreg.
                    // At cnt=k (k>=1): bram_rd = audio_bram[write_ptr-(k-1)] = x[n-(k-1)].
                    if (preload_cnt >= 1)
                        audio_shreg[preload_cnt - 1] <= bram_rd;
                    // Transition after the last write (cnt==NUM_MACS → shreg[NUM_MACS-1] written)
                    if (preload_cnt == $clog2(NUM_MACS+1)'(NUM_MACS))
                        state <= ST_SWEEP;
                end

                ST_SWEEP: begin
                    if (new_sample_valid) begin
                        preload_addr <= write_ptr;
                        preload_cnt  <= '0;
                        state        <= ST_PRELOAD;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // =================================---------------------------------------
    // 3. Coefficient Sweep State Machine
    //    Runs only during ST_SWEEP. COEF_DEPTH cycles: NUM_PHASES phases × TAPS_PER_PHASE taps.
    //    Starts 1 cycle after entering ST_SWEEP (to allow audio_shreg to settle).
    // =================================---------------------------------------
    logic [$clog2(COEF_DEPTH)-1:0] master_coef_addr;
    logic [$clog2(TAPS_PER_PHASE)-1:0] tap_counter;
    logic        phase_sync;
    logic        sweep_active;
    logic        sweep_done;     // prevents re-trigger after sweep completes

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            master_coef_addr <= '0;
            tap_counter      <= '0;
            phase_sync       <= 1'b0;
            sweep_active     <= 1'b0;
            sweep_done       <= 1'b0;
        end else begin
            phase_sync <= 1'b0;

            if (new_sample_valid) begin
                master_coef_addr <= '0;
                tap_counter      <= '0;
                sweep_active     <= 1'b0;
                sweep_done       <= 1'b0;
            end else if (state == ST_SWEEP && !sweep_active && !sweep_done) begin
                sweep_active     <= 1'b1;
                master_coef_addr <= '0;
                tap_counter      <= '0;
                phase_sync       <= 1'b1;   // reset accumulators for phase 0
            end else if (sweep_active) begin
                master_coef_addr <= master_coef_addr + 1'b1;
                tap_counter      <= tap_counter + 1'b1;
                if (tap_counter == $bits(tap_counter)'(TAPS_PER_PHASE - 1)) begin
                    phase_sync  <= 1'b1;
                end
                if (master_coef_addr == $bits(master_coef_addr)'(COEF_DEPTH - 1)) begin
                    sweep_active <= 1'b0;
                    sweep_done   <= 1'b1;
                end
            end
        end
    end

    // Coef address output: delay by 1 cycle for shared BRAM read pipeline.
    logic [$clog2(COEF_DEPTH)-1:0] master_coef_addr_d1;
    logic        phase_sync_d1;

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
    end

    assign coef_addr_out = master_coef_addr_d1;

    // =================================---------------------------------------
    // 4. MAC Array
    //    Each MAC m receives audio_shreg[m] = x[n-m] directly.
    //    All MACs receive the same phase_sync_d1 (broadcast, no hop delay).
    //    Each MAC outputs preg_out[m] independently — no PCIN/PCOUT.
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] mac_preg [0:NUM_MACS-1];

    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac
            polyphase_mac_engine #(
                .DATA_WIDTH(DATA_WIDTH),
                .COEF_WIDTH(COEF_WIDTH),
                .ACC_WIDTH (ACC_WIDTH),
                .MAC_ID    (i)
            ) u_mac (
                .clk        (clk),
                .rst_n      (rst_n),
                .phase_sync (phase_sync_d1),
                .coef_in    (coef_in[i]),
                .audio_in   (audio_shreg[i]),
                .preg_out   (mac_preg[i])
            );
        end
    endgenerate

    // =================================---------------------------------------
    // 5. Adder Tree
    //    Sums all NUM_MACS preg outputs in log2(NUM_MACS) pipelined levels.
    //    Latency = TREE_LEVELS cycles after mac_preg is valid.
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] tree_sum;

    polyphase_adder_tree #(
        .NUM_INPUTS(NUM_MACS),
        .WIDTH     (ACC_WIDTH)
    ) u_adder_tree (
        .clk     (clk),
        .rst_n   (rst_n),
        .data_in (mac_preg),
        .tree_out(tree_sum)
    );

    // =================================---------------------------------------
    // 6. Output Register
    //    Shadow trigger: phase_sync_d1 delayed by SHADOW_DELAY cycles.
    //    SHADOW_DELAY = 5 (MAC pipe) + TREE_LEVELS (tree) + 1 (margin) = 6 + $clog2(NUM_MACS).
    //    For 256 MACs: 5 + 8 + 1 = 14. For 4096 MACs: 5 + 12 + 1 = 18.
    //    Well inside 128-cycle (256 MACs) or 2048-cycle (4096 MACs) phase window.  ✓
    //    On rising edge of delayed trigger: register tree_sum as output.
    // =================================---------------------------------------
    localparam int TREE_LEVELS  = $clog2(NUM_MACS);          // 8 for 256 MACs, 12 for 4096 MACs
    localparam int SHADOW_DELAY = 6 + TREE_LEVELS;           // 5 (MAC) + TREE_LEVELS (tree) + 1 (margin)

    logic [SHADOW_DELAY-1:0] ps_shreg;

    always_ff @(posedge clk) begin
        if (!rst_n)
            ps_shreg <= '0;
        else
            ps_shreg <= {ps_shreg[SHADOW_DELAY-2:0], phase_sync_d1};
    end

    wire shadow_trigger = ps_shreg[SHADOW_DELAY-1];

    logic signed [ACC_WIDTH-1:0] interpolated_out_reg;
    logic                        shadow_trigger_last;
    logic                        shadow_rising;

    // Edge detect for shadow trigger
    always_ff @(posedge clk) begin
        if (!rst_n)
            shadow_trigger_last <= 1'b0;
        else
            shadow_trigger_last <= shadow_trigger;
    end

    assign shadow_rising = shadow_trigger & ~shadow_trigger_last;

    // Data register: capture tree_sum on rising edge of shadow trigger
    always_ff @(posedge clk) begin
        if (!rst_n)
            interpolated_out_reg <= '0;
        else if (shadow_rising)
            interpolated_out_reg <= tree_sum;
    end

    // Valid: delayed one cycle after data capture so data is stable
    always_ff @(posedge clk) begin
        if (!rst_n)
            interpolated_valid <= 1'b0;
        else
            interpolated_valid <= shadow_rising;
    end

    assign interpolated_out = interpolated_out_reg;

    // synthesis translate_off
    // (Debug prints removed — FIR output verified non-zero)
    // synthesis translate_on

endmodule
