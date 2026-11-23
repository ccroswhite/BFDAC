# Firmware Contract — FPGA ↔ XMOS ↔ AP

Status: DRAFT — sections appear as rulings land. Source of truth for the
register layer: `Xilinx/spi_regs.svh`, `Xilinx/dac_ctrl_plane.sv`, `SPI_BUS.md`.
Progress log: `progress.md`.

## 1. Stream gate — forcing remote renegotiation (ruled 2026-11-21)

### 1.1 The problem

Each source keeps stream state the FPGA cannot observe:

- XMOS: UAC2 negotiated state — the USB host may hold, start, or renegotiate a
  stream while XMOS I²S is deselected. Host `SET_INTERFACE` requests arrive at
  any time; the host owns stream lifetime (no device→host abort verb exists in
  UAC2 — isochronous endpoints have no handshake).
- AP: network renderer sessions — clients (Roon/UPnP/etc.) auto-reconnect
  regardless of `i2s_data2` selection.

The FPGA therefore cannot infer "what the remote side is doing" from
`STREAM_STATUS`, and cannot rely on a deselected source being idle.

### 1.2 Settled rule — unconditional reset on both transitions

**Every selection transition forces a stream reset on both affected sources —
no conditional checks, no state assessment:**

- **Switch-AWAY (gate close):** source tears down its remote session and
  refuses new ones.
- **Switch-TO (gate open):** source forces the remote endpoint to renegotiate
  unconditionally — even if a session appears to have survived, even if the
  rate would be unchanged. Renegotiation is the only path in.

Rationale: remote stream state is opaque; conditional logic inherits its
uncertainty. Unconditional reset converges state by construction — the same
philosophy the RTL already uses internally (a rate apply unconditionally
consumes `stream_source_valid*`, re-arm mandatory).

Gate state = `src_sel` (STREAM_STATUS 0x20[17], readable by both ports):
a source's gate is OPEN iff it is the selected source AND `!stream_fault`.
FPGA reset: `i2s_src_sel` = 0 (XMOS) — see boot-sequence rules (TBD §4).

### 1.3 What causes / forces the XMOS state change

| Layer | Event | Mechanism | Status |
|---|---|---|---|
| **Trigger (FPGA)** | AP writes `I2S_SRC` 0x1C[0] `src_sel` | register write, AP-owned | exists |
| | XMOS arm (0x1B) divergent-apply preempts AP | rate-apply consumes svalid2 | exists |
| | fault / `!clocks_ready` | clears both valid flags | exists |
| **Doorbell** | `fpga_irq_n` → XMOS X0D43 | **IMPLEMENTED**: `STREAM_EVENT` (read 0x22 / W1C 0x21) — `preempt_xmos`/`preempt_ap`/`echo_mismatch`, IRQ terms on `fpga_irq_n`/`spi_ap_irq_n`. Poll fallback retained regardless | done |
| | fallback: XMOS polls STREAM_STATUS on its own cadence | covers missed IRQ (boot window, ISR latency) | fw |
| **Read (XMOS)** | SPI read 0x20 → `src_sel[17]`, `fault[4]`, `clocks_ready[1]` | gate = `(src_sel==0) && !fault` | exists |
| **XMOS→host** | `CS_CLOCK_VALID_CONTROL` AC-interrupt notification | §1.4 | lib_xua delta |
| | `SET_INTERFACE` stall on streaming alt while gated | guaranteed refusal of NEW streams | lib_xua delta |
| | feedback-EP NAK | escalation if host ignores clock-invalid | fw policy, bench-verify |
| | USB detach (drop PHY pull-up / XUD soft-reset — NOT `XUD_SetDevAddr(0)`, which is only an address clear) | last resort only, after grace window; device drops from OS audio list briefly | fw policy |
| **Wire (XMOS)** | I²S TX engine stops / drives zeros while gated | data is discarded by FPGA anyway; cosmetic + protects XMOS internal state | fw |
| **Declare** | XMOS writes `rate_req_src1` on EVERY host negotiation — selected or not | deselected writes are a pure store (verified: no apply, no relock) | exists |
| **Re-entry** | host renegotiates → declare → arm 0x1B → two-leg apply | unmute only after fresh negotiation + arm + clocks_ready | exists |

AP mirror (same rule, software instead of USB protocol):
- AP sees `spi_ap_irq_n` + reads STREAM_STATUS (or knows — it wrote 0x1C).
- Gate close → renderer refuses/closes sessions (network clients get refused
  reconnects — no wire protocol needed).
