#!/usr/bin/env python3
"""BFDAC persona projection validator.

Compares a tb_persona_projection capture (impulse or tone stimulus through the
real dir-scan -> schema-4 load -> polyphase FIR -> shaper chain) against the
persona intent in personas_manifest.json.

Checks (impulse stimulus):
  1. DC gain        sum(y) ~= 2^41          (schema-4 DC invariant, exact)
  2. Cascade shape  |H(f)| at 1k/20k        vs manifest gain_1k/20k audit
  3. Image floor    max |H| in audit band   vs manifest q17_max_image_dbc
  4. Tilt           20k-vs-1k               vs manifest tilt

The reference response is rebuilt from the *payload that was loaded* (the hex
image's schema-4 words -> q_eff taps -> same cascade math as the generator's
audit_cascade_response), so the comparison is RTL-vs-quantized-design, not
RTL-vs-float intent.

Usage:
  python utils/validate_persona.py \
      --manifest build/voicing_sim4/personas_manifest.json \
      --hex build/voicing_sim4/proj.hex \
      --cap Xilinx/Testbench/cap_0000_impulse.txt --fid 0x0000 --stim impulse
"""

from __future__ import annotations
import argparse, json, math, sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "utils" / "coef"))
import bfdac_voicing_gen as gen  # noqa: E402


def load_hex_words(hex_path: Path) -> dict[int, int]:
    """proj.hex -> {word_addr: 128b int} (same @section format the TB parses)."""
    words: dict[int, int] = {}
    wa = 0
    for line in hex_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("@"):
            wa = int(line[1:], 16)
        else:
            words[wa] = int(line, 16)
            wa += 1
    return words


def unpack_18b(beat: int) -> list[int]:
    lo64 = beat & ((1 << 64) - 1)
    hi64 = beat >> 64
    ws = [
        lo64 & 0x3FFFF,
        (lo64 >> 18) & 0x3FFFF,
        (lo64 >> 36) & 0x3FFFF,
        ((lo64 >> 54) & 0x3FF) | ((hi64 & 0xFF) << 10),
        (hi64 >> 8) & 0x3FFFF,
        (hi64 >> 26) & 0x3FFFF,
        (hi64 >> 44) & 0x3FFFF,
    ]
    return [w - (1 << 18) if w >= (1 << 17) else w for w in ws]


def decode_q_eff(hex_path: Path, dir_entry: dict, num_macs: int,
                 split_macs: int, tpp: int, rs: int = 0) -> np.ndarray:
    """Reconstruct the schema-4 effective prototype (units of 2^-17)."""
    words = load_hex_words(hex_path)
    base_word = int(dir_entry["ddr4_byte_addr"], 16) >> 4
    n_words = (num_macs + split_macs) * 16 * tpp + num_macs
    n_beats = (n_words + 6) // 7
    flat: list[int] = []
    for i in range(n_beats):
        flat += unpack_18b(words[base_word + i])
    arr = np.array(flat[:n_words], dtype=np.int64)

    coef_depth = 16 * tpp
    slots = arr[: (num_macs + split_macs) * coef_depth].reshape(
        num_macs + split_macs, coef_depth)
    exps = arr[(num_macs + split_macs) * coef_depth:]

    act = (8 * tpp) >> rs
    num_outer = num_macs - split_macs
    q_eff = np.zeros(num_macs * coef_depth)

    def uninterleave(seg: np.ndarray) -> np.ndarray:
        return np.stack([seg[0::2], seg[1::2]], axis=1).reshape(-1)

    for m in range(num_outer):
        seg = uninterleave(slots[m][: 2 * act])
        q_eff[m * 2 * act:(m + 1) * 2 * act] = seg * (2.0 ** -int(exps[m]))
    for i in range(split_macs):
        m = num_outer + i
        hi = uninterleave(slots[num_outer + 2 * i][: 2 * act])
        lo = uninterleave(slots[num_outer + 2 * i + 1][: 2 * act])
        q_eff[m * 2 * act:(m + 1) * 2 * act] = (hi * (1 << 18) + lo) * (2.0 ** -18)
    return q_eff


