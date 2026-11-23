# SPI Bus — buses, register map, and write-access partition

Status: DRAFT for access-review. Source of truth: `Xilinx/spi_regs.svh`,
`Xilinx/dac_ctrl_plane.sv`. Progress log: `progress.md`.

## 1. Bus topology — three buses

| Bus | Master | Slave | Path | Access |
|---|---|---|---|---|
| `XMOS_SPI_*` | XMOS U851 (AP board) | FPGA | U851 → J7705 SEAF → J506 SEAF → U501 MAX22445C isolator → SoM J1 bank 90 | XMOS writes restricted subset |
| `AP_SPI_*` | VAR-SOM-MX93 AP (J855 SoM) | FPGA | J855 → J7705 SEAF → J506 SEAF → U509 MAX22445C + U513 MAX22445F (irq) → SoM J1 bank 91 | AP writes all registers |
| `HOST_*` | AP ↔ XMOS | — | private AP↔XMOS link, never reaches FPGA | n/a |

- Both FPGA SPI slaves see the **same register file** in `dac_ctrl_plane.sv`.
- Reads: **unrestricted on both ports** — same map, independent `read_addr` latch per port.
- Writes: per-port pending-slot arbiter drains into the shared decode; XMOS wins ties.
- `spi_ap_irq_n` = `fpga_irq_n` source (sticky errors) via U513 MAX22445F (asserted while FPGA domain down, same convention as U502/FPGA_IRQ_N).
- `CTRL_STATE[6]` = `last_wr_src` (0=XMOS, 1=AP) — ownership-fight debug aid.

## 2. Frame format

40 bits `{R/W[1], addr[7], data[24], crc8}`, CRC-8 poly 0x07 over bits [39:8].
Write and read address spaces are independent. Unknown read → `0xDEADBEEF`;
unknown/denied write → `sticky[5]` BAD_ADDR + `CMD_ERR_INFO`.

## 3. Write registers (28 active; 0x06 reserved)

Current access column = implemented draft (`wr_denied` in dac_ctrl_plane.sv).
Ruling column = review checkbox.