- Gate open → session teardown forced unconditionally; client must reconnect →
  fresh ALSA format → fresh 0x1C declare → arm → apply.

### 1.4 lib_xua modifications required

lib_xua already *architects* this mechanism — the AC interrupt EP + Clock
Entity validity path is its designed way to inform the host of status change
(docs: "the Clock Gen thread can also cause the Decouple thread to request an
interrupt packet on change of clock validity"). Currently instantiated only
under `XUA_SPDIF_RX_EN || XUA_ADAT_RX_EN`. Required deltas:

1. **Interrupt EP unconditional** — strip the `XUA_SPDIF_RX_EN || XUA_ADAT_RX_EN`
   guards on `ep_int`, `c_clk_int`, `g_intData[8]` template, `g_intFlag`
   (`ep_buffer.xc`). Keep the 6-byte message format: `bInfo=0x00`,
   `bAttribute=CUR`, `wValue=(CS_CLOCK_VALID_CONTROL<<8)|CN`,
   `wIndex=(entity_ID<<8)|ac_intf`.
2. **`CLOCK_VALID` tracks our gate** — model the FPGA clock domain as the
   streaming Clock Source whose validity = gate state. Currently
   `ID_CLKSRC_INT` is hardcoded valid=1 (`xua_ep0_uacreqs.xc`); its `GET_CUR`
   must answer the gate variable instead (gate variable delivered to
   `clockGen` via channel/atomic from the SPI ISR/poll task).
   Clock Source descriptor `bmControls` byte: `0x05` if `SAM_FREQ` R/O,
   `0x07` if `SAM_FREQ` host-programmable — either way `CLOCK_VALID` in
   D3..D2 stays `01` (present, read-only); host must never SET it.
3. **Gate transitions drive `setClockValidity()`** (`clockgen.xc`) — reuse its
   existing `outInterrupt(c_interruptControl, clockId)` notification path
   verbatim; `decouple` patches the ID into `g_intData[5]` and queues it on
   `ep_int` unchanged.
   On gate-OPEN emit the full 0→1 cycle unconditionally (coalesces to a single
   1-notification if already 0) — per the forced-renegotiation rule.
4. **`SET_INTERFACE` stall while gated** — small conditional in the EP0
   alternate-setting handler (`xua_ep0.xc`): stall the streaming alt-set while
   gate closed. This is the only genuinely non-library behavior; everything
   else uses their path.
5. **I²S TX + pipeline stop while gated** — via the weak user-function layer
   (`UserAudioStreamState`, `UserBufferManagement`) — sanctioned override
   points, no fork. Feed zeros / halt the TX engine; keep dequeuing USB so
   the host-side buffer drains cleanly during the teardown window.
   NOTE: `AudioHwShutdown()` is gated on `XUA_LOW_POWER_NON_STREAMING` —
   either define it or do the stop through the always-on user functions;
   do not rely on the shutdown hook existing.
6. **Declare-on-every-negotiation** — XMOS writes `rate_req_src1` (0x03/0x1A)
   on every `SET_INTERFACE`/clock-set event regardless of selection. Hardware
   verified free: deselected writes are a pure store.

`VendorClockValidity(int valid)` hook (`CLOCK_VALIDITY_CALL`) is the
sanctioned attach point for items driven by validity transitions.

### 1.5 Open verification items

- **Host reaction to `CLOCK_VALID`→0 mid-stream** — usbaudio2.sys /
  AppleUSBAudio / snd-usb-audio teardown behavior. Spec defines the
  notification, not the reaction. USB analyzer + all three OSes.
- **lib_xua version pin** — confirm exact tag (machinery verified on v5.5.0
  sources); check whether interrupt-EP guards changed in the shipped tree.
- **Feedback-EP NAK behavior** — driver tolerance of dead feedback pipe
  (ALSA known tolerant; needed only as escalation).
- Whether a dedicated AP-owned *gate-override* bit is still wanted on top of
  `src_sel` (deferred — `src_sel` suffices under the unconditional rule since
  the AP owns all select writes anyway).

## 2. Rulings applied from the §1 contract (2026-11-21)

All three follow directly from "remote state is opaque → force renegotiation,
never trust stored state":

- **R1 `STREAM_EVENT` doorbell — RULED IN + IMPLEMENTED.** Write `0x21` W1C
  `[2:0]` / read `0x22`: `[0] preempt_xmos`, `[1] preempt_ap`,
  `[2] echo_mismatch`, `[5:3] rate_req_src1` shadow. Set by the FPGA on any
  event that closes a source's gate or consumes its session (deselect,
  rate-apply, fault/busy auto-clear). XMOS W1C masked to `{0,2}` (own
  domain); AP clears all. `fpga_irq_n` = sticky_err | [0] | [2];
  `spi_ap_irq_n` = sticky_err | [1]. Sources still *read* gate state (§1.3)
  — the flag is a doorbell, never trusted state.
