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
| 0x4B | 1 | video_mode_eligible | 0/1 — tooling metadata only (2026-09-04: exactly ONE filter is flagged; it is the video-mode filter). Never shown to customers. |
| 0x4C | 4 | tap_count | total taps N |
| 0x50 | 4 | taps_per_phase | TPP as stored (N / 16 phases) |
| 0x54 | 1 | coef_width_bits | 18 |
| 0x55 | 1 | rate_family | 0=48k-family, 1=44.1k-family |
| 0x56 | 2 | base_sample_rate_hz_div100 | e.g. 441, 480, 960 … |
| 0x58 | 4 | latency_us | group-delay figure for the FILTER BUILDER to check the video filter against the 20 ms budget. Tooling-internal: never displayed to customers, never read by RTL (TODO-20 closed 2026-09-04). |
| 0x5C | 4 | payload_bytes | size of coefficient payload |
| 0x60 | 4 | payload_crc32 | CRC-32 (IEEE) over payload |
| 0x64 | 4 | header_crc32 | CRC-32 over bytes 0x00–0x63 |
| 0x68 | 1 | packing | 0 = 32-bit words (v1), 1 = 18-bit packed, 7 per 16-byte beat (2026-10-05). Copied to directory byte 0x14. |
| 0x69 | 151 | reserved | zero-filled |

### Payload
Two layouts, selected by the `packing` byte (header 0x68 / directory 0x14):

**packing = 0 (v1, 32-bit words).** `tap_count` coefficients, 18-bit
signed, one per 32-bit word (sign-extended) in DDR4 burst order as
consumed by `coef_bank_loader` (MAC-major, multi-burst per MAC at
TPP>64). `payload_bytes = NUM_MACS * COEF_DEPTH * 4`.

**packing = 1 (18-bit packed, 2026-10-05, bom item 18 (a)).** The same
MAC-major coefficient order as ONE continuous stream, 7 coefficients per
16-byte beat: slot *s* of beat *b* is coefficient *g = 7b + s* at bits
`[18s+17 : 18s]`; bits `[127:126]` of every beat are zero padding, and the
unused slots of the final beat are zero. No per-MAC or per-burst
alignment. `payload_bytes = ceil(NUM_MACS * COEF_DEPTH / 7) * 16`
(1M: 2,396,176 B vs 4,194,304 v1; 5.24M: 11,983,728 B vs 20,971,520 —
0.571x). The loader's `coef_bank_loader` unpacks 7 per beat and walks
`(mac, addr)` counters across beat boundaries; the stream in flash is
this payload verbatim (the QSPI boot loader stays a plain copier).
Implemented and verified (`tb_coef_bank_loader` T8/T9 at TPP 64 and 256).

**Symmetric (linear-phase) filters.** The payload holds the coefficients
the FIR *stores*, not the mathematical tap count. With the current
unfolded `fir_polyphase_*` all taps are stored (`tap_count` = stored).
The 10M-tap target (bom 18) is only reachable with the **folded FIR**
(DSP48E2 pre-adder: `h[k] * (x[n-k] + x[n-(N-1-k)])`), where the stored
set is the unique half (5,242,880) and the mirror is a datapath property
— there is NO mirror expansion in any loader. For a folded build,
`phase_type = 0` is required and `tap_count = 2 * NUM_MACS * COEF_DEPTH`;
an asymmetric filter (minimum-phase video filter) on a folded build runs
with the fold disabled at half the tap count (`tap_count = NUM_MACS *
COEF_DEPTH`, zero-padded). The fold-enable flag is derived from
`phase_type` by the loader/bank manager (RTL pending, item 18 (b)).

## DDR4 Filter Directory (built at staging, consumed by RTL)
Placed at a fixed DDR4 base address (`coef_bank_loader` parameter
`DIR_BASE_ADDR`, default `0x3FFF_0000` = top 64 KB of the 1 GB AXI
window). 32-byte entries (one 2-beat AXI burst each on the 128-bit
read port), terminated by an all-zero entry. The loader also stops after
`DIR_MAX_ENTRIES` (default 256 = 8 KB) so a missing terminator cannot
hang a load:

| Offset | Size | Field |
|---|---|---|
| 0x00 | 2 | filter_id |
| 0x02 | 1 | phase_type |
| 0x03 | 1 | rate_family |
| 0x04 | 4 | tap_count |
| 0x08 | 4 | ddr4_offset (16-byte units) |
| 0x0C | 4 | payload_bytes |
| 0x10 | 4 | latency_us |
| 0x14 | 1 | packing (0 = v1 32-bit, 1 = 18-bit packed; any other value → FILT_SIZE) |
| 0x15 | 11 | reserved |

Names are NOT in the directory — the host keeps the id↔name map from the
`.bfc` headers and exposes names over the UI/app. SPI commands carry
`filter_id` lists only (toggle list = ordered array of IDs; video mode =
host sends only eligible IDs).

### Loader lookup semantics (implemented, `coef_bank_loader.sv`)
- `filter_load_req` from the ctrl plane -> `coef_bank_manager` issues a
  load with `load_by_id=1`. The loader walks the directory from entry 0
  until `filter_id` matches, the all-zero terminator is hit, or
  `DIR_MAX_ENTRIES` are scanned. Only beat 0 (bytes 0x00-0x0F) is decoded;
  `latency_us`/reserved are ignored by RTL.
- On a match, `payload_bytes` must equal the build-time bank size for
  the entry's `packing` (`NUM_MACS * COEF_DEPTH * 4` for v1,
  `ceil(NUM_MACS * COEF_DEPTH / 7) * 16` for packed). Mismatch = filter
  built for another NUM_MACS/TAPS_PER_PHASE (or a wrong packing byte); it
  is rejected (code 2) instead of loaded as garbage. Both beats of the
  entry are read; beat 1 contributes only the packing byte.
- Coefficients are fetched from `ddr4_offset * 16` (absolute AXI byte
  address, NOT relative to `DDR4_BASE_ADDR`), `BANK_SIZE_BYTES` long.
- `load_done` pulses at the end of every attempt. `load_err` is a level
  (set before `load_done`, cleared on the next `load_start`) with
  `load_err_code`: 1 = ID not found, 2 = size mismatch. The bank manager
  does NOT swap the active bank on a failed load; the previous filter
  keeps playing.
- Legacy `load_by_id=0` path (`0x05` bank slot) still addresses
  `DDR4_BASE_ADDR + bank_id * BANK_SIZE_BYTES`; the directory is bypassed.

## SPI Command Set — filter list / video mode (DRAFT)
Extends the existing control-plane register file (`dac_ctrl_plane.sv`;
40-bit CRC-8 frames, write = `{1'b0, addr[6:0], data[23:0]}`, read =
`{1'b1, addr[6:0], -}` then readback on the following frame).

### Write registers
| Addr | Name | Data | Semantics |
|---|---|---|---|
| 0x08 | FILTER_LIST_CTRL | [0]=clear | Clears the toggle list (len=0, index=0). Host clears, then appends. |
| 0x09 | FILTER_LIST_APPEND | [15:0]=filter_id | Appends one entry; up to **32** (2026-09-03). Rejected when full (sticky[6] + CMD_ERR_INFO FILT_FULL; host reads 0x16 to verify). List order = toggle order; entry 0 is the user's default. |
| 0x0A | FILTER_SELECT | [16]=advance, [4:0]=index | advance=0: jump to `index` (out-of-range clamps to 0 + FILT_RANGE); advance=1: step to next entry (wraps). Either form pulses `filter_load_req` with the resolved `filter_id` — this is the customer filter-toggle action. |
| 0x17 | FILTER_SELECT_ID | [15:0]=filter_id | Direct select of ANY directory filter, bypassing the list ("any filter at any time"). Pulses `filter_load_req`; `cur_index` is left unchanged, so a subsequent advance resumes from the list position. Unknown ID → FILT_NOTFOUND as for 0x0A. |
| 0x0B | DAC_MODE | [0]=video_mode | Video mode flag, status/readback only. **Ruling 2026-09-04: video mode = ONE reserved filter.** Host enters video mode by writing 0x0B[0]=1 then FILTER_SELECT_ID 0x17 with the video filter's ID; exits by writing 0x0B[0]=0 and re-selecting the previous list entry (0x0A). No RTL is involved beyond the normal directory load (~4.4 ms, gapless swap). |

