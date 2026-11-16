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
| 0x03 | RATE | [2:0] | alias of STREAM_RATE | **XMOS-only** (ruled 11-15: XMOS is the sole audio source — USB or AP-network relay — rate always originates there; AP writes denied) | [x] ruled |
| 0x04 | UNMUTE | [0] | digital unmute req — releases force_zero clamp (relay untouched post-R1); stream-gated at top | both | **open** (R1a — XMOS-only vs both) | [ ] open |
| 0x05 | BANK_LOAD | [3:0] | legacy DDR4 slot id + coef_load_start trigger | AP | | [ ] |
| 0x06 | — | — | RESERVED (was clk_source_sel, merged 0x03) | — | — | [x] reserved |
| 0x07 | — | — | **REMOVED** (was OUTSEL 0=line/1=HP; no headphone output stage — ruled 11-14) | — | — | [x] removed |
| 0x08 | FILTER_LIST_CTRL | [0]clr [1]commit | clear filter toggle-list / commit entry 0 | AP | | [ ] |
| 0x09 | FILTER_LIST_APP | [15:0] | append filter_id to toggle list (≤32) | AP | | [ ] |
| 0x0A | FILTER_SELECT | [16]adv [4:0]idx | select from toggle list | AP | | [ ] |
| 0x0B | — | — | **REMOVED** (was DAC_MODE video_mode; video-sync streaming not supported — ruled 11-15) | — | — | [x] removed |
| 0x0C | CAL_ADDR | [8:0] | cal shadow-bank write pointer | AP | | [ ] |
| 0x0D | CAL_DATA | [23:0] | shadow word write, auto-incr | AP | | [ ] |
| 0x0E | CAL_COMMIT | [0] | atomic bank-swap toggle | AP | | [ ] |
| 0x0F | CAL_RDADDR | [8:0] | active-bank readback address | AP | | [ ] |
| 0x10 | FLASH_ADDR_LO | [23:0] | flash cmd addr[23:0] | AP | | [ ] |
| 0x11 | FLASH_ADDR_HI | [9:8] tgt | 0=SoM Flash1(coef) 1=SoM Flash0(bin) 2=carrier (chip=addr[29:28]) | AP | | [ ] |
| 0x12 | FLASH_CMD | [7:0] | 0x01 erase / 0x02 program / 0x03 read | AP | | [ ] |
| 0x13 | FLASH_DATA | [7:0] | page-buffer byte, auto-incr | AP | | [ ] |
| 0x14 | FLASH_PTR | [15:0] | page-buffer w/r pointer | AP | | [ ] |
| 0x15 | DPD_EN | [0] | DPD engine enable | AP | | [ ] |
| 0x16 | STICKY_W1C | [7:0] | write-1-clear sticky bits + CMD_ERR_INFO | both | **PARKED** — review in detail (XMOS can clear AP-domain errors) | [ ] parked |
| 0x17 | FILTER_SELECT_ID | [15:0] | direct directory filter_id, bypasses toggle list | AP | | [ ] |
| 0x18 | CELL_TEST_L | [7:0] | cell-test cfg L + req toggle | AP | | [ ] |
| 0x19 | CELL_TEST_R | [7:0] | cell-test cfg R + req toggle | AP | | [ ] |
| 0x1A | STREAM_RATE | [2:0] | {rate_shift[1:0],family48}; resets unmute/src-valid/dpd | **XMOS-only** (same ruling as 0x03) | [x] ruled |
| 0x1B | STREAM_VALID | [0] | "stream actually live" flag; gates digital unmute (top-level AND + UNMUTE reject); 0 also clears unmute. No relay gating post-R1 | both | open (§6 R4b — XMOS-only vs both) | [ ] open |
| 0x1C | I2S_RX_TRIM | [4:0]trim [5]src_sel | [4:0] FPGA-master I2S capture-point trim; [5] src_sel muxes i2s_data2 host path | both | **PARKED** — review in detail | [ ] parked |

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
| 0x20 | STREAM_STATUS | busy[0], clocks_ready[1], source_valid[2], bank_valid[3], fault[4], applied_rate[7:5], req_rate[10:8], rx_trim[15:11], audio_ready[16] |

Unmapped read → 0xDEADBEEF. Frame 40-bit {R/W, addr[7], data[24], crc8}, CRC-8/0x07.

**Sticky bits** (0x11/0x16): [0]SPI_CRC [1]i2s_err [2]ddr4_calib [3]pll_unlock
[4]frame_len [5]bad_addr [6]cmd_reject [7]boot_flash.

