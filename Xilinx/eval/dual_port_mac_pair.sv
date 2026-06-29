`timescale 1ns / 1ps

// =============================================================================
//  DUAL_PORT_MAC_PAIR  (EVALUATION — NOT PRODUCTION)
//
//  Concept: One RAMB36E2 in True Dual Port mode feeds two DSP48E2 MACs.
//    Port A reads even-addressed coefficients → DSP_even
//    Port B reads odd-addressed coefficients  → DSP_odd
//
//  Each DSP accumulates independently over its phase window.
//  Both preg outputs feed the adder tree (2 tree inputs per BRAM).
//
//  This doubles the effective MAC count per BRAM, increasing the
//  BRAM:DSP ratio from 1:1 to 1:2.
//
//  Coefficient layout (per MAC pair, per BRAM):
//    For phase p (0..15), t-slot t (0..255):
//      Even DSP: addr = p*256 + 2*t       (even addresses)
//      Odd  DSP: addr = p*256 + 2*t + 1   (odd addresses)
//    Total addresses = 16 * 256 * 2 = 8192, but we only have 2048 per port.
//
//  WAIT — this doesn't work as described. Let me reconsider.
//
//  Correct approach: TDP RAMB36E2, 18-bit per port, 2048 deep.
//    Port A: 2048 x 18-bit = one full coefficient set (MAC_even)
//    Port B: 2048 x 18-bit = one full coefficient set (MAC_odd)
//    Each port independently addressed → each DSP sweeps its own coefs.
//    Both share the same BRAM silicon, but store DIFFERENT coefficients
//    in the same physical memory using the TDP 18-bit-per-port mode.
//
//  RAMB36E2 in TDP mode:
//    36Kb total = 2 × 18Kb halves
//    Port A accesses the lower 18Kb → 2048 × 18-bit (one MAC's coefs)
//    Port B accesses the upper 18Kb → 2048 × 18-bit (another MAC's coefs)
//
//  This is equivalent to using two RAMB18E2s, but packed into one RAMB36E2.
//  The key: both ports can read SIMULTANEOUSLY at different addresses.
//
//  Effective: 2 MACs per RAMB36, each with 2048 × 18-bit coefs.
//  With TAPS_PER_PHASE = 128: sweep = 16 × 128 = 2048 ✓ (fills exactly)
//  With TAPS_PER_PHASE = 256: need 4096 addrs → need 2 RAMB36 per MAC pair
//    (cascade depth), giving 4 MACs per 2 RAMB36 = same 2:1 ratio. No gain.
//
//  KEY INSIGHT: The dual-port trick only helps if TAPS_PER_PHASE ≤ 128,
//  because each 18-bit port only has 2048 addresses. For 256 t-slots we
//  need 4096 addresses, which requires cascading — and we're back to 2 BRAM
//  per 2 MACs = 1:1 ratio.
//
//  REVISED APPROACH: Use TDP 36-bit mode with independent port addressing.
//  RAMB36E2 TDP at READ_WIDTH=18 per port:
//    Port A: 2048 × 18-bit (addresses 0..2047)
//    Port B: 2048 × 18-bit (addresses 0..2047) — SAME physical memory
//
//  Wait, in TDP mode both ports access the SAME memory space. So if Port A
//  reads addr 100 and Port B reads addr 200, they see the same memory array.
//  We can't store two independent MAC coefficient sets in the same address
//  space — they'd collide.
//
//  CORRECT APPROACH: Use the RAMB36E2 as two independent RAMB18E2 halves.
//  From UG573: "Each RAMB36E2 can be split into two independent RAMB18E2"
//  using CASCADE_ORDER and the upper/lower half addressing.
//
//  OR: Use RAMB36E2 in TDP with 36-bit width and pack two 18-bit coefs
//  into each 36-bit word. Port A writes both coefs at load time. Port B
//  reads the 36-bit word, splits into coef_even[17:0] and coef_odd[35:18].
//  Both DSPs get their coefficient from the SAME address in the SAME cycle.
//
//  This means both MACs in the pair share the SAME coef_addr sweep.
//  They read the SAME BRAM address, but get DIFFERENT 18-bit coefficients
//  from the low and high halves of the 36-bit word.
//
//  But then what audio sample does each DSP multiply against?
//    DSP_even: audio_shreg[2*m]     × coef_word[17:0]
//    DSP_odd:  audio_shreg[2*m + 1] × coef_word[35:18]
//
//  This is the EXISTING dual-bank scheme repurposed! Currently bank A/B
//  are used for gapless switching. In this eval, each BRAM word holds
//  coefs for two different MACs instead of two banks of one MAC.
//
//  Trade-off: we lose gapless dual-bank switching. Coefficient reload
//  requires a brief mute or crossfade. Worth discussing with user.
//
// =============================================================================
//
// FINAL ARCHITECTURE:
//   - 1 RAMB36E2 per MAC pair, 2048 deep × 36-bit
//   - Each 36-bit word: {coef_odd[17:0], coef_even[17:0]}
//   - Single read port, single address from sweep FSM
//   - Output split: low 18 bits → DSP_even, high 18 bits → DSP_odd
//   - DSP_even receives audio_shreg[2*pair_id]
//   - DSP_odd  receives audio_shreg[2*pair_id + 1]
//   - 2 DSP48E2 outputs feed adder tree
//   - TAPS_PER_PHASE = 128: 2048 addresses, 1 BRAM per pair ✓
//   - TAPS_PER_PHASE = 256: 4096 addresses, 2 BRAM per pair (cascaded)
//
//   For 384 MAC pairs (768 virtual MACs) × 128 t-slots × 16 phases:
//     Taps = 768 × 128 × 16 = 1,572,864 (~1.5M) per channel
//     BRAM = 384 per channel, 768 stereo (43% of 1800) ✓
//     DSP  = 768 per channel, 1536 stereo (44% of 3456) ✓
//
//   For 384 MAC pairs × 256 t-slots × 16 phases:
//     Taps = 768 × 256 × 16 = 3,145,728 (~3.1M) per channel
//     BRAM = 768 per channel, 1536 stereo (85% — too high)
//
//   Sweet spot: 384 pairs × 128 t-slots = 1.5M/ch, 3M stereo
//   Or:         256 pairs × 128 t-slots = 1M/ch (same as current, half BRAM)
//
// =============================================================================
module dual_port_mac_pair #(
    parameter int DATA_WIDTH = 24,
    parameter int COEF_WIDTH = 18,
    parameter int ACC_WIDTH  = 48,
    parameter int PAIR_ID    = 0
)(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          phase_sync,

    // Single coefficient word from BRAM (36-bit: two 18-bit coefs packed)
    input  logic [35:0]                   coef_word,

    // Audio inputs — two static samples from audio_shreg
    input  logic signed [DATA_WIDTH-1:0]  audio_even,   // x[n - 2*PAIR_ID]
    input  logic signed [DATA_WIDTH-1:0]  audio_odd,    // x[n - 2*PAIR_ID - 1]

    // Two outputs to adder tree
    output logic signed [ACC_WIDTH-1:0]   preg_even,
    output logic signed [ACC_WIDTH-1:0]   preg_odd
);

    // Split the 36-bit BRAM word into two 18-bit signed coefficients
    wire signed [COEF_WIDTH-1:0] coef_even = signed'(coef_word[17:0]);
    wire signed [COEF_WIDTH-1:0] coef_odd  = signed'(coef_word[35:18]);

    // Instantiate two independent MAC engines
    polyphase_mac_engine #(
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .MAC_ID     (2 * PAIR_ID)
    ) u_mac_even (
        .clk        (clk),
        .rst_n      (rst_n),
        .phase_sync (phase_sync),
        .coef_in    (coef_even),
        .audio_in   (audio_even),
        .preg_out   (preg_even)
    );

    polyphase_mac_engine #(
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .MAC_ID     (2 * PAIR_ID + 1)
    ) u_mac_odd (
        .clk        (clk),
        .rst_n      (rst_n),
        .phase_sync (phase_sync),
        .coef_in    (coef_odd),
        .audio_in   (audio_odd),
        .preg_out   (preg_odd)
    );

endmodule
