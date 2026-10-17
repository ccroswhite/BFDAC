# Schematic build-out - reconciliation ledger (2026-09-26)

Source of truth: `hw/ref_netlist.md` (from `bfdac_cosim112.cir`). This file
lists every place where `bom.md` / `schematic.html` / the deck disagree and
needs a ruling before the KiCad sheet is drawn. Closed items move to the
bottom with the ruling.

## OPEN

(none)

## CLOSED 2026-09-27 - confirmation gates (progress.md R111-R114)

- **G2 (MIDCODE 32.5 + DCOFF 0.5):** gate 121 HD2 -139.1 / HD3 -127.5 dBc,
  identical class to gate 112. Closed as expected.
- **G1 (real base drive):** NOT unchanged. With LVC1G74 Rout 25 R -> rs
  1.35 k / rp 301 -> VCM the old 109 LUT/kernel gave HD2 -90 (gates 119/122).
  Root cause (`utils/drive_inl.py`): the FF output resistance x network
  current (25 R x 1.18 / 0.81 mA) shifts the Q/Qb pin levels that the
  passive replica-ff sums through Rr1, so the feedforward gain no longer
  matches the cell currents -> a 3x larger static bow (34 vs 11 ppm). The
  Thevenin resistance itself adds only ~6 ppm; RC-compensating the divider
  (Cs/Cp) made things far worse (gate 123, rejected). Re-identifying the
  chain on the real-drive plant (R114: 125lut + 125c3jw3) gives D1 HD2
  -128.3 / HD3 -135.1 (both stretches met), D3 2f1-f2 -134.1, L1 added
  -142.8 dB0 -> all gates met. Ruling: **the network stands as drawn** (rs
  1.35 k / rp 301, no caps); the bow is static and calibrated out in situ.
  Consequences: (a) the replica-ff gain (Rsh) is nominally sized for the
  loaded pin swing ~3.25 V, not 3.3 V - LUT cal absorbs the rest; (b) keep
  the Q/Qb pins loaded ONLY by Rr1 + the base network (any extra load
  changes the replica scale); (c) LVC1G74 Rout stays in every deck.

## CLOSED 2026-09-26 - "proposals accepted" (user), applied to bom.md / KiCad

1. Base drive: rs **1.35 k** / rp **301 R** to a buffered **VCM 1.345 V**
   rail -> 1.10 / 1.70 V from the 3.3 V LVC1G74 swing (k 0.1823, swing
   0.602 V, Thevenin 246 R, 24 mA/channel constant sink, ~3.4 mW/cell).
   Rb/Rp PECL rows deleted; 10 R stoppers kept. Drawn in cell.kicad_sch.
2. EP52-era rails (1.00 V, 2.49 V, THR_D, THR_CLK) struck from bom 9.
3. vp8 / vfr2 not drawn; vcc15 = raw +15 -> filter -> +15F.
4. R_off drawn at MIDCODE 32.5: 133 / 116 R.
5. Replica-ff loading: Q/Qb each see 10 k (Rr1) + 1.35 k+301 network ->
   ~2.2 mA peak per output, inside the LVC1G74 24 mA drive; noted in bom 1.2.
6. casb2 realised replica-derived (diode-connected Si1555DL at 75 mA from
   the 3.0 V ref, buffered); 4.37 V stays the sim value. bom 9 row added.
- Also: bom 2 Cb 1000 uF -> **220 uF** (deck C_q4); steering pair named
  DMMT5551 (one dual per cell) in the capture.

## (record) original OPEN list

1. **Steering-pair base drive levels.** Deck: behavioural FF outputs
   `vlo = 1.1 V / vhi = 1.7 V` through 10 R stoppers (`R{k}a/b`), i.e. a
   0.6 V swing centred on 1.4 V. `bom.md` 1.2 / 2 (R30 ratified): LVC1G74
   3.3 V CMOS -> R43x 1.41 k series + R44x network -> swing 1.36-1.85 V
   (centre 1.6 V, 0.49 V), and the 2 rows `Rb1/Rp1 = 100/165 R to a 1.0 V
   rail` still describe the superseded EP52/PECL network. Every ID record,
   LUT and kernel since R28 was taken with 1.1/1.7; the hardware network
   must reproduce those levels (or the ID campaign is re-run on the new
   levels). Proposal: size the LVC1G74 resistive divider for 1.1/1.7 into
   the base (R43x/R44x recomputed from the 3.3 V swing and the
   base-current load), delete the Rb/Rp PECL rows, keep the 10 R stoppers.
2. **bom.md 9 EP52-era rails**: 1.00 V steering-bias rail, 2.49 V offset
   rail, THR_D 2.15 V and THR_CLK 2.31 V threshold rails belong to the
   superseded EP52 differential-input FF design (bom 1.2, R29). With the
   ratified single-ended LVC1G74 they have no consumer. Proposal: strike;
   keep only the dedicated 3.3 V FF LDO (TPS7A4700).
3. **Dead rails in the deck**: `vcc15` (+15 raw), `vp8` (9 V), `vfr2`
   (3.0 V) are declared but unused in `cosim112`. The +15 raw rail is
   needed in hardware (op-amp supplies, LDO input); `vp8` and `vfr2` are
   leftovers - do not draw.
4. **R_off exact values**: deck gates ran with MIDCODE 32 (132.8/116.0);
   shipping value MIDCODE 32.5. `patch_p5.py MIDCODE=32.5` gives the
   numbers to put on the sheet (E192/0.1 %: 133 / 116 R). Optional
   confirmation gate before release.
5. **Replica-ff realisation**: deck `Bq/Bqb` are the LVC1G74 Q/Qb outputs
   driving 10 k sum resistors directly (one per cell per rail, 128 per
   channel). The FF output loading (10 k + the base network) must be
   checked against the LVC1G74 drive at 3.3 V; bom 1.2 currently budgets
   only the base network.
6. **casb2 fixed 4.37 V**: the deck uses ideal `Vcb2p/Vcb2m`; bom 9 lists
   it as a reference to be realised. It is a "3.0 V + Vgs @ 75 mA" number
   tied to the Si1555 lot - consider a replica-derived source (diode-
   connected Si1555 at 75 mA from a 3.0 V ref) instead of a fixed voltage.

## CLOSED (ruling applied to bom.md / schematic.html)

- bom 3 rewritten to the locked plant (Si1555 double cascode, Rg 100 R,
  passive replica-ff, MOSFET pads, C_bus 47 n, C_col 12 n).
- bom 4 rewritten to the P5 TIA (OPA1612 + BUF634A, R_f 270 || 1.3 n,
  R_off 133/116 from +15F, V_VG 4.0, no filter, no V-stage).
- bom 5 (reconstruction filter), 6 (line V-stage), 10 (CM servo) marked
  SUPERSEDED, content kept for record.
- bom 9 reference ladder row replaced by the deck's seven references with
  the N7 noise specs.
- schematic.html: 2026-09-26 status banner; figures 4b/4c/5b and the Fig. 4
  +24 V feed / CM trim declared superseded; netlist declared authoritative.
