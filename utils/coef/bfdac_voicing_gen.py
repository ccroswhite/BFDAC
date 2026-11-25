#!/usr/bin/env python3
"""
bfdac_voicing_gen.py — Standalone Stage 1A Coefficient, DDR4 Image & Persona Generator

Self-contained replacement and superset of stage1a_coef_packer.py (requires only numpy):
  - Stage 1A (x2) symmetric half-curve synthesis + zero-phase Persona contours
  - Exact-DC 18-bit signed Q1.17 quantization (2^41 full-scale DC on Phase 0 & 1)
  - RTL-exact [NUM_MACS, 16*TPP] URAM mapping & 7x18b per 128b AXI4 beat packing
  - 32-byte DDR4 directory builder (schema=3/4, rate_shift=0..3)
  - Multirate FFT auditor cascading Stage 1A with Stage 1B [63, 63, 31] Q1.17 ROMs
"""

from __future__ import annotations
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any
import numpy as np

Q17_SCALE = 1 << 17          # 131,072 (unity gain per polyphase branch)
Q17_MIN   = -(1 << 17)       # -131,072
Q17_MAX   = (1 << 17) - 1    # +131,071

# Schema 4 (hybrid block-exponent outer MACs + Q1.35 hi/lo split main-lobe MACs)
Q35_SCALE = 1 << 35          # split-MAC quantization grid (Q1.35)
EXP_MAX   = 31               # 5-bit per-MAC block exponent (e_m in [0, 31])
L1_LIMIT  = 31.5             # per-phase l1 guard -> post-round sum|C| < 32*2^17, |dsp_preg| < 2^46
Q25_SCALE = 1 << 25          # 33,554,432 (dac_voicing_shaper k2/k3 scale)
SPI_K_MIN = -(1 << 23)       # -8,388,608 (-0.25 in Q(-1).25 sign-ext to Q2.25)
SPI_K_MAX = (1 << 23) - 1    # +8,388,607 (+0.25 - 2^-25)

# Exact 18-bit Q1.17 Stage 1B / halfband_x2.sv Kaiser ROM tables (h[center-(2k+1)])
HB63_HALF_Q17 = np.array(
    [41386, -12932, 6813, -3995, 2380, -1386, 771, -404,
     196, -86, 34, -11, 3, -1, 0, 0],
    dtype=np.int64,
)
HB31_HALF_Q17 = np.array(
    [40533, -10698, 3973, -1333, 349, -61, 5, 0],
    dtype=np.int64,
)


def bessel_i0_vec(x: np.ndarray) -> np.ndarray:
    """Vectorized modified Bessel function I0(x) accurate to IEEE-754 float64."""
    x_half_sq = 0.25 * np.square(x, dtype=np.float64)
    term = np.ones_like(x_half_sq, dtype=np.float64)
    total = np.ones_like(x_half_sq, dtype=np.float64)
    for m in range(1, 50):
        term *= x_half_sq / (m * m)
        total += term
        if float(np.max(term)) < 1e-18 * float(np.max(total)):
            break
    return total


def expand_hb_rom_interp2(half_rom_q17: np.ndarray, num_taps: int) -> np.ndarray:
    """Expands halfband_x2.sv Q1.17 ROM into its exact x2 interpolator impulse (DC sum == 2.0)."""
    h = np.zeros(num_taps, dtype=np.float64)
    center = num_taps // 2
    h[center] = 1.0
    for k, c_q17 in enumerate(half_rom_q17):
        val = (2.0 * float(c_q17)) / float(Q17_SCALE)
        idx_lo = center - (2 * k + 1)
        idx_hi = center + (2 * k + 1)
        if idx_lo >= 0:
            h[idx_lo] = val
            h[idx_hi] = val
    return h


def build_stage1b_impulse(rate_shift: int) -> np.ndarray:
    """Builds exact equivalent Stage 1B (x8/x4/x2/x1) impulse per fir_stage1b_interp8.sv."""
    if rate_shift == 3:
        return np.array([1.0], dtype=np.float64)
    stages: list[np.ndarray] = []
    if rate_shift == 0:
        stages.append(expand_hb_rom_interp2(HB63_HALF_Q17, 63))
    if rate_shift in (0, 1):
        stages.append(expand_hb_rom_interp2(HB63_HALF_Q17, 63))
    stages.append(expand_hb_rom_interp2(HB31_HALF_Q17, 31))

    acc = stages[0]
    for st in stages[1:]:
        up = np.zeros(acc.size * 2 - 1, dtype=np.float64)
        up[0::2] = acc
        acc = np.convolve(up, st)
    return acc


def build_zero_phase_contour_kernel(
    sample_rate_hz: float,
    rate_shift: int,
    lf_shelf_db: float = 0.0,
    lf_corner_hz: float = 80.0,
    total_hf_db_20k: float = 0.0,
    hf_corner_hz: float = 10000.0,
    hf_roll_hz: float | None = None,
    max_half_taps: int = 4096,
) -> np.ndarray | None:
    """Synthesizes an odd-length symmetric zero-phase tonal contour kernel at 2*Fs."""
    has_lf = abs(lf_shelf_db) > 1e-6
    has_hf = abs(total_hf_db_20k) > 1e-6
    has_roll = hf_roll_hz is not None and hf_roll_hz > 0.0
    if not (has_lf or has_hf or has_roll):
        return None

    fs_2x = 2.0 * sample_rate_hz
    eq_half = (2048 if has_lf else 256) << rate_shift
    eq_half = max(64, min(eq_half, max_half_taps))
    n_fft = 1 << max(14, int(math.ceil(math.log2(16 * (2 * eq_half + 1)))))
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / fs_2x)

    db_resp = np.zeros_like(freqs, dtype=np.float64)
    if has_lf:
        db_resp += lf_shelf_db / (1.0 + np.square(freqs / max(lf_corner_hz, 10.0)))
    if has_hf:
        f_hc = max(hf_corner_hz, 1000.0)
        s_f = np.square(freqs / f_hc) / (1.0 + np.square(freqs / f_hc))
        s_20k = ((20000.0 / f_hc) ** 2) / (1.0 + (20000.0 / f_hc) ** 2)
        ratio = np.minimum(s_f / max(s_20k, 1e-9), 1.20)
        db_resp += total_hf_db_20k * ratio
    if has_roll and hf_roll_hz is not None:
        k_1db = (10.0 ** (1.0 / 10.0)) - 1.0
        roll_db = -10.0 * np.log10(1.0 + k_1db * np.power(freqs / hf_roll_hz, 6.0))
        db_resp += np.maximum(roll_db, -36.0)

    mag = np.power(10.0, db_resp / 20.0)
    full_imp = np.fft.irfft(mag, n=n_fft)
    h_eq = np.concatenate([full_imp[-eq_half:], full_imp[: eq_half + 1]])

    u = np.linspace(-1.0, 1.0, 2 * eq_half + 1, dtype=np.float64)
    win = bessel_i0_vec(14.0 * np.sqrt(np.clip(1.0 - u * u, 0.0, 1.0))) / float(
        bessel_i0_vec(np.array([14.0]))[0]
    )
    h_eq *= win
    h_eq = 0.5 * (h_eq + h_eq[::-1])
    h_eq /= np.sum(h_eq)
    return h_eq


