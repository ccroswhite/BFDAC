#!/usr/bin/env python3
"""Hybrid quantizer prototype: per-MAC block exponents + hi/lo split main-lobe MACs.

Verifies across the full persona catalog x all rate codes:
  * e_m bounded by BOTH per-tap 18b limit AND per-phase l1 < 32 (48b preg guard)
  * fixed split-MAC set coverage ({78,79} vs {76..79} vs {72..79})
  * quantized image floor vs the -120 dBc target
"""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import bfdac_voicing_gen as g

Q = float(g.Q17_SCALE)
NUM_MACS = 80
TPP = 256
EXP_MAX = 31          # 5-bit exponent (0..31)
L1_LIMIT = 31.5       # post-rounding guard below 32.0 -> |preg| < 2^46 (schema 4)
SPLIT_SETS = {
    "{68..79}": set(range(68, 80)),
    "{72..79}": set(range(72, 80)),
    "{64..79}": set(range(64, 80)),
}


def mac_exponents(h: np.ndarray, num_macs: int, act_tpp: int) -> np.ndarray:
    """e_m = min(e_tap, e_l1_phase, EXP_MAX) per MAC. h = half-prototype."""
    e = np.zeros(num_macs, dtype=int)
    for m in range(num_macs):
        seg = h[m * 2 * act_tpp:(m + 1) * 2 * act_tpp]
        mx = np.abs(seg).max()
        e_tap = int(np.floor(-np.log2(mx))) - 1 if mx > 0 else EXP_MAX
        # per-phase l1 of the FLOAT taps (phase 0 = even offsets, phase 1 = odd)
        l1 = max(np.abs(seg[0::2]).sum(), np.abs(seg[1::2]).sum())
        e_l1 = int(np.floor(np.log2(L1_LIMIT / l1))) if l1 > 0 else EXP_MAX
        e[m] = max(0, min(e_tap, e_l1, EXP_MAX))
    return e


def hybrid_quantize(h, num_macs, act_tpp, e, split):
    """Return effective quantized coefs in units of 2^-17 (float)."""
    qh = np.zeros(h.size)
    for m in range(num_macs):
        lo, hi = m * 2 * act_tpp, (m + 1) * 2 * act_tpp
        seg = h[lo:hi]
        if m in split:
            qh[lo:hi] = np.rint(seg * Q * (1 << 18)) / (1 << 18)   # 36b borrow-comp (Q1.35)
        else:
            qh[lo:hi] = np.rint(seg * Q * (1 << e[m])) / (1 << e[m])
    return qh


def image_dbc(qh, fs_hz):
    fq = np.concatenate([qh, qh[::-1]]) / Q
    n = 1 << max(18, int(np.ceil(np.log2(2 * qh.size))))
    H = 0.5 * np.abs(np.fft.rfft(fq, n=n))
    fr = np.arange(H.size) * (2.0 * fs_hz / n)
    m = (fr >= 0.505 * fs_hz) & (fr <= 1.4 * fs_hz)
    return 20 * np.log10(max(H[m].max(), 1e-20))


def main():
    cat = json.load(open(Path(__file__).parent / "persona_catalog.json"))
    rates = cat["rates"]
    results = {}           # split_set -> worst (dbc, case)
    low_e_cases = []       # (case, mac, e) where e < 6 outside {72..79}
    for p in cat["personas"]:
        for flt in p["filters"]:
            for r in rates:
                rs, fs = r["rate_shift"], float(r["sample_rate_hz"])
                case = f"{p['key']}/{flt['key']}/rc{r['rate_code']}"
                h = g.design_persona_half_prototype(
                    num_macs=NUM_MACS, taps_per_phase=TPP, rate_shift=rs,
                    sample_rate_hz=fs, window=str(flt["window"]),
                    fc_fs_ratio=float(flt["fc_fs_ratio"]),
                    span_fraction=float(flt.get("span_fraction", 1.0)),
                    beta=float(flt.get("beta", 18.0)),
                    cos_power=float(flt.get("cos_power", 2.0)),
                    sigma=float(flt.get("sigma", 0.28)),
                    base_contour=p.get("base_contour"),
                    hf_roll_hz=flt.get("hf_roll_hz"),
                    extra_hf_db_20k=float(flt.get("extra_hf_db_20k", 0.0)),
                )
                act_tpp = (8 * TPP) >> rs
                e = mac_exponents(h, NUM_MACS, act_tpp)
                for m in range(68):          # hot MACs outside the split set
                    if e[m] < 6:
                        low_e_cases.append((case, m, int(e[m])))
                for name, sset in SPLIT_SETS.items():
                    qh = hybrid_quantize(h, NUM_MACS, act_tpp, e, sset)
                    d = image_dbc(qh, fs)
                    if name not in results or d > results[name][0]:
                        results[name] = (d, case, int(e.min()), int(e[79]))

    print(f"{'split set':>10} {'worst dBc':>10}  worst-case")
    for name, (d, case, emin, e79) in results.items():
        print(f"{name:>10} {d:>10.1f}  {case} (e_min={emin}, e79={e79})")
    print(f"\nMACs with e<6 outside 72..79 (would need split):")
    for c in low_e_cases[:20]:
        print("  ", c)
    print(f"  total: {len(low_e_cases)}")


if __name__ == "__main__":
    main()
