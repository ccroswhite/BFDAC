"""
fir_rtl_model.py — Cycle-accurate Python model of the redesigned
fir_polyphase_interpolator.sv (true polyphase interpolation).

Architecture modelled:
  - Audio preload: NUM_MACS+1=257 cycles fill audio_shreg[m]=x[n-m] from audio_bram.
  - Coef sweep: 2048 cycles (16 phases x 128 slots), each MAC gets static audio_shreg[m].
  - MAC pipeline per MAC m (NO cascade PCIN/PCOUT):
      Stage 1: a1    <= audio_shreg[m]          (1 reg)
      Stage 2: adreg <= a1 + a1  (= 2*x[n-m])  (1 reg)
               b1    <= coef_out_1              (1 reg)
      Stage 3: b2    <= b1                      (1 reg)
      Stage 4: mreg  <= adreg * b2              (1 reg)
      Stage 5: preg  <= preg + mreg             (1 reg, reset to mreg on phase_sync_d5)
  - phase_sync_d5 inside MAC resets PREG at start of each phase window.
  - 8-level pipelined binary adder tree sums all 256 preg outputs.
    Tree latency = 8 cycles after phase window ends.
  - Shadow trigger: ps_d1 delayed 14 cycles (5 MAC + 8 tree + 1 margin).
    Output = tree_sum captured at shadow trigger.

Usage:
  python fir_rtl_model.py [--impulse | --audio fir_audio_in.txt] --coefs fir_coefs.txt
"""

import sys, os, math, argparse

# ============================================================
# RTL Constants (must match RTL parameters)
# ============================================================
NUM_MACS     = 256
DATA_WIDTH   = 24
COEF_WIDTH   = 18
ACC_WIDTH    = 48
TAPS_WIN     = 128   # coef_addr slots per phase window
NUM_PHASES   = 16
SWEEP_LEN    = NUM_PHASES * TAPS_WIN   # 2048
PRELOAD_LEN  = NUM_MACS + 1           # 257 cycles for audio preload SM
TREE_LEVELS  = 8                       # log2(256) = 8
SHADOW_DELAY = 15  # matches RTL localparam 7+TREE_LEVELS(8)=15

def sign(v, w):
    """Return signed interpretation of v in w-bit two's complement."""
    v = int(v) & ((1 << w) - 1)
    return v if v < (1 << (w - 1)) else v - (1 << w)

def clip(v, w):
    """Clip to w-bit signed range."""
    lo = -(1 << (w - 1))
    hi =  (1 << (w - 1)) - 1
    return max(lo, min(hi, int(v)))

# ============================================================
# Load coefficient BRAMs
# ============================================================
def load_coefs(coef_file):
    bram = {}   # (mac, addr) -> int18 signed
    with open(coef_file) as f:
        for line in f:
            parts = line.strip().split()
            if len(parts) != 3:
                continue
            mac, addr, val = int(parts[0]), int(parts[1]), int(parts[2])
            bram[(mac, addr)] = int(val)
    return bram

# ============================================================
# Single-cycle pipeline register helper
# ============================================================
class Reg:
    def __init__(self, width=48, signed=True, init=0):
        self.val   = init
        self._next = init
        self.width = width
        self.signed = signed

    def d(self, v):
        """Schedule next value (like SystemVerilog non-blocking <=)"""
        self._next = int(v)

    def q(self):
        """Read current (pre-clock) value"""
        return self.val

    def step(self):
        """Commit scheduled value (clock edge)"""
        v = self._next & ((1 << self.width) - 1)
        if self.signed and v >= (1 << (self.width - 1)):
            v -= (1 << self.width)
        self.val = v

