# PCIe Card-Edge Pin Assignments

## Part and numbering

- Board-side part: **Amphenol Communications Solutions PCIe Gen 6 vertical SMT card-edge
  socket, family `10165968`** (backward compatible + footprint-interchangeable with
  Gen 1-5). 1.00 mm pitch, 1.57 mm card slot, 30 uin gold contacts, ~11.25 mm above
  board, metal solder-retention hold-downs. Family datasheet:
  `datasheets/Amphenol_PCIe_Gen6_10165968.pdf`.
  - Conn1 (x16, 164 pos): **`10165968-113Y000LF`** (Newark 25AM4158; ~$10 ea)
  - Conn2/Conn3 (x4, 64 pos): **`10165968-111T300LF`**
  - Current rating per family datasheet: 1.1 A min per pin for the 8 CEM power pins
    and 8 nearest ground pins; all contacts are the same copper-alloy cantilever.
    The V12SOM 20-contact bank carries ~15 A -> 0.75 A/contact nominal.
- Land patterns (project lib `bfdac.pretty`): `PCIe_x16_Amphenol_10165968` is the
  SnapEDA/Amphenol-derived land (imported `AMPHENOL_10165968-113Y000LF.kicad_mod`);
  `PCIe_x4_Amphenol_10165968` is derived from it with the same PCI-SIG CEM pad
  geometry (0.53 x 2.0 mm SMT pads, A/B rows at +/-3.6 mm, 3.0 mm key gap between
  positions 11/12, SH1/SH2 retention pads at the ends). The x4 far-end hold-down
  position should be confirmed against the -111T300LF drawing before release.
- Interposer: **user-made riser PCB** with card-edge gold fingers at both ends (no purchased
  interposer — replaces the SEAR-40, which was not purchasable, 2026-11-16 ruling).
  Riser spec: 1.57 mm board, hard-gold (>=30 uin) edge fingers on BOTH faces at both
  ends, 1.0 mm finger pitch, beveled insertion edge, key notch between positions
  11 and 12; use >=2 oz copper under the V12SOM/GND fingers and flood the return
  fingers. Finger land = PCI-SIG CEM add-in card edge.
- Numbering follows the PCIe convention: `B1..Bn` = solder side, `A1..An` = component side.
  Socket pads `A1..An`/`B1..Bn` map 1:1 to the riser fingers at the same position.
- Schematic symbols: `PCIe_x16` (4 units: A1-42, A43-82, B1-42, B43-82),
  `PCIe_x4` (2 units: A1-32, B1-32).
- All three main-board connectors are bottom-side sites: Conn1/J506 west near the FPGA
  (**PCIe x16**), Conn2/J603 north-center (**PCIe x4**), Conn3/J604 south-center (**PCIe x4**).
  Different sizes prevent mis-mating.
- Run `python utils/check_pcie_pinmap.py` to verify symbol/footprint counts and generated
  connector nets.

## Conn1 / J506 <-> J7705 (PCIe x16, 164 contacts)

Domain split by connector side: **side A = carrier power**, **side B = AP domain**.

### Side A — carrier power (A1..A82)

| Positions | Net | Notes |
|---|---|---|
| A1-A20 | `V12SOM` | SoM +12 V feed; 20 contacts ≈ 22 A at ~1.1 A/finger vs ~15 A planning figure |
| A21-A56 | `GND` | V12SOM return + shield, GND between/around power positions |
| A57-A60 | `V33_IF_IN` | carrier-side 1.8 V LDO input — NOT VAP_IO/GND_AP |
| A61-A82 | `GND` | V33_IF_IN guard + spare returns |

### Side B — AP domain (B1..B82)

Signals keep the old SEAF row-A order with the odd-signal/even-`GND_AP` interleave:

| Pos | Net | Pos | Net | Pos | Net | Pos | Net |
|---:|---|---:|---|---:|---|---:|---|
| B1 | `XMOS_SPI_SCLK` | B2 | `GND_AP` | B3 | `XMOS_SPI_CS_N` | B4 | `GND_AP` |
| B5 | `XMOS_SPI_MOSI` | B6 | `GND_AP` | B7 | `XMOS_SPI_MISO` | B8 | `GND_AP` |
| B9 | `AP_I2S_BCLK` | B10 | `GND_AP` | B11 | `AP_I2S_LRCLK` | B12 | `GND_AP` |
| B13 | `AP_I2S_DATA` | B14 | `GND_AP` | B15 | `AP_IRQ_N` | B16 | `GND_AP` |
| B17 | `AP_RST_N` | B18 | `GND_AP` | B19 | `AP_SDA` | B20 | `GND_AP` |
| B21 | `AP_SCL` | B22 | `GND_AP` | B23 | `SOM_PG` | B24 | `GND_AP` |
| B25 | `VAP_IO` | B26 | `GND_AP` | B27 | `GND_AP` | B28 | `GND_AP` |
| B29 | `AP_SPI_SCLK` | B30 | `GND_AP` | B31 | `AP_SPI_CS_N` | B32 | `GND_AP` |
| B33 | `AP_SPI_MOSI` | B34 | `GND_AP` | B35 | `AP_SPI_MISO` | B36 | `GND_AP` |
| B37 | `AP_SPI_IRQ_N` | B38 | `GND_AP` | B39-B44 | `GND_AP` | | |
| B45-B48 | `VAP_IO` | B49-B82 | `GND_AP` | | | | |

- B27 is spare (`GND_AP`) — was `AP_I2S_DATA2`, removed with the second-source path 2026-11-15.
- `VAP_IO` gets 5 contacts total (B25 + B45-B48); everything else on side B is `GND_AP`.
- Ground-domain rule: **no `GND_AP` on side A, no carrier `GND`/power on side B.** The two
  grounds meet only through the isolators, never through the riser.

## Conn2 / J603 <-> J7703 and Conn3 / J604 <-> J7704 (PCIe x4, 64 contacts)

Shared rails on side B; independent per-branch rails on side A (TPS7A4501 outputs are
never tied together — each branch carries its own 6 contacts + 4-pin GND return).

### Side B — shared rails (same on both connectors)

| Positions | Net | Positions | Net |
|---|---|---|---|
| B1-B6 | `P16A` (+16.2 V) | B7-B10 | `GND` |
| B11-B16 | `N16A` (−16.2 V) | B17-B20 | `GND` |
| B21-B26 | `V8P3` (+8.3 V) | B27-B32 | `GND` |

### Side A — branch rails

| Positions | J603 (north, L-side) | J604 (south, R-side) |
|---|---|---|
| A1-A6 | `V4P3_LA` | `V4P3_RA` |
| A7-A10 | `GND` | `GND` |
| A11-A16 | `V4P3_LB` | `V4P3_RB` |
| A17-A20 | `GND` | `GND` |
| A21-A26 | `V4P3_LC` | `GND` (no third branch) |
| A27-A32 | `GND` | `GND` |

## Riser PCBs (user-made)

- Each link gets one riser card: x16 for Conn1, x4 for Conn2/Conn3.
- Riser fingers: 1.0 mm pitch PCIe-standard edge pattern; finger N on the riser maps straight
  to socket pin N on both boards (straight-through mirror — sides stay aligned: A↔A, B↔B).
- V12SOM copper on the x16 riser should pour across all 20 fingers + returns; keep the
  side-A/side-B pour separation so the AP domain stays isolated.
- Board separation is set by the riser card height (was 40 mm target with the SEAR).
