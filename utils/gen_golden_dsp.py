"""
Golden vector generator for tb_dsp_core golden-vector check.

Replicates the full RTL pipeline of dac_dsp_core with passthrough FIR:
  audio_in -> FIR(passthrough) -> vol_multiply -> stable_hold
           -> TPDF_dither -> noise_shaper_5th_order -> dem_cmd

Passthrough FIR assumption:
  Only MAC 0, address 0 is loaded with 1.0 (18'h10000 = 65536 in Q1.17).
  FIR output = input sample * 65536  (= input << 16 in the 48-bit accumulator).

RTL parameters (must match dac_dsp_core.sv):
  DATA_WIDTH=24, COEF_WIDTH=18, ACC_WIDTH=48
  sys_volume  = 0xFFFFFFFF  (32-bit)
  boot_gain   = 0xFFFF      (16-bit)
  DITHER_WIDTH = 42
  INPUT_WIDTH=48, FRAC_WIDTH=42, OUT_WIDTH=9   (noise shaper)

Output file format (one line per valid dem_cmd sample):
  <sample_index> <dem_cmd_l> <dem_cmd_r>
"""

import math
import ctypes
import os

# ---------------------------------------------------------------------------
# Parameters matching RTL
# ---------------------------------------------------------------------------
NUM_SAMPLES    = 100
F_SINE         = 1000.0
F_SAMPLE       = 44100.0
SYS_VOLUME     = 0xFFFF_FFFF   # 32-bit unsigned
BOOT_GAIN      = 0xFFFF        # 16-bit unsigned
DITHER_WIDTH   = 42
INPUT_WIDTH    = 48
FRAC_WIDTH     = 42
OUT_WIDTH      = 9
IW             = INPUT_WIDTH + 6   # 54 bits

# Noise shaper constants (must match RTL localparams)
MAX_LEVEL      = 256
CENTER_OFFSET  = 128
CENTER_OFFSET_SCALED = CENTER_OFFSET << FRAC_WIDTH   # in IW-bit fixed-point
CLAMP_OFFSET   = MAX_LEVEL << FRAC_WIDTH

# ---------------------------------------------------------------------------
# Helpers: signed integers of specified width
# ---------------------------------------------------------------------------
def to_signed(val, bits):
    """Interpret val as a signed integer of 'bits' width."""
    mask = (1 << bits) - 1
    val = val & mask
    if val >= (1 << (bits - 1)):
        val -= (1 << bits)
    return val

def mask(val, bits):
    return val & ((1 << bits) - 1)

# ---------------------------------------------------------------------------
# 1. Sine stimulus (matches tb_dsp_core.sv exactly)
# ---------------------------------------------------------------------------
def gen_audio_samples():
    samples = []
    for i in range(NUM_SAMPLES):
        t = i / F_SAMPLE
        sine_val = math.sin(2.0 * math.pi * F_SINE * t)
        # $rtoi rounds toward zero (truncates)
        raw = int(sine_val * (0.5 * (2**23 - 1.0)))
        # 24-bit 2's complement
        samples.append(mask(raw, 24))
    return samples

# ---------------------------------------------------------------------------
# 2. FIR Passthrough
#    With only MAC0/addr0 = 18'h10000 (= 65536), the FIR multiplies the
#    input sample by coef=65536 and accumulates once.
#    Accumulator is 48-bit signed. Result = sign_extend(audio_24) * 65536.
# ---------------------------------------------------------------------------
def fir_passthrough(audio_24):
    """Return 48-bit signed accumulator output for passthrough FIR."""
    # Sign-extend 24-bit audio to signed integer
    s = to_signed(audio_24, 24)
    # Multiply by coef 1.0 in Q1.17: coef_value = 65536 (= 1 << 16 in Q1.17, 18-bit)
    # The MAC accumulates: acc += audio * coef  (48-bit result)
    acc = s * 65536
    return to_signed(acc, 48)

