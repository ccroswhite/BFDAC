#!/usr/bin/env python3
"""
stage1a_coef_packer.py — Milestone 5 Stage 1A (x2) Coefficient Generator & DDR4 Packer

Generates and packs fixed 18-bit signed Q1.17 Stage 1A polyphase coefficients for
fir_polyphase_stereo.sv (TWO_STAGE_EN=1) and coef_bank_loader.sv:
  - Geometry: COEF_DEPTH = 16 * TAPS_PER_PHASE (4096 @ TPP=256)
              Stage 1A   = 2 phases x ((8 * TAPS_PER_PHASE) >> rate_shift)
              Effective 16x taps (SYM_FOLD_EN=1) = 32 * NUM_MACS * TAPS_PER_PHASE >> rate_shift
  - Supports:
      * packing = 1 : 7 x 18-bit continuous stream per 128-bit AXI beat (bits [125:0])
      * packing = 0 : 4 x 32-bit sign-extended v1 words per 128-bit AXI beat
      * 32-byte DDR4 directory header generation (schema v3 for rate_shift 0..3)
      * $readmemh .mem export and built-in RTL bit-exactness self-test (--self-test)
"""

from __future__ import annotations
import argparse
import math
import struct
from pathlib import Path
import numpy as np

Q17_SCALE = 1 << 17          # 131,072 (unity gain per polyphase branch)
Q17_MIN   = -(1 << 17)       # -131,072
Q17_MAX   = (1 << 17) - 1    # +131,071


def bessel_i0_vec(x: np.ndarray) -> np.ndarray:
    """Vectorized modified Bessel function I0(x) accurate to IEEE-754 float64 precision."""
    x_half_sq = 0.25 * (x * x)
    term = np.ones_like(x_half_sq, dtype=np.float64)
    total = np.ones_like(x_half_sq, dtype=np.float64)
    for m in range(1, 45):
        term *= x_half_sq / (m * m)
        total += term
        if np.max(term) < 1e-18 * np.max(total):
            break
    return total


def design_stage1a_half_prototype(
    num_macs: int,
    taps_per_phase: int,
    rate_shift: int = 0,
    profile: str = "kaiser",
    cutoff_ratio: float = 0.495,
    kaiser_beta: float = 18.0,
    sym_fold: bool = True,
) -> np.ndarray:
    """
    Designs the x2 zero-stuffed Stage 1A interpolation prototype in float64.
    When sym_fold=True, returns the first half of length (2 * num_macs * act_tpp)
    whose sum is normalized to 1.0 (so full symmetric prototype sums to 2.0, i.e.,
    1.0 per polyphase branch).
    """
    if not (0 <= rate_shift <= 3):
        raise ValueError(f"rate_shift ({rate_shift}) must be in 0..3")

    s1a_tpp = 8 * taps_per_phase
    act_tpp = s1a_tpp >> rate_shift
    if act_tpp < 16 or (act_tpp & (act_tpp - 1)) != 0:
        raise ValueError(f"Invalid active Stage 1A TAPS_PER_PHASE: {act_tpp}")

    if sym_fold:
        half_len = 2 * num_macs * act_tpp
        full_len = 2 * half_len
        idx = np.arange(half_len, dtype=np.float64)
    else:
        full_len = 2 * num_macs * act_tpp
        idx = np.arange(full_len, dtype=np.float64)

    center = 0.5 * (full_len - 1)
    # Sample offset in baseband input intervals (2 oversampled taps per input sample)
    t_base = (idx - center) / 2.0
    # Ideal lowpass sinc at cutoff_ratio * (Fs_in / 2); np.sinc(u) = sin(pi*u)/(pi*u)
    sinc_core = cutoff_ratio * np.sinc(cutoff_ratio * t_base)

    u_norm = (idx - center) / center  # in [-1, +1]
    arg_sq = np.clip(1.0 - u_norm * u_norm, 0.0, 1.0)

    if profile == "kaiser":
        win = bessel_i0_vec(kaiser_beta * np.sqrt(arg_sq)) / float(
            bessel_i0_vec(np.array([kaiser_beta]))[0]
        )
    elif profile == "wta":
        # Cosine-power WTA-style smooth time-domain window (alpha = 2 -> Hann^2)
        win = (0.5 * (1.0 + np.cos(np.pi * u_norm))) ** 2
    else:
        raise ValueError(f"Unsupported profile '{profile}' (choose 'kaiser' or 'wta')")

    h = sinc_core * win

    if sym_fold:
        # First half of x2 interpolation filter must sum to 1.0
        h /= np.sum(h)
    else:
        # Normalize each polyphase branch independently to 1.0
        h[0::2] /= np.sum(h[0::2])
        h[1::2] /= np.sum(h[1::2])

    return h