# ============================================================
# MAC Engine — models polyphase_mac_engine.sv (adder-tree architecture)
#
# Pipeline (all non-blocking, committed at step()):
#   Stage 1: a1    <= audio_in            (registered audio input)
#            co1   <= coef_in             (registered coef input)
#   Stage 2: adreg <= a1 + a1 = 2*x[n-m] (pre-adder doubles)
#            b1    <= co1
#   Stage 3: b2    <= b1
#   Stage 4: mreg  <= adreg * b2
#   Stage 5: preg  <= preg + mreg         (standalone accumulator, no PCIN)
#             (reset to mreg on ps_d5)
#
# NO pcin/pcout — each MAC is fully independent.
# phase_sync delay chain: ps1..ps5 (5 stages).
# ps5 (= phase_sync_d5) resets PREG at the start of each phase window.
# ============================================================
class MACEngine:
    def __init__(self, mac_id):
        self.mac_id = mac_id

        # phase_sync delay chain: d1..d8
        self.ps1 = Reg(1, False)
        self.ps2 = Reg(1, False)
        self.ps3 = Reg(1, False)
        self.ps4 = Reg(1, False)
        self.ps5 = Reg(1, False)
        self.ps6 = Reg(1, False)
        self.ps7 = Reg(1, False)
        self.ps8 = Reg(1, False)

        # Audio + coef pipeline
        self.a1    = Reg(DATA_WIDTH)       # stage 1: registered audio_in
        self.co1   = Reg(COEF_WIDTH)       # stage 1: registered coef_in
        self.adreg = Reg(DATA_WIDTH + 1)   # stage 2: pre-adder = 2*a1
        self.b1    = Reg(COEF_WIDTH)       # stage 2
        self.b2    = Reg(COEF_WIDTH)       # stage 3

        # DSP accumulator (standalone — no cascade)
        self.mreg  = Reg(ACC_WIDTH)        # stage 4: multiplier
        self.preg  = Reg(ACC_WIDTH)        # stage 5: accumulator

    def tick(self, ps_in, coef_in, audio_in):
        """Schedule all next-state values using current .q() values.
        Does NOT commit — call step() after all MACs have been ticked."""
        # phase_sync chain (8 stages)
        self.ps1.d(ps_in)
        self.ps2.d(self.ps1.q())
        self.ps3.d(self.ps2.q())
        self.ps4.d(self.ps3.q())
        self.ps5.d(self.ps4.q())
        self.ps6.d(self.ps5.q())
        self.ps7.d(self.ps6.q())
        self.ps8.d(self.ps7.q())

        # Stage 1
        self.a1.d(audio_in)
        self.co1.d(coef_in)

        # Stage 2
        self.adreg.d(self.a1.q() + self.a1.q())   # 2 * audio_in (pre-adder)
        self.b1.d(self.co1.q())

        # Stage 3
        self.b2.d(self.b1.q())

        # Stage 4: multiplier
        self.mreg.d(self.adreg.q() * self.b2.q())

        # Stage 5: standalone PREG accumulator
        if self.ps8.q():   # phase_sync_d8 resets accumulator
            self.preg.d(self.mreg.q())
        else:
            self.preg.d(self.preg.q() + self.mreg.q())

    def step(self):
        """Commit all registers."""
        for r in [self.ps1, self.ps2, self.ps3, self.ps4, self.ps5,
                  self.ps6, self.ps7, self.ps8,
                  self.a1, self.co1, self.adreg, self.b1, self.b2,
                  self.mreg, self.preg]:
            r.step()

    def preg_out(self):
        return self.preg.q()


# ============================================================
# Interpolator top-level — models fir_polyphase_interpolator.sv
#
# State machine:
#   ST_IDLE    : waiting for new_sample_valid
#   ST_PRELOAD : filling audio_shreg[0..NUM_MACS-1] from audio_bram (NUM_MACS+1 cycles)
#   ST_SWEEP   : 2048-cycle coef sweep with frozen audio_shreg
#
# All always_ff blocks modelled with pre-tick reads, post-tick commits.
# ============================================================
ST_IDLE    = 0
ST_PRELOAD = 1
ST_SWEEP   = 2