# ---------------------------------------------------------------------------
# 3. Volume multiplier pipeline (4 cycles, but combinatorial for golden model)
#    combined_volume = (SYS_VOLUME * BOOT_GAIN) >> 16   (32-bit result, 0-saturate)
#    vol_product = fir_48 * combined_volume   (80-bit)
#    volumed = vol_product[79:16]   -> 64-bit signed
# ---------------------------------------------------------------------------
combined_volume = (SYS_VOLUME * BOOT_GAIN) >> 16
combined_volume = mask(combined_volume, 32)

def volume_multiply(fir_signed_48):
    """Return 64-bit signed volumed output."""
    # Treat combined_volume as unsigned (sign bit forced 0: {1'b0, vol_b_r1})
    cv_signed = combined_volume   # unsigned, used as signed positive
    # fir_signed_48 is a signed 48-bit value
    product = fir_signed_48 * cv_signed   # Python big int, 80-bit equivalent
    # Slice [79:16] = upper 64 bits of 80-bit result
    product_80 = mask(product, 80)
    volumed_64 = (product_80 >> 16) & ((1 << 64) - 1)
    return to_signed(volumed_64, 64)

# ---------------------------------------------------------------------------
# 4. TPDF Dither Generator (matches tpdf_dither_gen.sv exactly)
#    DITHER_WIDTH=42, output = {tpdf_raw[32:0], 9'b0}  (since 42 > 33)
# ---------------------------------------------------------------------------
class TpdfDitherGen:
    def __init__(self):
        self.lfsr1 = 0xACE11001
        self.lfsr2 = 0x1337BEEF

    def step(self):
        """Advance LFSRs and return signed 42-bit dither value."""
        # XOR feedback: {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]}
        def lfsr_next(r):
            fb = ((r >> 31) ^ (r >> 21) ^ (r >> 1) ^ r) & 1
            return mask((r << 1) | fb, 32)

        self.lfsr1 = lfsr_next(self.lfsr1)
        self.lfsr2 = lfsr_next(self.lfsr2)

        # tpdf_raw = signed({1'b0,lfsr_1}) - signed({1'b0,lfsr_2}) -> 33-bit signed
        tpdf_raw = self.lfsr1 - self.lfsr2   # range: -(2^32-1) to +(2^32-1), fits in 33 bits
        tpdf_raw = to_signed(mask(tpdf_raw, 33), 33)

        # DITHER_WIDTH=42 > 33: assign dither_out = {tpdf_raw, 9'b0}
        dither = tpdf_raw << (DITHER_WIDTH - 33)
        return to_signed(mask(dither, DITHER_WIDTH), DITHER_WIDTH)

