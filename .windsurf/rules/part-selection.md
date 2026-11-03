# Component selection requires user validation

**Ruling (user, 2026-10-24):** Devin may *propose* component selections (MPN,
package, footprint), but no MPN is locked or written into the generator/BOM as
"final" until the user has cross-checked it against **supply chain and
datasheet** and confirmed it. This applies to every passives class (R, C,
diode, connector), not just ICs.

Workflow:

1. Present the candidate manufacturer + full orderable MPN, tolerance grade,
   tempco, package/footprint, and the *reason* for the choice (what it was
   picked over and why).
2. Wait for user confirmation before adding the part to `bom.md`, the
   `PARTS` table in `utils/gen_kicad.py`, or generated schematic MPN fields.
3. If a position is already implemented and later changes, update the
   generator + bom.md + checkers together and regenerate.

Current audit status (as of 2026-10-24):

- **Ruling confirmed:** LDO SET / PGFB divider positions use the best-grade
  class — Susumu RG1608N-W 0.05 % / 10 ppm 0603 (47 R–475k), Vishay TNPW0603
  0.1 % below 47 R, Susumu RG1608P 0.1 % above 475k — same policy as the
  reference/bias dividers. Implemented: IV sheet (R685–R687) and CLKR sheet
  (R840–R842) were moved off TNPW 1 % to match the refs sheet.
- **Ruling extended (user 2026-10-24):** "esoteric product — spare no
  expense, within limits" + "tolerance and temperature coefficient should
  trend to the higher resolution (within reason)". Policy: any resistor
  that SETS or MEASURES a voltage (LDO SET/PGFB/ADJ, supervisor SENSE,
  telemetry MON dividers, reference/bias dividers) gets the best available
  grade = Susumu RG1608N-W 0.05 % / 10 ppm (47 R–475k), Susumu RG1608P /
  Vishay TNPW 0.1 % outside that range. Housekeeping-only positions (LED
  series, button/address pulls, bleeder, pull-ups/downs) may stay TNPW 1 %
  — no measurement or set function.
- Implemented: IV R685-687, CLKR R840-842, POWER R1702-1713 (SENSE pairs),
  PREREG ADJ dividers, CTRL U510/U511 MON divider pairs — all RG1608N.
- **AGREED IN PRINCIPLE (user 2026-10-25):** the full Susumu RG1608N-W value
  list (~164 positions, 24 E96 values project-wide, generated MPNs
  `RG1608N-{E96}-W-T1`) is accepted as the design target.
- **Pending final gate — JLCPCB cross-correlation (user deferred):** the
  build assembler is JLCPCB (pick-and-place). Before procurement lock, every
  precision value must be cross-correlated with JLCPCB stock; alternates
  if needed: Vishay Dale TNPU0603 (0.05 %/5-15 ppm) or PATT0603
  (0.05 %/25 ppm), KOA RN73H1JTD (0.05 %/10 ppm) / RN73R1JTD (5 ppm),
  Panasonic ERA-3, Yageo RT0603 / Bourns CRT-0603 / Stackpole RNCF0603 as
  fallbacks — all must hold 0603, ±0.05 %, ≤10–15 ppm thin film, ≥75 V.
  Any substitution goes into `precision_r()` in gen_kicad.py — never into
  generated files directly.

- **ACENTRY / mains chain (2026-10-26) — PROPOSED except the relays, the
  CM choke, and the power-entry module:** every part on
  `hw/kicad/acentry.kicad_sch` and the new PWR_PARTS entries (`iec, fuse20,
  min14, mov275, movpe, cx2, cy2, rss, recon, cecon, auxcap, s1j, d4148, lm393, t555,
  tlv431, ao34, q7, npn3904, xfmr6, xfmr9, xfmr18, csnub, rsnub, c1ut`)
  is a candidate pending user supply/datasheet cross-check per this rule.
  Mains-domain parts are safety-critical — be extra conservative.
  Transformers are user-supplied Chinese R-cores with non-searchable MPNs;
  footprint/pinout TBD at part receipt. See bom.md item 17p for the full
  table and OPEN items.