class FIRInterpolator:
    def __init__(self, coef_bram):
        self.bram = coef_bram

        # Audio BRAM
        self.audio_bram  = [0] * 2048
        self.write_ptr   = 0          # 11-bit

        # Audio preload
        self.state        = ST_IDLE
        self.preload_addr = 0         # BRAM read address during preload
        self.preload_cnt  = 0         # 0..NUM_MACS
        self.bram_rd      = 0         # registered BRAM output (1-cycle latency)
        self.audio_shreg  = [0] * NUM_MACS  # audio_shreg[m] = x[n-m]

        # Coef sweep
        self.master_coef_addr = 0
        self.tap_counter      = 0
        self.phase_sync       = 0
        self.sweep_active     = 0
        self.sweep_done       = 0   # prevents sweep re-trigger after completion

        # Coef address pipeline (1 delay stage)
        self.mca_d1 = 0
        self.ps_d1  = 0

        # Coef BRAM read pipeline: 2 stages (BRAM stage1, DOB_REG)
        self.coef_s1  = [0] * NUM_MACS
        self.coef_out = [0] * NUM_MACS

        # Shadow trigger: ps_d1 delayed by SHADOW_DELAY cycles via shift register
        self.ps_shreg = [0] * SHADOW_DELAY

        # MAC engines
        self.macs = [MACEngine(i) for i in range(NUM_MACS)]

        # Adder tree pipeline: TREE_LEVELS+1 stages (level 0..TREE_LEVELS)
        # tree_pipe[0] = newest preg snapshot, tree_pipe[TREE_LEVELS] = oldest (output)
        self.tree_pipe = [[0]*NUM_MACS for _ in range(TREE_LEVELS + 1)]

        # Output
        self.shadow_trig_last = 0
        self.interp_out       = 0
        self.interp_valid     = 0

    def _coef(self, mac, addr):
        return self.bram.get((mac, int(addr) & 0x7FF), 0)

    def tick(self, nsv, nsv_data):
        """
        Simulate one posedge clk.
        nsv      : new_sample_valid (1 or 0)
        nsv_data : new_sample_data (signed 24-bit)
        Returns  : (interpolated_out, interpolated_valid)
        """
        # ================================================================
        # STEP 1: Read all pre-tick state, compute next values
        # ================================================================

        # --- Audio BRAM write (on NSV, uses pre-increment write_ptr) ---
        if nsv:
            self.audio_bram[self.write_ptr & 0x7FF] = nsv_data

        wp_next = ((self.write_ptr + 1) & 0x7FF) if nsv else self.write_ptr

        # --- Registered BRAM read (1-cycle latency) ---
        bram_rd_next = self.audio_bram[self.preload_addr & 0x7FF]

        # --- Preload FSM ---
        state_next        = self.state
        preload_addr_next = self.preload_addr
        preload_cnt_next  = self.preload_cnt
        shreg_wr_idx      = -1   # index to write bram_rd into audio_shreg (-1 = no write)

        if self.state == ST_IDLE:
            if nsv:
                preload_addr_next = self.write_ptr   # x[n] at write_ptr (pre-increment)
                preload_cnt_next  = 0
                state_next        = ST_PRELOAD

        elif self.state == ST_PRELOAD:
            cnt = self.preload_cnt
            preload_cnt_next = cnt + 1
            # Issue address for next read
            if cnt < NUM_MACS:
                preload_addr_next = (self.write_ptr - (cnt + 2)) & 0x7FF
            # Write bram_rd (= result of previous address) into shreg
            # At cnt=k (k>=1): bram_rd = audio_bram[write_ptr-(k-1)] = x[n-(k-1)]
            if cnt >= 1:
                shreg_wr_idx = cnt - 1   # x[n-(cnt-1)] → shreg[cnt-1]
            if cnt == NUM_MACS:
                state_next = ST_SWEEP

        elif self.state == ST_SWEEP:
            # Final bram_rd write: cnt was NUM_MACS when we transitioned
            # This cycle is the first of ST_SWEEP; bram_rd = x[n-(NUM_MACS-1)]
            # We already wrote shreg[NUM_MACS-2] last cycle. Need shreg[NUM_MACS-1].
            # Actually the transition happens when preload_cnt == NUM_MACS,
            # so the write for shreg[NUM_MACS-1] happened at cnt=NUM_MACS (shreg_wr_idx=NUM_MACS-1).
            # The first cycle of ST_SWEEP just holds.
            if nsv:
                preload_addr_next = self.write_ptr
                preload_cnt_next  = 0
                state_next        = ST_PRELOAD

        # --- Coef sweep FSM ---
        # sweep_active: asserted for exactly SWEEP_LEN cycles per ST_SWEEP entry.
        # After sweep completes, sweep_active=0 and STAYS 0 until next NSV.
        mca_next    = self.master_coef_addr
        tc_next     = self.tap_counter
        ps_next     = 0
        sweep_next  = self.sweep_active
        done_next   = self.sweep_done

        if nsv:
            mca_next   = 0
            tc_next    = 0
            sweep_next = 0
            done_next  = 0
        elif self.state == ST_SWEEP and not self.sweep_active and not self.sweep_done:
            sweep_next = 1
            done_next  = 0
            mca_next   = 0
            tc_next    = 0
            ps_next    = 1   # phase_sync at sweep start (resets accum for phase 0)
        elif self.sweep_active:
            mca_next = (self.master_coef_addr + 1) & 0x7FF
            tc_next  = (self.tap_counter + 1) & 0x7F
            if self.tap_counter == TAPS_WIN - 1:
                ps_next = 1
            if self.master_coef_addr == SWEEP_LEN - 1:
                sweep_next = 0
                done_next  = 1   # prevent re-trigger

        # Coef address pipeline
        mca_d1_next = self.master_coef_addr
        ps_d1_next  = self.phase_sync

        # Coef BRAM read (2-stage)
        coef_s1_next  = [self._coef(m, self.mca_d1) for m in range(NUM_MACS)]
        coef_out_next = list(self.coef_s1)

        # Shadow trigger shift register: ps_d1 delayed SHADOW_DELAY cycles
        ps_shreg_next = [self.ps_d1] + list(self.ps_shreg[:-1])
        shadow_trigger = self.ps_shreg[-1]   # oldest bit = fully delayed

        # ================================================================
        # STEP 2: Tick all MACs (schedule next values) then commit.
        #   tick() schedules using current .q() values (pre-step).
        #   step() commits to new .q() values.
        #   preg_vals is snapshotted AFTER step() — matches RTL where
        #   preg_out is the registered output visible the same cycle it's
        #   written (NBA commit before adder tree reads).
        # ================================================================
        ps_broadcast = self.ps_d1
        for m in range(NUM_MACS):
            self.macs[m].tick(ps_broadcast, self.coef_out[m], self.audio_shreg[m])
        for mac in self.macs:
            mac.step()

        # ================================================================
        # STEP 3: Adder tree — 8-level pipelined binary sum of preg outputs
        #   Snapshots post-step preg values (combinatorial input to tree level 0).
        #   tree_pipe[0] = newest (just computed), tree_pipe[TREE_LEVELS] = oldest.
        #   tree_pipe[-1] = tree_pipe[TREE_LEVELS] = sum available after 8 reg stages.
        # ================================================================
        preg_vals = [self.macs[m].preg_out() for m in range(NUM_MACS)]
        # Push new level-0 into the front of the pipeline
        self.tree_pipe = [preg_vals] + self.tree_pipe[:-1]  # shift right

        # Compute tree output: full 8-level reduction of tree_pipe[8]
        # (tree_pipe[8] is the values that entered 8 cycles ago)
        def tree_reduce(vals):
            while len(vals) > 1:
                nxt = []
                for i in range(0, len(vals), 2):
                    nxt.append(vals[i] + (vals[i+1] if i+1 < len(vals) else 0))
                vals = nxt
            return vals[0] if vals else 0

        tree_sum_now = tree_reduce(list(self.tree_pipe[-1]))

        # Shadow trigger — rising edge: capture tree_sum as output
        rising = shadow_trigger and not self.shadow_trig_last
        if rising:
            interp_valid_next = 1
            interp_out_next   = tree_sum_now
        else:
            interp_valid_next = 0
            interp_out_next   = self.interp_out

        # No shadow_acc needed — tree is combinatorial from preg values
        shadow_next = 0

        # ================================================================
        # STEP 4: Commit all state
        # ================================================================
        old_bram_rd = self.bram_rd   # save pre-commit bram_rd (RTL registered value)
        self.write_ptr        = wp_next
        self.bram_rd          = bram_rd_next
        self.state            = state_next
        self.preload_addr     = preload_addr_next
        self.preload_cnt      = preload_cnt_next
        if shreg_wr_idx >= 0:
            self.audio_shreg[shreg_wr_idx] = old_bram_rd   # RTL: audio_shreg[k] <= bram_rd (registered)

        self.master_coef_addr = mca_next
        self.tap_counter      = tc_next
        self.phase_sync       = ps_next
        self.sweep_active     = sweep_next
        self.sweep_done       = done_next
        self.mca_d1           = mca_d1_next
        self.ps_d1            = ps_d1_next
        self.coef_s1          = coef_s1_next
        self.coef_out         = coef_out_next
        self.ps_shreg         = ps_shreg_next
        self.shadow_trig_last = shadow_trigger
        self.interp_out       = sign(int(interp_out_next) & ((1 << ACC_WIDTH) - 1), ACC_WIDTH)
        self.interp_valid     = interp_valid_next

        return self.interp_out, self.interp_valid