### Read registers
| Addr | Name | Payload |
|---|---|---|
| 0x11 | STICKY_ERR | [7:0] sticky error bits (see below); W1C via write 0x16 |
| 0x16 | FILTER_LIST_STATUS | {video_mode[11], list_len[10:5], cur_index[4:0]} (repacked 2026-09-03 for 32 entries) |
| 0x17 | FILTER_IDS | {next_filter_id[15:0], cur_filter_id[15:0]} — `cur` = ID of the last load request (list or 0x17 direct); `next` = the list entry an advance would select. Informational only: there is NO shadow-bank preload (loads are on demand, gapless, ~4.4 ms @ 1M taps). |
| 0x1C | CMD_ERR_INFO | {addr[6:0], reason[3:0]} of the most recent bit[7:4] event; cleared with the sticky W1C |

### Per-cell converter measurements (2026-10-14)

Write `0x18` (L) or `0x19` (R): `[7]=enable`, `[6]=add selected cell`,
`[5:0]=cell index 0..63`, `[23:8]=0`. Index 0 is physical cell 1
(`DAT01` / `DATR01`); index 63 is cell 64. Each channel has its own command
and request/acknowledge handshake. Read `0x1D` (L) / `0x1E` (R):
`[8]=pending`, `[7:0]=last accepted command`. These write addresses do not
change the existing calibration-store read registers at `0x18/0x19`.

For selected cell i, the baseline selects the next 32 cells cyclically
(i+1 through i+32 modulo 64), excluding i. Test state adds only cell i:
32 versus 33 selected cells. Subtract the two settled I/V output readings
at the SAME cell index; do not subtract baselines across different indices.
The measured difference includes that cell's normal 6-of-8 RTZ duty and the
I/V transfer gain. All other cells retain the same pattern in the pair.
During a diagnostic session, a channel without its enable bit set runs a
fixed 32-cell baseline (indices 0..31), not audio/DEM. This allows L-only,
R-only, or independently configured simultaneous measurements with a
repeatable other-channel background. The normal IOB/reclock/RTZ path is
retained. Diagnostic cadence comes from cell_clk/8; no I2S source, filter
coefficients, DDR loading, volume, or DPD is needed for these patterns.

Bench sequence:
1. Mute (`0x04=0`); wait for relay drive/status low and sequencer idle.
   Enabling diagnostics while unmute is requested or either relay drive is
   high is rejected. DSP additionally waits 4,000,000 consecutive safe
   clocks (audio clamped and both relay drives low) before accepting enable.
2. Write `0x80 | i` to the selected channel; poll its pending bit clear with
   a timeout, check sticky errors, then allow analog/measurement settling.
   Pending clears on DSP acceptance, BEFORE the next RTZ pattern reaches
   the pins; it is not a sample-trigger or settling flag.
3. Measure OUT_P and OUT_M before the mute relay. Write `0xC0 | i`, repeat
   the wait/measurement, and difference the readings to measure the cell.
   Summing-node COL_P/COL_M taps on both channels are for compliance and
   settling checks; their near-constant voltage is not a cell-current readout.
4. Repeat for all 64 cells/channel. Write zero to BOTH diagnostic registers
   and poll both pending bits clear before requesting normal unmute.

UNMUTE is rejected while either channel is enabled or any command is pending.
Reset clears diagnostic state; after any clock-family change or lock loss,
abort the measurement, disable both channels, and re-enter explicitly.
Rejects set sticky[6] / CMD_ERR_INFO: `0xC TEST_BUSY` (do not overwrite a
pending channel command), `0xD TEST_UNSAFE` (mute interlock),
`0xE TEST_FORMAT` (nonzero reserved bits). No new test-sync pin or ADC is
provided: measurements require an external instrument. The 1k summing-node
probe resistors reduce loading, not eliminate it; 10 pF gives approximately
16 MHz probe-path bandwidth. Use a low-capacitance active probe, never a
50-ohm termination. DC output-delta measurements and wideband settling
measurements require different instrument setups.

### Local two-button bring-up controller (locked 2026-10-14)

