# Connector X/Y Datum Register — bfdac_analog carrier + Tub-1 prereg

Status: 2026-11-24. One row per connector: the mechanical datum (the point
on the part that anchors its X/Y placement), what governs that position,
and the source document. Layout places each footprint's datum at the
governed coordinate; everything else follows from the land pattern.

Datum convention: unless noted, datum = the manufacturer's drawing origin
(KiCad footprint origin already matches — verify at placement, not assumed).

## Rear panel (governed: panel cutouts + chassis)

| Ref | Part | Datum | Governing | Source / status |
|---|---|---|---|---|
| J601 | Neutrik NC3MD-H-B XLR (L out) | D-size panel-hole centre; PCB fingers land on board edge | rear panel XLR row (with J602), fixed spacing per panel art | Neutrik S1-NC3MD-H (in `datasheets/`); footprint `bfdac:Neutrik_NC3MD-H` built from it — VERIFIED |
| J602 | Neutrik NC3MD-H-B XLR (R out) | same as J601 | same | same |
| J852 | GCT USB4085 USB-C receptacle | shell tongue centreline on board edge (mid-mount) | rear panel USB cutout (UAC2 service face) | GCT USB4085 drawing — **land + edge offset TO VERIFY** |
| J856 | ARJM11C7-502 RJ45 MagJack | jack face centreline on board edge | rear panel Ethernet cutout | Abracon ARJM11 dwg — **land + edge offset TO VERIFY** |
| J900 | DD12-PEM IEC inlet (PEM module) | panel-mount flange screw pattern; board lands FASTONs | rear panel IEC cutout | Schurter DD12 dwg — board is solder-landing only, panel owns the XY |

## Board-internal (governed: interboard mates + keep-outs)

| Ref | Part | Datum | Governing | Source / status |
|---|---|---|---|---|
| J1–J4 | Samtec ADM6-60-01.5-L-4-2-A (SoM) | pin A01 (+x, top-right); alignment NPTHs at ±C/2 = ±20.135 mm on centreline | ACKU15S SoM connector map — positions MUST come from the Alinx board drawing | Samtec print ECN-358211 footprint DONE (`bfdac.pretty`); **X/Y BLOCKED — item #10, Alinx STEP/DXF not yet obtained** |
| J506 | Amphenol 10165968 PCIe x16 | pin 1 pad; 1.00 mm pitch card-edge | mates Tub-1 J7705 (AP DIG + PWR); the two boards' connector pitch must share one datum plane | `docs/PCIE_PIN_ASSIGNMENTS.md`; board spacing = tub mechanicals |
| J603 | Amphenol 10165968 PCIe x4 | pin 1 pad | mates Tub-1 J7703 (PREREG L branch) | same |
| J604 | Amphenol 10165968 PCIe x4 | pin 1 pad | mates Tub-1 J7704 (PREREG R branch) | same; keep J603/J604 on the same datum line and pitch as J7703/J7704 |
| J855 | TE 1612618-4 SODIMM-200 9.2H | socket datum per TE dwg (centreline / pin-1 pad) | VAR-SOM-AM62P module: 4 plated mounting holes must register to carrier standoffs (module hole span 62.52 mm); MAC8 TH-1.6-3.0-M2-B standoffs; module lies flat, die face UP | Variscite ds §12 + TE 1612618-4 dwg — **standoff XY pattern + socket edge offset TO VERIFY** |
| J802 | Xilinx 14-pin 2 mm JTAG hdr | pin 1 | internal, service access top side | cosmetic |
| J505 | TSW 1×4 2.54 mm (PMBUS) | pin 1 | internal | cosmetic |
| J851 | FTSH-110-01-F-DV-K-TR xSYS2 (proposed) | pin 1 pad | internal, XTAG4 access | **MPN + land still PROPOSED** |
| J857 | TSW 1×3 2.54 mm (console) | pin 1 | internal | cosmetic |
| J858 | TSW 1×4 2.54 mm (USB0 service) | pin 1 | internal, DNP-able | cosmetic |

## Power / harness (Phoenix MSTB-GF horizontal, threaded flange)

All Phoenix land datums VERIFIED vs datasheet drilling diagram
(progress 2026-11-24, todo #16): pin 1×1 → drill Ø1.4 mm, pitch 5.08,
NPTH Ø2.4 at ±5.08 outboard of end pins (+2.5 mm plug-side offset);
envelope a = 15.24 mm (4-pos) / 20.32 (5-pos). Flange screws in BEFORE
wave solder (ST 2.2×6.5, 0.3 Nm). Datum = **pin 1 centre**; plug exits
parallel to board — keep all harness landings near their board edges.

| Ref | Pos | MPN | Lands | Notes |
|---|---|---|---|---|
| J854 | 4 | 1776524 | RS-50-3.3 DC → VAP_IO (2+2 paralleled) | AP island feed |
| J910 | 3 | 1776511 | PEM FASTON harness → board | mains entry |
| J921/J925/J927 | 4 | 1776524 | transformer secondaries L/R | edge exit |
| J922/J920/J924/J926 | 5 | 1776537 | primary harness P1A/P1B/P2A/P2B/SCN | edge exit |
| J930/J933 | 3 | 1776511 | SMPS mains feed | |
| J931/J932 | 3 | 1776511 | V12SOM DC harness (3× 12 A pins paralleled) | |

(J923/J928 = XF-CONN 4-pos 1776524 — same family, same datum rules.)

## Tub-1 PREREG board (`on_board=no`, separate PCB)

| Ref | Part | Datum | Governing |
|---|---|---|---|
| J7703/J7704 | Amphenol 10165968 PCIe x4 | pin 1 | mate to carrier J603/J604 — mirrored pin-out, same datum plane |
| J7705 | Amphenol 10165968 PCIe x16 | pin 1 | mate to carrier J506 |

## Open items

1. **J1–J4 SoM connectors** — the single layout blocker (item #10). Need
   the Alinx ACKU15S dimensional drawing (requested from Alinx; they do
   not publish a STEP). Interim: `som_seed.kicad_pcb` placeholder.
2. **J855 SoM socket standoffs** — MAC8 standoff XY must match the
   Variscite 4-hole pattern exactly; take hole XY from the Variscite
   STEP (available on variscite.com CAD page) before layout.
3. **J852 / J856 panel-edge offsets** — verify KiCad land origin vs
   shell face before fixing rear-panel cutout Y.
4. **J851** — MPN/land still proposed; confirm before fab.