# ============================================================
# Drive stimulus and collect outputs
# ============================================================
def run_simulation(coef_file, audio_samples, n_capture=512, warm_cycles=0):
    """
    Drive audio_samples into the FIR and collect n_capture valid outputs.
    warm_cycles: extra cycles before driving audio (to match TB pre-run).
    Returns list of (capture_idx, output_value) tuples.
    """
    coef_bram = load_coefs(coef_file)
    fir = FIRInterpolator(coef_bram)

    SAMPLE_CLKS = 8163   # must match TB localparam

    results   = []
    cap_count = 0

    # Warm-up: simulate the cycles that the TB spends loading coefficients
    # (during this time the FIR runs freely with zero audio).
    for _ in range(warm_cycles):
        out, vld = fir.tick(0, 0)
        if vld and cap_count < n_capture:
            results.append(out)
            cap_count += 1

    # Drive audio samples
    for sample in audio_samples:
        # new_sample_valid for 1 cycle
        out, vld = fir.tick(1, sample)
        if vld and cap_count < n_capture:
            results.append(out)
            cap_count += 1
        # Remaining SAMPLE_CLKS-1 cycles
        for _ in range(SAMPLE_CLKS - 1):
            out, vld = fir.tick(0, 0)
            if vld and cap_count < n_capture:
                results.append(out)
                cap_count += 1

    # Drain pipeline
    for _ in range(10 * SAMPLE_CLKS):
        out, vld = fir.tick(0, 0)
        if vld and cap_count < n_capture:
            results.append(out)
            cap_count += 1

    # Pad with zeros if needed
    while len(results) < n_capture:
        results.append(0)

    return results