**CMD_ERR_INFO reasons**: 0 none, 1 BAD_ADDR, 2 FLASH_BUSY, 3 FLASH_OP,
4 FILT_FULL, 5 FILT_EMPTY, 6 FILT_RANGE, 7 CAL_WRAP, 8 FLASH_WDT,
9 FRAME_LEN, A FILT_NOTFOUND, B FILT_SIZE, C TEST_BUSY, D TEST_UNSAFE,
E TEST_FORMAT, F FILT_RATE.

## 5. Current draft partition (implemented)

- **XMOS-allowed (7)**: NOP, RATE/STREAM_RATE (XMOS-only), UNMUTE,
  STICKY_W1C, STREAM_VALID, I2S_RX_TRIM
- **XMOS-only**: RATE (0x03) / STREAM_RATE (0x1A) — AP writes denied
  (ruled 2026-11-15)
- Removed registers: OUTSEL 0x07 (2026-11-14), DAC_MODE 0x0B (2026-11-15)
  — both now reserved, writes → BAD_ADDR
- **AP-only (17)**: BANK_LOAD, FILTER_LIST_CTRL/APP, FILTER_SELECT,
  FILTER_SELECT_ID, CAL_ADDR/DATA/COMMIT/RDADDR, FLASH_ADDR_LO/HI/CMD/DATA/PTR,
  DPD_EN, CELL_TEST_L/R
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
- [ ] R1a UNMUTE (0x04) semantics/ownership: **still open**. Under the new
  model UNMUTE is purely digital (releases the force_zero clamp; stream-
  readiness gating in top still applies). Ownership options: both (AP can
  force-mute/kill) vs XMOS-only (consistent with RATE/STREAM_VALID).
- [ ] R3 I2S_RX_TRIM (0x1C): **[PARKED — review in detail as todo]**
  `[4:0]` trim = FPGA-master I2S capture-point adjustment (round-trip skew
  to XMOS) — likely still useful. `[5]` src_sel muxes i2s_data2 (host
  audio path) — dead if XMOS is the only source. Open: keep trim + drop
  src_sel/i2s_data2 mux?
- [ ] R4 STICKY_W1C (0x16): **[PARKED — review in detail as todo]**
  write-1-clear port for the shared sticky-error register + CMD_ERR_INFO;
  releases fpga_irq_n/spi_ap_irq_n. XMOS can currently clear shared
  AP-domain bits (BOOT_FLASH/FLASH_OP/DDR4_CALIB). Open: AP-only, or XMOS
  restricted mask (only SPI_CRC/I2S_ERR/FRAME_LEN)?
- [ ] R4b STREAM_VALID (0x1B): still needed — the "stream actually live"
  flag; gates the digital unmute path (spi_unmute top-level AND + UNMUTE
  reject + auto-clears unmute on 0). Post-R1 it NO LONGER gates
  relay_line_mute (relay is startup/fault/test only), so it is now
  purely digital-mute/UX state. Ownership: XMOS-only (consistent with
  RATE) vs both (AP can force-stop by writing 0)?
- [ ] R5 DPD_EN (0x15): confirm AP-only.
- [ ] R7 CELL_TEST_L/R: confirm AP-only (bench feature).
- [ ] R8 FILTER_*: confirm all four AP-only per user ruling "XMOS should not choose filters".
- [ ] R9 FLASH_*: confirm AP-only (update start = AP only per user).
- [ ] R10 BANK_LOAD legacy: keep AP-only or deprecate?
- [ ] Document final partition in firmware protocol doc (todo: firmware protocol doc FPGA↔XMOS↔host).
- [ ] Decide dedicated deny reason code vs current BAD_ADDR reuse.
- [ ] TB coverage: extend denied-write tests to every AP-only addr (currently T10 spot-checks FILTER_LIST_CTRL).

## 7. Physical / schematic state (done)

- XMOS bus: U501 MAX22445C, J506 pads 1-7, J1 bank 90 pins T26/R26/H29/G29 + irq→none.
- AP bus: U509 MAX22445C (3F+1R), U513 MAX22445F (irq, asserted while FPGA down),
  C513–C516; J506 row-A pads 29/31/33/35/37; J1 bank 91 (B11/B10/A11/C7/C8).
- J855 MCSPI2 IOSet proposal (pins 80/39/45/41 + irq 61): VERIFY pending vs Variscite pin list.
- Pre-existing bug on ctrl sheet: VAP_IO net merged into GND_AP (xcheck FAIL(1) on HEAD too) — separate todo.