| Addr | Name | Data | Function | Now | Ruling | Status |
|---|---|---|---|---|---|---|
| 0x00 | NOP | — | no-op; clocks out pending read response | both | both | [ ] confirmed |
| 0x01 | VOLUME | [23:0] Q0.24 | normalized volume → Q16.16 internal gain; 0xFFFFFF=FS | AP | **AP-only** (ruled 11-14: UAC2 volume disabled; app sets volume) | [x] ruled |
| 0x02 | LEVEL | [2:0] | digital level cap 000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms; applied muted | AP | **AP-only** (ruled 11-14: app-controlled) | [x] ruled |
| 0x03 | RATE | [2:0] | alias of STREAM_RATE | **XMOS-only** (XMOS declares ITS stream's rate; stored while XMOS deselected, applies on re-select/arm. AP's rate lives in I2S_SRC 0x1C. Same-rate rewrite = stream restart/invalidate only — no relock) | [x] ruled |
| 0x04 | — | — | **REMOVED** (was UNMUTE — retired 11-15; stream arm = STREAM_VALID 0x1B, user mute = VOLUME) | — | — | [x] removed |
| 0x05 | BANK_LOAD | [3:0] | legacy DDR4 slot id + coef_load_start trigger | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x06 | — | — | RESERVED (was clk_source_sel, merged 0x03) | — | — | [x] reserved |
| 0x07 | — | — | **REMOVED** (was OUTSEL 0=line/1=HP; no headphone output stage — ruled 11-14) | — | — | [x] removed |
| 0x08 | FILTER_LIST_CTRL | [0]clr [1]commit | clear filter toggle-list / commit entry 0 | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x09 | FILTER_LIST_APP | [15:0] | append filter_id to toggle list (≤32) | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x0A | FILTER_SELECT | [16]adv [4:0]idx | select from toggle list | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x0B | — | — | **REMOVED** (was DAC_MODE video_mode; video-sync streaming not supported — ruled 11-15) | — | — | [x] removed |
| 0x0C | CAL_ADDR | [8:0] | cal shadow-bank write pointer | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x0D | CAL_DATA | [23:0] | shadow word write, auto-incr | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x0E | CAL_COMMIT | [0] | atomic bank-swap toggle | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x0F | CAL_RDADDR | [8:0] | active-bank readback address | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x10 | FLASH_ADDR_LO | [23:0] | flash cmd addr[23:0] | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x11 | FLASH_ADDR_HI | [9:8] tgt | 0=SoM Flash1(coef) 1=SoM Flash0(bin) 2=carrier (chip=addr[29:28]) | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x12 | FLASH_CMD | [7:0] | 0x01 erase / 0x02 program / 0x03 read | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x13 | FLASH_DATA | [7:0] | page-buffer byte, auto-incr | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x14 | FLASH_PTR | [15:0] | page-buffer w/r pointer | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x15 | DPD_EN | [0] | DPD engine enable | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x16 | STICKY_W1C | [7:0] | write-1-clear sticky bits + CMD_ERR_INFO; XMOS masked to {0,1,4} (its bus errors + I2S) | masked | **AP full, XMOS masked** (ruled 11-15) | [x] ruled |
| 0x17 | FILTER_SELECT_ID | [15:0] | direct directory filter_id, bypasses toggle list | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x18 | CELL_TEST_L | [7:0] | cell-test cfg L + req toggle | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x19 | CELL_TEST_R | [7:0] | cell-test cfg R + req toggle | AP | | **AP-only** (ruled 11-16) | [x] ruled |
| 0x1A | STREAM_RATE | [2:0] | {rate_shift[1:0],family48}; resets unmute/src-valid/dpd | **XMOS-only** (same ruling as 0x03) | [x] ruled |
| 0x1B | STREAM_VALID | [4:0] | XMOS "stream actually live" flag at [0]; arms the stream when XMOS is the selected source; rejects while busy/not-ready/fault/diagnostics. **[4:2] arm-echo (2026-11-21 ruling, MANDATORY):** arm writes must echo the source's expected `rate_req_src1`; mismatch refuses the arm + sets `STREAM_EVENT[2]` (no relock burned). Disarm ([0]=0) ignores echo | **XMOS-only** | **XMOS-only** (ruled 11-15, echo ruled 11-21) | [x] ruled |
| 0x1C | I2S_SRC | [20:0] | **dual-source restore 2026-11-20**: [0] src_sel (0=XMOS i2s_data, 1=AP i2s_data2), [1] AP stream-live flag, [4:2] AP declared rate {shift,fam48}, [12:8] rx_trim_src1, [20:16] rx_trim_src2. **Select ≠ rate**: a bare select of an unarmed source never re-rates. Apply fires on exactly two events: (a) the selected source's **live/divergent** rate — select-to-armed, or arm (0x1C[1] sel=1 / XMOS 0x1B sel=0) with declared≠applied; (b) a **fresh declare while selected** — a CHANGED [4:2] field while sel=1 is symmetric to an XMOS RATE write. Same-rate writes never relock (idempotent). Any apply = re-rate FSM flush+reload + consumes the arm (re-arm post clocks_ready). src_sel flushes capture + re-arms framing — no torn frames | **AP-only** | **AP-only** (ruled 11-20: AP owns input select + its stream declaration; XMOS denied) | [x] ruled |

| 0x1D | VOICING_K2 | [23:0] | k2 raw Q2.25, sign-extended | AP | AP-only | |
| 0x1E | VOICING_K3 | [23:0] | k3 raw Q2.25, sign-extended | AP | AP-only | |
| 0x1F | VOICING_CTRL | [8:0] | [0] voicing_en shadow, [8] commit at fir_frame_done | AP | AP-only | |
| 0x20 | VOICING_FILTER_ID | [15:0] | raw directory ID; 0xFFFF = don't-touch-bank sentinel | AP | AP-only | |
| 0x21 | STREAM_EVENT | [2:0] | **stream-gate W1C (2026-11-21)**: [0] preempt_xmos, [1] preempt_ap, [2] echo_mismatch — doorbell flags for gate-close/session-consumed/arm-reject events (see FIRMWARE_CONTRACT.md §1-2). XMOS masked to {0,2} (own domain); AP clears all. Asserts fpga_irq_n ([0]|[2]) / spi_ap_irq_n ([1]) | masked | **AP all, XMOS masked** | [x] ruled |