def quantize_q17_exact_dc(h: np.ndarray, sym_fold: bool = True) -> np.ndarray:
    """
    Quantizes prototype to signed 18-bit Q1.17 [-131072, +131071] and distributes
    any integer rounding residual (+/-1 LSB) across the main-lobe taps so DC gain
    equals 131,072 (2^17) with 0-LSB error.
    """
    q = np.rint(h * Q17_SCALE).astype(np.int64)
    q = np.clip(q, Q17_MIN, Q17_MAX)

    def fix_branch_sum(branch: np.ndarray, target: int, near_end: bool) -> None:
        diff = int(target - np.sum(branch))
        if diff == 0:
            return
        step = 1 if diff > 0 else -1
        count = abs(diff)
        # Adjust +/-1 LSB on the largest main-lobe taps (end of array for folded half)
        order = (
            np.arange(branch.size - 1, -1, -1)
            if near_end
            else np.argsort(-np.abs(branch))
        )
        adjusted = 0
        for idx in order:
            cand = int(branch[idx]) + step
            if Q17_MIN <= cand <= Q17_MAX:
                branch[idx] = cand
                adjusted += 1
                if adjusted == count:
                    break
        if adjusted != count:
            raise RuntimeError(f"Could not absorb DC rounding residual ({diff} LSBs)")

    if sym_fold:
        # Both Phase 0 and Phase 1 sum (fwd + rev) over the entire half-curve
        fix_branch_sum(q, Q17_SCALE, near_end=True)
    else:
        fix_branch_sum(q[0::2], Q17_SCALE, near_end=False)
        fix_branch_sum(q[1::2], Q17_SCALE, near_end=False)

    return q.astype(np.int32)


def map_to_uram_table(
    q_coefs: np.ndarray,
    num_macs: int,
    taps_per_phase: int,
    rate_shift: int = 0,
) -> np.ndarray:
    """
    Maps quantized Stage 1A coefficients into [NUM_MACS, COEF_DEPTH] URAM layout:
      - uram[m, 0 : act_tpp]           = Phase 0 (t = 0 .. act_tpp - 1)
      - uram[m, act_tpp : 2 * act_tpp] = Phase 1 (t = 0 .. act_tpp - 1)
      - uram[m, 2 * act_tpp : 16*TPP]  = 0 (zero-padded for rate_shift > 0)
    """
    coef_depth = 16 * taps_per_phase
    act_tpp = (8 * taps_per_phase) >> rate_shift
    expected_len = 2 * num_macs * act_tpp
    if q_coefs.size != expected_len:
        raise ValueError(f"Expected {expected_len} quantized taps, got {q_coefs.size}")

    uram = np.zeros((num_macs, coef_depth), dtype=np.int32)
    # Reshape [m, t, p] -> transpose [m, p, t] -> flatten active phase-major [m, 2*act_tpp]
    uram[:, : 2 * act_tpp] = (
        q_coefs.reshape(num_macs, act_tpp, 2)
        .transpose(0, 2, 1)
        .reshape(num_macs, 2 * act_tpp)
    )
    return uram