def fft_convolve_sym_even_odd(h_lp_half: np.ndarray, h_eq: np.ndarray, half_len: int) -> np.ndarray:
    """Convolves even-length symmetric filter with odd-length symmetric contour via FFT."""
    a_len = h_lp_half.size
    e_half = (h_eq.size - 1) // 2
    h_lp_sym = np.concatenate([h_lp_half, h_lp_half[::-1]])
    conv_len = h_lp_sym.size + h_eq.size - 1
    n_fft = 1 << int(math.ceil(math.log2(conv_len)))
    prod = np.fft.irfft(
        np.fft.rfft(h_lp_sym, n=n_fft) * np.fft.rfft(h_eq, n=n_fft),
        n=n_fft,
    )[:conv_len]

    c_half_len = a_len + e_half
    c_first_half = prod[:c_half_len]
    out_half = np.zeros(half_len, dtype=np.float64)
    if c_half_len <= half_len:
        out_half[half_len - c_half_len :] = c_first_half
    else:
        out_half[:] = c_first_half[c_half_len - half_len :]
    return out_half


def design_persona_half_prototype(
    num_macs: int,
    taps_per_phase: int,
    rate_shift: int,
    sample_rate_hz: float,
    window: str = "kaiser",
    fc_fs_ratio: float = 0.495,
    span_fraction: float = 1.0,
    beta: float = 18.0,
    cos_power: float = 2.0,
    sigma: float = 0.28,
    base_contour: dict[str, Any] | None = None,
    hf_roll_hz: float | None = None,
    extra_hf_db_20k: float = 0.0,
) -> np.ndarray:
    """Designs float64 Stage 1A (x2) first-half prototype of length (2*num_macs*act_tpp)."""
    if not (0 <= rate_shift <= 3):
        raise ValueError(f"rate_shift ({rate_shift}) must be in 0..3")
    act_tpp = (8 * taps_per_phase) >> rate_shift
    if act_tpp < 16 or (act_tpp & (act_tpp - 1)) != 0:
        raise ValueError(f"Invalid active Stage 1A TAPS_PER_PHASE: {act_tpp}")

    half_len = 2 * num_macs * act_tpp
    act_half = max(32, min(half_len, int(round(half_len * float(span_fraction)))))

    offset = np.arange(act_half, dtype=np.float64) - (act_half - 0.5)
    u = np.abs(offset) / (act_half - 0.5)
    sinc_core = (2.0 * fc_fs_ratio) * np.sinc(fc_fs_ratio * offset)

    if window == "kaiser":
        arg = np.sqrt(np.clip(1.0 - u * u, 0.0, 1.0))
        win = bessel_i0_vec(beta * arg) / float(bessel_i0_vec(np.array([beta]))[0])
    elif window in ("wta_cos", "apodizing_cos"):
        win = np.power(0.5 * (1.0 + np.cos(np.pi * u)), cos_power)
    elif window == "gaussian_spline":
        win = np.exp(-0.5 * np.square(u / sigma)) * np.square(np.clip(1.0 - u * u, 0.0, 1.0))
    else:
        raise ValueError(f"Unsupported window family '{window}'")

    h_lp_half = sinc_core * win
    bc = base_contour or {}
    h_eq = build_zero_phase_contour_kernel(
        sample_rate_hz=sample_rate_hz,
        rate_shift=rate_shift,
        lf_shelf_db=float(bc.get("lf_shelf_db", 0.0)),
        lf_corner_hz=float(bc.get("lf_corner_hz", 80.0)),
        total_hf_db_20k=float(bc.get("hf_tilt_db_20k", 0.0)) + float(extra_hf_db_20k),
        hf_corner_hz=float(bc.get("hf_corner_hz", 10000.0)),
        hf_roll_hz=hf_roll_hz,
        max_half_taps=min(4096, half_len // 2),
    )

    if h_eq is not None:
        h_half = fft_convolve_sym_even_odd(h_lp_half, h_eq, half_len)
    else:
        h_half = np.zeros(half_len, dtype=np.float64)
        h_half[half_len - act_half :] = h_lp_half

    h_half /= float(np.sum(h_half))
    return h_half


def quantize_q17_exact_dc(
    h: np.ndarray,
    sym_fold: bool = True,
    shape_stopband: bool = False,
) -> np.ndarray:
    """Quantizes to signed 18-bit Q1.17 and enforces exact 2^17 DC sum per branch."""
    scaled = h * float(Q17_SCALE)
    if shape_stopband and sym_fold:
        q = np.zeros(h.size, dtype=np.int64)
        nz = np.flatnonzero(np.abs(scaled) > 1e-4)
        start = int(nz[0]) if nz.size > 0 else 0
        err = 0.0
        for i in range(start, h.size):
            y = float(scaled[i]) + 0.85 * err
            qi = int(round(y))
            qi = max(Q17_MIN, min(Q17_MAX, qi))
            err = qi - y
            q[i] = qi
    else:
        q = np.clip(np.rint(scaled).astype(np.int64), Q17_MIN, Q17_MAX)

    def fix_sum(branch: np.ndarray, target: int, near_end: bool) -> None:
        diff = int(target - int(np.sum(branch)))
        if diff == 0:
            return
        step = 1 if diff > 0 else -1
        need = abs(diff)
        order = np.arange(branch.size - 1, -1, -1) if near_end else np.argsort(-np.abs(branch))
        done = 0
        for idx in order:
            cand = int(branch[idx]) + step
            if Q17_MIN <= cand <= Q17_MAX:
                branch[idx] = cand
                done += 1
                if done == need:
                    break
        if done != need:
            raise RuntimeError(f"Could not absorb DC residual ({diff} LSBs)")

    if sym_fold:
        fix_sum(q, Q17_SCALE, near_end=True)
    else:
        fix_sum(q[0::2], Q17_SCALE, near_end=False)
        fix_sum(q[1::2], Q17_SCALE, near_end=False)

    return q.astype(np.int32)


def map_to_uram_table(
    q_coefs: np.ndarray,
    num_macs: int,
    taps_per_phase: int,
    rate_shift: int = 0,
) -> np.ndarray:
    """Maps quantized Stage 1A coefficients into [NUM_MACS, 16*TAPS_PER_PHASE] URAM table."""
    coef_depth = 16 * taps_per_phase
    act_tpp = (8 * taps_per_phase) >> rate_shift
    expected_len = 2 * num_macs * act_tpp
    if q_coefs.size != expected_len:
        raise ValueError(f"Expected {expected_len} taps, got {q_coefs.size}")

    uram = np.zeros((num_macs, coef_depth), dtype=np.int32)
    uram[:, : 2 * act_tpp] = (
        q_coefs.reshape(num_macs, act_tpp, 2)
        .transpose(0, 2, 1)
        .reshape(num_macs, 2 * act_tpp)
    )
    return uram


def compute_mac_exponents(
    h: np.ndarray,
    num_macs: int,
    act_tpp: int,
    num_outer: int,
) -> np.ndarray:
    """e_m = max(0, min(e_tap, e_l1_phase, EXP_MAX)) for m < num_outer; 0 on split MACs."""
    e = np.zeros(num_macs, dtype=np.int64)
    for m in range(num_outer):
        seg = h[m * 2 * act_tpp:(m + 1) * 2 * act_tpp]
        mx = float(np.abs(seg).max())
        e_tap = int(math.floor(-math.log2(mx))) - 1 if mx > 0 else EXP_MAX
        l1 = max(float(np.abs(seg[0::2]).sum()), float(np.abs(seg[1::2]).sum()))
        e_l1 = int(math.floor(math.log2(L1_LIMIT / l1))) if l1 > 0 else EXP_MAX
        e[m] = max(0, min(e_tap, e_l1, EXP_MAX))
    return e


def split_hi_lo(c_q35: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Borrow-compensated signed 18b + 18b split: (c_hi << 18) + c_lo == c_q35 exactly."""
    c_lo = ((c_q35 + (1 << 17)) & 0x3FFFF) - (1 << 17)
    c_hi = (c_q35 - c_lo) >> 18
    assert np.all(c_hi >= Q17_MIN) and np.all(c_hi <= Q17_MAX), \
        "split C_hi exceeds signed 18-bit range (|h| ~ 1.0)"
    assert np.array_equal((c_hi << 18) + c_lo, c_q35)
    return c_hi, c_lo


def quantize_hybrid_schema4(
    h: np.ndarray,
    num_macs: int,
    act_tpp: int,
    split_macs: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Schema-4 hybrid quantization.

    Returns (slot_words, e, q_eff):
      slot_words : [num_outer + 2*split_macs, 2*act_tpp] int64 — virtual slot rows
                   (outer mantissas, then per split MAC the {hi, lo} pair)
      e          : [num_macs] int64 exponents (0 on split MACs)
      q_eff      : effective quantized prototype in units of 2^-17 (float64) for
                   the cascade audit / .mem comparison
    """
    num_outer = num_macs - split_macs
    e = compute_mac_exponents(h, num_macs, act_tpp, num_outer)

    q_out = np.zeros((num_outer, 2 * act_tpp), dtype=np.int64)
    outer_dc = 0.0                    # exact dyadic: sum C_m * 2^(18-e_m) on the 2^35 grid
    for m in range(num_outer):
        seg = h[m * 2 * act_tpp:(m + 1) * 2 * act_tpp]
        q_out[m] = np.clip(np.rint(seg * float(Q17_SCALE << int(e[m]))), Q17_MIN, Q17_MAX)
        l1_int = max(int(np.abs(q_out[m][0::2]).sum()), int(np.abs(q_out[m][1::2]).sum()))
        assert l1_int < 32 * Q17_SCALE, f"MAC {m}: post-round l1 {l1_int} would wrap dsp_preg"
        # e_m can exceed 18 -> 2^(18-e_m) is fractional; dyadic float64 stays exact.
        outer_dc += int(q_out[m].sum()) * (2.0 ** (18 - int(e[m])))

    q35 = np.zeros((split_macs, 2 * act_tpp), dtype=np.int64)
    for i, m in enumerate(range(num_outer, num_macs)):
        seg = h[m * 2 * act_tpp:(m + 1) * 2 * act_tpp]
        q35[i] = np.rint(seg * float(Q35_SCALE)).astype(np.int64)

    # DC closure on the 2^35 grid: distribute the integer residual across the
    # last (center) split MAC's taps — per-tap perturbation ~|delta|/2*act_tpp
    # LSBs is quantization-invisible. Sub-LSB remainder (<0.5 on the 2^35 grid)
    # is an irreducible -216 dB DC error from fractional outer contributions.
    residual = float(Q35_SCALE) - outer_dc - float(q35.sum())
    delta = int(round(residual))
    if delta:
        seg_last = q35[-1]
        n = seg_last.size
        seg_last += delta // n
        for idx in np.argsort(-np.abs(seg_last))[: abs(delta - (delta // n) * n)]:
            seg_last[idx] += 1 if delta > 0 else -1

    rows = [q_out[m] for m in range(num_outer)]
    for i, m in enumerate(range(num_outer, num_macs)):
        c_hi, c_lo = split_hi_lo(q35[i])
        rows += [c_hi, c_lo]
    slot_words = np.stack(rows).astype(np.int64)

    q_eff = np.empty(h.size, dtype=np.float64)
    for m in range(num_outer):
        q_eff[m * 2 * act_tpp:(m + 1) * 2 * act_tpp] = q_out[m] * (2.0 ** -int(e[m]))
    for i, m in enumerate(range(num_outer, num_macs)):
        q_eff[m * 2 * act_tpp:(m + 1) * 2 * act_tpp] = q35[i] * (2.0 ** -18)
    return slot_words, e, q_eff


def map_to_uram_schema4(
    slot_words: np.ndarray,
    taps_per_phase: int,
    rate_shift: int = 0,
) -> np.ndarray:
    """Maps [n_slots, 2*act_tpp] schema-4 slot rows into [n_slots, COEF_DEPTH]."""
    coef_depth = 16 * taps_per_phase
    act_tpp = (8 * taps_per_phase) >> rate_shift
    n_slots = slot_words.shape[0]
    uram = np.zeros((n_slots, coef_depth), dtype=np.int32)
    uram[:, : 2 * act_tpp] = (
        slot_words.reshape(n_slots, act_tpp, 2)
        .transpose(0, 2, 1)
        .reshape(n_slots, 2 * act_tpp)
    )
    return uram


def pack_ddr4_18b(uram_table: np.ndarray) -> bytes:
    """Packs [NUM_MACS, COEF_DEPTH] into 7 x 18-bit words per 128-bit AXI4 beat (packing=1)."""
    flat_u18 = (uram_table.reshape(-1).astype(np.int64) & 0x3FFFF).astype(np.uint64)
    n_coefs = flat_u18.size
    n_beats = (n_coefs + 6) // 7
    padded = np.zeros(n_beats * 7, dtype=np.uint64)
    padded[:n_coefs] = flat_u18
    slots = padded.reshape(n_beats, 7)

    lo64 = (
        slots[:, 0]
        | (slots[:, 1] << np.uint64(18))
        | (slots[:, 2] << np.uint64(36))
        | ((slots[:, 3] & np.uint64(0x3FF)) << np.uint64(54))
    )
    hi64 = (
        (slots[:, 3] >> np.uint64(10))
        | (slots[:, 4] << np.uint64(8))
        | (slots[:, 5] << np.uint64(26))
        | (slots[:, 6] << np.uint64(44))
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
    split_macs: int = 0,
) -> bytes:
    """Builds 32-byte DDR4 directory entry (schema=3 for packing 0/1, schema=4 for packing 2)."""
    if ddr4_byte_addr % 16 != 0:
        raise ValueError(f"ddr4_byte_addr (0x{ddr4_byte_addr:X}) must be 16-byte aligned")

    coef_depth = 16 * taps_per_phase
    total_coefs = num_macs * coef_depth
    if packing == 2:
        # Schema 4: (NUM_MACS + SPLIT_MACS) URAM slots + NUM_MACS exponent words
        n_words = (num_macs + split_macs) * coef_depth + num_macs
        payload_bytes = ((n_words + 6) // 7) * 16
        schema = 4
    elif packing == 1:
        payload_bytes = ((total_coefs + 6) // 7) * 16
        schema = 3
    else:
        payload_bytes = total_coefs * 4
        schema = 3

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
    beat1 = struct.pack("<IBBB9x", latency_us, packing & 0xFF, rate_shift & 0xFF, schema)
    return beat0 + beat1


def write_mem_hex(uram_table: np.ndarray, path: Path) -> None:
    """Writes 5-hex-digit 18-bit words in MAC-major order for $readmemh."""
    flat_u18 = uram_table.reshape(-1).astype(np.int64) & 0x3FFFF
    with path.open("w", encoding="ascii") as f:
        for val in flat_u18:
            f.write(f"{val:05x}\n")


def write_sim_ddr4_hex(
    payload_bytes: bytes,
    dir_bytes: bytes,
    ddr4_base_addr: int,
    dir_base_addr: int,
    hex_path: Path,
) -> None:
    """Writes a unified word-addressed DDR4 image (32-hex-digit 128-bit AXI4
    beats with @word-address section headers) for $readmemh associative-array
    TBs (tb_dsp_voicing_e2e). Byte 0 of each beat lands in m_axi_rdata[7:0]."""
    assert len(payload_bytes) % 16 == 0 and len(dir_bytes) % 16 == 0
    hex_path.parent.mkdir(parents=True, exist_ok=True)
    with hex_path.open("w", encoding="ascii") as f:
        for base_byte, blob in ((ddr4_base_addr, payload_bytes), (dir_base_addr, dir_bytes)):
            f.write(f"@{base_byte >> 4:08x}\n")
            beats = np.frombuffer(blob, dtype="<u8").reshape(-1, 2)
            for lo64, hi64 in beats:
                f.write(f"{int(hi64):016x}{int(lo64):016x}\n")


def audit_cascade_response(
    h_half_float: np.ndarray,
    q_half_int: np.ndarray,
    sample_rate_hz: float,
    rate_shift: int,
) -> dict[str, float]:
    """Audits multirate Stage 1A + Stage 1B ([63, 63, 31] ROMs) frequency & image response."""
    full_len = 2 * h_half_float.size
    n_fft_1a = 1 << max(18, int(math.ceil(math.log2(full_len))))

    h_full_f = np.concatenate([h_half_float, h_half_float[::-1]])
    h_full_q = np.concatenate([q_half_int, q_half_int[::-1]]).astype(np.float64) / float(Q17_SCALE)

    H1a_f = 0.5 * np.abs(np.fft.rfft(h_full_f, n=n_fft_1a))
    H1a_q = 0.5 * np.abs(np.fft.rfft(h_full_q, n=n_fft_1a))

    interp_1b = 8 >> rate_shift
    fs_2x = 2.0 * sample_rate_hz
    fs_out = fs_2x * interp_1b

    f_img_lo = 0.505 * sample_rate_hz
    # Replica-safe upper edge: the mirrored passband replica occupies
    # [fs_2x - f_img_lo, fs_2x] and its floor (~-87 dBc) is set by the fixed
    # Stage-1B HB63/31 ROMs — identical for every persona and unaffected by
    # fc_fs_ratio. Scanning into it flags a hardware constant as a filter
    # defect (the 12 phantom rc=1/44.1k proto-ceiling fails — the band edge
    # 68k sits inside the replica only for the 44.1k family).
    replica_onset = fs_2x - f_img_lo
    if rate_shift == 0:
        f_img_hi = min(68000.0, replica_onset)
    elif rate_shift in (1, 2):
        f_img_hi = min(1.42 * sample_rate_hz, replica_onset)
    else:
        f_img_hi = min(0.98 * sample_rate_hz, replica_onset)

    df = fs_2x / float(n_fft_1a)
    max_bin = int(math.ceil(fs_2x / df))
    bins = np.arange(0, max_bin + 1, dtype=np.int64)
    freqs = bins.astype(np.float64) * df

    mod_bins = bins % n_fft_1a
    s1a_bins = np.where(mod_bins <= (n_fft_1a // 2), mod_bins, n_fft_1a - mod_bins)

    h_s1b = build_stage1b_impulse(rate_shift)
    if h_s1b.size == 1:
        H1b = np.ones_like(freqs)
    else:
        c_idx = (h_s1b.size - 1) // 2
        H1b_c = np.full_like(freqs, h_s1b[c_idx], dtype=np.float64)
        omega_out = (2.0 * np.pi / fs_out) * freqs
        for k in range(1, c_idx + 1):
            val = h_s1b[c_idx + k]
            if val != 0.0:
                H1b_c += (2.0 * val) * np.cos(k * omega_out)
        H1b = np.abs(H1b_c) / float(interp_1b)

    cas_f = H1a_f[s1a_bins] * H1b
    cas_q = H1a_q[s1a_bins] * H1b

    idx_1k = int(round(1000.0 / df))
    idx_20k = int(round(20000.0 / df))
    img_mask = (freqs >= f_img_lo) & (freqs <= f_img_hi)
    # Mirrored-replica floor (fixed 1B suppression only meaningful rs<3;
    # at rs=3 the replica is raw and HB1's job downstream — report -inf).
    rep_mask = (freqs >= replica_onset) & (freqs <= fs_2x) & (rate_shift < 3)

    eps = 1e-20
    gain_1k_db = float(20.0 * math.log10(max(float(cas_q[idx_1k]), eps)))
    gain_20k_db = float(20.0 * math.log10(max(float(cas_q[idx_20k]), eps)))
    proto_img_dbc = float(20.0 * math.log10(max(float(np.max(cas_f[img_mask])), eps)))
    q17_img_dbc = float(20.0 * math.log10(max(float(np.max(cas_q[img_mask])), eps)))
    replica_dbc = float(20.0 * math.log10(max(float(np.max(cas_q[rep_mask])), eps))) if np.any(rep_mask) else -300.0

    return {
        "gain_1k_db": round(gain_1k_db, 4),
        "gain_20k_db": round(gain_20k_db, 4),
        "tilt_20k_vs_1k_db": round(gain_20k_db - gain_1k_db, 4),
        "proto_max_image_dbc": round(proto_img_dbc, 2),
        "q17_max_image_dbc": round(q17_img_dbc, 2),
        "replica_floor_dbc": round(replica_dbc, 2),
        "nonzero_half_taps": int(np.count_nonzero(q_half_int)),
    }


def encode_filter_id(persona_id: int, filter_idx: int, rate_code: int) -> int:
    if not (0 <= persona_id <= 126):
        raise ValueError(f"persona_id ({persona_id}) must be 0..126 (127 reserved for 0xFFFF)")
    if not (0 <= filter_idx <= 63):
        raise ValueError(f"filter_idx ({filter_idx}) must be 0..63")
    if not (0 <= rate_code <= 7):
        raise ValueError(f"rate_code ({rate_code}) must be 0..7")
    fid = ((persona_id & 0x7F) << 9) | ((filter_idx & 0x3F) << 3) | (rate_code & 0x7)
    assert fid != 0xFFFF, "filter_id collided with 0xFFFF keep-bank sentinel!"
    return fid


def emit_c_header(manifest: dict[str, Any], header_path: Path) -> None:
    lines = [
        "/* Auto-generated by bfdac_voicing_gen.py — DO NOT EDIT MANUALLY */",
        "#ifndef BFDAC_PERSONAS_TABLE_H",
        "#define BFDAC_PERSONAS_TABLE_H",
        "",
        "#include <stdint.h>",
        "#include <stdbool.h>",
        "",
        "#define BFDAC_STREAM_RATE_TO_CODE(sr) (((uint16_t)(sr) & 0x7u) ^ 0x1u)",
        "#define BFDAC_MAKE_FILTER_ID(persona, filt_idx, rate_code) \\",
        "    ((uint16_t)((((uint16_t)(persona) & 0x7Fu) << 9) | \\",
        "                (((uint16_t)(filt_idx) & 0x3Fu) << 3) | \\",
        "                ((uint16_t)(rate_code) & 0x7u)))",
        "#define BFDAC_VOICING_KEEP_BANK_FID 0xFFFFu",
        "",
        "typedef struct {",
        "    uint8_t     persona_id;",
        "    const char *key;",
        "    const char *name;",
        "    bool        voicing_en;",
        "    int32_t     k2_q25;",
        "    int32_t     k3_q25;",
        "    uint32_t    spi_k2_u24;",
        "    uint32_t    spi_k3_u24;",
        "    uint8_t     filter_count;",
        "    const char *filter_names[8];",
        "} bfdac_persona_desc_t;",
        "",
        f"#define BFDAC_PERSONA_COUNT {len(manifest['personas'])}u",
        "",
        "static const bfdac_persona_desc_t g_bfdac_personas[BFDAC_PERSONA_COUNT] = {",
    ]
    for p in manifest["personas"]:
        fnames = [f'"{flt["name"]}"' for flt in p["filters"][:8]]
        while len(fnames) < 8:
            fnames.append("0")
        en_str = "true" if p["voicing_en"] else "false"
        lines.append(
            f'    {{ {p["persona_id"]}u, "{p["key"]}", "{p["name"]}", {en_str}, '
            f'{p["k2_q25"]}, {p["k3_q25"]}, '
            f'0x{p["spi_k2_u24"]:06X}u, 0x{p["spi_k3_u24"]:06X}u, '
            f'{len(p["filters"])}u, {{ {", ".join(fnames)} }} }},'
        )
    lines += ["};", "", "#endif /* BFDAC_PERSONAS_TABLE_H */", ""]
    header_path.write_text("\n".join(lines), encoding="utf-8")


def build_from_catalog(
    catalog_path: Path,
    out_dir: Path,
    num_macs_override: int | None,
    tpp_override: int | None,
    rate_codes_sel: list[int],
    persona_keys_sel: set[str] | None,
    shape_q17: bool,
    emit_individual: bool,
    emit_mem: bool,
    split_macs_override: int | None = None,
    emit_sim_hex: Path | None = None,
    skip_audit_fail: bool = False,
) -> None:
    cat = json.loads(catalog_path.read_text(encoding="utf-8"))
    defaults = cat["target_defaults"]
    num_macs = num_macs_override if num_macs_override is not None else int(defaults["num_macs"])
    tpp = tpp_override if tpp_override is not None else int(defaults["taps_per_phase"])
    packing = int(defaults.get("packing", 2))   # Schema-4 is the hw contract —
                                               # dir_packing_ok rejects schema!=4
    split_macs = (split_macs_override if split_macs_override is not None
                  else int(defaults.get("split_macs", 0))) if packing == 2 else 0
    if packing == 2:
        num_outer = num_macs - split_macs
        if split_macs <= 0 or num_outer < 2 or num_outer % 2:
            raise ValueError(
                f"packing=2 requires even NUM_OUTER = num_macs - split_macs >= 2 "
                f"(got num_macs={num_macs}, split_macs={split_macs})"
            )
        if shape_q17:
            print("[VOICING-GEN] note: --shape-q17 ignored for packing=2 (hybrid grid supersedes it)")
    sym_fold = bool(defaults.get("sym_fold", True))
    ddr4_base = int(str(defaults.get("ddr4_base_addr", "0x0")), 0)
    if ddr4_base % 4096 != 0:
        raise ValueError(
            f"ddr4_base_addr (0x{ddr4_base:X}) must be 4 KiB aligned — "
            "loader bursts are 256-beat INCR and must not cross page boundaries"
        )
    dir_base = int(str(defaults.get("dir_base_addr", "0x3FFF0000")), 0)
    dir_max = int(defaults.get("dir_max_entries", 1024))

    rate_map = {int(r["rate_code"]): r for r in cat["rates"]}
    selected_rates = [rate_map[rc] for rc in rate_codes_sel]

    out_dir.mkdir(parents=True, exist_ok=True)
    banks_dir = out_dir / "banks"
    if emit_individual or emit_mem:
        banks_dir.mkdir(parents=True, exist_ok=True)

    seen_fids: set[int] = set()
    dedup_addr_by_sha: dict[str, int] = {}
    payload_chunks: list[bytes] = []
    dir_entries: list[bytes] = []
    cur_ddr4_addr = ddr4_base
    manifest_personas: list[dict[str, Any]] = []

    print(
        f"[VOICING-GEN] Target NUM_MACS={num_macs}, TAPS_PER_PHASE={tpp} "
        f"({(32 if sym_fold else 16) * num_macs * tpp:,} eff 16x taps @ 1x) | "
        f"rates={[r['sample_rate_hz'] for r in selected_rates]}"
    )
    quant_hdr = "QuantImg" if packing == 2 else "Q17Img"
    print(
        f"{'FID':<8} {'Persona / Filter':<38} {'Fs(kHz)':>7} "
        f"{'20kTilt':>8} {'ProtoImg':>9} {quant_hdr:>8} {'Limit':>8}"
    )
    print("-" * 92)

    for p in cat["personas"]:
        if persona_keys_sel and p["key"] not in persona_keys_sel:
            continue

        pid = int(p["persona_id"])
        sh = p["shaper"]
        vo_en = bool(sh["voicing_en"])
        k2_q25 = int(sh["k2_q25"])
        k3_q25 = int(sh["k3_q25"])
        exp_k2 = int(round(float(sh["k2_float"]) * Q25_SCALE))
        exp_k3 = int(round(float(sh["k3_float"]) * Q25_SCALE))
        if abs(k2_q25 - exp_k2) > 1 or abs(k3_q25 - exp_k3) > 1:
            raise ValueError(f"Persona {p['key']}: k2/k3_q25 mismatch vs float * 2^25")
        if not (SPI_K_MIN <= k2_q25 <= SPI_K_MAX and SPI_K_MIN <= k3_q25 <= SPI_K_MAX):
            raise ValueError(f"Persona {p['key']}: k2/k3 exceeds signed 24-bit Q(-1).25 SPI range")

        p_entry: dict[str, Any] = {
            "persona_id": pid,
            "key": p["key"],
            "name": p["name"],
            "execution_class": p["execution_class"],
            "voicing_en": vo_en,
            "k2_q25": k2_q25,
            "k3_q25": k3_q25,
            "spi_k2_u24": k2_q25 & 0xFFFFFF,
            "spi_k3_u24": k3_q25 & 0xFFFFFF,
            "filters": [],
        }

        for flt in p["filters"]:
            fidx = int(flt["filter_idx"])
            max_img_limit = float(flt["max_image_dbc"])
            f_entry: dict[str, Any] = {
                "filter_idx": fidx,
                "key": flt["key"],
                "name": flt["name"],
                "rates": {},
            }

            for rinfo in selected_rates:
                rc = int(rinfo["rate_code"])
                rs = int(rinfo["rate_shift"])
                fs_hz = float(rinfo["sample_rate_hz"])
                is_48k = int(rinfo["family_44k1"]) == 0

                fid = encode_filter_id(pid, fidx, rc)
                if fid in seen_fids:
                    raise ValueError(f"Duplicate filter_id 0x{fid:04X}")
                seen_fids.add(fid)

                h_half = design_persona_half_prototype(
                    num_macs=num_macs,
                    taps_per_phase=tpp,
                    rate_shift=rs,
                    sample_rate_hz=fs_hz,
                    window=str(flt["window"]),
                    fc_fs_ratio=float(flt["fc_fs_ratio"]),
                    span_fraction=float(flt.get("span_fraction", 1.0)),
                    beta=float(flt.get("beta", 18.0)),
                    cos_power=float(flt.get("cos_power", 2.0)),
                    sigma=float(flt.get("sigma", 0.28)),
                    base_contour=p.get("base_contour"),
                    hf_roll_hz=flt.get("hf_roll_hz"),
                    extra_hf_db_20k=float(flt.get("extra_hf_db_20k", 0.0)),
                )
                act_tpp = (8 * tpp) >> rs
                if packing == 2:
                    slot_words, exp_words, q_meas = quantize_hybrid_schema4(
                        h_half, num_macs, act_tpp, split_macs
                    )
                    low_e = np.flatnonzero(exp_words[: num_macs - split_macs] < 6)
                    if low_e.size:
                        print(
                            f"[EXP WARN] {p['key']}/{flt['key']} @ {fs_hz} Hz: outer MACs "
                            f"{list(low_e)} have e<6 — check split-set coverage for this contour"
                        )
                    uram = map_to_uram_schema4(slot_words, tpp, rs)
                    blob = pack_ddr4_18b(np.concatenate([uram.reshape(-1).astype(np.int64), exp_words]))
                else:
                    exp_words = None
                    q_meas = quantize_q17_exact_dc(h_half, sym_fold=sym_fold, shape_stopband=shape_q17)
                    assert int(np.sum(q_meas)) == Q17_SCALE, "Exact 2^17 DC invariant violated!"
                    uram = map_to_uram_table(q_meas, num_macs, tpp, rs)
                    blob = pack_ddr4_18b(uram) if packing == 1 else pack_ddr4_v1_32b(uram)

                metrics = audit_cascade_response(h_half, q_meas, fs_hz, rs)
                if metrics["proto_max_image_dbc"] > max_img_limit:
                    if skip_audit_fail:
                        print(
                            f"[AUDIT SKIP] {p['key']}/{flt['key']} @ {fs_hz} Hz: "
                            f"prototype image {metrics['proto_max_image_dbc']:.2f} dBc > "
                            f"ceiling {max_img_limit:.2f} dBc — excluded (sim geometry)"
                        )
                        continue
                    raise RuntimeError(
                        f"[AUDIT FAIL] {p['key']}/{flt['key']} @ {fs_hz} Hz: "
                        f"prototype image {metrics['proto_max_image_dbc']:.2f} dBc > "
                        f"ceiling {max_img_limit:.2f} dBc"
                    )
                if metrics["q17_max_image_dbc"] > max_img_limit:
                    # Hardware response is the QUANTIZED one — warn when tail
                    # underflow pushes image rejection past the proto ceiling
                    # (candidate for --shape-q17 or a longer tail).
                    print(
                        f"[AUDIT WARN] {p['key']}/{flt['key']} @ {fs_hz} Hz: "
                        f"quantized image {metrics['q17_max_image_dbc']:.2f} dBc exceeds "
                        f"ceiling {max_img_limit:.2f} dBc (proto "
                        f"{metrics['proto_max_image_dbc']:.2f} dBc)"
                    )

                sha = hashlib.sha256(blob).hexdigest()[:16]

                if sha in dedup_addr_by_sha:
                    bank_addr = dedup_addr_by_sha[sha]
                else:
                    bank_addr = cur_ddr4_addr
                    dedup_addr_by_sha[sha] = bank_addr
                    payload_chunks.append(blob)
                    # 4 KiB bank alignment: coef_bank_loader issues 256-beat
                    # (4096 B) INCR bursts and AXI4 forbids a burst crossing a
                    # 4 KiB boundary — a 16 B-aligned bank start would make
                    # every burst a protocol violation (SLVERR on the dwc).
                    # Costs <0.3% padding at ~1.2 MB/bank.
                    aligned_len = (len(blob) + 4095) & ~4095
                    cur_ddr4_addr += aligned_len
                    if aligned_len > len(blob):
                        payload_chunks.append(b"\x00" * (aligned_len - len(blob)))

                dir_hdr = build_directory_entry(
                    filter_id=fid,
                    num_macs=num_macs,
                    taps_per_phase=tpp,
                    ddr4_byte_addr=bank_addr,
                    rate_shift=rs,
                    is_48k_family=is_48k,
                    packing=packing,
                    sym_fold=sym_fold,
                    split_macs=split_macs,
                )
                dir_entries.append(dir_hdr)

                if emit_individual:
                    (banks_dir / f"fid_{fid:04x}_{p['key']}_{flt['key']}_{int(fs_hz)}.bin").write_bytes(blob)
                if emit_mem:
                    mem_words = uram if exp_words is None else np.concatenate(
                        [uram.reshape(-1).astype(np.int64), exp_words]
                    )
                    write_mem_hex(mem_words, banks_dir / f"fid_{fid:04x}_{p['key']}_{flt['key']}_{int(fs_hz)}.mem")

                label = f"{p['key'][:14]}/{flt['key'][:22]}"
                print(
                    f"0x{fid:04X}   {label:<38} {fs_hz/1e3:>7.1f} "
                    f"{metrics['tilt_20k_vs_1k_db']:>+7.2f}dB "
                    f"{metrics['proto_max_image_dbc']:>8.1f}  "
                    f"{metrics['q17_max_image_dbc']:>7.1f}  "
                    f"{max_img_limit:>7.1f}"
                )

                f_entry["rates"][str(rc)] = {
                    "filter_id": fid,
                    "filter_id_hex": f"0x{fid:04X}",
                    "sample_rate_hz": int(fs_hz),
                    "ddr4_byte_addr": f"0x{bank_addr:08X}",
                    "payload_bytes": len(blob),
                    "audit": metrics,
                }

            p_entry["filters"].append(f_entry)
        manifest_personas.append(p_entry)

    if len(dir_entries) + 1 > dir_max:
        raise RuntimeError(
            f"Directory entries ({len(dir_entries)} + 1 terminator) exceed DIR_MAX_ENTRIES ({dir_max})"
        )
    dir_entries.append(b"\x00" * 32)

    if cur_ddr4_addr > dir_base:
        raise RuntimeError(
            f"Payload footprint top 0x{cur_ddr4_addr:X} overruns dir_base_addr "
            f"0x{dir_base:X} — grow dir_base_addr or shrink the catalog"
        )

    payload_bytes_all = b"".join(payload_chunks)
    dir_bytes_all = b"".join(dir_entries)
    (out_dir / "ddr4_coef_payload.bin").write_bytes(payload_bytes_all)
    (out_dir / "ddr4_directory.bin").write_bytes(dir_bytes_all)
    if emit_sim_hex is not None:
        write_sim_ddr4_hex(payload_bytes_all, dir_bytes_all, ddr4_base, dir_base, emit_sim_hex)

    manifest_doc = {
        "num_macs": num_macs,
        "taps_per_phase": tpp,
        "sym_fold": sym_fold,
        "packing": packing,
        "split_macs": split_macs,
        "dir_schema": 4 if packing == 2 else 3,
        "shape_q17": shape_q17,
        "directory_entries": len(dir_entries) - 1,
        "unique_payload_banks": len(dedup_addr_by_sha),
        "total_payload_bytes": len(payload_bytes_all),
        "personas": manifest_personas,
    }
    (out_dir / "personas_manifest.json").write_text(json.dumps(manifest_doc, indent=2), encoding="utf-8")
    emit_c_header(manifest_doc, out_dir / "bfdac_personas_table.h")

    print("-" * 92)
    print(
        f"[VOICING-GEN] OK: {len(dir_entries)-1} directory entries "
        f"({len(dedup_addr_by_sha)} unique banks, {len(payload_bytes_all)/1048576:.2f} MiB) -> {out_dir}"
    )


def run_self_test(catalog_path: Path | None = None) -> None:
    print("[SELF-TEST 1/3] Stage 1A URAM layout, 2^41 DC gain, 7/beat AXI4 unpack & schema=3 dir...")
    for rs in (0, 1, 2, 3):
        fs = 48_000.0 * (1 << rs)
        h = design_persona_half_prototype(128, 256, rate_shift=rs, sample_rate_hz=fs, window="kaiser")
        q = quantize_q17_exact_dc(h, sym_fold=True)
        uram = map_to_uram_table(q, 128, 256, rate_shift=rs)
        act_tpp = 2048 >> rs

        x_fs = 1 << 23
        p0_sum = int(np.sum(uram[:, :act_tpp]) + np.sum(uram[:, act_tpp : 2 * act_tpp]))
        p1_sum = int(np.sum(uram[:, act_tpp : 2 * act_tpp]) + np.sum(uram[:, :act_tpp]))
        assert p0_sum == Q17_SCALE and p1_sum == Q17_SCALE
        assert (2 * x_fs * p0_sum) == (1 << 41), "Full-scale DC output must equal exact 2^41!"
        assert np.all(uram[:, 2 * act_tpp :] == 0), "Unused upper URAM region must be 0!"

        blob = pack_ddr4_18b(uram)
        assert len(blob) == 1_198_384, f"Expected 1,198,384 B, got {len(blob)}"
        beats = np.frombuffer(blob, dtype="<u8").reshape(-1, 2)
        lo, hi = beats[:, 0], beats[:, 1]
        unp = np.empty((beats.shape[0], 7), dtype=np.int64)
        unp[:, 0] = lo & 0x3FFFF
        unp[:, 1] = (lo >> 18) & 0x3FFFF
        unp[:, 2] = (lo >> 36) & 0x3FFFF
        unp[:, 3] = ((lo >> 54) | ((hi & 0xFF) << 10)) & 0x3FFFF
        unp[:, 4] = (hi >> 8) & 0x3FFFF
        unp[:, 5] = (hi >> 26) & 0x3FFFF
        unp[:, 6] = (hi >> 44) & 0x3FFFF
        assert np.all((hi >> 62) == 0), "AXI beat bits [127:126] must be 0!"

        u_flat = unp.reshape(-1)[: 128 * 4096]
        s_flat = np.where(u_flat >= Q17_SCALE, u_flat - (1 << 18), u_flat).astype(np.int32)
        assert np.array_equal(s_flat.reshape(128, 4096), uram), "7/beat unpack mismatch!"

        fid = encode_filter_id(persona_id=4, filter_idx=2, rate_code=(rs << 1))
        hdr = build_directory_entry(fid, 128, 256, 0x0020_0000, rate_shift=rs, is_48k_family=True)
        d_fid, _, rcode, taps, doff, pbytes = struct.unpack("<HBBIII", hdr[:16])
        _, pack_b, rsm, schema = struct.unpack("<IBBB9x", hdr[16:])
        stream_rate = (rs << 1) | 1
        assert d_fid == fid and pack_b == 1 and pbytes == 1_198_384 and doff == (0x0020_0000 >> 4)
        assert schema == 3 and rsm == rs and ((rcode >> 1) & 0x3) == rs
        assert (rcode & 1) == ((~stream_rate) & 1) and taps == ((128 * 4096) >> rs)

    print("[SELF-TEST 1b/3] Schema-4 hybrid quantizer (80 MACs, split 68..79, packing=2)...")
    NM, SM = 80, 12
    for rs in (0, 3):
        fs = 48_000.0 * (1 << rs)
        h = design_persona_half_prototype(NM, 256, rate_shift=rs, sample_rate_hz=fs, window="kaiser")
        act_tpp = 2048 >> rs
        sw, e, q_eff = quantize_hybrid_schema4(h, NM, act_tpp, SM)
        n_outer = NM - SM
        n_slots = n_outer + 2 * SM
        assert sw.shape == (n_slots, 2 * act_tpp) and e.shape == (NM,)
        assert np.all(e[n_outer:] == 0) and e[:n_outer].min() >= 0 and e[:n_outer].max() <= EXP_MAX
        # Reconstruct exact dyadic DC from slot words (e can exceed 18 -> outer
        # contribution is fractional); residual must be < 0.5 LSB on the 2^35 grid.
        dc = 0.0
        for m in range(n_outer):
            dc += int(sw[m].sum()) * (2.0 ** (18 - int(e[m])))
        for m in range(n_outer, NM):
            c_hi = sw[n_outer + 2 * (m - n_outer)].astype(np.int64)
            c_lo = sw[n_outer + 2 * (m - n_outer) + 1].astype(np.int64)
            dc += float(((c_hi << 18) + c_lo).sum())
        assert abs(dc - float(Q35_SCALE)) <= 0.5, f"schema-4 DC off grid by {dc - Q35_SCALE}"
        # Post-round per-phase l1 on every outer MAC must stay < 32*2^17 (preg bound).
        for m in range(n_outer):
            l1i = max(int(np.abs(sw[m][0::2]).sum()), int(np.abs(sw[m][1::2]).sum()))
            assert l1i < 32 * Q17_SCALE, f"MAC {m} l1 {l1i} wraps preg"
        # q_eff DC must equal the reconstructed dyadic DC (audit units 2^-17).
        assert abs(float(q_eff.sum()) * (2.0 ** 18) - dc) < 1e-6
        # Flat stream = n_slots*COEF_DEPTH + NM exp words; pack & dir header checks.
        uram = map_to_uram_schema4(sw, 256, rs)
        assert uram.shape == (n_slots, 4096)
        flat = np.concatenate([uram.reshape(-1).astype(np.int64), e])
        n_words = n_slots * 4096 + NM
        blob = pack_ddr4_18b(flat)
        assert len(blob) == ((n_words + 6) // 7) * 16
        hdr = build_directory_entry(
            encode_filter_id(4, 2, rs << 1), NM, 256, 0x0020_0000,
            rate_shift=rs, packing=2, split_macs=SM,
        )
        _, _, rcode, taps, doff, pbytes = struct.unpack("<HBBIII", hdr[:16])
        _, pb, rsm, schema = struct.unpack("<IBBB9x", hdr[16:])
        assert schema == 4 and pb == 2 and rsm == rs
        assert pbytes == len(blob) and doff == (0x0020_0000 >> 4)
        assert taps == ((NM * 4096) >> rs), "tap_count must be NUM_MACS*COEF_DEPTH >> rs (loader check)"

    print("[SELF-TEST 2/3] Verifying Stage 1B [63, 63, 31] Q1.17 ROM DC & image rejection...")
    assert int(np.sum(HB63_HALF_Q17)) == 32768 and int(np.sum(HB31_HALF_Q17)) == 32768
    for rs, exp_sum in ((0, 8.0), (1, 4.0), (2, 2.0), (3, 1.0)):
        h1b = build_stage1b_impulse(rs)
        assert abs(float(np.sum(h1b)) - exp_sum) < 1e-12

    cat_file = catalog_path if (catalog_path and catalog_path.exists()) else Path("persona_catalog.json")
    if cat_file.exists():
        cat = json.loads(cat_file.read_text(encoding="utf-8"))
        td = cat.get("target_defaults", {})
        st_nm = int(td.get("num_macs", 128))
        st_tpp = int(td.get("taps_per_phase", 256))
        st_packing = int(td.get("packing", 2))
        st_sm = int(td.get("split_macs", 12)) if st_packing == 2 else 0
        print(f"[SELF-TEST 3/3] Auditing all Personas & Filters in {cat_file} @ 48 kHz "
              f"(catalog defaults: NUM_MACS={st_nm}, packing={st_packing}, split={st_sm})...")
        checked = 0
        quant_over = 0
        for p in cat["personas"]:
            pid = int(p["persona_id"])
            for flt in p["filters"]:
                fidx = int(flt["filter_idx"])
                _ = encode_filter_id(pid, fidx, 0)
                h = design_persona_half_prototype(
                    num_macs=st_nm,
                    taps_per_phase=st_tpp,
                    rate_shift=0,
                    sample_rate_hz=48_000.0,
                    window=str(flt["window"]),
                    fc_fs_ratio=float(flt["fc_fs_ratio"]),
                    span_fraction=float(flt.get("span_fraction", 1.0)),
                    beta=float(flt.get("beta", 18.0)),
                    cos_power=float(flt.get("cos_power", 2.0)),
                    sigma=float(flt.get("sigma", 0.28)),
                    base_contour=p.get("base_contour"),
                    hf_roll_hz=flt.get("hf_roll_hz"),
                    extra_hf_db_20k=float(flt.get("extra_hf_db_20k", 0.0)),
                )
                if st_packing == 2:
                    _, _, q = quantize_hybrid_schema4(h, st_nm, 8 * st_tpp, st_sm)
                else:
                    q = quantize_q17_exact_dc(h, sym_fold=True)
                m = audit_cascade_response(h, q, 48_000.0, rate_shift=0)
                assert m["proto_max_image_dbc"] <= float(flt["max_image_dbc"]), (
                    f"{p['key']}/{flt['key']} failed ceiling: {m['proto_max_image_dbc']} > {flt['max_image_dbc']}"
                )
                if m["q17_max_image_dbc"] > float(flt["max_image_dbc"]):
                    quant_over += 1
                    print(
                        f"  [WARN] {p['key']}/{flt['key']}: quantized image "
                        f"{m['q17_max_image_dbc']} > ceiling {flt['max_image_dbc']} "
                        f"(proto {m['proto_max_image_dbc']})"
                    )
                checked += 1
        print(f"  -> Audited {checked} filters across {len(cat['personas'])} Personas: 0 ceiling violations"
              + (f" ({quant_over} quantized-level warnings)" if quant_over else ""))
    else:
        print("[SELF-TEST 3/3] (persona_catalog.json not found in cwd; skipped full catalog sweep)")

    print("[SELF-TEST] ALL CHECKS PASSED!")


def main() -> None:
    ap = argparse.ArgumentParser(description="BFDAC Standalone Voicing & Stage 1A Coefficient Generator")
    ap.add_argument("--self-test", action="store_true", help="Run bit-exact packer + catalog FFT self-tests")
    ap.add_argument("--catalog", type=Path, default=Path("persona_catalog.json"), help="Path to persona_catalog.json")
    ap.add_argument("--out-dir", type=Path, default=Path("build/voicing"), help="Output directory for DDR4/AP artifacts")
    ap.add_argument("--num-macs", type=int, default=None, help="Override NUM_MACS (e.g. 128 for 8.39M, 80 for 5.24M)")
    ap.add_argument("--taps-per-phase", type=int, default=None, help="Override TAPS_PER_PHASE (default: catalog 256)")
    ap.add_argument("--split-macs", type=int, default=None, help="Override SPLIT_MACS for packing=2 (default: catalog 12)")
    ap.add_argument("--rates", default="base", help="'base' (48k+44.1k), 'all' (0..7), or comma list e.g. '0,1'")
    ap.add_argument("--personas", default=None, help="Optional comma-separated persona keys to build")
    ap.add_argument("--shape-q17", action="store_true", help="Apply 1st-order Nyquist-zero error feedback on Q1.17 taps")
    ap.add_argument("--emit-individual", action="store_true", help="Also write individual per-bank .bin files")
    ap.add_argument("--emit-mem", action="store_true", help="Also write $readmemh .mem files for xsim")
    ap.add_argument("--emit-sim-hex", type=Path, default=None, metavar="HEX",
                    help="Also write a unified 128-bit word-addressed DDR4 image "
                         "(payload + directory) for associative-array $readmemh TBs")
    ap.add_argument("--skip-audit-fail", action="store_true",
                    help="Exclude persona/rate variants whose prototype image exceeds "
                         "the ceiling instead of aborting (sim-geometry subset builds)")
    args = ap.parse_args()

    if args.self_test:
        run_self_test(args.catalog)
        return

    if args.rates == "all":
        rate_codes = list(range(8))
    elif args.rates == "base":
        rate_codes = [0, 1]
    else:
        rate_codes = [int(x.strip()) for x in args.rates.split(",") if x.strip()]

    p_keys = {k.strip() for k in args.personas.split(",") if k.strip()} if args.personas else None

    build_from_catalog(
        catalog_path=args.catalog,
        out_dir=args.out_dir,
        num_macs_override=args.num_macs,
        tpp_override=args.taps_per_phase,
        split_macs_override=args.split_macs,
        rate_codes_sel=rate_codes,
        persona_keys_sel=p_keys,
        shape_q17=args.shape_q17,
        emit_individual=args.emit_individual,
        emit_mem=args.emit_mem,
        emit_sim_hex=args.emit_sim_hex,
        skip_audit_fail=args.skip_audit_fail,
    )


if __name__ == "__main__":
    main()