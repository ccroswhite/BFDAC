# Samtec SEAF-40 Pin Assignments

## Part and numbering

- Board-side part: `SEAF-40-05.0-L-06-2-A-K-TR`.
- Interposer: `SEAR-40-30.0-06-85`, BOM-only; it has no PCB footprint or chassis geometry.
- Each board-side SEAF has 40 contacts per row and six rows, for 240 SMT contacts.
- Footprint pads are numbered row-major: A1-A40 = 1-40, B1-B40 = 41-80, through F1-F40 = 201-240.
- The local KiCad symbol has six units, one 40-pin unit per physical row. Symbol pin numbers match the footprint pad numbers.
- All three main-board connectors are bottom-side sites: Conn1/J506 west near the FPGA, Conn2/J603 north-center, and Conn3/J604 south-center.
- Run `python utils/check_seaf_pinmap.py` to verify symbol/footprint counts and generated connector nets.

## Conn1 / J506

AP signal and return assignments retain the existing row-A pin order:

| Pad | Net | Pad | Net |
|---:|---|---:|---|
| 1 | `AP_SPI_SCLK` | 2 | `GND_AP` |
| 3 | `AP_SPI_CS_N` | 4 | `GND_AP` |
| 5 | `AP_SPI_MOSI` | 6 | `GND_AP` |
| 7 | `AP_SPI_MISO` | 8 | `GND_AP` |
| 9 | `AP_I2S_BCLK` | 10 | `GND_AP` |
| 11 | `AP_I2S_LRCLK` | 12 | `GND_AP` |
| 13 | `AP_I2S_DATA` | 14 | `GND_AP` |
| 15 | `AP_IRQ_N` | 16 | `GND_AP` |
| 17 | `AP_RST_N` | 18 | `GND_AP` |
| 19 | `AP_SDA` | 20 | `GND_AP` |
| 21 | `AP_SCL` | 22 | `GND_AP` |
| 23 | `SOM_PG` | 24 | `GND_AP` |
| 25 | `VAP_IO` | 26 | `GND_AP` |
| 27 | `AP_I2S_DATA2` | 28-40 | `GND_AP` |

The additional power assignments use the six-row matrix, where each row has 40 columns:

- `V12SOM`: C2-C11, D2-D11, E2-E11 (pads 82-91, 122-131, 162-171), 30 contacts total.
- `GND` return/surround for `V12SOM`: B1-B12, F1-F12, C1/C12, D1/D12, E1/E12 (30 contacts).
- `V33_IF_IN`: C30/C31 and D30/D31 (pads 110-111 and 150-151), a separate carrier-side 3.3 V input for the local 1.8 V interface LDO.
- Carrier-side `GND` guard for `V33_IF_IN`: B29-B32, E29-E32, C29/C32, D29/D32 (12 contacts).
- `VAP_IO`: A25 plus B34/B36/B38/B40 (pads 25, 74, 76, 78, 80), with `GND_AP` return contacts interleaved on row B.
- `GND_AP` is used for the AP-side return/shield field across the signal side of rows B-F. `GND_AP` is not connected to carrier `GND`.
- Every Conn1 contact is assigned to a signal, supply, `GND`, or `GND_AP`; no Conn1 pads are intentionally floating.

`VAP_IO/GND_AP` remains the AP-side supply and return for the AP and AP-side isolator supplies. `V33_IF_IN/GND` is a distinct carrier-side domain and must not be tied to `VAP_IO/GND_AP`. The `V33_IF_IN` source on the mating/pre-regulator assembly, local 1.8 V LDO part, and LDO output net are not yet represented in the schematic.

`SOM_PG` is present at Conn1 pad 23, but the current implementation still needs an isolation-path review before this signal can be considered release-ready.

## Conn2 / J603 and Conn3 / J604

Power domains are partitioned left/right by channel: Conn2 (north)
carries the left channel's rails, Conn3 (south) the right channel's.
`P16A`, `N16A` and `V8P3` remain shared nets on both connectors (one
regulator output feeding two destinations is allowed; paralleled LDO
outputs are not). `V4P3` is split into five independent pre-regulator
outputs — three TPS7A4501 branches on the left 6 VAC transformer
(LA/LB/LC) and two on the right (RA/RB) — so each
connector carries distinct nets with no cross-connection:

| Pad | Conn2 net | Conn3 net | Pad | Net |
|---:|---|---|---:|---|
| 1 | `P16A` | `P16A` | 2 | `GND` |
| 3 | `N16A` | `N16A` | 4 | `GND` |
| 5 | `V8P3` | `V8P3` | 6 | `GND` |
| 7 | `V4P3_LA` | `V4P3_RA` | 8 | `GND` |

Branch current banks (4 power + 4 return contacts each, ≤ 1 A per
branch derated from the TPS7A4501's 1.5 A rating):

- `V4P3_LA`/`V4P3_RA`: pads 7, 9, 10, 11 with `GND` on 8, 12, 13, 14.
- `V4P3_LB`/`V4P3_RB`: pads 15, 16, 17, 18 with `GND` on 19, 20, 21, 22.
- `V4P3_LC` (Conn2 only — the V33FF_L feed; the FF bank is split per
  channel, user ruling 2026-10-12): pads 23, 24, 25, 26 with `GND` on
  27–30. Conn3 pads 23–30 remain unassigned.

Shared rails get a second contact each for margin: `P16A` B1 (pad 41),
`N16A` B3 (pad 43), `V8P3` B5 (pad 45), each with adjacent `GND` on
row B.

The remaining contacts on Conn2 and Conn3 are represented by the
240-pin symbol and are not assigned to nets yet. Their final
return/current distribution must be coordinated with the
pre-regulator-board pin map.

## Qualification limits

- The 30-contact `V12SOM` bank, five-contact `VAP_IO` group and four-contact `V33_IF_IN` bank are schematic allocations, not current-capacity sign-off. Verify Samtec contact-current derating, temperature rise, and parallel-current sharing for the final stackup.
- Identify the source of `V33_IF_IN` on the mating assembly and qualify the local LDO/output before release.
- No carrier or pre-regulator PCB placement/routing is implied by this pin map.
- The AP-side `SOM_PG` isolation issue and the local 1.8 V LDO implementation remain open.
