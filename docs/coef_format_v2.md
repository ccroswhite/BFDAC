# BFDAC Coefficient File Format v2 (DRAFT — pending ratification)

Status: DRAFT 2026-08-11. Supersedes the bare-coefficient text/bin formats
emitted by the current tooling. Required by the named-filter / user-curated
toggle-list features and video mode (see BFDAC_IMPLEMENTATION_PLAN.md,
"Filter UX Features").

## Design goals
1. Self-describing: name + metadata travel with the coefficients.
2. Host parses strings; FPGA never does. RTL sees only numeric IDs and
   DDR4 offsets via the filter directory built at QSPI→DDR4 staging time.
3. Integrity: every payload checksummed; a corrupt filter must never load.
4. Forward compatibility: versioned header, fixed-size reserved fields.

## Container: `.bfc` file (BFDAC Filter Coefficients)
All multi-byte fields little-endian. One filter (one rate family entry) per
file; a product image bundles many `.bfc` files into the QSPI staging
archive.

### Header (256 bytes, fixed)
| Offset | Size | Field | Notes |
|---|---|---|---|
| 0x00 | 4 | magic | ASCII `BFC2` |
| 0x04 | 2 | format_version | 0x0002 |
| 0x06 | 2 | header_size | 256 |
| 0x08 | 64 | name | UTF-8, NUL-padded (display name, e.g. `Chestnut Linear 2M`) |
| 0x48 | 2 | filter_id | product-unique numeric ID (what SPI/RTL use) |
| 0x4A | 1 | phase_type | 0=linear-phase, 1=minimum-phase, 2=other/asymmetric |
| 0x4B | 1 | video_mode_eligible | 0/1 (host-enforced; requires latency ≤ budget) |
| 0x4C | 4 | tap_count | total taps N |
| 0x50 | 4 | taps_per_phase | TPP as stored (N / 16 phases) |
| 0x54 | 1 | coef_width_bits | 18 |
| 0x55 | 1 | rate_family | 0=48k-family, 1=44.1k-family |
| 0x56 | 2 | base_sample_rate_hz_div100 | e.g. 441, 480, 960 … |
| 0x58 | 4 | latency_us | published end-to-end group delay figure |
| 0x5C | 4 | payload_bytes | size of coefficient payload |
| 0x60 | 4 | payload_crc32 | CRC-32 (IEEE) over payload |
| 0x64 | 4 | header_crc32 | CRC-32 over bytes 0x00–0x63 |
| 0x68 | 152 | reserved | zero-filled |

### Payload
`tap_count` coefficients, 18-bit signed, packed one per 32-bit word
(sign-extended) in DDR4 burst order as consumed by `coef_bank_loader`
(MAC-major, multi-burst per MAC at TPP>64 — layout produced by the DDR4
bank layout generator, TODO f6). Symmetric filters store ALL taps
(unfolded layout, VU13P decision 2026-08-11).

## DDR4 Filter Directory (built at staging, consumed by RTL)
Placed at a fixed DDR4 base address. 32-byte entries, terminated by an
all-zero entry:

| Offset | Size | Field |
|---|---|---|
| 0x00 | 2 | filter_id |
| 0x02 | 1 | phase_type |
| 0x03 | 1 | rate_family |
| 0x04 | 4 | tap_count |
| 0x08 | 4 | ddr4_offset (16-byte units) |
| 0x0C | 4 | payload_bytes |
| 0x10 | 4 | latency_us |
| 0x14 | 12 | reserved |

Names are NOT in the directory — the host keeps the id↔name map from the
`.bfc` headers and exposes names over the UI/app. SPI commands carry
`filter_id` lists only (toggle list = ordered array of IDs; video mode =
host sends only eligible IDs).

## SPI Command Set — filter list / video mode (DRAFT)
Extends the existing control-plane register file (`dac_ctrl_plane.sv`;
40-bit CRC-8 frames, write = `{1'b0, addr[6:0], data[23:0]}`, read =
`{1'b1, addr[6:0], -}` then readback on the following frame).

### Write registers
| Addr | Name | Data | Semantics |
|---|---|---|---|
| 0x08 | FILTER_LIST_CTRL | [0]=clear | Clears the toggle list (len=0, index=0). Host clears, then appends. |
| 0x09 | FILTER_LIST_APPEND | [15:0]=filter_id | Appends one entry; up to 16. Ignored when full (host reads 0x16 to verify). List order = toggle order. |
| 0x0A | FILTER_SELECT | [16]=advance, [3:0]=index | advance=0: jump to `index`; advance=1: step to next entry (wraps). Either form pulses `filter_load_req` with the resolved `filter_id` — this is the customer filter-toggle action. |
| 0x0B | DAC_MODE | [0]=video_mode | Video mode flag. Host enforces eligibility (only low-latency IDs appended while set); FPGA treats it as status/readback state. |

### Read registers
| Addr | Name | Payload |
|---|---|---|
| 0x16 | FILTER_LIST_STATUS | {video_mode, list_len[4:0], cur_index[3:0]} |
| 0x17 | FILTER_IDS | {next_filter_id[15:0], cur_filter_id[15:0]} — `next` = the entry the bank manager should PRELOAD into the inactive bank for gapless toggle |

### Notes
- Legacy 0x05 (coef_bank_id + load_start) remains for bring-up/debug;
  the named path supersedes it for product use.
- Name→ID resolution is HOST-side (from `.bfc` headers at staging time);
  the FPGA only ever sees 16-bit IDs and resolves them via the DDR4
  filter directory (loader work, TODO v3).
- Latency readback per filter comes from the directory, not the ctrl
  plane (deferred to v3 wiring).

## Open questions (ratification gates)
1. Per-rate-family variants: one filter_id per (name, rate_family) pair or
   a family field with sub-entries? (Current draft: one file/id per pair,
   name shared.)
2. Coefficient packing: 32-bit/coef is loader-friendly but 1.78x storage;
   9 coefs / 4×64-bit words tight-pack option deferred until DDR4 capacity
   pressure exists (10 GB ≫ menu of even 4M-tap sets).
3. Latency budget constant for video_mode_eligible (proposed ≤20 ms).
4. Where the id↔name map lives for a headless (no-app) front panel: front
   panel MCU reads `.bfc` headers directly from QSPI, or a compiled menu
   blob is staged alongside.