Reserved: 0x06 (was clk_source_sel, merged into 0x03).

## 4. Read registers — unrestricted on both ports

| Addr | Name | Contents |
|---|---|---|
| 0x10 | MAGIC | 0xDAC02026 |
| 0x11 | STICKY_ERR | sticky bits below |
| 0x12 | CTRL_STATE | last_wr_src[6], clk_source_sel[5], base_rate_sel[4], rsvd[3]=0, level[2:0] |
| 0x13 | COEF_STATUS | bank_valid[12], mgr_busy[11], load_done[10], clk_src[9], base_rate[8], cur_bank[7:4], bank_id[3:0] |
| 0x14 | MUTE_STATUS | i2s_err[4], switch_busy[3], rsvd[2]=0, line_mute[1], unmute[0] |
| 0x15 | CLK_STATUS | dpd_enable, ddr4_calib, clk_locked |
| 0x16 | FILTER_LIST_STAT | video_mode[11], list_len[10:5], cur_index[4:0] |
| 0x17 | FILTER_IDS | next_in_list_id[31:16], cur_filter_id[15:0] |
| 0x18 | CAL_STATUS | cal_valid[11], cal_wr_ptr[10:2], pending[1], active_bank[0] |
| 0x19 | CAL_RDDATA | active-bank word at CAL_RDADDR |
| 0x1A | BOOT_STATUS | boot_src[13], record_count[12:5], axi_fail[4], crc_fail[3], boot_ok[2], boot_done[1], flash_busy[0] |
| 0x1B | FLASH_RDDATA | page-buffer byte at FLASH_PTR[15:8] |
| 0x1C | CMD_ERR_INFO | detail[11], addr[10:4], reason[3:0] |
| 0x1D | CELL_TEST_L | busy[8], cfg[7:0] |
| 0x1E | CELL_TEST_R | busy[8], cfg[7:0] |
| 0x1F | BENCH_STATUS | bench controller status word |
| 0x20 | STREAM_STATUS | busy[0], clocks_ready[1], svalid_xmos[2], bank_valid[3], fault[4], applied_rate[7:5], req_rate[10:8], rx_trim_selected[15:11], audio_ready[16], src_sel[17], svalid_ap[18], rate_req_src2[21:19] |
| 0x22 | STREAM_EVENT | preempt_xmos[0], preempt_ap[1], echo_mismatch[2], rate_req_src1[5:3] (informational shadow only — never authorization) |

Unmapped read → 0xDEADBEEF. Frame 40-bit {R/W, addr[7], data[24], crc8}, CRC-8/0x07.

**Sticky bits** (0x11/0x16): [0]SPI_CRC [1]i2s_err [2]ddr4_calib [3]pll_unlock
[4]frame_len [5]bad_addr [6]cmd_reject [7]boot_flash.

**CMD_ERR_INFO reasons**: 0 none, 1 BAD_ADDR, 2 FLASH_BUSY, 3 FLASH_OP,
4 FILT_FULL, 5 FILT_EMPTY, 6 FILT_RANGE, 7 CAL_WRAP, 8 FLASH_WDT,
9 FRAME_LEN, A FILT_NOTFOUND, B FILT_SIZE, C TEST_BUSY, D TEST_UNSAFE,
E TEST_FORMAT, F FILT_RATE.

## 5. Current draft partition (implemented)

- **XMOS-allowed (6)**: NOP, STICKY_W1C (masked to own bits), STREAM_EVENT
  W1C 0x21 (masked to own bits {preempt_xmos, echo_mismatch})
