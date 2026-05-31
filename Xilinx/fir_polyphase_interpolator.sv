`timescale 1ns / 1ps

// Mono polyphase FIR interpolator — TRUE x16 polyphase interpolation.
//
// Architecture:
//   Phase 1 - Audio Preload (NUM_MACS+1 cycles):
//     At new_sample_valid, sequentially read audio_bram at addresses
//     write_ptr, write_ptr-1, ..., write_ptr-(NUM_MACS-1) and store into
//     audio_shreg[0..NUM_MACS-1] so that audio_shreg[m] = x[n-m].
//
//   Phase 2 - Coefficient Sweep (NUM_PHASES*TAPS_PER_PHASE = 4096 cycles):
//     Each MAC m receives audio_shreg[m] = x[n-m] as a STATIC direct input.
//     No audio cascade between MACs. The DSP cascade carries only PCIN/PCOUT.
//     phase_sync_d1 is BROADCAST to all NUM_MACS MACs simultaneously.
//     Each MAC resets its PREG 5 cycles after phase_sync_d1 (phase_sync_d5
//     inside the MAC). All MACs reset together — no cascade skew.
//     The cascade then takes 127 more cycles to propagate the fresh sum
//     from MAC 0 to cascade_acc[NUM_MACS]. Total shadow trigger delay:
//     phase_sync_d1 + 5 (MAC pipe) + 127 (cascade hops) = +133 cycles.
//     Phase window = 256 cycles > 133 cycles delay. ✓
//
//   Phase p output: y[n*16+p] = 2 * sum_{m=0}^{NUM_MACS-1} h[p+m*16] * x[n-m]
//
//   Total cycle budget: NUM_MACS+1 + 4096 = 4225 cycles.
//   At 48 kHz / 357 MHz: 7437 cycles available. 43% margin.
//
// Coefficient BRAMs are NOT owned here -- shared at fir_polyphase_stereo level.
module fir_polyphase_interpolator #(
    parameter int NUM_MACS        = 128,
    parameter int DATA_WIDTH      = 24,
    parameter int COEF_WIDTH      = 18,
    parameter int ACC_WIDTH       = 48, // STRICTLY 48 BITS to guarantee DSP PCIN/PCOUT routing
    parameter int NUM_PHASES      = 16,
    parameter int TAPS_PER_PHASE  = 256
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
    output logic [11:0]                          coef_addr_out
);

    // =================================---------------------------------------
    // 1. Audio History BRAM  (single-port, depth 2048)
    //    Write: on new_sample_valid, store new_sample_data at write_ptr.
    //    Read:  during preload phase, sequential addresses write_ptr..write_ptr-255.
    // =================================---------------------------------------
    logic [10:0] write_ptr;

    (* ram_style = "block" *) logic signed [DATA_WIDTH-1:0] audio_bram [0:2047];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 2048; init_i = init_i + 1)
            audio_bram[init_i] = '0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            write_ptr <= '0;
        else if (new_sample_valid)
            write_ptr <= write_ptr + 11'b1;
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
    //      PRELOAD  : reading audio_bram for NUM_MACS cycles, filling shreg
    //      SWEEP    : 4096-cycle coef sweep with frozen audio_shreg
    //
    //    Timing:
    //      Cycle 0  (IDLE → PRELOAD): new_sample_valid asserted.
    //               Audio write at write_ptr (old value, pre-increment).
    //               preload_addr <= write_ptr (old).
    //      Cycle 1..NUM_MACS: BRAM read latency = 1 cycle (single registered output).
    //               At cycle k (k=1..NUM_MACS): audio_bram_out = x[n-(k-1)].
    //               Loaded into audio_shreg[k-1].
    //      After NUM_MACS+1 cycles: audio_shreg[m] = x[n-m] for m=0..NUM_MACS-1. ✓
    //      SWEEP begins: master_coef_addr sweeps 0..4095, phase windows fire.
    // =================================---------------------------------------
    typedef enum logic [1:0] { ST_IDLE, ST_PRELOAD, ST_SWEEP } state_t;
    state_t state;

    logic [10:0] preload_addr;    // BRAM read address during preload
    logic [7:0]  preload_cnt;     // 0..NUM_MACS
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
                    if (preload_cnt < 8'(NUM_MACS))
                        preload_addr <= write_ptr - 11'(preload_cnt + 1);
                    // Write bram_rd result from the PREVIOUS address into shreg.
                    // At cnt=k (k>=1): bram_rd = audio_bram[write_ptr-(k-1)] = x[n-(k-1)].
                    if (preload_cnt >= 1)
                        audio_shreg[preload_cnt - 1] <= bram_rd;
                    // Transition after the last write (cnt==NUM_MACS → shreg[NUM_MACS-1] written)
                    if (preload_cnt == 8'(NUM_MACS))
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
    //    Runs only during ST_SWEEP. 4096 cycles: 16 phases × 256 taps.
    //    Starts 1 cycle after entering ST_SWEEP (to allow audio_shreg to settle).
    // =================================---------------------------------------
    logic [11:0] master_coef_addr;
    logic [7:0]  tap_counter;
    logic        phase_sync;
    logic        sweep_active;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            master_coef_addr <= '0;
            tap_counter      <= '0;
            phase_sync       <= 1'b0;
            sweep_active     <= 1'b0;
        end else begin
            phase_sync <= 1'b0;

            if (new_sample_valid) begin
                master_coef_addr <= '0;
                tap_counter      <= '0;
                sweep_active     <= 1'b0;
            end else if (state == ST_SWEEP && !sweep_active) begin
                sweep_active     <= 1'b1;
                master_coef_addr <= '0;
                tap_counter      <= '0;
            end else if (sweep_active) begin
                master_coef_addr <= master_coef_addr + 12'b1;
                tap_counter      <= tap_counter + 8'b1;
                if (tap_counter == 8'(TAPS_PER_PHASE - 1)) begin
                    phase_sync  <= 1'b1;
                end
                if (master_coef_addr == 12'(NUM_PHASES * TAPS_PER_PHASE - 1))
                    sweep_active <= 1'b0;
            end
        end
    end

    // Coef address output: delay by 1 cycle for shared BRAM read pipeline.
    logic [11:0] master_coef_addr_d1;
    logic        phase_sync_d1;

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
    end

    assign coef_addr_out = master_coef_addr_d1;

    // =================================---------------------------------------
    // 4. Accumulator Cascade Interconnect
    //    cascade_acc[0] = 0, cascade_acc[i+1] = pcout of MAC i.
    //    phase_sync_d1 is BROADCAST to all MACs simultaneously (no cascade).
    //    All MAC pregs reset together 5 cycles after phase_sync_d1.
    //    The cascade sum propagates in 127 cycles (1 per hop); the shadow
    //    trigger is delayed by 5+127 = 132 cycles after phase_sync_d1 to
    //    ensure cascade_acc[NUM_MACS] is fully settled before capture.
    //    Phase window = 256 cycles >> 132 cycles.  2-cycle guard margin. ✓
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] cascade_acc [0:NUM_MACS];
    assign cascade_acc[0] = '0;

    // =================================---------------------------------------
    // 5. MAC Array
    //    Each MAC m receives audio_shreg[m] = x[n-m] directly.
    //    All MACs receive the same phase_sync_d1 (broadcast, no hop delay).
    // =================================---------------------------------------
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
                .phase_sync (phase_sync_d1),   // broadcast — same signal to all MACs
                .coef_in    (coef_in[i]),
                .audio_in   (audio_shreg[i]),
                .pcin       (cascade_acc[i]),
                .pcout      (cascade_acc[i+1])
            );
        end
    endgenerate

    // =================================---------------------------------------
    // 6. Shadow Accumulator + Output Register
    //    Shadow trigger: phase_sync_d1 delayed by SHADOW_DELAY cycles.
    //    SHADOW_DELAY = MAC pipeline (5) + cascade depth (NUM_MACS-1=127) + 1
    //    = 133 cycles.  Well inside the 256-cycle phase window.
    //    On the delayed rising edge: latch accumulated sum and output.
    // =================================---------------------------------------
    localparam int SHADOW_DELAY = 5 + (NUM_MACS - 1) + 1;  // 133

    logic [SHADOW_DELAY-1:0] ps_shreg;   // shift register for shadow trigger

    always_ff @(posedge clk) begin
        if (!rst_n)
            ps_shreg <= '0;
        else
            ps_shreg <= {ps_shreg[SHADOW_DELAY-2:0], phase_sync_d1};
    end

    wire shadow_trigger = ps_shreg[SHADOW_DELAY-1];

    logic signed [ACC_WIDTH-1:0] shadow_acc;
    logic signed [ACC_WIDTH-1:0] interpolated_out_reg;
    logic                        shadow_trigger_last;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            shadow_acc           <= '0;
            interpolated_out_reg <= '0;
            interpolated_valid   <= 1'b0;
            shadow_trigger_last  <= 1'b0;
        end else begin
            shadow_trigger_last <= shadow_trigger;
            if (shadow_trigger && !shadow_trigger_last) begin
                interpolated_valid   <= 1'b1;
                interpolated_out_reg <= shadow_acc;
                shadow_acc           <= cascade_acc[NUM_MACS];
            end else begin
                interpolated_valid <= 1'b0;
                shadow_acc         <= shadow_acc + cascade_acc[NUM_MACS];
            end
        end
    end

    assign interpolated_out = interpolated_out_reg;

    // synthesis translate_off
    int dbg_fir_cnt = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_fir_cnt <= 0;
        end else begin
            if (interpolated_valid) begin
                dbg_fir_cnt <= dbg_fir_cnt + 1;
`ifdef SIM_DEBUG
                if (dbg_fir_cnt < 60 || interpolated_out != 0)
                    $display("[FIR_DBG @%0t] valid_cnt=%0d out=%0d",
                        $time, dbg_fir_cnt, interpolated_out);
`endif
            end
`ifdef SIM_DEBUG
            if (cascade_acc[NUM_MACS] != 0)
                $display("[CLAST_NZ @%0t] c_last=%0d valid=%0b out=%0d shadow=%0d",
                    $time, cascade_acc[NUM_MACS], interpolated_valid,
                    interpolated_out_reg, shadow_acc);
`endif
        end
    end
    // synthesis translate_on

endmodule