No AP, I2S traffic, filter coefficients, or DDR initialization is required for
these tests. The FPGA must be configured, audio clocks running, and PG_ALL
asserted. SW9000 (Button 1 / SELECT) counts presses in a fixed three-second
window beginning with the first debounced press. One, two, or three presses
select the modes below; four or more reject selection and leave outputs muted.
A held button does not repeat. The default debounce interval is 10 ms.

| Selection | Held conditions, LEFT then RIGHT | D9023 while running |
|---|---|---|
| 1 CELL | Cell 1 baseline, cell 1 added, cell 2 baseline, ... cell 64 added; 128 conditions/channel | 1 Hz |
| 2 DC/LEVEL | Offsets 0, +1, -1, +4, -4 cell-equivalents relative to digital mid-code; 5 conditions/channel | 2 Hz |
| 3 FREQUENCY | Continuous sine at 1, 2, ... 20 kHz; 20 conditions/channel | 3 Hz |

SW9001 (Button 2 / STEP) advances exactly one held condition. No timed sweep
or automatic wrap occurs. After the last RIGHT condition, one more STEP ends
the test, extinguishes D9023, and leaves XLR muted. Button 1 during HOLD stops
the old stimulus and opens a new selection window. Holding Button 1 for two
seconds cancels; release it before selecting again. Inputs during a command
transfer are not queued. Wait for the running indication before STEP.

The single test LED continues flashing while waiting for measurements; off
means no test is running (including selection/waiting for power-good), not
"measurements passed". It is also off during command handshakes. No LED PWM
or multiplexing is used beyond the agreed 1/2/3 Hz status flashing. D9023 is
fed through 20k from V12SOM for approximately 500uA, with an MMBT3904 sink
controlled by LVCMOS18 through a 10k base resistor;
it does not draw its LED current from V33D or analog supplies.

Mode 2 and mode 3 bypass FIR, volume, boot envelope and DPD, but retain the
noise shaper, DEM, physical cell drivers and RTZ timing. The sine DDS has a
32-bit phase accumulator and a 1024-entry, 16-bit sine ROM, with a fixed peak
of approximately four cell-equivalents. Tuning uses Fs = MCLK/8: 5.6448 MHz
or 6.144 MHz according to the selected clock family. Frequency accuracy also
depends on the real oscillator. This is a frequency-response/bring-up source,
NOT a certified low-distortion source for the -115/-125 dBc acceptance gates.
The non-selected channel receives zero digital signal in modes 2/3 (normal
mid-code noise shaping/DEM); CELL uses the fixed 32-cell pattern described
above. DC values are codes, not calibrated 2/4/6 V output settings.

Measure pre-relay OUT_P/M. These modes exercise the converter PLUS the I/V
OPA1612/BUF634A feedback loop; no separate voltage-gain stage or independent
I/V current-injection fixture has been added. The operator determines analog
and instrument settling before acquisition. Acknowledgement is not a hardware
trigger output or a guarantee that analog settling is complete.

Safety/ownership: first accepted SELECT latches the SPI unmute command off.
Local start is refused while a SPI cell test is enabled/pending. SPI cell
writes, clock-family changes and UNMUTE are rejected while local control owns
the test. There is no automatic unmute on exit. The core requires PG_ALL,
force_zero and both relay drives low for 4,000,000 consecutive DSP clocks
before starting; the manual command uses a held-bus request/acknowledge
handshake. Clock/power-good loss aborts, with command draining deferred until
clocks run again; recovery never deliberately resumes the old sequence.
External reset clears both controllers. Physical FPGA configuration failure
cannot be diagnosed using these buttons; use supply/configuration indicators.

SPI read `0x1F` BENCH_STATUS: `[0] busy/ownership`, `[1] LED`, `[3:2] mode`,
`[4] channel (0=L)`, `[11:5] step`, `[12] rate (1=48k family)`,
`[15:13] FSM (0=idle,1=selecting,2=waiting-safe,3=request,4=ack-release,5=hold)`,
`[18:16] selection count`, `[19] cancel pending`, `[20] fault/rejected-selection`.
Only state 5 denotes a held running condition. The existing SPI cell commands
remain available when local control is idle; automated event control for the
DC/tone sequences is deferred. SPI rejects use the existing TEST_BUSY/UNSAFE
reason codes. Read status does not move the test forward.