- **XMOS-only**: RATE 0x03, STREAM_RATE 0x1A, STREAM_VALID 0x1B
  (AP writes denied BAD_ADDR)

- Removed registers: OUTSEL 0x07 (2026-11-14), DAC_MODE 0x0B (2026-11-15),
  UNMUTE 0x04 (2026-11-15) — all now reserved, writes → BAD_ADDR.
  I2S_RX_TRIM 0x1C removed 11-15, **restored as I2S_SRC 11-20** (dual-source)
- **AP-only (18, all ruled)**: BANK_LOAD, FILTER_LIST_CTRL/APP, FILTER_SELECT,
  FILTER_SELECT_ID, CAL_ADDR/DATA/COMMIT/RDADDR, FLASH_ADDR_LO/HI/CMD/DATA/PTR,
  DPD_EN, CELL_TEST_L/R, **I2S_SRC**
- Reads: unrestricted both ports.

## 6. Rulings log + open items

**Ruled 2026-11-14:**

- [x] VOLUME (0x01) → **AP-only**. UAC2 volume control is disabled on the USB
  path; only the streamer/AP application sets volume. XMOS has no access.
- [x] LEVEL (0x02) → **AP-only**. Output level is application-controlled.
- [x] OUTSEL (0x07) → **REMOVED**. No separate headphone XLR/amp stage exists;
  register retired to reserved, all HP-path RTL struck (automute outsel FSM,
  hp_mute/hp_rails drives, relay_hp_mute/relay_hp_rails ports + pins E5/A6,
  CTRL_STATE[3] and MUTE_STATUS[2] now reserved 0).
- [ ] UNMUTE (0x04) → **deferred** ("probably needs to change"). Still both.

**Ruled 2026-11-15:**

- [x] RATE (0x03) / STREAM_RATE (0x1A) → **XMOS-only**. XMOS is the sole
  audio source to the FPGA (USB or AP-network relay); rate always
  originates there. AP writes denied (BAD_ADDR).
- [x] DAC_MODE (0x0B) → **REMOVED**. Video-sync streaming not supported;
  register retired, video_mode output + FILTER_LIST_STAT[11] now reserved 0.

**Open rulings — review checklist:**

- [x] R1 MUTE ARCHITECTURE (ruled + implemented 11-15): three tiers —
  (a) no stream/stream stops → digital clamp (force_zero+volume),
  (b) user mute → same digital path, (c) not-ready/unsafe → relay.
  Relay transitions are AUDIBLE so the relay must not cycle mid-session:
  it energizes ONCE at startup (sys_ready = clk_locked && pg_all) and
  stays closed for the session. Mid-session relay open ONLY on pg_all
  loss (extreme power error) or cell-test/bench entry (factory-only).
  i2s_err/rate-change/unmute=0/stream-stop are all digital clamp only —
  no click on dropped USB or format changes. Implemented:
  automute_controller rewritten (ST_OPEN→SETTLING→ARMED→FLUSHING→
  PLAYING + ST_SWITCHING/ST_LVL_SETTLE for the level cap);
  relay_line_mute = line_mute_drive && pg_all_sync (no stream/fault
  gating); test_mode_active opens the relay for cell-test isolation.
  tb_automute rewritten, tb_cell_measurement + tb_vu13p_top updated.
- [x] R1a UNMUTE (0x04) → **RETIRED** (ruled 11-15). User clarified the
  semantics: only two mute notions exist — (a) zero output voltage
  (VOLUME / stream transitions / STREAM_VALID), (b) relay disconnect
  (startup + major power events only). A dedicated unmute register was a
  third path duplicating STREAM_VALID, so it was removed: writes to 0x04
  → BAD_ADDR; automute's unmute input is now stream_source_valid &&
  stream_clocks_ready && bank_valid. STREAM_VALID=1 gained the
  cell-test/bench reject that UNMUTE had. MUTE_STATUS[0] now reserved-0.
