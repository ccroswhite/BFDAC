`timescale 1ns / 1ps

// Mono polyphase FIR interpolator — TRUE x16 polyphase interpolation.
//
// Architecture: Parameterized NUM_MACS adder-tree reduction, per-MAC
// tap-indexed audio WINDOW RAMs with systolic one-sample handoff.
//
// !! AUDIO-WINDOW REDESIGN (2026-08-01, user-ratified) !!
// The previous datapath fed each MAC ONE static history sample for the whole
// sweep, so the TAPS_PER_PHASE coefficients of each MAC phase window
// collapsed into a single effective tap: the "1M-tap" build actually
// computed a 16k-tap filter with boxcar-summed coefficients. Each MAC now
// owns a TAPS_PER_PHASE-deep window of the history so every coefficient
// multiplies its own sample.
//
//   Tap partition: MAC m, phase p, tap t computes
//       h[p + 16*(TAPS_PER_PHASE*m + t)] * x[n - (TAPS_PER_PHASE*m + t)]
//   Coefficient layout per MAC (URAM address): addr = p*TAPS_PER_PHASE + t
//       ↔ c_m[addr] = h[p + 16*(TAPS_PER_PHASE*m + t)]
//   Total taps = NUM_PHASES * NUM_MACS * TAPS_PER_PHASE (1024 MACs -> 1M).
//   History depth K = NUM_MACS*TAPS_PER_PHASE samples (65,536 @ 1M taps),
//   held in NUM_MACS distributed-RAM windows, TAPS_PER_PHASE deep each.
//
//   Phase 1 - Systolic shift (4 cycles; replaces the NUM_MACS+1 preload):
//     On new_sample_valid each window emits its oldest sample to its
//     right-hand neighbor and absorbs one (window 0 absorbs the new input
//     sample): a one-sample advance of the whole K-deep delay line.
//   Phase 2 - Coefficient Sweep (NUM_PHASES*TAPS_PER_PHASE cycles):
//     One GLOBAL window read address (same tap index t for every MAC),
//     pipelined so audio and coefficient arrive CO-TIMED at each MAC
//     (both are 3-cycle paths from the sweep counter).
//     phase_sync_d1 broadcast to all NUM_MACS simultaneously.
//     Each MAC accumulates independently (NO PCIN/PCOUT cascade).
//     preg_out[m] connects to polyphase_adder_tree for log2(NUM_MACS)-level reduction.
//
//   Shadow trigger: phase_sync_d1 + 5 (MAC pipe) + tree_levels + 1 cycles.
//
//   Phase p output: y[16n+p] = 2 * sum_{k=0}^{K-1} h[p+16k] * x[n-k]
//   (factor 2 = legacy pre-adder gain, preserved; the pre-adder is the hook
//   for a future symmetric fwd+rev coefficient fold.)
//
//   Total cycle budget: 4 (shift) + NUM_PHASES*TAPS_PER_PHASE (sweep).
//   At 48 kHz / 400 MHz: ~8333 available. TAPS_PER_PHASE=64 -> 1028 (12%);
//   TAPS_PER_PHASE=256 (4M taps on 1024 MACs) -> 4100 (49%).
//   TAPS_PER_PHASE must be a power of two and exceed SHADOW_DELAY.
//
//   NUM_MACS (2026-08-17): any multiple of 8 (window group tree granularity);
//   power of 2 NOT required — the adder tree zero-pads. The stereo wrapper
//   additionally requires a multiple of 64 at production scale (URAM group
//   tree). E.g. 1280 MACs x TAPS_PER_PHASE=256 = 5,242,880 taps, gapless.
//
// Coefficient BRAMs are NOT owned here -- shared at fir_polyphase_stereo level.
module fir_polyphase_interpolator #(
    parameter int NUM_MACS        = 4096,        // Any multiple of 8 (see header)
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
    // 1. Per-MAC Audio Window RAMs + systolic handoff
    //    Window m holds x[n - TAPS_PER_PHASE*m - j], j = 0..TAPS_PER_PHASE-1.
    //    Newest sample of window m sits at address hp (global head pointer);
    //    sample x[n - (TAPS_PER_PHASE*m + t)] sits at address (hp - t).
    //    ONE global read address serves all windows (same tap t for all MACs).
    //
    //    Handoff (ST_SHIFT, 3 counts after the new_sample_valid cycle):
    //      E   (new_sample_valid): read address switches to hp+1 (the OLDEST
    //           sample slot = the slot the incoming sample will overwrite)
    //      cnt0: address registered into the RAM read pipeline
    //      cnt1: win_q[m] = oldest sample of window m → boundary_reg[m]
    //      cnt2: win_we — window 0 writes ns_reg (new input sample), window
    //            m>0 writes boundary_reg[m-1]; hp advances → ST_SWEEP
    //
    //    Sweep read pipeline (incl. 2-stage broadcast tree, 2026-08-13):
    //      T: win_rd_addr (comb, from tap_counter) → T+1: win_rd_addr_q
    //      → T+2: rd_addr_s2 → T+3: rd_addr_s3 → T+4: win_q → T+5: win_q2
    //      Coef: T: master_coef_addr → T+1: coef_addr_out → T+2/T+3: addr
    //      tree in stereo wrapper → T+5: coef_in (2-cycle URAM read).
    //      Audio (win_q2) and coef therefore arrive CO-TIMED at the MACs.
    // =================================---------------------------------------
    localparam int WIN_AW = $clog2(TAPS_PER_PHASE);

    // -- Broadcast pipeline (2026-08-13 timing fix, f9 datum route) ----------
    // The global window read/write address, write strobes and phase_sync fan
    // out to NUM_MACS windows spread across all four SLRs. The f9 route showed
    // this broadcast failing timing on pure route delay (WNS -2.74 ns, 97%
    // route, 1 logic level). All window-facing controls now travel through a
    // 3-stage replicated register tree (global -> NUM_SUPER -> NUM_GROUPS),
    // adding 2 cycles of uniform latency. Coefficient delivery is delayed the
    // same 2 cycles in fir_polyphase_stereo (URAM address tree) so audio and
    // coef stay CO-TIMED at the MACs; SHADOW_DELAY absorbs the extra 2.
    // GROUP_SZ 64 -> 16 (2026-08-14, f9wb route review): with 64 windows per
    // final replica the s3 -> win_q hop still failed at -2.1 ns on pure route
    // delay (windows spread across the super-group pblock). 16 windows per
    // replica keeps every final hop local; s2 -> s3 fanout rises to 16, well
    // within reach of a single dsp_clk cycle. Latency unchanged (still 3 stages).
    // GROUP_SZ 16 -> 8, NUM_SUPER 4 -> 8 (2026-08-16, f9we route review): the
    // s3 -> win_q hop was the LAST remaining violation class (-0.097 ns, >90%
    // route, 2608 shallow endpoints) - a 16-window capture cluster is still
    // too physically spread. 8 windows per replica halves the cluster again;
    // 8 super groups keep the s2 -> s3 fanout at 16. Latency unchanged.
    localparam int GROUP_SZ    = (NUM_MACS < 8) ? NUM_MACS : 8;
    localparam int NUM_GROUPS  = NUM_MACS / GROUP_SZ;
    localparam int NUM_SUPER   = ((NUM_GROUPS >= 8) && (NUM_GROUPS % 8 == 0)) ? 8 :
                                 ((NUM_GROUPS >= 4) && (NUM_GROUPS % 4 == 0)) ? 4 : 1;
    localparam int GRP_PER_SUP = NUM_GROUPS / NUM_SUPER;

    typedef enum logic [1:0] { ST_IDLE, ST_SHIFT, ST_SWEEP } state_t;
    state_t state;

    // Sweep counters — declared here (referenced by the window read mux),
    // driven by the sweep FSM in section 3.
    logic [$clog2(COEF_DEPTH)-1:0]     master_coef_addr;
    logic [$clog2(TAPS_PER_PHASE)-1:0] tap_counter;
    logic                              phase_sync;   // driven by the sweep FSM (section 3)

    logic [WIN_AW-1:0]            hp;         // global head pointer (newest-sample slot)
    logic [1:0]                   shift_cnt;
    logic signed [DATA_WIDTH-1:0] ns_reg;     // captured new input sample

    logic [WIN_AW-1:0] win_rd_addr;           // combinational, global
    logic [WIN_AW-1:0] win_rd_addr_q;         // registered address into all windows
    logic [WIN_AW-1:0] win_wr_addr;           // combinational, global
    logic              cap_bnd;               // capture boundary_reg this cycle
    logic              win_we;                // window write strobe

    assign win_wr_addr = hp + WIN_AW'(1);   // slot vacated by the departing oldest sample

    // Global read address: oldest slot during handoff, tap-indexed during sweep
    assign win_rd_addr = (new_sample_valid || state == ST_SHIFT)
                         ? (hp + WIN_AW'(1))
                         : (hp - tap_counter);   // both WIN_AW bits, natural mod-TPP wrap

    assign cap_bnd = (state == ST_SHIFT) && (shift_cnt == 2'd1);
    assign win_we  = (state == ST_SHIFT) && (shift_cnt == 2'd2);

    always_ff @(posedge clk)
        win_rd_addr_q <= win_rd_addr;

    // Broadcast tree stage 1 (single copies; win_rd_addr_q above is the
    // read-address stage 1), stages 2/3 replicated. dont_touch prevents the
    // identical replicas from being merged back into one high-fanout driver.
    logic [WIN_AW-1:0] win_wr_addr_s1;
    logic              win_we_s1, cap_bnd_s1, ps_s1;

    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_addr_s2 [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] wr_addr_s2 [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              we_s2      [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              cap_s2     [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              ps_s2      [0:NUM_SUPER-1];

    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_addr_s3 [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] wr_addr_s3 [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              we_s3      [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              cap_s3     [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              ps_s3      [0:NUM_GROUPS-1];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            win_we_s1  <= 1'b0;
            cap_bnd_s1 <= 1'b0;
            ps_s1      <= 1'b0;
            for (int s = 0; s < NUM_SUPER; s++) begin
                we_s2[s]  <= 1'b0;
                cap_s2[s] <= 1'b0;
                ps_s2[s]  <= 1'b0;
            end
            for (int g = 0; g < NUM_GROUPS; g++) begin
                we_s3[g]  <= 1'b0;
                cap_s3[g] <= 1'b0;
                ps_s3[g]  <= 1'b0;
            end
        end else begin
            win_we_s1  <= win_we;
            cap_bnd_s1 <= cap_bnd;
            ps_s1      <= phase_sync;
            for (int s = 0; s < NUM_SUPER; s++) begin
                we_s2[s]  <= win_we_s1;
                cap_s2[s] <= cap_bnd_s1;
                ps_s2[s]  <= ps_s1;
            end
            for (int g = 0; g < NUM_GROUPS; g++) begin
                we_s3[g]  <= we_s2[g / GRP_PER_SUP];
                cap_s3[g] <= cap_s2[g / GRP_PER_SUP];
                ps_s3[g]  <= ps_s2[g / GRP_PER_SUP];
            end
        end
    end

    always_ff @(posedge clk) begin
        win_wr_addr_s1 <= win_wr_addr;
        for (int s = 0; s < NUM_SUPER; s++) begin
            rd_addr_s2[s] <= win_rd_addr_q;
            wr_addr_s2[s] <= win_wr_addr_s1;
        end
        for (int g = 0; g < NUM_GROUPS; g++) begin
            rd_addr_s3[g] <= rd_addr_s2[g / GRP_PER_SUP];
            wr_addr_s3[g] <= wr_addr_s2[g / GRP_PER_SUP];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            shift_cnt <= '0;
            hp        <= '0;
            ns_reg    <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (new_sample_valid) begin
                        ns_reg    <= new_sample_data;
                        shift_cnt <= '0;
                        state     <= ST_SHIFT;
                    end
                end

                ST_SHIFT: begin
                    shift_cnt <= shift_cnt + 2'd1;
                    if (shift_cnt == 2'd2) begin
                        hp    <= hp + WIN_AW'(1);
                        state <= ST_SWEEP;
                    end
                end

                ST_SWEEP: begin
                    if (new_sample_valid) begin
                        ns_reg    <= new_sample_data;
                        shift_cnt <= '0;
                        state     <= ST_SHIFT;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // Window RAM array — distributed RAM, fully parallel one-cycle handoff.
    // 1024 windows × 64 × 24 b = 1.5 Mb LUTRAM (≈ 1.4% of VU13P LUTs).
    logic signed [DATA_WIDTH-1:0] win_q        [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] win_q2       [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] boundary_reg [0:NUM_MACS-1];

    genvar w;
    generate
        for (w = 0; w < NUM_MACS; w++) begin : gen_win
            localparam int GRP = w / GROUP_SZ;

            (* ram_style = "distributed" *)
            logic signed [DATA_WIDTH-1:0] win [0:TAPS_PER_PHASE-1];

            integer wi;
            initial begin
                for (wi = 0; wi < TAPS_PER_PHASE; wi = wi + 1)
                    win[wi] = '0;
            end

            // All controls arrive via the group-stage broadcast registers
            // (uniform +2 cycles vs. the pre-f9 direct broadcast).
            always_ff @(posedge clk) begin
                win_q[w]  <= win[rd_addr_s3[GRP]];
                win_q2[w] <= win_q[w];
                if (cap_s3[GRP])
                    boundary_reg[w] <= win_q[w];
                if (we_s3[GRP])
                    win[wr_addr_s3[GRP]] <= (w == 0) ? ns_reg : boundary_reg[w-1];
            end
        end
    endgenerate

    // =================================---------------------------------------
    // 3. Coefficient Sweep State Machine
    //    Runs only during ST_SWEEP. COEF_DEPTH cycles: NUM_PHASES phases × TAPS_PER_PHASE taps.
    //    Starts 1 cycle after entering ST_SWEEP (handoff write completed).
    //    (master_coef_addr / tap_counter declared in section 1 — the window
    //    read mux references tap_counter.)
    // =================================---------------------------------------
    logic        sweep_active;
    logic        sweep_done;     // prevents re-trigger after sweep completes
    logic        sweep_first;    // suppresses shadow capture on sweep-start phase_sync

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            master_coef_addr <= '0;
            tap_counter      <= '0;
            phase_sync       <= 1'b0;
            sweep_active     <= 1'b0;
            sweep_done       <= 1'b0;
            sweep_first      <= 1'b0;
        end else begin
            phase_sync <= 1'b0;

            if (new_sample_valid) begin
                master_coef_addr <= '0;
                tap_counter      <= '0;
                sweep_active     <= 1'b0;
                sweep_done       <= 1'b0;
                sweep_first      <= 1'b0;
            end else if (state == ST_SWEEP && !sweep_active && !sweep_done) begin
                sweep_active     <= 1'b1;
                master_coef_addr <= '0;
                tap_counter      <= '0;
                phase_sync       <= 1'b1;   // reset accumulators for phase 0
                sweep_first      <= 1'b1;   // this pulse has no prior phase to capture
            end else if (sweep_active) begin
                master_coef_addr <= master_coef_addr + 1'b1;
                tap_counter      <= tap_counter + 1'b1;
                if (tap_counter == $bits(tap_counter)'(TAPS_PER_PHASE - 1)) begin
                    phase_sync  <= 1'b1;
                    sweep_first <= 1'b0;    // first real phase boundary; suppress flag cleared
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
    logic        sweep_first_d1;  // delayed sweep_first, aligned with phase_sync_d1

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
        sweep_first_d1      <= sweep_first;
    end

    assign coef_addr_out = master_coef_addr_d1;

    // =================================---------------------------------------
    // 4. MAC Array
    //    Each MAC m receives win_q2[m] — its tap-indexed window sample,
    //    CO-TIMED with coef_in[m] (both 5-cycle paths from the sweep counter
    //    since the broadcast-tree fix: window path T+3 -> T+5, URAM address
    //    tree in the stereo wrapper delays coef T+3 -> T+5 to match).
    //    phase_sync reaches each MAC through the same group tree (ps_s3), so
    //    the sync-vs-data alignment at the MAC inputs is unchanged.
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
                .phase_sync (ps_s3[i / GROUP_SZ]),
                .coef_in    (coef_in[i]),
                .audio_in   (win_q2[i]),
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
    //    Captures the fully-accumulated PREG of phase p triggered by phase_sync of phase p+1.
    //    Timeline from phase_sync_d1(p+1):
    //      +0  : phase_sync_d1(p+1) fires
    //      +5  : last PREG update of phase p (engine d6 load fires at +6)
    //      +6  : stage[1] of adder tree registers the final PREG value
    //      +6+TREE_LEVELS : tree_out valid (one-cycle window)
    //    shadow_rising fires at phase_sync_d1(p+1) + SHADOW_DELAY
    //    → SHADOW_DELAY = 6 + TREE_LEVELS   (TB-verified, tb_fir_window)
    //    TAPS_PER_PHASE must exceed SHADOW_DELAY.
    //    On rising edge of shadow trigger: register tree_sum as output.
    // =================================---------------------------------------
    localparam int TREE_LEVELS  = $clog2(NUM_MACS);          // 2 for 4 MACs, 8 for 256 MACs
    // 6 = matches the d6 load in the MAC engine (phase p's completed sum is
    // visible in PREG for exactly one cycle before the load overwrites it);
    // the tree delays it TREE_LEVELS more.
    // (2026-08-01: was 8 + TREE_LEVELS, paired with the old d8 load.)
    // +2 (2026-08-13): broadcast-tree stages delay data (and therefore PREG
    // completion) two cycles relative to phase_sync_d1, which does NOT go
    // through the tree for this shadow path.
    localparam int SHADOW_DELAY = 8 + TREE_LEVELS;           // PREG_pipe(6) + bcast(2) + TREE_LEVELS

    // Parameter legality (2026-08-17, scalable-coefficient generalization)
    initial begin
        assert ((NUM_MACS < 8) || (NUM_MACS % 8 == 0))
            else $fatal(1, "NUM_MACS (%0d) must be a multiple of 8 (window group tree)", NUM_MACS);
        assert ((TAPS_PER_PHASE & (TAPS_PER_PHASE - 1)) == 0)
            else $fatal(1, "TAPS_PER_PHASE (%0d) must be a power of 2 (mod-TPP window wrap)", TAPS_PER_PHASE);
        assert (TAPS_PER_PHASE > SHADOW_DELAY)
            else $fatal(1, "TAPS_PER_PHASE (%0d) must exceed SHADOW_DELAY (%0d)", TAPS_PER_PHASE, SHADOW_DELAY);
    end

    logic [SHADOW_DELAY-1:0] ps_shreg;
    wire  phase_sync_d1_gated = phase_sync_d1 & ~sweep_first_d1;  // suppress sweep-start pulse

    always_ff @(posedge clk) begin
        if (!rst_n)
            ps_shreg <= '0;
        else
            ps_shreg <= {ps_shreg[SHADOW_DELAY-2:0], phase_sync_d1_gated};
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