# ---------------------------------------------------------------------------
# 5. 5th-Order Noise Shaper (bit-exact replica of noise_shaper_5th_order.sv)
#    Pipelined, but since enable fires << pipeline depth, each output is
#    determined after 5 enable pulses from the first. We model the pipeline
#    by processing the queue of enable-stage snapshots.
# ---------------------------------------------------------------------------
class NoiseShaper5th:
    def __init__(self):
        # Error delay line
        self.e_z = [0] * 6   # e_z[1..5], index 0 unused
        # Pipeline stage queues: each is (data_in_snapshot, dither_snapshot)
        # Stages A,B,C1,C2,D1,D2 — we model as 5 enable-clocked pipeline regs
        self.pipe_a  = None   # (t1,t2,t3,t4,offset,e_z5_a,dither_a)
        self.pipe_b  = None   # (sum_pos_1, sum_pos_2, sum_neg, dither_b)
        self.pipe_c1 = None   # (noise_shaped, dither_c)
        self.pipe_c2 = None   # (noise_shaped_c2, dithered_r)
        self.pipe_d1 = None   # (cand_over, cand_under, cand_normal, dem_normal, range_sel)
        self.dem_drive_out = CENTER_OFFSET & ((1 << OUT_WIDTH) - 1)

    def _iw_signed(self, v):
        return to_signed(mask(v, IW), IW)

    def _fw_signed(self, v):
        return to_signed(mask(v, FRAC_WIDTH), FRAC_WIDTH)

    def step(self, data_in_48, dither_42):
        """
        Clock one enable pulse. data_in_48 is signed 48-bit, dither_42 is signed 42-bit.
        Returns dem_drive_out [0..255] for this enable cycle (output of Stage D2).
        """
        ez = self.e_z  # shorthand

        # --- Stage A: compute from current e_z state ---
        t1 = self._iw_signed((ez[1] << 2) + ez[1])          # 5*e_z1
        t2 = self._iw_signed((ez[2] << 3) + (ez[2] << 1))   # 10*e_z2
        t3 = self._iw_signed((ez[3] << 3) + (ez[3] << 1))   # 10*e_z3
        t4 = self._iw_signed((ez[4] << 2) + ez[4])           # 5*e_z4
        offset = self._iw_signed(to_signed(mask(data_in_48, INPUT_WIDTH), INPUT_WIDTH) + CENTER_OFFSET_SCALED)
        e_z5_a = ez[5]
        dither_a = dither_42

        new_a = (t1, t2, t3, t4, offset, e_z5_a, dither_a)

        # --- Stage B: sum nodes ---
        new_b = None
        if self.pipe_a is not None:
            t1r, t2r, t3r, t4r, off_r, e5a, dith_a = self.pipe_a
            sp1 = self._iw_signed(off_r + t1r)
            sp2 = self._iw_signed(t3r + e5a)
            sn  = self._iw_signed(t2r + t4r)
            new_b = (sp1, sp2, sn, dith_a)

        # --- Stage C1: combine ---
        new_c1 = None
        if self.pipe_b is not None:
            sp1, sp2, sn, dith_b = self.pipe_b
            ns = self._iw_signed((sp1 + sp2) - sn)
            new_c1 = (ns, dith_b)

        # --- Stage C2: dither add ---
        new_c2 = None
        if self.pipe_c1 is not None:
            ns_r, dith_c = self.pipe_c1
            dithered = self._iw_signed(ns_r + self._fw_signed(dith_c))
            new_c2 = (ns_r, dithered)   # (noise_shaped_c2, dithered_r)

        # --- Stage D1: pre-compute candidates ---
        new_d1 = None
        if self.pipe_c2 is not None:
            ns_c2, dith_r = self.pipe_c2
            cand_over   = self._iw_signed(ns_c2 - CLAMP_OFFSET)
            cand_under  = self._iw_signed(ns_c2)
            # dem_drive_normal = dithered_r[FRAC_WIDTH + OUT_WIDTH - 1 : FRAC_WIDTH]
            slice_hi = FRAC_WIDTH + OUT_WIDTH   # 51
            slice_lo = FRAC_WIDTH               # 42
            dith_r_mask = mask(dith_r, IW)
            dem_normal = (dith_r_mask >> slice_lo) & ((1 << OUT_WIDTH) - 1)
            # cand_normal = noise_shaped_c2 - (dem_normal << FRAC_WIDTH)
            cand_normal = self._iw_signed(ns_c2 - (dem_normal << FRAC_WIDTH))
            # range_sel
            dith_r_iw = mask(dith_r, IW)
            sign_bit = (dith_r_iw >> (IW - 1)) & 1
            # overflow: sign=0 AND any bit in [IW-2 : FRAC_WIDTH+OUT_WIDTH-1] set
            overflow_bits = (dith_r_iw >> (FRAC_WIDTH + OUT_WIDTH - 1)) & ((1 << (IW - 1 - (FRAC_WIDTH + OUT_WIDTH - 1))) - 1)
            if sign_bit == 0 and overflow_bits != 0:
                rsel = 1  # overflow
            elif sign_bit == 1:
                rsel = 2  # underflow
            else:
                rsel = 0  # normal
            new_d1 = (cand_over, cand_under, cand_normal, dem_normal, rsel)

        # --- Stage D2: mux + commit ---
        if self.pipe_d1 is not None:
            cand_ov, cand_un, cand_nm, dem_nm, rsel = self.pipe_d1
            if rsel == 1:   # overflow
                self.dem_drive_out = MAX_LEVEL & ((1 << OUT_WIDTH) - 1)
                new_e_z1 = cand_ov
            elif rsel == 2: # underflow
                self.dem_drive_out = 0
                new_e_z1 = cand_un
            else:           # normal
                self.dem_drive_out = dem_nm & ((1 << OUT_WIDTH) - 1)
                new_e_z1 = cand_nm
            # Shift error delay line
            ez[5] = ez[4]
            ez[4] = ez[3]
            ez[3] = ez[2]
            ez[2] = ez[1]
            ez[1] = self._iw_signed(new_e_z1)

        # Advance pipeline registers
        self.pipe_a  = new_a
        self.pipe_b  = new_b
        self.pipe_c1 = new_c1
        self.pipe_c2 = new_c2
        self.pipe_d1 = new_d1

        return self.dem_drive_out