def pack_ddr4_18b(uram_table: np.ndarray) -> bytes:
    """
    Packs [NUM_MACS, COEF_DEPTH] signed 18-bit coefficients into coef_bank_loader.sv's
    packing=1 continuous stream: 7 x 18-bit coefs per 128-bit little-endian AXI beat
    (bits [125:0]; bits [127:126] = 2'b00; final beat zero-padded).
    """
    flat_u18 = uram_table.reshape(-1).astype(np.int64) & 0x3FFFF
    n_coefs = flat_u18.size
    n_beats = (n_coefs + 6) // 7
    padded = np.zeros(n_beats * 7, dtype=np.uint64)
    padded[:n_coefs] = flat_u18.astype(np.uint64)
    slots = padded.reshape(n_beats, 7)

    # Low 64 bits hold slots 0, 1, 2 (54 bits) + lower 10 bits of slot 3
    lo64 = (
        slots[:, 0]
        | (slots[:, 1] << 18)
        | (slots[:, 2] << 36)
        | ((slots[:, 3] & 0x3FF) << 54)
    )
    # High 64 bits hold upper 8 bits of slot 3 + slots 4, 5, 6 (62 bits total; [63:62]=0)
    hi64 = (
        (slots[:, 3] >> 10)
        | (slots[:, 4] << 8)
        | (slots[:, 5] << 26)
        | (slots[:, 6] << 44)
    )

    beats_le = np.empty((n_beats, 2), dtype="<u8")
    beats_le[:, 0] = lo64
    beats_le[:, 1] = hi64
    return beats_le.tobytes()


def pack_ddr4_v1_32b(uram_table: np.ndarray) -> bytes:
    """Packs [NUM_MACS, COEF_DEPTH] as sign-extended 32-bit little-endian words (packing=0)."""
    return uram_table.reshape(-1).astype("<i4").tobytes()