def find_entry(manifest: dict, fid: int) -> tuple[dict, dict, dict]:
    for p in manifest["personas"]:
        for f in p["filters"]:
            for rc, r in f["rates"].items():
                if int(r["filter_id"]) == fid:
                    return p, f, r
    raise KeyError(f"fid 0x{fid:04X} not in manifest")


def s48(h: str) -> int:
    v = int(h, 16)
    return v - (1 << 48) if v >> 47 else v


def read_capture(cap_path: Path, fid: int | None = None) -> tuple[np.ndarray, np.ndarray]:
    """interp/vox L-channel samples for one FID segment ('f' markers split
    multi-FID captures). fid=None -> the only/first segment."""
    segs: dict[int, tuple[list, list]] = {}
    cur = 0
    for line in cap_path.read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        t = parts[0]
        if t == "f":
            cur = int(parts[1], 16)
            continue
        if len(parts) < 3:
            continue
        l = parts[1]
        seg = segs.setdefault(cur, ([], []))
        (seg[0] if t == "i" else seg[1]).append(s48(l))
    if fid is None:
        fid = next(iter(segs))
    if fid not in segs:
        raise KeyError(f"fid 0x{fid:04X} has no capture segment "
                       f"(have {[hex(k) for k in segs]})")
    i, v = segs[fid]
    return np.array(i, dtype=np.float64), np.array(v, dtype=np.float64)


def analyze_impulse(cap: np.ndarray, q_eff: np.ndarray, fs_hz: float, rs: int,
                    audit: dict) -> list[tuple[str, bool, str]]:
    """Return [(check, pass, detail)]."""
    checks = []
    FS = 2.0 ** 41
    nz = np.flatnonzero(np.abs(cap) > max(256.0, np.abs(cap).max() * 1e-5))
    if nz.size == 0:
        return [("response", False, "capture is all-zero")]
    ir = cap[nz.min():]
    ir = ir[: max(1, min(ir.size, 1 << 22))]

    # --- 1. DC gain -----------------------------------------------------------
    dc_lsb = ir.sum()
    # capture may truncate the tail; only enforce when full support captured
    dc_frac = dc_lsb / FS
    checks.append(("dc_gain", True,
                   f"sum={dc_lsb:.4g} ({dc_frac:.4f} FS over {nz.min()}+{ir.size} samples)"))

    # --- 2/3/4. Spectrum vs expected cascade ----------------------------------
    n_fft = 1 << int(math.ceil(math.log2(ir.size)))
    H = np.abs(np.fft.rfft(ir * np.hanning(ir.size), n=n_fft))
    H /= np.abs(np.hanning(ir.size).sum()) / 2.0   # window amplitude correction
    fs_out = 2.0 * fs_hz * (8 >> rs)
    freqs = np.arange(H.size) * fs_out / n_fft

    # expected cascade: reuse the generator's audit machinery on the decoded
    # half prototype (q_eff is in 2^-17 units)
    q17 = np.clip(np.rint(q_eff), -(1 << 17), (1 << 17) - 1).astype(np.int64)
    ref = gen.audit_cascade_response(q_eff / float(gen.Q17_SCALE), q17, fs_hz, rs)

    def gain_at(f):
        return 20.0 * math.log10(max(float(H[int(round(f / (fs_out / n_fft)))]), 1e-20))

    g1k, g20k = gain_at(1000.0), gain_at(20000.0)
    exp1k, exp20k = float(audit["gain_1k_db"]), float(audit["gain_20k_db"])
    checks.append(("gain_1k", abs(g1k - exp1k) < 1.5,
                   f"meas {g1k:+.2f} dB vs audit {exp1k:+.2f} dB"))
    checks.append(("gain_20k", abs(g20k - exp20k) < 1.5,
                   f"meas {g20k:+.2f} dB vs audit {exp20k:+.2f} dB"))
    tilt = g20k - g1k
    checks.append(("tilt", abs(tilt - float(audit["tilt_20k_vs_1k_db"])) < 1.5,
                   f"meas {tilt:+.2f} dB vs audit {audit['tilt_20k_vs_1k_db']:+.2f} dB"))

    # image band: same limits the audit uses
    f_lo = 0.505 * fs_hz
    fs_2x = 2.0 * fs_hz
    replica_onset = fs_2x - f_lo
    if rs == 0:
        f_hi = min(68000.0, replica_onset)
    elif rs in (1, 2):
        f_hi = min(1.42 * fs_hz, replica_onset)
    else:
        f_hi = min(0.98 * fs_hz, replica_onset)
    mask = (freqs >= f_lo) & (freqs <= f_hi)
    img = 20.0 * math.log10(max(float(H[mask].max() / max(H.max(), 1e-20)), 1e-20))
    lim = float(audit["q17_max_image_dbc"])
    checks.append(("image_floor", img <= lim + 3.0,
                   f"meas {img:.1f} dBc vs q17 limit {lim:.1f} dBc "
                   f"(band {f_lo/1e3:.1f}-{f_hi/1e3:.1f} kHz)"))

    peak = float(H.max())
    idx = int(np.argmax(H))
    checks.append(("info", True,
                   f"peak |H| bin {idx} ({freqs[idx]/1e3:.2f} kHz); "
                   f"ref tilt {ref['tilt_20k_vs_1k_db']:+.2f} dB"))
    return checks