# NS_LATENCY: number of enable pulses before NS pipeline produces first real output.
# RTL: Stage A fires on enable[0], D2 commits on enable[5] -> 5 enables of latency.
# The Python step() returns dem_drive_out AFTER Stage D2 commits, which happens
# at step N from the perspective of the PREVIOUS step's pipe_d1. So the first
# non-center output of step() appears at call #5 (0-indexed). We write 100+5
# total enables to golden and the TB compares cap[0..99] vs gv[0..99] with offset=0.
NS_LATENCY = 5

# ---------------------------------------------------------------------------
# Main: run the full pipeline and write golden vectors
# ---------------------------------------------------------------------------
def main():
    audio_samples = gen_audio_samples()

    dither_l = TpdfDitherGen()
    dither_r = TpdfDitherGen()
    ns_l = NoiseShaper5th()
    ns_r = NoiseShaper5th()

    # stable_hold: holds last valid volumed value (combinatorial in model)
    stable_l = 0
    stable_r = 0

    # We need NUM_SAMPLES+NS_LATENCY enable pulses total so that after the
    # pipeline warm-up, exactly NUM_SAMPLES real outputs are in the file.
    # Inputs for the warm-up period: use zero (silence -> NS stays at 128).
    all_audio = [0] * NS_LATENCY + list(audio_samples)
    output_lines = []

    for i, audio_24 in enumerate(all_audio):
        # FIR passthrough
        fir_out = fir_passthrough(audio_24)

        # Volume pipeline
        vol_out = volume_multiply(fir_out)

        # stable_hold: update on volumed_valid (every enable)
        stable_l = vol_out
        stable_r = vol_out   # L==R in testbench

        # data_in to noise shaper = stable_l[63:16]
        data_ns = to_signed(mask(stable_l >> 16, INPUT_WIDTH), INPUT_WIDTH)

        # Dither step
        d_l = dither_l.step()
        d_r = dither_r.step()

        # Noise shaper step
        dem_l = ns_l.step(data_ns, d_l)
        dem_r = ns_r.step(data_ns, d_r)

        output_lines.append(f"{i} {dem_l} {dem_r}")

    # We write all NS_LATENCY+NUM_SAMPLES lines; TB compares all of them
    # with offset=0 in the capture array.
    out_path = r"c:\Users\ccros\src\BFDAC\Xilinx\golden_dsp_vectors.txt"
    with open(out_path, "w") as f:
        f.write("\n".join(output_lines) + "\n")

    total = len(output_lines)
    print(f"Written {total} golden vectors ({NS_LATENCY} warmup + {NUM_SAMPLES} real) to {out_path}")
    print("First 15 lines:")
    for line in output_lines[:15]:
        print(" ", line)

if __name__ == "__main__":
    main()
