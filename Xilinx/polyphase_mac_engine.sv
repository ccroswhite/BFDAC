`timescale 1ns / 1ps

module polyphase_mac_engine #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 64, // 64 BITS (DSP48E1 + CARRY4 Fabric Overflow)
    parameter int MAC_ID     = 0
)(
    input  logic                               clk,
    input  logic                               rst_n,

    // Phase Control
    input  logic                               phase_sync,
    input  logic [10:0]                        coef_addr,

    // The Folded Audio Cascade
    input  logic signed [DATA_WIDTH-1:0]       audio_fwd_in,
    input  logic signed [DATA_WIDTH-1:0]       audio_rev_in,
    output logic signed [DATA_WIDTH-1:0]       audio_fwd_out,
    output logic signed [DATA_WIDTH-1:0]       audio_rev_out,

    // The Systolic Accumulator Chain
    input  logic signed [ACC_WIDTH-1:0]        acc_in,
    output logic signed [ACC_WIDTH-1:0]        acc_out,
    output logic                               valid_out
);

    // =================================---------------------------------------
    // 1. Pipeline Delay Taps
    // =================================---------------------------------------
    // 7-cycle pipeline alignment (DSP48E1 (A+D)*B template + 3-stage fabric):
    //   T=1  AREG/DREG/BREG  (fwd_q1, rev_q1, coef_q1)     -> phase_sync_d1
    //   T=2  ADREG           (pre_add_q2, coef_q2)         -> phase_sync_d2
    //   T=3  MREG            (mult_q3)                     -> phase_sync_d3
    //   T=4  PREG            (dsp_preg_out)                -> phase_sync_d4
    //   T=5  stage 7 (dsp_p_lsb_q / dsp_p_sext_q)          -> phase_sync_d5
    //   T=6  stage 8 (acc_lsb_q / acc_carry_q)             -> phase_sync_d6
    //   T=7  stage 9 (acc_out)                               (valid_out=d6)
    (* shreg_extract = "no" *) logic phase_sync_d1, phase_sync_d2, phase_sync_d3;
    (* shreg_extract = "no" *) logic phase_sync_d4, phase_sync_d5, phase_sync_d6;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase_sync_d1 <= 1'b0; phase_sync_d2 <= 1'b0; phase_sync_d3 <= 1'b0;
            phase_sync_d4 <= 1'b0; phase_sync_d5 <= 1'b0; phase_sync_d6 <= 1'b0;
        end else begin
            phase_sync_d1 <= phase_sync;
            phase_sync_d2 <= phase_sync_d1;
            phase_sync_d3 <= phase_sync_d2;
            phase_sync_d4 <= phase_sync_d3;
            phase_sync_d5 <= phase_sync_d4;
            phase_sync_d6 <= phase_sync_d5;
        end
    end

    // =================================---------------------------------------
    // 2. RAM Array Read & Audio Registration
    // =================================---------------------------------------
    (* rom_style = "block" *) logic signed [COEF_WIDTH-1:0] coef_rom [0:2047];

    // Placeholder ROM contents: each entry seeded with its index so that
    // synthesis cannot prove the multiplier output is constant-zero and
    // optimize the inferred multiplier fanout away. Replace with the real
    // $readmemh / write-port path once the coefficient pipeline lands.
    initial begin
        for (int k = 0; k < 2048; k++) begin
            coef_rom[k] = COEF_WIDTH'(k);
        end
    end

    // =================================---------------------------------------
    // 3. DSP48E1 (A+D)*B INFERENCE TEMPLATE (behavioral; sync reset)
    //    Four register stages, single always_ff, mapping 1-to-1 onto the
    //    DSP48E1 hardened pipeline so Vivado packs the entire (A+D)*B chain
    //    into a single slice instead of splitting it into two A*B multipliers.
    //
    //        Cycle 1 : fwd_q1 / rev_q1 / coef_q1  -- AREG / DREG / BREG
    //        Cycle 2 : pre_add_q2 = fwd_q1 + rev_q1
    //                  coef_q2    = coef_q1       -- ADREG (+ B alignment)
    //        Cycle 3 : mult_q3    = pre_add_q2 * coef_q2  -- MREG
    //        Cycle 4 : dsp_preg_out = sign_extend_48(mult_q3) -- PREG
    //
    //    Bit widths chosen to match the DSP48E1 port limits exactly:
    //      fwd_q1, rev_q1 : signed [DATA_WIDTH-1:0]   (24 b   -> A / D)
    //      coef_q1, coef_q2 : signed [COEF_WIDTH-1:0] (18 b   -> B)
    //      pre_add_q2     : signed [DATA_WIDTH:0]     (25 b   -> A2+D sum)
    //      mult_q3        : signed [42:0]             (25 * 18 -> 43 b)
    //      dsp_preg_out   : signed [47:0]             (sign-ext 43 -> 48 b)
    //
    //    use_dsp = "yes" sits on mult_q3 only. Putting it on the surrounding
    //    pipeline registers can confuse Vivado's pattern matcher and cause
    //    the pre-adder to be implemented in fabric instead.
    //    All registers use synchronous reset only.
    // =================================---------------------------------------
    // DSP-input registers: fanout strictly to the pre-adder so Vivado can
    // absorb them into the DSP48E1's internal AREG / DREG. Any external
    // fanout on these flops (e.g. driving the systolic audio cascade) blocks
    // pre-adder inference and forces Vivado to split the math across two
    // DSP slices as (fwd*coef) + (rev*coef).
    logic signed [DATA_WIDTH-1:0] fwd_q1, rev_q1;
    logic signed [COEF_WIDTH-1:0] coef_q1, coef_q2;
    logic signed [DATA_WIDTH:0]   pre_add_q2;
    (* use_dsp = "yes" *) logic signed [42:0] mult_q3;
    logic signed [47:0]           dsp_preg_out;

    // Parallel fabric flops dedicated to the systolic audio cascade. These
    // exist purely so the cascade has a 1-cycle delay per MAC without
    // contaminating the AREG/DREG fanout. Synthesis cost is 2 x DATA_WIDTH
    // flops per MAC -- trivial relative to the DSP slice we recover.
    //
    // keep_equivalent_registers is REQUIRED here. fwd_cascade_q has the same
    // D-input/clock/reset as fwd_q1, so Vivado's default equivalent-register
    // removal pass will merge them into one register, restoring the dual-
    // fanout problem on fwd_q1 and forcing the (fwd*coef)+(rev*coef) split
    // across two DSP slices. The attribute pins these flops as distinct.
    (* keep_equivalent_registers = "yes" *)
    logic signed [DATA_WIDTH-1:0] fwd_cascade_q, rev_cascade_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fwd_q1        <= '0;
            rev_q1        <= '0;
            fwd_cascade_q <= '0;
            rev_cascade_q <= '0;
            coef_q1       <= '0;
            pre_add_q2    <= '0;
            coef_q2       <= '0;
            mult_q3       <= '0;
            dsp_preg_out  <= '0;
        end else begin
            // Cycle 1: AREG / DREG / BREG -- register the inputs
            fwd_q1        <= audio_fwd_in;
            rev_q1        <= audio_rev_in;
            coef_q1       <= coef_rom[coef_addr];
            // Cycle 1 (parallel): cascade flops for the next MAC's audio_*_in
            fwd_cascade_q <= audio_fwd_in;
            rev_cascade_q <= audio_rev_in;
            // Cycle 2: ADREG -- 24b + 24b -> 25b signed pre-add; align coef
            pre_add_q2    <= fwd_q1 + rev_q1;
            coef_q2       <= coef_q1;
            // Cycle 3: MREG -- 25b * 18b -> 43b signed multiply
            mult_q3       <= pre_add_q2 * coef_q2;
            // Cycle 4: PREG -- sign-extend 43 -> 48 bits for the fabric
            dsp_preg_out  <= {{5{mult_q3[42]}}, mult_q3};
        end
    end

    assign audio_fwd_out = fwd_cascade_q;
    assign audio_rev_out = rev_cascade_q;

    // =================================---------------------------------------
    // 4. STAGE 7: HARD DSP/FABRIC BOUNDARY REGISTERS
    //    These flops are the strict pipeline boundary between the DSP48E1 P
    //    output and the CARRY4 fabric. dont_touch/keep prevent Vivado from
    //    absorbing them back into the CARRY4 chain or replicating them into
    //    the DSP slice's PREG (which is already enabled via PREG=1).
    //    The incoming systolic accumulator is split here into LSB/MSB halves
    //    so that the 48-bit and 16-bit additions can be staged in different
    //    clock cycles.
    // =================================---------------------------------------
    (* use_dsp = "no", keep = "true", dont_touch = "true" *)
    logic signed [47:0] dsp_p_lsb_q;     // Registered DSP P[47:0] in fabric
    (* use_dsp = "no", keep = "true", dont_touch = "true" *)
    logic signed [15:0] dsp_p_sext_q;    // Registered sign-extension of P[47] for upper 16b
    logic signed [47:0] acc_in_lsb_q;    // Lower half of incoming systolic accumulator
    logic signed [15:0] acc_in_msb_q;    // Upper half of incoming systolic accumulator

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dsp_p_lsb_q  <= '0;
            dsp_p_sext_q <= '0;
            acc_in_lsb_q <= '0;
            acc_in_msb_q <= '0;
        end else begin
            dsp_p_lsb_q  <= dsp_preg_out;
            dsp_p_sext_q <= {16{dsp_preg_out[47]}};
            acc_in_lsb_q <= acc_in[47:0];
            acc_in_msb_q <= acc_in[63:48];
        end
    end

    // =================================---------------------------------------
    // 5. STAGE 8: 48-BIT LSB ACCUMULATION (~12 CARRY4) + REGISTERED CARRY
    //    This is the cycle-N add. The unsigned carry-out of the 48-bit sum
    //    is captured in its own boundary flop (acc_carry_q), explicitly
    //    marked dont_touch so Vivado cannot fold the carry path back into
    //    a single 64-bit CARRY4 chain. The MSB sign-extension and incoming
    //    upper half are pushed forward one cycle to align with the MSB add.
    // =================================---------------------------------------
    (* use_dsp = "no", keep = "true", dont_touch = "true" *)
    logic [47:0]        acc_lsb_q;       // Lower-48 accumulator result
    (* use_dsp = "no", keep = "true", dont_touch = "true" *)
    logic               acc_carry_q;     // Unsigned carry-out of LSB add
    logic signed [15:0] acc_in_msb_q2;   // MSB half forwarded to next stage
    logic signed [15:0] dsp_p_sext_q2;   // Sign-ext forwarded to next stage

    // 49-bit unsigned add to expose the natural carry bit
    logic [48:0] lsb_sum_c;
    assign lsb_sum_c = {1'b0, acc_in_lsb_q} + {1'b0, dsp_p_lsb_q};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_lsb_q     <= '0;
            acc_carry_q   <= 1'b0;
            acc_in_msb_q2 <= '0;
            dsp_p_sext_q2 <= '0;
        end else if (phase_sync_d5) begin
            // Dump-and-restart: load only the new product, drop incoming cascade.
            // MSB stage will see acc_in_msb_q2=0, acc_carry_q=0 next cycle, and
            // therefore reproduces sign-extended dsp_preg_out exactly.
            acc_lsb_q     <= dsp_p_lsb_q;
            acc_carry_q   <= 1'b0;
            acc_in_msb_q2 <= '0;
            dsp_p_sext_q2 <= dsp_p_sext_q;
        end else begin
            acc_lsb_q     <= lsb_sum_c[47:0];
            acc_carry_q   <= lsb_sum_c[48];
            acc_in_msb_q2 <= acc_in_msb_q;
            dsp_p_sext_q2 <= dsp_p_sext_q;
        end
    end

    // =================================---------------------------------------
    // 6. STAGE 9: 16-BIT MSB ACCUMULATION (~4 CARRY4)
    //    Cycle-N+1 add: upper 16 bits of incoming cascade + sign-extension of
    //    this tap's P + registered carry from the LSB add. The final 64-bit
    //    result is reassembled at the module output.
    // =================================---------------------------------------
    (* use_dsp = "no" *) logic signed [15:0] msb_sum;
    assign msb_sum = acc_in_msb_q2 + dsp_p_sext_q2 + {15'd0, acc_carry_q};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else begin
            acc_out <= {msb_sum, acc_lsb_q};
        end
    end

    // The valid flag pulses on the cycle where acc_out displays the final
    // accumulated sum of the current phase (one cycle before stage 8 dumps
    // the new phase's first product). Aligned to the 7-cycle module latency.
    assign valid_out = phase_sync_d6;

endmodule