def build_directory_entry(
    filter_id: int,
    num_macs: int,
    taps_per_phase: int,
    ddr4_byte_addr: int,
    rate_shift: int = 0,
    is_48k_family: bool = True,
    packing: int = 1,
    phase_type: int = 0,
    sym_fold: bool = True,
) -> bytes:
    """
    Builds a 32-byte DDR4 directory entry (dir_beat0 + dir_beat1) matching coef_bank_loader.sv:
      - rate_code[0] = ~stream_rate[0] -> 0 for 48k family, 1 for 44.1k family
      - rate_code[2:1] = rate_shift, rate_schema = 3, rate_shift_mirror = rate_shift
      - tap_count = (NUM_MACS * COEF_DEPTH) >> rate_shift
      - payload_bytes = PK_BYTES (packing=1) or BANK_SIZE_BYTES (packing=0)
    """
    if ddr4_byte_addr % 16 != 0:
        raise ValueError(f"ddr4_byte_addr (0x{ddr4_byte_addr:X}) must be 16-byte aligned")

    coef_depth = 16 * taps_per_phase
    total_coefs = num_macs * coef_depth
    pk_bytes = ((total_coefs + 6) // 7) * 16
    bank_size_bytes = total_coefs * 4
    payload_bytes = pk_bytes if packing == 1 else bank_size_bytes

    rate_code = ((rate_shift & 0x3) << 1) | (0 if is_48k_family else 1)
    tap_count_field = total_coefs >> rate_shift
    ddr4_offset_16b = ddr4_byte_addr >> 4

    base_fs = (48_000.0 if is_48k_family else 44_100.0) * (1 << rate_shift)
    act_tpp = (8 * taps_per_phase) >> rate_shift
    grp_delay_samples = (num_macs * act_tpp) if sym_fold else (0.5 * num_macs * act_tpp)
    latency_us = int(round(1e6 * grp_delay_samples / base_fs))

    beat0 = struct.pack(
        "<HBBIII",
        filter_id & 0xFFFF,
        phase_type & 0xFF,
        rate_code & 0xFF,
        tap_count_field,
        ddr4_offset_16b,
        payload_bytes,
    )
    beat1 = struct.pack(
        "<IBBB9x",
        latency_us,
        packing & 0xFF,
        rate_shift & 0xFF,   # dir_rate_shift_mirror
        3,                   # dir_rate_schema = 3 (supports rate_shift 0..3)
    )
    assert len(beat0) == 16 and len(beat1) == 16
    return beat0 + beat1


def write_mem_hex(uram_table: np.ndarray, path: Path) -> None:
    """Writes 5-hex-digit 18-bit two's-complement coefficients in MAC-major order for $readmemh."""
    flat_u18 = uram_table.reshape(-1).astype(np.int64) & 0x3FFFF
    with path.open("w", encoding="ascii") as f:
        for val in flat_u18:
            f.write(f"{val:05x}\n")


def run_self_test() -> None:
    """Bit-exact verification of Stage 1A gain, URAM mapping, 7/beat packer, and dir header."""
    print("[SELF-TEST] Testing 8.39M-tap geometry (NUM_MACS=128, TAPS_PER_PHASE=256)...")
    for rs in (0, 1, 2, 3):
        h = design_stage1a_half_prototype(128, 256, rate_shift=rs, profile="kaiser")
        q = quantize_q17_exact_dc(h, sym_fold=True)
        uram = map_to_uram_table(q, 128, 256, rate_shift=rs)
        act_tpp = 2048 >> rs

        # 1. Verify exact 2^41 full-scale DC response on BOTH Phase 0 and Phase 1
        x_fs = 1 << 23
        p0_sum = int(np.sum(uram[:, :act_tpp]) + np.sum(uram[:, act_tpp : 2 * act_tpp]))
        p1_sum = int(np.sum(uram[:, act_tpp : 2 * act_tpp]) + np.sum(uram[:, :act_tpp]))
        assert p0_sum == Q17_SCALE and p1_sum == Q17_SCALE
        assert (2 * x_fs * p0_sum) == (1 << 41), "DC full-scale output must equal 2^41!"
        assert np.all(uram[:, 2 * act_tpp :] == 0), "Unused upper URAM region must be 0!"

        # 2. Verify 7-per-beat packing size & exact ST_DRAIN round-trip
        blob = pack_ddr4_18b(uram)
        assert len(blob) == 1_198_384, f"Expected 1,198,384 B, got {len(blob)}"
        beats = np.frombuffer(blob, dtype="<u8").reshape(-1, 2)
        lo, hi = beats[:, 0], beats[:, 1]
        unpacked = np.empty((beats.shape[0], 7), dtype=np.int64)
        unpacked[:, 0] = lo & 0x3FFFF
        unpacked[:, 1] = (lo >> 18) & 0x3FFFF
        unpacked[:, 2] = (lo >> 36) & 0x3FFFF
        unpacked[:, 3] = ((lo >> 54) | ((hi & 0xFF) << 10)) & 0x3FFFF
        unpacked[:, 4] = (hi >> 8) & 0x3FFFF
        unpacked[:, 5] = (hi >> 26) & 0x3FFFF
        unpacked[:, 6] = (hi >> 44) & 0x3FFFF
        assert np.all((hi >> 62) == 0), "Padding bits [127:126] must be zero!"

        u_flat = unpacked.reshape(-1)[: 128 * 4096]
        s_flat = np.where(u_flat >= Q17_SCALE, u_flat - (1 << 18), u_flat).astype(np.int32)
        assert np.array_equal(s_flat.reshape(128, 4096), uram), "7/beat round-trip mismatch!"

        # 3. Verify directory entry fields against coef_bank_loader.sv RTL equations
        hdr = build_directory_entry(
            filter_id=10 + rs,
            num_macs=128,
            taps_per_phase=256,
            ddr4_byte_addr=0x0010_0000,
            rate_shift=rs,
            is_48k_family=True,
            packing=1,
        )
        fid, ptype, rcode, taps, doff, pbytes = struct.unpack("<HBBIII", hdr[:16])
        lat_us, pack_b, rsm, schema = struct.unpack("<IBBB9x", hdr[16:])
        stream_rate = (rs << 1) | 1  # rate_r[0]=1 for 48k family
        assert fid == 10 + rs and pack_b == 1 and pbytes == 1_198_384
        assert schema == 3 and rsm == rs and ((rcode >> 1) & 0x3) == rs
        assert (rcode & 1) == ((~stream_rate) & 1)
        assert taps == ((128 * 4096) >> rs)

    print("[SELF-TEST] PASS: All rate_shift=0..3 Stage 1A tables, 2^41 DC gains,")
    print("            1,198,384-byte 7/beat streams, and directory headers verified!")


def main() -> None:
    ap = argparse.ArgumentParser(description="BFDAC Milestone 5 Stage 1A Coefficient Packer")
    ap.add_argument("--self-test", action="store_true", help="Run bit-exact RTL round-trip tests")
    ap.add_argument("--num-macs", type=int, default=128, help="Stage 1A NUM_MACS (default: 128 -> 8.39M taps)")
    ap.add_argument("--taps-per-phase", type=int, default=256, help="Top-level 16x-normalized TAPS_PER_PHASE (default: 256)")
    ap.add_argument("--rate-shift", type=int, default=0, choices=[0, 1, 2, 3], help="Rate shift 0..3")
    ap.add_argument("--family", choices=["48k", "44k1"], default="48k", help="Oscillator rate family")
    ap.add_argument("--profile", choices=["kaiser", "wta"], default="kaiser", help="Prototype window family")
    ap.add_argument("--beta", type=float, default=18.0, help="Kaiser beta (default: 18.0)")
    ap.add_argument("--cutoff", type=float, default=0.495, help="Cutoff as fraction of Fs_in/2 (default: 0.495)")
    ap.add_argument("--filter-id", type=int, default=1, help="16-bit directory filter_id")
    ap.add_argument("--ddr4-addr", type=lambda x: int(x, 0), default=0x0000_0000, help="16B-aligned DDR4 byte offset")
    ap.add_argument("--packing", type=int, choices=[0, 1], default=1, help="1 = 7x18b packed (default), 0 = 32b v1")
    ap.add_argument("--unfolded", action="store_true", help="Disable 2x symmetric fold (for asymmetric filters)")
    ap.add_argument("--from-npy", type=Path, default=None, help="Load custom float64 prototype from .npy")
    ap.add_argument("--out-bin", type=Path, default=None, help="Output DDR4 payload binary path")
    ap.add_argument("--out-dir-entry", type=Path, default=None, help="Output 32-byte directory entry binary path")
    ap.add_argument("--out-mem", type=Path, default=None, help="Optional $readmemh hex file output")
    args = ap.parse_args()

    if args.self_test:
        run_self_test()
        return

    sym_fold = not args.unfolded
    if args.from_npy is not None:
        h = np.load(args.from_npy).astype(np.float64).reshape(-1)
    else:
        h = design_stage1a_half_prototype(
            num_macs=args.num_macs,
            taps_per_phase=args.taps_per_phase,
            rate_shift=args.rate_shift,
            profile=args.profile,
            cutoff_ratio=args.cutoff,
            kaiser_beta=args.beta,
            sym_fold=sym_fold,
        )

    q = quantize_q17_exact_dc(h, sym_fold=sym_fold)
    uram = map_to_uram_table(q, args.num_macs, args.taps_per_phase, args.rate_shift)
    payload = pack_ddr4_18b(uram) if args.packing == 1 else pack_ddr4_v1_32b(uram)
    dir_entry = build_directory_entry(
        filter_id=args.filter_id,
        num_macs=args.num_macs,
        taps_per_phase=args.taps_per_phase,
        ddr4_byte_addr=args.ddr4_addr,
        rate_shift=args.rate_shift,
        is_48k_family=(args.family == "48k"),
        packing=args.packing,
        sym_fold=sym_fold,
    )

    eff_taps = (
        (32 if sym_fold else 16) * args.num_macs * args.taps_per_phase
    ) >> args.rate_shift
    print(
        f"[STAGE1A PACKER] eff_16x_taps={eff_taps:,} | NUM_MACS={args.num_macs} | "
        f"S1A_TPP={(8 * args.taps_per_phase) >> args.rate_shift} | "
        f"packing={args.packing} | payload={len(payload):,} B"
    )

    if args.out_bin is not None:
        args.out_bin.write_bytes(payload)
        print(f"  -> Wrote payload binary   : {args.out_bin}")
    if args.out_dir_entry is not None:
        args.out_dir_entry.write_bytes(dir_entry)
        print(f"  -> Wrote 32B dir header   : {args.out_dir_entry}")
    if args.out_mem is not None:
        write_mem_hex(uram, args.out_mem)
        print(f"  -> Wrote $readmemh file   : {args.out_mem}")


if __name__ == "__main__":
    main()