# ============================================================
# Main
# ============================================================
def main():
    SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
    XILINX_DIR  = os.path.join(SCRIPT_DIR, "..", "Xilinx")

    parser = argparse.ArgumentParser()
    parser.add_argument("--coefs",  default=os.path.join(XILINX_DIR, "fir_coefs.txt"))
    parser.add_argument("--audio",  default=os.path.join(XILINX_DIR, "fir_audio_in.txt"))
    parser.add_argument("--out",    default=os.path.join(XILINX_DIR, "fir_golden.txt"))
    parser.add_argument("--impulse", action="store_true",
                        help="Drive single unit impulse instead of audio file")
    parser.add_argument("--warm",   type=int, default=2345,
                        help="Warm-up cycles before audio (matches TB: 30 reset+2048 coef+11 post + 256 preload)")
    parser.add_argument("--capture", type=int, default=512)
    args = parser.parse_args()

    if args.impulse:
        amp = (1 << (DATA_WIDTH-1)) - 1   # 2^23-1
        audio = [amp] + [0] * 16
        print(f"[golden] Impulse mode: amp={amp}, {len(audio)} samples")
    else:
        audio = []
        with open(args.audio) as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    audio.append(int(parts[1]))
        print(f"[golden] Audio mode: {len(audio)} samples from {args.audio}")

    print(f"[golden] Running cycle-accurate model... (warm={args.warm} cycles)")
    results = run_simulation(args.coefs, audio,
                             n_capture=args.capture,
                             warm_cycles=args.warm)

    # Write golden file
    nonzero = 0
    with open(args.out, "w") as f:
        for i, v in enumerate(results):
            f.write(f"{i} {v}\n")
            if v != 0:
                nonzero += 1
    print(f"[golden] Written {len(results)} values → {args.out}")
    print(f"[golden] Non-zero: {nonzero}")

    # Print first 20 non-zero
    print("[golden] First 20 non-zero outputs:")
    shown = 0
    for i, v in enumerate(results):
        if v != 0:
            print(f"  [{i}] = {v}")
            shown += 1
            if shown >= 20:
                break


if __name__ == "__main__":
    main()