GPIOs (Alinx J1, bank 71): SELECT M29/D20, STEP L29/D19, TEST_LED L28/D17;
PG_ALL N29/B7 is now an input. The obsolete, undrawn relay_level[1] output
was moved to unused K28/D16 to remove its previous collision with PG_ALL.

Targeted regressions: `run_tb_ctrl_plane.ps1 tb_bench_controller`,
`run_tb_ctrl_plane.ps1 tb_bench_stimulus`, and
`run_tb_ctrl_plane.ps1 tb_cell_measurement` (the last supplies SIM and includes
the real DSP path). The existing `tb_dac_ctrl_plane` also checks arbitration,
status readback and no automatic unmute. Production timing/CDC sign-off still
requires synthesis and implementation.

### Filter-load error reporting
A failed directory load (ui_clk `load_err` level from the loader) is
edge-synchronised into the SPI clock domain and raises `fpga_irq_n`:

| Sticky bit | Meaning |
|---|---|
| 6 | rejected command OR filter load failed |

| CMD_ERR_INFO reason | addr | Cause |
|---|---|---|
| 0xA FILT_NOTFOUND | 0x0A | `filter_id` not in DDR4 directory (terminator / scan cap reached); no bank swap |
| 0xB FILT_SIZE | 0x0A | directory `payload_bytes` != bank size; no bank swap |

Other reasons: 1 BAD_ADDR, 2 FLASH_BUSY, 3 FLASH_OP, 4 FILT_FULL,
5 FILT_EMPTY, 6 FILT_RANGE, 7 CAL_WRAP, 8 FLASH_WDT, 9 FRAME_LEN.
Host flow after `FILTER_SELECT`: wait for IRQ or poll 0x11; if bit 6 is
set read 0x1C, then write 0x16 with bit 6 to clear (also clears 0x1C).
A held error level does not re-latch after the W1C (edge-triggered).

### Notes
- Legacy 0x05 (coef_bank_id + load_start) remains for bring-up/debug;
  the named path supersedes it for product use.
- Name→ID resolution is HOST-side (from `.bfc` headers at staging time);
  the FPGA only ever sees 16-bit IDs and resolves them via the DDR4
  filter directory (see "Loader lookup semantics" above).
- **No latency readback (TODO-20 closed 2026-09-04).** Customers never see
  delay numbers, so the directory `latency_us` word (beat 1) stays unread
  by RTL and there is no ctrl-plane register for it. The field remains in
  the `.bfc` header / directory as builder metadata.
- **Video-mode filter.** A single minimum-phase (or short) filter with a
  reserved `filter_id`, zero-padded at staging to the full 1M-tap bank
  (`payload_bytes` = 4,194,304 like every other filter — the loader
  enforces this). Padding costs nothing at runtime; the group delay is set
  by where the coefficient energy sits, not by the padded length. With two
  FIR banks it is loaded on demand like any other filter (4.4 ms), so it
  need not stay resident. Budget justification: a 1M-tap linear-phase
  filter at 16x has ~683 ms group delay at 48 kHz (32,768 input samples),
  which is why video mode exists; the <=20 ms end-to-end budget is far
  below the audio-lag detectability thresholds (ITU-R BT.1359 ~125 ms lag
  detectable; ATSC IS-191 recommends <=45 ms lag), so 5 ms vs 20 ms is
  immaterial for lip sync.

## Open questions (ratification gates)
1. Per-rate-family variants: one filter_id per (name, rate_family) pair or
   a family field with sub-entries? (Current draft: one file/id per pair,
   name shared.)
2. ~~Coefficient packing~~ RESOLVED 2026-10-05: 18-bit packed, 7 per
   16-byte beat (`packing = 1`), implemented in `coef_bank_loader`; v1
   remains selectable per entry. Driver was carrier-flash capacity (bom
   18/18a: 22 filters per 2 Gb device at 10M taps), not DDR4.
3. ~~Latency budget constant for video_mode_eligible~~ RESOLVED 2026-09-04:
   <=20 ms end-to-end (incl. halfbands + ingress), single video filter,
   checked by the filter builder from `latency_us`; see Notes.
4. Where the id↔name map lives for a headless (no-app) front panel: front
   panel MCU reads `.bfc` headers directly from QSPI, or a compiled menu
   blob is staged alongside.
