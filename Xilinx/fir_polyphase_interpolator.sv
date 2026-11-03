`timescale 1ns / 1ps

// =============================================================================
// FIR_POLYPHASE_INTERPOLATOR — Milestone 1 + Milestone 2 (Option B Fold)
//
// - SYM_FOLD_EN = 0 (Milestone 1):
//     Uses phase-end snapshot + 3-tier time-multiplexed polyphase_adder_tree.
// - SYM_FOLD_EN = 1 (Milestone 2):
//     Bit-exact Option B polyphase half-curve fold. Doubles effective tap count
//     (2 * NUM_PHASES * NUM_MACS * TAPS_PER_PHASE) from a half-curve URAM table
//     using dual systolic windows (win shifting 0 -> NUM_MACS-1 and win_rev
//     shifting NUM_MACS-1 -> 0). Evaluates Y_fwd[s] and Y_rev[s] during the
//     sweep and emits y[p] = Y_fwd[p] + Y_rev[P - 1 - p] in chronological order
//     p = 0..P-1 spaced by EMIT_SPACING = 16 dsp_clk cycles.
// =============================================================================
module fir_polyphase_interpolator #(
    parameter int NUM_MACS       = 4096,
    parameter int DATA_WIDTH     = 24,
    parameter int COEF_WIDTH     = 18,
    parameter int ACC_WIDTH      = 48,
    parameter int NUM_PHASES     = 16,
    parameter int TAPS_PER_PHASE = 64,
    parameter bit SYM_FOLD_EN    = 1'b0
)(
    input  logic                                clk,
    input  logic                                rst_n,
    input  tri0 [1:0]                           rate_shift,
    output logic                                input_overrun,

    // Baseband Input
    input  logic                                new_sample_valid,
    input  logic signed [DATA_WIDTH-1:0]        new_sample_data,

    // Oversampled Output
    output logic signed [ACC_WIDTH-1:0]         interpolated_out,
    output logic                                interpolated_valid,
    output logic                                input_frame_done,

    // Coefficient input from shared URAMs (one value per MAC per cycle)
    input  logic signed [COEF_WIDTH-1:0]        coef_in [0:NUM_MACS-1],

    // Coefficient address output (to drive shared URAM read port)
    output logic [$clog2(NUM_PHASES*TAPS_PER_PHASE)-1:0] coef_addr_out
);

    localparam int COEF_DEPTH = NUM_PHASES * TAPS_PER_PHASE;
    localparam int PHASE_COUNT_WIDTH = $clog2(NUM_PHASES + 1);
    logic [PHASE_COUNT_WIDTH-1:0] output_phase_count;
    logic sample_accept;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            output_phase_count <= '0;
            input_frame_done   <= 1'b0;
        end else begin
            input_frame_done <= 1'b0;
            if (sample_accept)
                output_phase_count <= '0;
            else if (interpolated_valid) begin
                if (output_phase_count == PHASE_COUNT_WIDTH'((NUM_PHASES >> rate_shift) - 1)) begin
                    input_frame_done   <= 1'b1;
                    output_phase_count <= '0;
                end else
                    output_phase_count <= output_phase_count + 1'b1;
            end
        end
    end

    // =================================---------------------------------------
    // 1. Per-MAC Audio Window RAMs (Forward + Reverse Systolic Handoff)
    // =================================---------------------------------------
    localparam int WIN_AW = $clog2(TAPS_PER_PHASE);
    logic [WIN_AW-1:0] history_clear_addr;
    logic history_clear;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            history_clear      <= 1'b1;
            history_clear_addr <= '0;
        end else if (history_clear) begin
            if (history_clear_addr == WIN_AW'(TAPS_PER_PHASE - 1))
                history_clear <= 1'b0;
            else
                history_clear_addr <= history_clear_addr + 1'b1;
        end
    end

    localparam int GROUP_SZ    = (NUM_MACS < 8) ? NUM_MACS : 8;
    localparam int NUM_GROUPS  = NUM_MACS / GROUP_SZ;
    localparam int NUM_SUPER   = ((NUM_GROUPS >= 8) && (NUM_GROUPS % 8 == 0)) ? 8 :
                                 ((NUM_GROUPS >= 4) && (NUM_GROUPS % 4 == 0)) ? 4 : 1;
    localparam int GRP_PER_SUP = NUM_GROUPS / NUM_SUPER;

    typedef enum logic [1:0] { ST_IDLE, ST_SHIFT, ST_SWEEP } state_t;
    state_t state;
    assign sample_accept = new_sample_valid && !history_clear &&
                           ((state == ST_IDLE) ||
                            (state == ST_SWEEP && input_frame_done));

    logic [$clog2(COEF_DEPTH)-1:0]     master_coef_addr;
    logic [$clog2(TAPS_PER_PHASE)-1:0] tap_counter;
    logic                              phase_sync;

    logic [WIN_AW-1:0]            hp;
    logic [1:0]                   shift_cnt;
    logic signed [DATA_WIDTH-1:0] ns_reg;

    logic [WIN_AW-1:0] win_rd_addr,     win_rd_addr_q;
    logic [WIN_AW-1:0] win_rev_rd_addr, win_rev_rd_addr_q;
    logic [WIN_AW-1:0] win_wr_addr;
    logic              cap_bnd;
    logic              win_we;

    assign win_wr_addr = hp + WIN_AW'(1);

    // Forward window reads (hp - tap_counter) newest-to-oldest during sweep;
    // Reverse window reads (hp + 1 + tap_counter) oldest-to-newest during sweep.
    assign win_rd_addr     = (sample_accept || state == ST_SHIFT)
                             ? (hp + WIN_AW'(1))
                             : (hp - tap_counter);
    assign win_rev_rd_addr = (sample_accept || state == ST_SHIFT)
                             ? (hp + WIN_AW'(1))
                             : (hp + WIN_AW'(1) + tap_counter);

    assign cap_bnd = (state == ST_SHIFT) && (shift_cnt == 2'd1);
    assign win_we  = (state == ST_SHIFT) && (shift_cnt == 2'd2);

    always_ff @(posedge clk) begin
        win_rd_addr_q     <= win_rd_addr;
        win_rev_rd_addr_q <= win_rev_rd_addr;
    end

    logic [WIN_AW-1:0] win_wr_addr_s1;
    logic              win_we_s1, cap_bnd_s1, ps_s1;

    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_addr_s2     [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_rev_addr_s2 [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] wr_addr_s2     [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              we_s2          [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              cap_s2         [0:NUM_SUPER-1];
    (* dont_touch = "true" *) logic              ps_s2          [0:NUM_SUPER-1];

    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_addr_s3     [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] rd_rev_addr_s3 [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic [WIN_AW-1:0] wr_addr_s3     [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              we_s3          [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              cap_s3         [0:NUM_GROUPS-1];
    (* dont_touch = "true" *) logic              ps_s3          [0:NUM_GROUPS-1];

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
            rd_addr_s2[s]     <= win_rd_addr_q;
            rd_rev_addr_s2[s] <= win_rev_rd_addr_q;
            wr_addr_s2[s]     <= win_wr_addr_s1;
        end
        for (int g = 0; g < NUM_GROUPS; g++) begin
            rd_addr_s3[g]     <= rd_addr_s2[g / GRP_PER_SUP];
            rd_rev_addr_s3[g] <= rd_rev_addr_s2[g / GRP_PER_SUP];
            wr_addr_s3[g]     <= wr_addr_s2[g / GRP_PER_SUP];
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
                    if (sample_accept) begin
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
                    if (sample_accept) begin
                        ns_reg    <= new_sample_data;
                        shift_cnt <= '0;
                        state     <= ST_SHIFT;
                    end else if (input_frame_done)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    logic signed [DATA_WIDTH-1:0] win_q            [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] win_q2           [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] boundary_reg     [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] win_rev_q        [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] win_rev_q2       [0:NUM_MACS-1];
    logic signed [DATA_WIDTH-1:0] boundary_rev_reg [0:NUM_MACS-1];

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

            always_ff @(posedge clk) begin
                win_q[w]  <= win[rd_addr_s3[GRP]];
                win_q2[w] <= win_q[w];
                if (cap_s3[GRP])
                    boundary_reg[w] <= win_q[w];
                if (history_clear)
                    win[history_clear_addr] <= '0;
                else if (we_s3[GRP])
                    win[wr_addr_s3[GRP]] <= (w == 0) ? ns_reg : boundary_reg[w-1];
            end

            if (SYM_FOLD_EN) begin : gen_win_rev
                (* ram_style = "distributed" *)
                logic signed [DATA_WIDTH-1:0] win_rev [0:TAPS_PER_PHASE-1];

                integer wri;
                initial begin
                    for (wri = 0; wri < TAPS_PER_PHASE; wri = wri + 1)
                        win_rev[wri] = '0;
                end

                always_ff @(posedge clk) begin
                    win_rev_q[w]  <= win_rev[rd_rev_addr_s3[GRP]];
                    win_rev_q2[w] <= win_rev_q[w];
                    if (cap_s3[GRP])
                        boundary_rev_reg[w] <= win_rev_q[w];
                    if (history_clear)
                        win_rev[history_clear_addr] <= '0;
                    else if (we_s3[GRP])
                        win_rev[wr_addr_s3[GRP]] <= (w == NUM_MACS - 1)
                                                    ? boundary_reg[NUM_MACS - 1]
                                                    : boundary_rev_reg[w + 1];
                end
            end else begin : gen_no_win_rev
                assign win_rev_q[w]        = '0;
                assign win_rev_q2[w]       = '0;
                assign boundary_rev_reg[w] = '0;
            end
        end
    endgenerate

    // =================================---------------------------------------
    // 3. Coefficient Sweep State Machine
    // =================================---------------------------------------
    logic        sweep_active;
    logic        sweep_done;
    logic        sweep_first;
    always_ff @(posedge clk) begin
        if (!rst_n) input_overrun <= 1'b0;
        else if (new_sample_valid && !sample_accept) input_overrun <= 1'b1;
    end

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

            if (sample_accept) begin
                master_coef_addr <= '0;
                tap_counter      <= '0;
                sweep_active     <= 1'b0;
                sweep_done       <= 1'b0;
                sweep_first      <= 1'b0;
            end else if (state == ST_SWEEP && !sweep_active && !sweep_done) begin
                sweep_active     <= 1'b1;
                master_coef_addr <= '0;
                tap_counter      <= '0;
                phase_sync       <= 1'b1;
                sweep_first      <= 1'b1;
            end else if (sweep_active) begin
                master_coef_addr <= master_coef_addr + 1'b1;
                tap_counter      <= tap_counter + 1'b1;
                if (tap_counter == $bits(tap_counter)'(TAPS_PER_PHASE - 1)) begin
                    phase_sync  <= 1'b1;
                    sweep_first <= 1'b0;
                end
                if (master_coef_addr == $bits(master_coef_addr)'((COEF_DEPTH >> rate_shift) - 1)) begin
                    sweep_active <= 1'b0;
                    sweep_done   <= 1'b1;
                end
            end
        end
    end

    logic [$clog2(COEF_DEPTH)-1:0] master_coef_addr_d1;
    logic        phase_sync_d1;
    logic        sweep_first_d1;

    always_ff @(posedge clk) begin
        master_coef_addr_d1 <= master_coef_addr;
        phase_sync_d1       <= phase_sync;
        sweep_first_d1      <= sweep_first;
    end

    assign coef_addr_out = master_coef_addr_d1;

    // =================================---------------------------------------
    // 4. MAC Array
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] mac_preg     [0:NUM_MACS-1];
    logic signed [ACC_WIDTH-1:0] mac_preg_rev [0:NUM_MACS-1];

    genvar i;
    generate
        for (i = 0; i < NUM_MACS; i++) begin : gen_poly_mac
            polyphase_mac_engine #(
                .DATA_WIDTH (DATA_WIDTH),
                .COEF_WIDTH (COEF_WIDTH),
                .ACC_WIDTH  (ACC_WIDTH),
                .MAC_ID     (i),
                .SYM_FOLD_EN(SYM_FOLD_EN)
            ) u_mac (
                .clk          (clk),
                .rst_n        (rst_n),
                .phase_sync   (ps_s3[i / GROUP_SZ]),
                .coef_in      (coef_in[i]),
                .audio_in     (win_q2[i]),
                .audio_rev_in (win_rev_q2[i]),
                .preg_out     (mac_preg[i]),
                .preg_rev_out (mac_preg_rev[i])
            );
        end
    endgenerate

    // =================================---------------------------------------
    // 5. Phase-End Snapshot Trigger & Time-Multiplexed Adder Tree(s)
    // =================================---------------------------------------
    localparam int SNAP_PIPE_DELAY = 8;
    localparam int TREE_G1 = (TAPS_PER_PHASE >= 64) ? 32 :
                             (TAPS_PER_PHASE >= 32) ? 8  : 4;
    localparam int TREE_G2 = (TAPS_PER_PHASE >= 64) ? 8  :
                             (TAPS_PER_PHASE >= 32) ? 4  : 2;

    initial begin
        assert ((NUM_MACS < 8) || (NUM_MACS % 8 == 0))
            else $fatal(1, "NUM_MACS (%0d) must be a multiple of 8", NUM_MACS);
        assert ((TAPS_PER_PHASE & (TAPS_PER_PHASE - 1)) == 0)
            else $fatal(1, "TAPS_PER_PHASE (%0d) must be a power of 2", TAPS_PER_PHASE);
        assert (TAPS_PER_PHASE >= 16)
            else $fatal(1, "TAPS_PER_PHASE (%0d) must be >= 16", TAPS_PER_PHASE);
    end

    logic [SNAP_PIPE_DELAY-2:0] ps_shreg;
    (* max_fanout = 32 *) logic snap_en_reg;
    wire phase_sync_d1_gated = phase_sync_d1 & ~sweep_first_d1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ps_shreg    <= '0;
            snap_en_reg <= 1'b0;
        end else begin
            ps_shreg    <= {ps_shreg[SNAP_PIPE_DELAY-3:0], phase_sync_d1_gated};
            snap_en_reg <= ps_shreg[SNAP_PIPE_DELAY-2];
        end
    end

    logic signed [ACC_WIDTH-1:0] tree_sum;
    logic                        tree_valid;

    polyphase_adder_tree #(
        .NUM_INPUTS(NUM_MACS),
        .WIDTH     (ACC_WIDTH),
        .G1        (TREE_G1),
        .G2        (TREE_G2)
    ) u_adder_tree (
        .clk      (clk),
        .rst_n    (rst_n),
        .snap_en  (snap_en_reg),
        .data_in  (mac_preg),
        .tree_out (tree_sum),
        .valid_out(tree_valid)
    );

    // =================================---------------------------------------
    // 6. Output Register (Direct in Milestone 1, Conjugate-Folded in Milestone 2)
    // =================================---------------------------------------
    logic signed [ACC_WIDTH-1:0] interpolated_out_reg;

    generate
        if (!SYM_FOLD_EN) begin : gen_out_m1
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    interpolated_out_reg <= '0;
                    interpolated_valid   <= 1'b0;
                end else begin
                    if (tree_valid)
                        interpolated_out_reg <= tree_sum;
                    interpolated_valid <= tree_valid;
                end
            end
        end else begin : gen_out_m2
            localparam int EMIT_SPACING = 16; // >= 8 clks required by downstream halfband_x2
            logic signed [ACC_WIDTH-1:0] tree_sum_rev;
            logic                        tree_valid_rev;

            polyphase_adder_tree #(
                .NUM_INPUTS(NUM_MACS),
                .WIDTH     (ACC_WIDTH),
                .G1        (TREE_G1),
                .G2        (TREE_G2)
            ) u_adder_tree_rev (
                .clk      (clk),
                .rst_n    (rst_n),
                .snap_en  (snap_en_reg),
                .data_in  (mac_preg_rev),
                .tree_out (tree_sum_rev),
                .valid_out(tree_valid_rev)
            );

            logic signed [ACC_WIDTH-1:0] fwd_phase_buf [0:NUM_PHASES-1];
            logic signed [ACC_WIDTH-1:0] rev_phase_buf [0:NUM_PHASES-1];
            logic [PHASE_COUNT_WIDTH-1:0] cap_phase_idx;
            logic [PHASE_COUNT_WIDTH-1:0] emit_phase_idx;
            logic                         emit_active;
            logic [3:0]                   emit_spacing_cnt;

            wire [PHASE_COUNT_WIDTH-1:0] active_phases = PHASE_COUNT_WIDTH'(NUM_PHASES >> rate_shift);

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    for (int p = 0; p < NUM_PHASES; p++) begin
                        fwd_phase_buf[p] <= '0;
                        rev_phase_buf[p] <= '0;
                    end
                    cap_phase_idx        <= '0;
                    emit_phase_idx       <= '0;
                    emit_active          <= 1'b0;
                    emit_spacing_cnt     <= '0;
                    interpolated_out_reg <= '0;
                    interpolated_valid   <= 1'b0;
                end else begin
                    interpolated_valid <= 1'b0;

                    if (sample_accept) begin
                        cap_phase_idx    <= '0;
                        emit_phase_idx   <= '0;
                        emit_active      <= 1'b0;
                        emit_spacing_cnt <= '0;
                    end else if (tree_valid) begin
                        fwd_phase_buf[cap_phase_idx] <= tree_sum;
                        rev_phase_buf[cap_phase_idx] <= tree_sum_rev;
                        if (cap_phase_idx == active_phases - 1'b1) begin
                            cap_phase_idx    <= '0;
                            emit_active      <= 1'b1;
                            emit_phase_idx   <= '0;
                            emit_spacing_cnt <= '0;
                        end else begin
                            cap_phase_idx <= cap_phase_idx + 1'b1;
                        end
                    end else if (emit_active) begin
                        if (emit_spacing_cnt == 4'd0) begin
                            automatic int p_idx   = int'(emit_phase_idx);
                            automatic int rev_idx = int'(active_phases) - 1 - p_idx;
                            interpolated_out_reg <= fwd_phase_buf[p_idx] + rev_phase_buf[rev_idx];
                            interpolated_valid   <= 1'b1;
                            if (emit_phase_idx == active_phases - 1'b1) begin
                                emit_active <= 1'b0;
                            end else begin
                                emit_phase_idx   <= emit_phase_idx + 1'b1;
                                emit_spacing_cnt <= 4'(EMIT_SPACING - 1);
                            end
                        end else begin
                            emit_spacing_cnt <= emit_spacing_cnt - 4'd1;
                        end
                    end
                end
            end
        end
    endgenerate

    assign interpolated_out = interpolated_out_reg;

endmodule