- [x] R3 I2S_RX_TRIM (0x1C) → ~~REMOVED 11-15~~ **RESTORED as I2S_SRC
  (2026-11-20)**: the AP is a second direct I2S source (McASP0 → U503 →
  `i2s_data2` B2/J1-A6, reinstated). `[0]` src_sel, `[1]` AP stream-live
  flag (0x1B-equivalent for the AP stream), `[4:2]` AP declared rate,
  `[12:8]`/`[20:16]` per-source rx_trim (trim is per-source again — the
  two return paths differ: U502-rev+XU316 vs U503-fwd+McASP0). Select and
  rate are **separate decisions** (user ruling): a bare `src_sel` change
  on an unarmed source never touches the clock — the rate applies only
  when the selected source is live (select-to-armed applies its stored
  declared rate; an arm — 0x1C[1] sel=1 or XMOS 0x1B sel=0 — applies the
  declared rate if it diverged while deselected). Any apply runs the
  re-rate FSM flush+reload (Option A); the deselected source conforms to
  the wire rate or idles. XMOS denied.
- [x] R4 STICKY_W1C (0x16) → **MASKED** (ruled 11-15): XMOS may clear
  only its own bits — {SPI_CRC[0], I2S_ERR[1], FRAME_LEN[4]} — via a
  write mask (AP-domain bits DDR4_CALIB/PLL_UNLOCK/BAD_ADDR/CMD_REJECT/
  BOOT_FLASH are masked off, and CMD_ERR_INFO is never cleared by XMOS —
  it's the AP's debug record). AP retains full W1C + CMD_ERR_INFO clear
  (debugging access to XMOS-domain bits too).
- [x] R4b STREAM_VALID (0x1B) → **XMOS-only** (ruled 11-15): XMOS
  controls all streaming — bit rate, stream type — so the stream arm
  flag is XMOS-owned like RATE. AP writes denied BAD_ADDR. Post-R1 it
  is the XMOS "stream is live" path: unmute_req (XMOS selected) =
  stream_source_valid && clocks_ready && bank_valid. Writing 0 disarms
  (underrun/stop). **2026-11-20**: the AP's equivalent flag is
  I2S_SRC[1]; the muxed valid (src_sel ? svalid_ap : svalid_xmos)
  drives the unmute arm and ingress source_valid.
- [x] R5 DPD_EN (0x15) → **AP-only** (ruled 11-16 — confirmed).
- [x] R7 CELL_TEST_L/R → **AP-only** (ruled 11-16 — confirmed).
- [x] R8 FILTER_* (0x08/09/0A/17) → **AP-only** (ruled 11-16 — confirmed).
- [x] R9 FLASH_* (0x10-0x14) → **AP-only** (ruled 11-16 — confirmed).
- [x] R10 BANK_LOAD (0x05) → **AP-only** (ruled 11-16 — kept as a
  debug/recovery hook for manual DDR4 bank loads).
- [ ] Document final partition in firmware protocol doc (todo: firmware protocol doc FPGA↔XMOS↔host).
- [ ] Decide dedicated deny reason code vs current BAD_ADDR reuse.
- [ ] TB coverage: extend denied-write tests to every AP-only addr (currently T10 spot-checks FILTER_LIST_CTRL).

## 7. Physical / schematic state (done)

- XMOS bus: U501 MAX22445C, J506 pads 1-7, J1 bank 90 pins T26/R26/H29/G29 + irq→none.
- AP bus: U509 MAX22445C (3F+1R), U513 MAX22445F (irq, asserted while FPGA down),
  C513–C516; J506 row-A pads 29/31/33/35/37; J1 bank 91 (B11/B10/A11/C7/C8).
- J855 MCSPI2 IOSet proposal (pins 80/39/45/41 + irq 61): VERIFY pending vs Variscite pin list.
- Pre-existing bug on ctrl sheet: VAP_IO net merged into GND_AP (xcheck FAIL(1) on HEAD too) — separate todo.