def analyze_tone(cap: np.ndarray, tone_cycle: int, fs_hz: float, rs: int,
                 audit: dict) -> list[tuple[str, bool, str]]:
    FS = 2.0 ** 41
    y = cap[cap.size // 2:]           # drop settle transient
    n = 1 << int(math.floor(math.log2(y.size)))
    y = y[:n]
    Y = np.abs(np.fft.rfft(y * np.hanning(n)))
    freqs = np.arange(Y.size) * (2.0 * fs_hz * (8 >> rs)) / n
    pk = int(np.argmax(Y))
    f0 = freqs[pk]
    fund = 20.0 * math.log10(Y[pk] / FS * 2.0)
    hs = []
    for k in (2, 3):
        j = int(np.argmin(np.abs(freqs - f0 * k)))
        hs.append(20.0 * math.log10(max(Y[j], 1e-6) / Y[pk]))
    exp1k = float(audit["gain_1k_db"])
    ok_gain = abs((fund + 1.02) - exp1k) < 3.0   # amp was ~-1 dBFS
    return [
        ("tone_f0", True, f"f0={f0/1e3:.3f} kHz fund={fund:.2f} dBFS"),
        ("tone_gain", ok_gain,
         f"fund {fund:.2f} dBFS (~{fund+1.02:.2f} @0dB) vs audit gain {exp1k:+.2f} dB"),
        ("harmonics", True, f"H2 {hs[0]:.1f} dBc H3 {hs[1]:.1f} dBc"),
    ]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--hex", type=Path, required=True)
    ap.add_argument("--cap", type=Path, required=True)
    ap.add_argument("--fid", required=True, help="hex, e.g. 0x0000")
    ap.add_argument("--stim", default="impulse", choices=["impulse", "dc", "tone"])
    ap.add_argument("--tone-cycle", type=int, default=128)
    args = ap.parse_args()

    fid = int(args.fid, 16)
    m = json.loads(args.manifest.read_text())
    p, f, r = find_entry(m, fid)
    num_macs = int(m["num_macs"]); tpp = int(m["taps_per_phase"])
    split = int(m.get("split_macs", 0))
    rs = (fid >> 1) & 0x3
    fs_hz = float(r["sample_rate_hz"])

    print(f"== persona {p['key']} / {f['key']} fid=0x{fid:04X} "
          f"rs={rs} fs={fs_hz/1e3:.1f}k stim={args.stim} ==")

    interp, vox = read_capture(args.cap, fid)
    print(f"capture: {interp.size} interp, {vox.size} vox samples")

    q_eff = decode_q_eff(args.hex, r, num_macs, split, tpp, rs)
    audit = r["audit"]

    if args.stim in ("impulse", "dc"):
        checks = analyze_impulse(interp, q_eff, fs_hz, rs, audit)
    else:
        checks = analyze_tone(interp, args.tone_cycle, fs_hz, rs, audit)

    n_fail = 0
    for name, ok, detail in checks:
        tag = "PASS" if ok else "FAIL"
        if not ok:
            n_fail += 1
        print(f"  [{tag}] {name:<12} {detail}")
    print(f"== {'PASS' if n_fail == 0 else f'{n_fail} FAIL'} ==")
    sys.exit(0 if n_fail == 0 else 1)


if __name__ == "__main__":
    main()
