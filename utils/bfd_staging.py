#!/usr/bin/env python3
"""
bfd_staging.py — BFDAC DDR4 coefficient staging image builder (TODO-22a)

Builds everything the FPGA boot path needs to make FILTER_SELECT work on
hardware:

  .bfc (pack)     Wrap a raw coefficient payload in a coef_format_v2.md
                  container: 256-byte header + payload, CRC-32 protected.
                  One filter (one rate family / rate_shift entry) per file.

  image           Take a set of .bfc files, lay their payloads out in DDR4
                  space, and emit the QSPI boot record chain that
                  qspi_boot_loader.sv copies verbatim into DDR4 at boot:
                    - one or more records per filter payload
                    - one record for the filter directory at DIR_BASE_ADDR
                  Also emits the host-side id->name manifest (JSON) and an
                  optional byte-per-line .hex for $readmemh flash models.

  verify          Re-parse a .bfc file or a staged image and check every
                  field against the RTL equations in coef_bank_loader.sv.

RTL constraints enforced here (a violation would reach hardware as
FILT_NOTFOUND / FILT_SIZE / format_fail):
  * Boot records: 16-byte header {magic=0x42464443, dest_addr, length,
    crc32(IEEE/zlib)}, dest 16B-aligned, [dest, dest+len) < 0x4000_0000,
    0 < len <= 0x00FF_FFF0 and a multiple of 16. Payloads larger than the
    per-record limit are split into consecutive records.
  * Directory: 32-byte entries at DIR_BASE_ADDR (default 0x3FFF_0000),
    all-zero 32-byte terminator, <= DIR_MAX_ENTRIES (256).
  * Directory tap_count = (NUM_MACS*COEF_DEPTH) >> rate_shift  (stored
    slot count, NOT the .bfc mathematical tap_count).
  * Directory payload_bytes = NUM_MACS*COEF_DEPTH*4 (packing=0) or
    ceil(NUM_MACS*COEF_DEPTH/7)*16 (packing=1) and must equal the actual
    .bfc payload size.
  * rate_code bit0: 0 = 48k family, 1 = 44.1k family; bits[2:1] =
    rate_shift; bits[7:3] = 0. Directory schema byte = 3 (V3 multirate).

Production geometry: NUM_MACS=128, TAPS_PER_PHASE=256 -> COEF_DEPTH=4096,
524,288 stored coefficients per filter bank.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants (must match Xilinx/*.sv and docs/coef_format_v2.md)
# ---------------------------------------------------------------------------

BFC_MAGIC      = b"BFC2"
BFC_VERSION    = 0x0002
BFC_HEADER_LEN = 256

REC_MAGIC      = 0x4246_4443            # "BFDC"
REC_HEADER_LEN = 16
REC_MAX_LEN    = 0x00FF_FFF0            # per-record payload cap (16 MiB - 16)
AXI_LIMIT      = 0x4000_0000            # 1 GiB AXI aperture

DEFAULT_DIR_BASE   = 0x3FFF_0000        # top 64 KB of the AXI window
DEFAULT_DIR_MAX    = 256
DEFAULT_PAYLOAD_BASE = 0x0000_0000

DEFAULT_NUM_MACS = 128
DEFAULT_TPP      = 256

FLASH1_CAPACITY  = 128 * 1024 * 1024    # 128 MiB coefficient flash (TODO-24)

PHASE_TYPES = {"linear": 0, "minimum": 1, "other": 2}

# ---------------------------------------------------------------------------
# .bfc container
# ---------------------------------------------------------------------------

@dataclass
class BfcFilter:
    name: str
    filter_id: int
    phase_type: int
    video_eligible: bool
    tap_count: int            # mathematical taps (informational for RTL)
    taps_per_phase: int
    rate_code: int            # bit0 family (0=48k), bits[2:1] rate_shift
    base_fs_div100: int
    latency_us: int
    packing: int
    payload: bytes = field(repr=False)

    @property
    def rate_shift(self) -> int:
        return (self.rate_code >> 1) & 0x3

    @property
    def family_48k(self) -> bool:
        return (self.rate_code & 1) == 0


def _crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFF_FFFF


def build_bfc(f: BfcFilter) -> bytes:
    """Serialize a filter to the 256-byte-header .bfc container."""
    name_b = f.name.encode("utf-8")[:63] + b"\x00"
    name_b = name_b.ljust(64, b"\x00")
    hdr = struct.pack(
        "<4sHH64sHBBIIBBHIIII",
        BFC_MAGIC,            # 0x00
        BFC_VERSION,          # 0x04
        BFC_HEADER_LEN,       # 0x06
        name_b,               # 0x08
        f.filter_id & 0xFFFF, # 0x48
        f.phase_type & 0xFF,  # 0x4A
        1 if f.video_eligible else 0,   # 0x4B
        f.tap_count,          # 0x4C
        f.taps_per_phase,     # 0x50
        18,                   # 0x54 coef_width_bits
        f.rate_code & 0xFF,   # 0x55
        f.base_fs_div100 & 0xFFFF,      # 0x56
        f.latency_us,         # 0x58
        len(f.payload),       # 0x5C payload_bytes
        _crc32(f.payload),    # 0x60 payload_crc32
        0,                    # 0x64 header_crc32 placeholder
    )
    hdr += bytes([f.packing & 0xFF])           # 0x68
    hdr += bytes(BFC_HEADER_LEN - len(hdr))    # 0x69..0xFF reserved
    assert len(hdr) == BFC_HEADER_LEN
    hdr = hdr[:0x64] + struct.pack("<I", _crc32(hdr[:0x64])) + hdr[0x68:]
    return hdr + f.payload


def parse_bfc(data: bytes) -> BfcFilter:
    if len(data) < BFC_HEADER_LEN + 16:
        raise ValueError("file too small for .bfc container")
    (magic, ver, hlen, name_b, fid, ptype, video, taps, tpp,
     cwidth, rcode, fs100, lat, plen, pcrc, hcrc) = struct.unpack(
        "<4sHH64sHBBIIBBHIIII", data[:0x68])
    if magic != BFC_MAGIC:
        raise ValueError(f"bad magic {magic!r} (expected {BFC_MAGIC!r})")
    if ver != BFC_VERSION:
        raise ValueError(f"unsupported format_version 0x{ver:04X}")
    if hlen != BFC_HEADER_LEN:
        raise ValueError(f"header_size {hlen} != {BFC_HEADER_LEN}")
    if _crc32(data[:0x64]) != hcrc:
        raise ValueError("header_crc32 mismatch")
    payload = data[BFC_HEADER_LEN:]
    if len(payload) != plen:
        raise ValueError(f"payload_bytes field {plen} != actual {len(payload)}")
    if _crc32(payload) != pcrc:
        raise ValueError("payload_crc32 mismatch")
    packing = data[0x68]
    name = name_b.split(b"\x00")[0].decode("utf-8", errors="replace")
    return BfcFilter(name, fid, ptype, bool(video), taps, tpp, rcode,
                     fs100, lat, packing, payload)


# ---------------------------------------------------------------------------
# DDR4 directory entry (32 bytes, two AXI beats — coef_bank_loader.sv)
# ---------------------------------------------------------------------------

def build_dir_entry(f: BfcFilter, num_macs: int, coef_depth: int,
                    ddr4_addr: int) -> bytes:
    """
    Fields checked by RTL (dir_rate_ok / payload-size compare):
      tap_count      = (NUM_MACS*COEF_DEPTH) >> rate_shift
      payload_bytes  = PK_BYTES or BANK_SIZE_BYTES for the entry's packing
      rate_code      = bit0 family, bits[2:1] rate_shift, bits[7:3] = 0
      beat1          = latency_us, packing, rate_shift_mirror, schema=3
    """
    if ddr4_addr % 16 or ddr4_addr < 0 or ddr4_addr >= AXI_LIMIT:
        raise ValueError(f"ddr4_addr 0x{ddr4_addr:X} not 16B-aligned in window")
    if f.rate_code >> 3:
        raise ValueError(f"rate_code 0x{f.rate_code:02X} sets reserved bits")
    total = num_macs * coef_depth
    pk_bytes = ((total + 6) // 7) * 16
    expect = pk_bytes if f.packing == 1 else total * 4
    if f.packing not in (0, 1):
        raise ValueError(f"packing {f.packing} unsupported by loader")
    if len(f.payload) != expect:
        raise ValueError(
            f"{f.name!r}: payload {len(f.payload)} B != {expect} B expected "
            f"for NUM_MACS={num_macs} COEF_DEPTH={coef_depth} packing={f.packing}")
    stored_taps = total >> f.rate_shift
    beat0 = struct.pack("<HBBIII",
                        f.filter_id & 0xFFFF, f.phase_type & 0xFF,
                        f.rate_code & 0xFF, stored_taps,
                        ddr4_addr >> 4, len(f.payload))
    beat1 = struct.pack("<IBBB9x", f.latency_us, f.packing & 0xFF,
                        f.rate_shift & 0xFF, 3)   # schema = 3 (V3 multirate)
    return beat0 + beat1


# ---------------------------------------------------------------------------
# Boot record chain (qspi_boot_loader.sv)
# ---------------------------------------------------------------------------

def build_records(items: list[tuple[int, bytes]]) -> bytes:
    """
    items = [(dest_addr, payload_bytes)]. Splits oversized payloads into
    consecutive records. Returns the raw record-chain bytes.
    """
    out = bytearray()
    for dest, payload in items:
        if dest % 16:
            raise ValueError(f"record dest 0x{dest:X} not 16-byte aligned")
        off = 0
        while off < len(payload):
            chunk = payload[off:off + REC_MAX_LEN]
            chunk = chunk[:len(chunk) - (len(chunk) % 16)] \
                if len(chunk) % 16 else chunk
            if not chunk:
                raise ValueError("record payload chunk shrank to 0")
            d = dest + off
            if d + len(chunk) > AXI_LIMIT:
                raise ValueError(
                    f"record [0x{d:X}, 0x{d + len(chunk):X}) exceeds "
                    f"0x{AXI_LIMIT:X} AXI window")
            out += struct.pack("<IIII", REC_MAGIC, d, len(chunk),
                               _crc32(chunk))
            out += chunk
            off += len(chunk)
    return bytes(out)


# ---------------------------------------------------------------------------
# Image assembly
# ---------------------------------------------------------------------------

def build_image(filters: list[BfcFilter],
                num_macs: int = DEFAULT_NUM_MACS,
                taps_per_phase: int = DEFAULT_TPP,
                dir_base: int = DEFAULT_DIR_BASE,
                payload_base: int = DEFAULT_PAYLOAD_BASE,
                align: int = 16,
                flash_capacity: int = FLASH1_CAPACITY
                ) -> tuple[bytes, dict]:
    coef_depth = 16 * taps_per_phase
    if len(filters) > DEFAULT_DIR_MAX:
        raise ValueError(f"{len(filters)} filters > DIR_MAX_ENTRIES "
                         f"{DEFAULT_DIR_MAX}")
    ids = [f.filter_id for f in filters]
    if len(set(ids)) != len(ids):
        dup = sorted({i for i in ids if ids.count(i) > 1})
        raise ValueError(f"duplicate filter_id(s): {dup}")

    # Lay out payloads: sequential from payload_base, 'align'-aligned.
    records: list[tuple[int, bytes]] = []
    entries = []
    addr = payload_base
    for f in filters:
        addr = (addr + align - 1) & ~(align - 1)
        if addr + len(f.payload) > dir_base:
            raise ValueError(
                f"{f.name!r}: payload at 0x{addr:X}..0x{addr+len(f.payload):X} "
                f"collides with directory window at 0x{dir_base:X}")
        records.append((addr, f.payload))
        entries.append(build_dir_entry(f, num_macs, coef_depth, addr))
        addr += len(f.payload)

    # Directory blob: entries + all-zero terminator, staged at dir_base.
    dir_blob = b"".join(entries) + bytes(32)
    records.append((dir_base, dir_blob))

    image = build_records(records)
    if len(image) > flash_capacity:
        raise ValueError(
            f"image {len(image):,} B exceeds flash capacity "
            f"{flash_capacity:,} B")

    manifest = {
        "format": "bfd-staging-manifest/v1",
        "geometry": {
            "num_macs": num_macs,
            "coef_depth": coef_depth,
            "taps_per_phase": taps_per_phase,
            "stored_coefs": num_macs * coef_depth,
        },
        "dir_base_addr": f"0x{dir_base:08X}",
        "filters": [
            {
                "filter_id": f.filter_id,
                "name": f.name,
                "phase_type": f.phase_type,
                "video_mode_eligible": f.video_eligible,
                "rate_family": "48k" if f.family_48k else "44.1k",
                "rate_shift": f.rate_shift,
                "tap_count": f.tap_count,
                "ddr4_addr": f"0x{e_addr:08X}",
                "payload_bytes": len(f.payload),
                "packing": f.packing,
                "payload_crc32": f"0x{_crc32(f.payload):08X}",
            }
            for f, e_addr in
            zip(filters, [a for a, _ in records[:-1]])
        ],
    }
    return image, manifest


# ---------------------------------------------------------------------------
# Verification (parse an image back — the boot loader's view)
# ---------------------------------------------------------------------------

def verify_image(path: Path, num_macs: int, taps_per_phase: int,
                 dir_base: int = DEFAULT_DIR_BASE) -> list[str]:
    """Walk a staged image; return a list of problems (empty = clean)."""
    problems: list[str] = []
    data = path.read_bytes()
    pos = 0
    rec_no = 0
    dir_entries: list[tuple[int, int, int, int, int]] = []
    while pos + REC_HEADER_LEN <= len(data):
        magic, dest, length, crc = struct.unpack("<IIII", data[pos:pos + 16])
        pos += 16
        if magic == 0xFFFF_FFFF:
            break
        if magic != REC_MAGIC:
            problems.append(f"record {rec_no}: bad magic 0x{magic:08X} "
                            f"at 0x{pos - 16:X}")
            break
        payload = data[pos:pos + length]
        pos += length
        problems += ([f"record {rec_no}: dest 0x{dest:X} unaligned"]
                     if dest % 16 else [])
        problems += ([f"record {rec_no}: length {length} not multiple of 16"]
                     if length % 16 else [])
        problems += ([f"record {rec_no}: exceeds AXI window"]
                     if dest + length > AXI_LIMIT else [])
        if len(payload) != length:
            problems.append(f"record {rec_no}: truncated payload")
            break
        if _crc32(payload) != crc:
            problems.append(f"record {rec_no}: crc32 mismatch")
        if dest == dir_base:
            for i in range(0, length - 31, 32):
                e = payload[i:i + 32]
                if e == bytes(32):
                    break
                (fid, ptype, rcode, taps, off16, plen,
                 lat, packing, rsm, schema) = struct.unpack("<HBBIIIIBBB",
                                                          e[:23])
                dir_entries.append((fid, rcode, taps, off16 << 4, plen))
                total = num_macs * 16 * taps_per_phase
                exp_plen = ((total + 6) // 7) * 16 if packing == 1 else total * 4
                if taps != total >> ((rcode >> 1) & 3):
                    problems.append(f"dir id {fid}: tap_count {taps} wrong")
                if plen != exp_plen:
                    problems.append(f"dir id {fid}: payload_bytes {plen} "
                                    f"!= {exp_plen}")
                if packing not in (0, 1):
                    problems.append(f"dir id {fid}: packing {packing} illegal")
                if rcode >> 3:
                    problems.append(f"dir id {fid}: rate_code reserved bits")
                if rsm != ((rcode >> 1) & 3) or schema != 3:
                    problems.append(f"dir id {fid}: V3 mirror/schema wrong")
            else:
                problems.append("directory: no zero terminator")
        rec_no += 1
    return problems


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_pack(a) -> None:
    payload = a.payload.read_bytes()
    rcode = ((a.rate_shift & 0x3) << 1) | (0 if a.family == "48k" else 1)
    f = BfcFilter(
        name=a.name,
        filter_id=a.filter_id,
        phase_type=PHASE_TYPES[a.phase_type],
        video_eligible=a.video,
        tap_count=a.tap_count,
        taps_per_phase=a.taps_per_phase,
        rate_code=rcode,
        base_fs_div100=a.base_fs // 100,
        latency_us=a.latency_us,
        packing=a.packing,
        payload=payload,
    )
    if len(payload) % 16:
        print(f"WARNING: payload {len(payload)} B is not 16-byte aligned "
              f"(record chain would pad/truncate)", file=sys.stderr)
    if a.video and a.latency_us == 0:
        print("WARNING: video_mode_eligible with latency_us=0 — the "
              "filter builder must check the 20 ms budget", file=sys.stderr)
    out = build_bfc(f)
    a.out.write_bytes(out)
    print(f"[PACK] {a.out} : '{f.name}' id={f.filter_id} "
          f"packing={f.packing} {len(payload):,} B payload "
          f"({len(out):,} B total)")


def cmd_image(a) -> None:
    filters = [parse_bfc(p.read_bytes()) for p in a.bfc]
    print(f"[IMAGE] {len(filters)} filter(s):")
    for f in filters:
        print(f"  id={f.filter_id:>3} '{f.name}' packing={f.packing} "
              f"rate_shift={f.rate_shift} family={'48k' if f.family_48k else '44.1k'} "
              f"{len(f.payload):,} B")
    image, manifest = build_image(
        filters, num_macs=a.num_macs, taps_per_phase=a.taps_per_phase,
        dir_base=a.dir_base, payload_base=a.payload_base, align=a.align,
        flash_capacity=a.flash_capacity)
    a.out_image.write_bytes(image)
    a.out_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[IMAGE] {a.out_image} : {len(image):,} B record chain")
    print(f"[IMAGE] {a.out_manifest} : id->name manifest")
    if a.out_hex:
        with a.out_hex.open("w") as fh:
            fh.writelines(f"{b:02x}\n" for b in image)
        print(f"[IMAGE] {a.out_hex} : $readmemh byte image")
    probs = verify_image(a.out_image, a.num_macs, a.taps_per_phase, a.dir_base)
    if probs:
        for p in probs:
            print(f"  VERIFY-FAIL: {p}")
        sys.exit(1)
    print("[IMAGE] self-verify: record chain + directory clean")


def cmd_verify(a) -> None:
    if a.file.suffix == ".bfc":
        f = parse_bfc(a.file.read_bytes())
        print(f"[VERIFY] {a.file}: '{f.name}' id={f.filter_id} "
              f"OK ({len(f.payload):,} B payload)")
        return
    probs = verify_image(a.file, a.num_macs, a.taps_per_phase, a.dir_base)
    if probs:
        for p in probs:
            print(f"[VERIFY] FAIL: {p}")
        sys.exit(1)
    print(f"[VERIFY] {a.file}: record chain + directory clean")


def cmd_self_test(a) -> None:
    """Synthetic end-to-end: payload -> .bfc -> image -> re-parse."""
    nm, tpp = DEFAULT_NUM_MACS, DEFAULT_TPP
    total = nm * 16 * tpp
    pk = ((total + 6) // 7) * 16

    # packed payload: coefficient g at bits [18*(g%7)+17 : 18*(g%7)]
    buf = bytearray(pk)
    for g in range(total):
        v = ((g * 2654435761) & 0x3FFFF) - 0x20000   # deterministic spread
        u = v & 0x3FFFF
        byte_i = (g // 7) * 16 + (g % 7) * 18 // 8
        bit_i = (g % 7) * 18 % 8
        cur = int.from_bytes(buf[byte_i:byte_i + 4], "little")
        cur |= u << bit_i
        buf[byte_i:byte_i + 4] = cur.to_bytes(4, "little")
    fs = [BfcFilter("Test Linear 48k x16", 1, 0, False, 2 * total >> 0,
                    total >> 0, 0 << 1 | 0, 480, 8500, 1, bytes(buf)),
          BfcFilter("Test MinPhase 44k x8", 7, 1, True, total >> 1,
                    total >> 1, 1 << 1 | 1, 882, 4200, 1, bytes(buf))]
    img, man = build_image(fs, num_macs=nm, taps_per_phase=tpp)
    tmp = Path(sys.argv[0]).with_suffix(".selftest.bin")
    tmp.write_bytes(img)
    probs = verify_image(tmp, nm, tpp)
    tmp.unlink()
    assert not probs, probs
    # .bfc round-trip
    rt = parse_bfc(build_bfc(fs[0]))
    assert rt.payload == fs[0].payload and rt.name == fs[0].name
    # record split check: fake >16 MiB payload -> 2 consecutive records
    big = build_records([(0x1000_0000, bytes(REC_MAX_LEN + 4096))])
    off, count, prev_dest = 0, 0, 0x1000_0000
    while off < len(big):
        magic, dest, ln, crc = struct.unpack("<IIII", big[off:off + 16])
        assert magic == REC_MAGIC and ln <= REC_MAX_LEN and ln % 16 == 0
        assert dest == prev_dest
        prev_dest = dest + ln
        off += 16 + ln
        count += 1
    assert count == 2, f"expected 2 split records, got {count}"
    print("[SELF-TEST] PASS: .bfc round-trip, image build+verify,")
    print("            directory equations, >16 MiB record split")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="BFDAC coefficient staging: .bfc containers and "
                    "QSPI->DDR4 boot images (TODO-22a)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    pk = sub.add_parser("pack", help="raw payload + metadata -> .bfc")
    pk.add_argument("--payload", type=Path, required=True)
    pk.add_argument("--out", type=Path, required=True)
    pk.add_argument("--name", required=True)
    pk.add_argument("--filter-id", type=int, required=True)
    pk.add_argument("--family", choices=["48k", "44k1"], default="48k")
    pk.add_argument("--rate-shift", type=int, default=0, choices=[0, 1, 2, 3])
    pk.add_argument("--phase-type", choices=list(PHASE_TYPES), default="linear")
    pk.add_argument("--video", action="store_true")
    pk.add_argument("--tap-count", type=int, required=True)
    pk.add_argument("--taps-per-phase", type=int, required=True)
    pk.add_argument("--base-fs", type=int, default=48000,
                    help="filter sample rate at this rate_shift, Hz")
    pk.add_argument("--latency-us", type=int, default=0)
    pk.add_argument("--packing", type=int, choices=[0, 1], default=1)
    pk.set_defaults(fn=cmd_pack)

    im = sub.add_parser("image", help=".bfc set -> flash image + manifest")
    im.add_argument("bfc", type=Path, nargs="+")
    im.add_argument("--out-image", type=Path, required=True)
    im.add_argument("--out-manifest", type=Path, required=True)
    im.add_argument("--out-hex", type=Path, default=None)
    im.add_argument("--num-macs", type=int, default=DEFAULT_NUM_MACS)
    im.add_argument("--taps-per-phase", type=int, default=DEFAULT_TPP)
    im.add_argument("--dir-base", type=lambda x: int(x, 0),
                    default=DEFAULT_DIR_BASE)
    im.add_argument("--payload-base", type=lambda x: int(x, 0),
                    default=DEFAULT_PAYLOAD_BASE)
    im.add_argument("--align", type=lambda x: int(x, 0), default=16,
                    help="payload placement granularity (default 16B)")
    im.add_argument("--flash-capacity", type=lambda x: int(x, 0),
                    default=FLASH1_CAPACITY)
    im.set_defaults(fn=cmd_image)

    vf = sub.add_parser("verify", help="re-check a .bfc or a staged image")
    vf.add_argument("file", type=Path)
    vf.add_argument("--num-macs", type=int, default=DEFAULT_NUM_MACS)
    vf.add_argument("--taps-per-phase", type=int, default=DEFAULT_TPP)
    vf.add_argument("--dir-base", type=lambda x: int(x, 0),
                    default=DEFAULT_DIR_BASE)
    vf.set_defaults(fn=cmd_verify)

    st = sub.add_parser("self-test", help="synthetic end-to-end check")
    st.set_defaults(fn=cmd_self_test)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