- **R2 `rate_req_src1` readback — RULED IN + IMPLEMENTED** as
  `STREAM_EVENT[5:3]` (moved from `STREAM_STATUS[24:22]` — the SPI data
  field is 24 bits and `STREAM_STATUS` has only `[23:22]` free).
  Informational shadow only — NEVER authorization: under §1.2 every select
  forces renegotiation → fresh declare anyway.
- **R3 arm-echo — RULED IN + IMPLEMENTED for XMOS.** `STREAM_VALID` (0x1B)
  `[4:2]` = expected-rate echo — MANDATORY on every arm write (`3'b000` is a
  legal rate, no "unset" sentinel exists). FPGA cross-checks vs
  `rate_req_src1`; mismatch refuses the arm (svalid stays 0, no relock) and
  sets `echo_mismatch`. AP needs no echo: declare+arm is atomic in `0x1C`.
  Format check now allows `[4:2]` (`[23:5]` must be 0).
- **R4 bug found + fixed during implementation:** `SPI_W_I2S_SRC` (0x1C) and
  `SPI_W_VOICING_FILTER_ID` (0x20) were missing from the valid-address
  decode — every legit write flagged `sticky[5]` BAD_ADDR while still
  executing (`wr_exec` doesn't gate on `wr_addr_invalid`). Both added.

## 3. Boot / holdoff

- `i2s_src_sel` resets to 0 (XMOS gate open) — but `clocks_ready`=0 and both
  svalid flags reset cleared, so no source can stream until the FPGA rate
  tree is up and a source declares+arms. Gate reads
  `(src_sel==own) && !fault` return CLOSED for everyone while the FPGA is
  unready — no boot-default exception needed.
- **HOST_IRQ_N holdoff (ruled):** XMOS must not assert `HOST_IRQ_N`
  (J855.63) until `SYS_NRSTIN_3V3` rise + 1 ms. The AM62P samples the pin
  domain early; a doorbell during the strap/boot window is undefined.
- AP should write its intended `I2S_SRC` selection early in boot before
  enabling its renderer — establishes the gate state the contract assumes.

## 4. DFU_EN semantics (ruled 2026-11-18, HW closed 11-21)

- USB DFU via the AP is the **only** field path (U857 mux, `USB_MUX_SEL` =
  J855.68, AP-owned).
- `XMOS_DFU_EN` (J855.69) gates DFU entry: `R864` 4.7 kΩ pull-down =
  **disarmed by default** (wins over AM62P internal ~20 kΩ PU → ~0.6 V <
  VIL). AP drives high to arm DFU before mux/dettach sequencing.
- XMOS fw: DFU-EN gating + U857 mux/detach sequencing — fw work pending
  (todo 21).

## 5. HOST_SPI / ATTACH flag

- `HOST_SPI` is the private AP↔XMOS link + `HOST_IRQ_N` doorbell — surface
  undefined (todo 22). Minimum required content implied by §1/§4:
  - **ATTACH flag**: XMOS-visible indication that the AP's USB is attached
    to it through U857 (AP-side mux attach sense) — AP writes on mux
    transitions so XMOS knows when its DFU/diagnostic USB is actually
    connected to the host AP vs. floating.
  - Heartbeat / watchdog command surface (todo 23).
  - NOT used for stream-gate signaling — gate truth is FPGA-owned
    (STREAM_STATUS); HOST_SPI must not become a second selection authority.

## 6. I²S source / rate contract

Settled — see `SPI_BUS.md` §3 (0x1C) and the dual-source testbench suite:
two-leg apply (live-divergent | fresh-declare), same-rate no-relock, apply
consumes arm → re-arm mandatory, deselected declares are pure stores. The
§1 gate contract sits on top: select transitions additionally force remote
renegotiation regardless of rate equality — a *source* change is a stream
reset even when a *same-source same-rate* rewrite would be idempotent.