- **Relays LOCKED (2026-10-27, user: "go with the Omron devices"):**
  `k5le` = Omron G5LE-14-DC5 (K900 bypass), `k2rl` = Omron G2RL-24-DC5
  (K901 select). Pin maps verified against manufacturer figures —
  G5LE: coil 2/5, COM 1, NO 3, NC 4; G2RL-2 IEC: A1/A2 coil,
  11/12/14 + 21/22/24 = COM/NC/NO. Stock Relay:G5LE-1 / Relay:G2RL-2
  symbols + Relay_THT footprints. Do not reopen unless a sourcing
  problem appears (alternates on record: RT424005 / RT114005).
  **TOPOLOGY HOLD (2026-10-28):** the relay PARTS stay locked, but K901's
  primary-select function is provisional — the purchased R-cores are
  believed to have single primaries, so the 115/230 V architecture is
  parked (bom.md 17p open item (l)) until the transformer winding spec
  is confirmed at receipt. Do not treat the K901 wiring as committed.
- **CM choke LOCKED (2026-10-27, user: "lock in that choke"):**
  `cmc` = Schaffner RN222-2-02-6M8 (L900): 2 A / 6.8 mH, 300 VAC,
  fully potted toroid, THT vertical. Winding pin pairing verified vs the
  RN-series mech figure — A = pins 1-2 (line), B = pins 3-4 (neutral);
  an earlier drawn pairing (1-4 / 2-3) was a dead L-N short and is fixed.
  Footprint bfdac:Common_Mode_Choke_Schaffner_RN222 (15 x 12.5 mm grid,
  18 x 31 mm body). Second source on record: RN212-2-02-1M8 (2 A/1.8 mH,
  same construction, 10 x 15 mm grid — different footprint).
- **Power-entry module LOCKED (2026-10-27, user confirmed DigiKey
  availability):** `iec` = Schurter DD12.4121.111 (DigiKey 486-1294-ND) —
  C14 inlet + 4 A standard filter (2×1.5 mH CM choke, 100 nF Cx, 2×2.2 nF
  Cy, 1M bleed) + 2-pole fuseholder + 2-pole rocker switch, screw-on A
  portrait, 6.3 mm QC tabs. Internal order inlet→fuse→switch→filter is
  fuse-first (protects everything). Replaces the separate inlet +
  chassis rocker + board fuse/clips: `swm` entry and bfdac:SW_2P symbol
  deleted, F900 deleted from the board (2× Schurter 0001.2509 T2A now live
  in the module's 4301.1401 2-pole drawer — user-accessible). RC320 rear
  cover for tab insulation. Variant rulings: 4 A for 5× CM inductance at
  3× margin; 2-pole fuse for both legs (Schuko markets); standard filter
  over medical M5 (Cy wanted for CM attenuation; ~0.5 mA total leakage
  at 230 V is under the 3.5 mA limit). Chassis part — no PCB footprint;
  schematic J900 pins are the module's load-side output tabs.
- **Mains wire entry RULED (2026-10-27, user: Phoenix COMBICON):**
  `min14` = J910, Phoenix **MSTBV 2,5/3-GF-5,08** vertical header
  (order 1777086, 12 A/320 V III/2, threaded flange, through-board
  mount holes so plug load lands on screws not solder joints) at the
  AC-zone board edge. Wire-side mate = **MSTB 2,5/3-STF-5,08** plug
  (order 1777992, screw-clamp tension-sleeve, 0.2–2.5 mm² = 24–12 AWG
  incl. 14 AWG, 0.3 Nm flange torque). PEM end uses insulated
  FASTON-250 receptacles on the DD12 QC tabs.
- **Surge clamps RULED (2026-10-27, user picked premium stack A):**
  RV901 L–N = Littelfuse **TMOV14RP275E** (2-lead thermally-protected
  MOV, 275 VAC/430 V/6 kA; thermal disconnect = graceful end-of-life;
  drops into bfdac:Varistor_Disc_D14.0mm_P7.5mm). RV902/903 L–PE/N–PE
  = Bourns **ISOM5-275-B-L2** IsoMOV MOV+GDT hybrids (275 VAC MCOV,
  10 kA, <10 µA, ~30 pF, UL1449+TÜV; GDT blocks MOV leakage/aging on
  the earth legs, fuse-clearing end-of-life; new fp
  bfdac:Varistor_IsoM5_D14_P10.0mm — note **10 mm** lead pitch, not
  7.5). Closes bom 17p open item (g). Replaces 3× S14K275 baseline.

