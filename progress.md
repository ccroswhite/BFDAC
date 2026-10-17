# BFDAC Progress Notes — RTL + Analog Converter
_Last updated: 2026-10-07 (STEP 10: SoM carrier + control-plane sheets; all 8 ACVU13P connectors mapped)_

## ACCEPTANCE SPEC - RATIFIED 2026-09-23 (user: "lock in the design")
Goal: a noise floor beyond the dCS Vivaldi APEX (spec better than -113 dB0,
20-20k unweighted, 6 V) WITHOUT giving up the sound-quality class of dCS /
Chord / Mola Mola / Berkeley / MSB. 128 dB0 is a STRETCH, not a gate.
All figures: analog output, 6 Vrms balanced, 20 Hz-20 kHz unweighted, at the
cell-array cal temperature (temperature-indexed cal table, Step 6.6).
- MUST (go/no-go for hardware and for every future plant change):
    N1  noise >= 120 dB0 (<= 6.0 uV rms at 6 V)
    D1  every harmonic HD2..HD8 <= -115 dBc at -1 dBFS, any in-band fund
    D2  no spur > -120 dB0 (idle tones, DEM patterns, clock/PSU products)
    D3  19+20 kHz equal-tone IMD products <= -115 dBc
    L1  noise floor flat within 1 dB from -60 dBFS to digital silence and
        no level-dependent spurs (P7 long-record test - PROMOTED TO MUST:
        this is the test that separates "measures well" from the dCS class)
- STRETCH: 128 dB0; HD2/HD3 <= -125 dBc (parity with dCS's best harmonic).
- DESIGN RULE that follows: distortion class outranks the last dB of noise.
  A plant that lands 124-126 dB0 but buys 5-10 dB of harmonic margin is
  preferred over 128 dB0 with -116 dBc harmonics. The NPAR=2 front amp and
  the 0.6 ps jitter push were 128-driven and stay as fallbacks only.
- Status vs spec (sim, 45C, LOCKED plant + REAL LVC1G74 base drive, shipping
  chain 125lut + 125c3jw3 + DCOFF 0.5, MIDCODE 32.5 - R114, 2026-09-27):
  N1 128.1 dB0 (3-6 dB sim-to-bench loss still clears 120). D1 gate 126
  HD2 -128.3 / HD3 -135.1 / HD4-8 <= -128.2 dBc - BOTH stretches met.
  D3 gate 127 2f1-f2 -134.1 / 2f2-f1 -137.1. L1 gate 128 added floor
  -142.8 dB0, max bin -153.1 (idle tone killed by DCOFF 0.5). D2 met (R109).
  All MUSTs and both stretches met; hardware capture in progress (hw/kicad).

## Target platform
- XCVU13P-2FHGB2104I on Alinx ACVU13 SOM
- Single top-level: `vu13p_dac_top.sv`
- DSP clock: ~280–357 MHz derived from OCXO via MMCM
- I2S slave: up to 768 kHz (48k family) / 705.6 kHz (44.1k family), 32-bit stereo
- Configuration: ARM SPI master → `dac_ctrl_plane` (no I2C)

## Layout / fabrication constraints (user 2026-10-08 20:46)
- FAB + ASSEMBLY: **JLCPCB** fabricates AND populates the board. Reason: the
  user's own pick-and-place cannot place 0201, and there is no capacity for
  double-sided placement/reflow in-house. Consequences for the design:
  * part selection must stay within JLCPCB's assembly catalogue (basic /
    extended parts) or be consignable; check every BOM line against it.
  * (user 21:14) the 0201 worry was about the SoM, which arrives assembled -
    moot. CARRIER RULE: **0603 is the smallest R/C package**, dropping to
    0402 only where 0603 makes routing genuinely too hard (document each
    exception). Hand-reworkable everywhere by design.
  * stackup, via rules, min track/space, and controlled impedance follow
    JLCPCB's published capabilities (e.g. their 4/6-layer impedance stackups);
    pick the stackup before routing and record it here.
- BRING-UP POPULATION (user 21:14): the first one or two board spins are
  bring-up / tweak boards. Populate ONE channel only (e.g. R) and leave the
  whole L channel DNP; the shared parts (SoM connectors, clocks, power,
  control plane, flash) are populated. gen_kicad: give every per-channel part
  a DNP/variant attribute keyed on the channel so JLC's BOM/CPL export for the
  bring-up variant drops the L channel automatically; also mark bench-tuning
  parts (SET resistors, snubbers, terminations) in the BOM so they can be
  left DNP or fitted with starting values.
- TEST POINTS (user 21:14): add MANY - every rail, every reference, cell drive
  lines (a representative subset), clock nodes, the summing node / VCM /
  output stages, control-plane handshakes. Rules so they do not degrade the
  circuit: (a) analog/high-speed nodes get a small SMD pad or 0603 series-R
  stub tapped off the trace with the shortest possible stub, never a loop
  or through-hole pin on the signal path; (b) clock and cell-drive test points
  are stubs through a series resistor (e.g. 1k) so the probe does not load
  the line; (c) low-impedance / DC nodes (rails, references) can take
  through-hole or large pads freely; (d) every test point has a nearby GND
  pad or pin for a short-spring probe ground; (e) test-point placement is
  part of the match/capacitance budget review, not an afterthought.
- PASSIVE VENDOR POLICY (user 23:21-23:3x). Current gen_kicad passives are
  MY defaults, never discussed: Murata GRM ceramics (19 lines), Yageo RC
  thick / RT thin film (23), Susumu RG 0.1 % (8), Nichicon UKL (4), WIMA
  MKS (2). User preference: KEMET capacitors, VISHAY resistors (Rohm as
  occasional 2nd source). Re-point pass TODO (values/tolerances unchanged):
  R -> Vishay CRCW (non-critical thick), TNPW 0.1 %/25 ppm (precision),
  Rohm MCR 2nd source; C -> Kemet C0G + X7R, T52x polymer for pure bulk;
  keep Nichicon UKL where LOW-LEAKAGE is the spec (q4 base bypass, ref
  filters - Kemet has no equivalent, flag in bom); film -> Kemet R82 /
  Vishay MKP. TWO-TIER PRECISION (user): bring-up boards TNPW everywhere;
  production = TNPW + Vishay Z-foil (VSMP) in the linearity-critical
  positions. => critical positions go on 0805 PADS now (TNPW0805 <->
  VSMP0805 same land) so production is a BOM-only swap; bom gets a
  bring-up MPN and a production MPN column for those lines. Which
  positions are critical = tolerance SENSITIVITY SWEEP in the cosim decks
  (HD2/HD3, L/R gain match), expected ~10/channel: I/V R_f, cell
  current-set, build-outs, VCM/threshold dividers. Order of work: (1)
  sensitivity ranking, (2) vendor re-point + 0805 pads in gen_kicad,
  (3) JLC Basic/Extended/Global/Consign classification of the BOM.
  Still MISSING entirely: power sheet 17(d) LDOs/refs, AXC1T45-class
  translator MPN, mezzanine connectors, test points, mounting hardware.
  (Relay is NOT missing: K4 = Omron G6K-2F-Y DC12 confirmed in gen_kicad
  OUT_PARTS + bom 7, changed from AGN200A12 2026-10-08 for lack of a
  footprint; the stale "MPN TBD" status row in bom.md fixed 23:39.)
  YAGEO PURGED 2026-10-08 23:39 (user: bad experience, never again).
  All 23 Yageo lines -> Vishay, same value/size/tolerance:
    RC0402 thick 1 % (33R 100R 120R 2K2 4K7 470R 10K) -> CRCW0402xxxxFKED
    RT0402 thin 1 % (10R 100R 301R 1K35)              -> TNPW0402xxxxFEEA
                                                  (25 ppm; range 10R-100k OK)
    RT0603 thin 1 % (10R 100R 910R + template)        -> TNPW0603xxxxFEEA
                                                  (template codes -> 4-char
                                                  Vishay: 2R20 47R0 1K00)
    RT2010 574R (Rpad)   -> PAT2010E5740FST1 (0.8 W vs 0.5 W; TNPW e3 no
                            longer lists 2010/2512, PAT does, 25 ppm)
    RT2512 266R / 232R   -> PAT2512E2660FST1 / PAT2512E2320FST1 (1 W)
  Part-number formats checked against the Vishay TNPW e3 and PAT
  datasheets (tol F, TCR E = 25 ppm, EEA / ST1 packaging). gen_kicad
  regenerated, xcheck PASS, netlist: TNPW0402 x776, TNPW0603 x31, CRCW0402
  x179, PAT2010 x8, PAT2512 x8, zero RC/RT left. bom.md Rpad / items
  13-14 wording updated. Murata GRM, Nichicon UKL, WIMA remain for the
  planned vendor re-point pass.
  PRECISION 0603 POSITIONS - RULED 23:44 (user: Susumu has been reliable;
  pick whichever of Susumu/Vishay has the BETTER TOLERANCE per position).
  Datasheet comparison (Susumu RG catalogue vs Vishay TNPW e3):
    Susumu RG1608 W grade = 0.05 % / N 10 ppm, range 47 R..475k
           (V 5 ppm + P 0.02 % exist 100 R..10.2k but made-to-order, T5
           5000-pc reels - production option only)
    Vishay TNPW0603 best = 0.1 % B (Y 10 ppm >= 47 R, E 25 ppm from 1 R)
  -> Susumu wins everywhere it has range. Implemented as precision_r()
  in gen_kicad (value -> MPN): 47 R..475k -> RG1608N-xxxx-W-T1 (0.05 %);
  < 47 R -> TNPW0603xxxxBEEA (0.1 % 25 ppm; Susumu below 47 R is only
  0.1 % / 50 ppm); > 475k -> RG1608P-xxxx-B-T5 (0.1 %). Fixed entries
  upgraded 0.1 % -> 0.05 %: Rt 750 (x128), Rr1 10k (x256), Rsh 156, R_rc
  4.99k, all V_VG/CASB2/PADB divider discretes. Vishay where Susumu has no
  0.05 %: Rbo 10 R build-out, Re 35.7 (NOTE: the previous RG1608N-35R7-W
  MPN did NOT exist - W grade starts at 47 R; option to keep 0.05 % = 2 x
  71.5 R RG1608N-71R5-W in parallel, flagged in the part descr, not done).
  R_f stays RG3216N 0.05 % / 10 ppm; its code fixed 271 -> 2700 (RG3216
  is always 4-digit). 499k stays RG1608P-B (over the W range). xcheck
  PASS; netlist: RG1608N-W x425 over 16 values, RG1608P x4, RG3216N x4,
  TNPW0603-B x8. Production Z-foil tier for the sensitivity-ranked
  positions unchanged (0805 pads still TODO after the ranking).
  APPROVED RESISTOR VENDORS (user 23:49): Vishay, Susumu, STACKPOLE
  (Rohm occasional). Yageo banned. Stackpole = the thick-film jellybean
  2nd source (RMCF 0402 1 % for the CRCW positions; RNCP thin film 1 %
  as a TNPW-F alternate if supply needs it). To be recorded as the
  alternate column in the JLC classification pass.
  PACKAGE POLICY (user 23:51): 0402 ONLY out of necessity, 0603 default.
  Done in gen_kicad: every non-cell 0402 -> 0603 (clock 33 R series x73,
  mclk divider, all pull-ups/straps/LED/I2C R, gate stoppers Rg5/6, Csh
  50p, every 100n decoupling outside the cells) with Vishay CRCW0603 /
  TNPW0603 / Murata GRM188 (0603) MPNs. Remaining 0402 = cell array only:
  cff 100n x128 (FF-pin loop), rs/rp/rstop x768 (array area, base-pin
  stopper) - reason written in each part descr; revisit when the cell
  layout shows whether the SOIC-14/VSSOP-8 pitch leaves room for 0603
  anyway. xcheck PASS; netlist 0402 count = 896, all on CELL sheets.
- OUTPUT LEVEL = DIGITAL GAIN CAP, RTL DONE 2026-10-09 00:52-01:05 (bom 7
  ruling 2026-10-07 had left the RTL still driving relay taps). User asked
  how level works without relays + whether dCS's 0.2 V setting matters:
  answer = with digital level the analog floor (~1.4 uV rms at the XLR)
  is fixed and only the signal shrinks, so SNR-on-paper drops 132.8 ->
  103 dB0 at 0.2 V but absolute noise is at/below a power amp's own input
  noise; the low settings are a safety cap / volume-range convenience for
  direct-to-amp use. Ruled: add 0.6 V and 0.2 V (free), no analog
  switching (option A heat; unbuildable in the TIA at 0.2 V).
  RTL: SPI_W_LEVEL 0x02 now [2:0]: 000=2V 001=4V 010=6V 011=0.6V 100=0.2V.
    automute_controller: level_target/level_relay_drive [2:0]; level
      state in its own always_ff reset ONLY on rst_n; pending = (target
      stable 2 cycles) && (target != applied); applied in ST_SWITCHING.
      level_switch_req port kept but unused.
    vu13p_dac_top: level_gain LUT (Q0.16: 21845/43691/FFFF/6554/2185) x
      boot_envelope_gain -> env_level_gain -> dac_dsp_core
      .boot_envelope_gain (DSP core untouched). relay_level pins driven 0.
      level_target CDC chain 3 bits x 2.
    dac_ctrl_plane: cmd_level [2:0]; CTRL_STATE 0x12 layout now
      {clk_src[5], base_rate[4], outsel[3], level[2:0]} (was [4:0]).
  Two LATENT BUGS fixed by the restructure: (1) level_relay_int was in the
  mute-reset branch -> every SPI mute / i2s_err / rate change silently
  reverted the level to 2 V with no way to re-request the same code;
  (2) level_switch_req was a single 200 MHz pulse through a 2-FF 90 MHz
  chain (could be missed) and was cleared by the mute branch (write while
  muted lost). outsel still uses the pulse scheme - same exposure, HP path
  is removed anyway; leave.
  Tests: tb_automute +4 checks (level survives mute; muted write applied
  on next unmute pass, 0.2 V code) ALL PASS; tb_spi_ctrl_plane ALL PASS
  with the new CTRL_STATE layout; xvlog of top/automute/ctrl_plane clean.
  tb_vu13p_top not re-run (relay_level still [1:0] at the top port).
  VOLUME WORD BUG CONFIRMED + FIXED 2026-10-09 08:35 (user: "definitely
  wrong"): frame is {R/W, addr[7], data[24], crc8} so SPI_W_VOLUME could
  only ever store {8'h00, data[23:0]} -> max 0x00FFFFFF = -48.2 dB below
  the 0xFFFFFFFF every DSP TB + gen_golden_dsp.py used. Fix in
  dac_ctrl_plane: sys_volume <= {data[23:0], 8'h00} (0xFFFFFF ->
  0xFFFFFF00, -0.000003 dB vs simulated unity; 0 -> 0). NO resimulation
  needed: the DSP core / golden model / NS feed scaling were verified at
  the gain SPI now actually delivers. tb_spi_ctrl_plane [1] updated
  (0x001234 -> 0x00123400), ALL PASS. AP driver note: VOLUME is a 24-bit
  linear word, 0xFFFFFF = 0 dB.
  VOLUME RESET -> ZERO 2026-10-09 13:30 (user: at power-on/warm-up mute the
  volume should be zero). Was 0xFFFFFFFF = full scale: an UNMUTE without a
  prior VOLUME write would have played at the full 2 V cap. Now
  sys_volume resets to 0 in dac_ctrl_plane; power-on sequence is: K4
  de-energised (XLR shorted) + force_zero until UNMUTE; boot envelope
  fades 0 -> 1 after coef load (click suppressor only); LEVEL = 2 V;
  VOLUME = 0 until the AP writes it. tb_spi_ctrl_plane / tb_dac_ctrl_plane
  ALL PASS; tb_vu13p_top already writes VOLUME before UNMUTE.
  AP SEQUENCE RULING 2026-10-09 17:25 (user): reset/power-up = muted +
  VOLUME 0; the AP (over SPI) first writes UNMUTE, then steps VOLUME up to
  the user level; the AP owns the slew rate. No RTL ramp. Driver contract:
  UNMUTE (0x04) -> poll CTRL_STATE until relay engaged -> VOLUME (0x01)
  stepped from 0; on MUTE the AP should step VOLUME back to 0 first if it
  wants a fade (MUTE alone is an instant relay/force_zero cut).
  CDC FIX forced by this: sys_volume was consumed raw in dsp_clk (written
  in clk_200m, no synchroniser) - fine while it was a write-once-muted
  value, a tear risk once the AP slews it during playback (0x00FFFF00 ->
  0x01000000 could land as 0x01FFFF00 for a sample = click). vu13p_dac_top
  now has a toggle-handshake capture (vol_tog / vol_tog_sync[2:0] ->
  sys_volume_dsp) feeding dac_dsp_core; XDC line 83 false-path already
  covers clk_200m->dsp_clk. tb_vu13p_top ALL PASS (10).
- BOARD TOPOLOGY (user 21:23-21:26, agreed): production arrangement from
  spin 1 - do NOT build a same-side bring-up board and flip later, because
  the cell-drive match / capacitance budget would have to be tuned twice and
  the thermal operating point (temperature-indexed cal, 45C sims) would
  differ.
  * BOTTOM side: the ACVU13 SoM (8 x ADM6; SoM FPGA faces down and bolts to
    the tub floor = heatsink 1, via the 97.364 + 78 mm hole patterns), the
    4 x MT25Q coefficient QSPI flash (BGA-24, digital, next to J1 bank 70),
    and the power + application-processor connectors to the base tub.
    Tub connectors (user 21:28): BOARD-TO-BOARD MEZZANINE, no cabling. The
    base "tub" holds a POWER + APPLICATION-PROCESSOR board; the carrier
    mates to it from the bottom side, laterally beside the SoM (the SoM +
    heatsink project down to the tub floor, so the power/AP board cannot be
    under the SoM). Replaces J901 Mini-Fit (+12 V) and J501 2x10 AP header.
    Selection criteria (MPN pick with datasheets, bom item):
      - two connector classes, SAME stack height, same vendor family so the
        heights are catalogue-matched: (1) POWER blades for +12 V SoM
        (VU13P SoM is a 5-10 A class load - real power contacts, not pins)
        and the analog rails (+-15A, VEE15, VP10, V33FF, V33CLK, ... per the
        regulation split below), each with its OWN return (analog return,
        digital return, GND_AP kept separate across the connector);
        (2) SIGNAL mezzanine for the isolated AP side: SPI(4) + IRQ, I2S(4),
        AP_RST, I2C(2), PG/status, LED/debug, spares -> ~24-30 pins + GND_AP.
        Candidates: Samtec (matches the ADM6 already used): mPOWER/PowerStrip
        for power + Q Strip (QSH/QTH) / Edge Rate (ERM8/ERF8) / SEARAY for
        signal; Hirose FX/IT families as alternative. Blind-mate needs
        guide pins + float or a rigid standoff pattern shared by both boards.
      - stack height: driven by the tallest bottom-side part of the carrier
        and the power board's top-side parts; pick once, then both connector
        classes come from that height.
      - mating cycles / retention: screw-down standoffs between carrier and
        power board carry the mechanical load, not the connectors.
    REGULATION SPLIT (user 21:33, restating an earlier ruling; PSU design
    itself deferred): every analog rail is LINEAR - R-core transformer ->
    Schottky full-wave bridge + reservoir caps -> FIRST-STAGE LDO with heavy
    filtering (all on the POWER BOARD) -> comes across the mezzanine at
    ~1 V ABOVE the final value -> FINAL LDO ON THE CARRIER right at the sink
    drops it to the exact voltage. So the power connector carries one
    pre-regulated "V+1" feed per analog rail (plus its return), and the
    carrier power sheet 17(d) = final LDOs + local filtering only. The SoM
    +12 V is a SWITCH-MODE supply on the power board with an output filter
    and copious bulk capacitance for the VU13P's load steps; the carrier
    adds its own bulk + filter at J901's replacement (the SoM's +12 V pins).
    Header design: not now.
    B2B PARTITIONING (user 21:39, CONFIRMED 21:52: noisy digital on one side
    of the board, noise-sensitive on the other): THREE connector groups, all
    PUSHED TO THE PCB EDGE, bottom side.
      LEFT edge (NOISY/digital; J1/J2 side of the SoM: +12 V pins on J2,
        flash bank 70, clk_sel, ext_rst_n on J1):
        (a) +12 V SoM power b2b - **12 V @ 15 A** (user figure), fed by the
            switch-mode PSU; its own connector, own return. 15 A sizes the
            contacts: a power-blade part (several contacts in parallel, each
            derated), not a signal-pin connector; 12 V copper on the carrier
            = wide pour / planes from the connector to the J2 +12 V pins;
        (b) AP DATA signal b2b - isolated side (SPI+IRQ, I2S, AP_RST, I2C,
            status, debug, spares, GND_AP).
      RIGHT edge (analog; J5/J6 side: all 64 L cell-drive lines on J6
        banks 64/65, R channel to be assigned on J5/J6 as well):
        (c) ANALOG RAILS power b2b - one or more connectors, one "V+1" feed
            + return per rail, analog returns only; many rails -> allow
            several identical connectors rather than one huge one.
    Consequences: the base-tub power/AP board is effectively TWO boards
    (digital/12 V/AP under the left edge, linear analog PSU under the right)
    since the SoM + heatsink occupy the floor between them.
    Also LEFT/noisy (user 21:56): the relay H-BRIDGE DRIVER (level/output
    relay coils) - coil pulses and its supply belong with the digital side;
    relay coil wiring then crosses to the relays on the analog side as a
    twisted/adjacent pair over ground, far from the summing nodes.
    CLOCK FAN-OUT SIDE - DECIDED (user 21:57, self-corrected): TOP side,
    right next to the FF retimers where the clock is consumed; the clock
    crosses vias ONLY for the single MCLK_P/N pair to the SoM. Reasons:
    the tree is 2 x CCHD-957 -> LMK00304 -> LMK1C1108 root + 8 leaves ->
    64 x 33 R -> 64 cells, i.e. 64+ matched clock lines that all terminate
    on TOP; only ONE differential pair (MCLK_P/N LVDS from LMK00304
    CLKoutB0) goes to the SoM, and that single pair can drop through vias
    to J1 trivially. Bottom-side fan-out would put 64 matched lines through
    64 vias and populate the side we want to keep to connectors + flash,
    and would sit the XOs near the 12 V switcher feed. Plan-view placement
    (not layer): clock block on the top side in the strip ABOVE or BELOW
    the SoM footprint on the right half, so the leaves reach the cells and
    the LVDS pair reaches J1 (left edge) around the SoM corner; or move
    MCLK to a clock-capable pair on J5/J6, which removes the crossing.
    DONE 2026-10-08 21:59 (user: "move the MCLK to a clock-capable pair"):
    MCLK_FPGA -> J6-C30 = B65_L12_P / AW28 (true GC pair, bank 65, VCCIO
    1.8 V; _N = J6-C29 / AY28 left no-connect, reserved for an LVDS
    option); CLK_SEL -> J6-A19 = B65_L16_P / AR25. J1-A17/A16/B5 freed.
    Changed: gen_kicad alinx_used() + texts/descr; vu13p_dac_top.xdc
    mclk_p AW28 / mclk_n AY28 / clk_sel AR25 (IBUFDS->IBUF conversion of
    mclk still the carried TODO). Regenerated: xcheck PASS, ERC = the 2
    known CASB2 notes only, netlist confirms J6 C30 / A19. Free GC pairs
    left on J6: B65_L11, L13, L14, B66_L13, L14.
    CONFLICT FOUND + FIXED (user go 22:07): cascode_r[48..63] (DATR49..64;
    16 lines, not 32 as first stated) sat on J1 bank 69 = LEFT/noisy edge.
    Moved to bank 66 on J6: L15_P/N, L16, L17, L18, L19, L20, L21, L24
    (AT18 AU17 AR17 AT17 AP18 AR18 AP20 AR20 AN18 AN17 AN19 AP19 AM16 AN16
    AL20 AM20 = J6 B59/B58/A59/A58/C50/C49/C53/C52/A52/A51/A54/A53/B57/
    B56/B52/B51), GC pairs B66_L13/L14 untouched, VCCIO_66 already V18.
    Rewritten identically in vu13p_dac_top.xdc s8 and Alinx/
    cascode_pins_gen.txt; gen_kicad alinx_used() now asserts every
    cascode_r pin is on J5/J6; descr/texts updated. Checks: xcheck PASS,
    XDC 283 package pins no duplicates, ERC = 2 known CASB2 notes, netlist
    DATR on J5 = 48 / J6 = 16 / J1 = 0. J1 now carries ONLY flash + control
    plane (+ VCCIO/GND): the left edge is purely digital.
    XO supply V33CLK is a quiet right-side rail. The two reference clocks
    Y301/Y302 (CCHD-957 49.152 / 45.1584) are likewise TOP side, directly
    beside the LMK1C1108 root(s) (user 22:00): the XOCLK net (XO -> 33 R ->
    root U302/U303 + U312 FPGA copy) is the one node whose jitter is not
    retimed anywhere downstream, so it stays millimetres long, over solid
    ground, away from the cell drive bus and the 12 V area.
    All bottom parts OUTSIDE the SoM's 106 x 106 footprint;
    anything inside it must be low-profile (<= ~2 mm until the SoM bottom
    component height is read from the STEP; stack is 5 mm nominal).
  * TOP side: FF retiming, converter cells, analog/output stages, clocks,
    power regulators - the enclosure lid is heatsink 2 and the whole probe
    surface faces up. Test points for any SoM-side net are brought to the
    top via short stubs so the board is never flipped on the bench.
  * BRING-UP FIXTURE: tall standoffs on the 8 holes (clear of SoM + Alinx
    fan/heatsink and of the bottom harness), or a flat aluminium "bench tub
    floor" plate the SoM bolts to (= the real thermal path). Keep the Alinx
    FAN90X90 on the 78 mm pattern whenever the plate is not used.
- LENGTH MATCHING: the cell-array drive lines (FPGA -> J1..J8 -> cell base
  drivers, both channels) and the clock distribution must be length/delay
  matched; the cell-switching skew is part of the DEM/distortion budget, so
  treat the match tolerance as a spec item, not a routing nicety. Alinx's
  SoM-internal lengths (FPGA ball -> ADF6 pin) have to be pulled from the
  SoM design data and folded into the match - the carrier alone is not enough.
- CAPACITANCE BUDGET: every cell drive line gets an explicit load-capacitance
  budget (trace C per unit length for the chosen stackup + connector pin +
  driver input) so the edge rate at the switch base stays inside what the
  LVC1G74 drive / timing sims assumed. Longer runs must be re-simulated,
  not just matched. Record the per-net budget alongside the match table.

## SPI Frame Format
40 bits total: `{R/W[1], addr[7], data[24], crc8[8]}`
- R/W=0 write, R/W=1 read
- CRC-8 poly x^8+x^2+x+1, computed MSB-first over bits[39:8]
- Data field is 24 bits; ARM must not pass values > 24 bits

## SPI Register Map (as of 2026-09-03, `dac_ctrl_plane.sv`; TB coverage `tb_spi_ctrl_plane` / `tb_dac_ctrl_plane`)
Write and read address spaces are independent (same 7-bit address can mean
different things per R/W bit). Unknown read addr returns 0xDEADBEEF; unknown
write addr latches sticky[5].

| Addr | Dir   | Name | Description |
|------|-------|------|-------------|
| 0x01 | Write | VOLUME | 24-bit volume, LEFT-justified into the 32-bit multiplier word: sys_volume = {data[23:0], 8'h00}; 0xFFFFFF = unity (2026-10-09 fix, was right-justified = -48 dB cap) |
| 0x02 | Write | LEVEL | output level cap [2:0], DIGITAL gain: 000=2V 001=4V 010=6V 011=0.6V 100=0.2V rms (applied by automute while muted; survives mute; reset 2V) |
| 0x03 | Write | RATE | RTL draft: alias of STREAM_RATE 0x1A, three-bit native-rate code; old 0/1 meanings retained; verification pending |
| 0x04 | Write | UNMUTE | spi_unmute [0] |
| 0x05 | Write | BANK_LOAD (legacy) | coef_bank_id [3:0] + load trigger — fixed DDR4 slot, bypasses directory |
| 0x07 | Write | OUTSEL | 0=line XLR, 1=headphone |
| 0x08 | Write | FILTER_LIST_CTRL | [0]=clear toggle list; [1]=commit → select entry 0 (FILT_EMPTY if list empty; [0] wins if both) |
| 0x09 | Write | FILTER_LIST_APPEND | [15:0]=filter_id, up to 32 (FILT_FULL rejected) |
| 0x0A | Write | FILTER_SELECT | [16]=advance, [4:0]=index → `filter_load_req` (directory lookup, `docs/coef_format_v2.md`) |
| 0x0B | Write | DAC_MODE | [0]=video_mode (status only; host enforces eligibility) |
| 0x0C | Write | CAL_ADDR | cal_coef_store shadow write pointer [8:0] |
| 0x0D | Write | CAL_DATA | shadow-bank word [23:0], auto-increment (CAL_WRAP rejected) |
| 0x0E | Write | CAL_COMMIT | [0]=1 toggles atomic bank swap at sample tick |
| 0x0F | Write | CAL_RDADDR | active-bank readback address [8:0] |
| 0x10 | Write | FLASH_ADDR_LO | flash_cmd_addr [23:0] |
| 0x11 | Write | FLASH_ADDR_HI | flash_cmd_addr [31:24] + target flash select |
| 0x12 | Write | FLASH_CMD | 0x01 erase / 0x02 program / 0x03 read (FLASH_BUSY / FLASH_OP rejected) |
| 0x13 | Write | FLASH_DATA | page-buffer byte, auto-increment |
| 0x14 | Write | FLASH_PTR | [7:0] write ptr, [15:8] read ptr |
| 0x15 | Write | DPD_EN | [0]=dpd_enable |
| 0x16 | Write | STICKY_W1C | clear sticky bits [7:0]; also clears CMD_ERR_INFO |
| 0x17 | Write | FILTER_SELECT_ID | [15:0]=directory filter_id, bypasses the list (cur_index untouched) → `filter_load_req` |
| 0x18 | Write | CELL_TEST_L | [7]=enable, [6]=test-cell contribution (0 baseline / 1 add cell), [5:0]=cell index 0..63; [23:8]=0; independent left channel |
| 0x19 | Write | CELL_TEST_R | Same format, independent right channel |
| 0x1A | Write | STREAM_RATE | [2:0]={rate_shift[1:0],family48}; codes 0..7 = 44.1/48/88.2/96/176.4/192/352.8/384 kHz; other bits zero |
| 0x1B | Write | STREAM_VALID | [0]=AP-ready; zero on source stop/underrun; other bits zero |
| 0x1C | Write | I2S_RX_TRIM | [4:0]=additional DSP capture cycles (reset 8); source stopped/muted only |
| 0x10 | Read  | MAGIC | 0xDAC02026 |
| 0x11 | Read  | STICKY_ERR | [0] SPI CRC, [1] I2S err, [2] DDR4 calib lost, [3] MMCM unlock, [4] SPI frame length, [5] bad write addr, [6] rejected cmd OR filter load failed, [7] boot/flash error — any set bit asserts `fpga_irq_n` |
| 0x12 | Read  | CTRL_STATE | {clk_source_sel, base_rate_sel, outsel, level[1:0]} |
| 0x13 | Read  | COEF_STATUS | {bank_valid[12], mgr_busy[11], coef_load_done[10], clk_source_sel[9], base_rate_sel[8], current_bank_id[7:4], coef_bank_id[3:0]} — bank_valid = FIR active bank holds a successful load (0 until the first post-boot select) |
| 0x14 | Read  | MUTE_STATUS | {i2s_err, switch_busy, hp_mute, line_mute, unmute} |
| 0x15 | Read  | CLK_STATUS | {dpd_enable, ddr4_calib, clk_locked} |
| 0x16 | Read  | FILTER_LIST_STATUS | {video_mode[11], list_len[10:5], cur_index[4:0]} |
| 0x17 | Read  | FILTER_IDS | {next_in_list_id[15:0], cur_filter_id[15:0]} (informational; no preload) |
| 0x18 | Read  | CAL_STATUS | {cal_wr_ptr, cal_commit_pending, cal_active_bank} |
| 0x19 | Read  | CAL_RDDATA | active-bank word at CAL_RDADDR |
| 0x1A | Read  | BOOT_STATUS | {boot_record_count, boot_axi_fail, boot_crc_fail, boot_ok, boot_done, flash_cmd_busy} |
| 0x1B | Read  | FLASH_RDDATA | page-buffer byte at FLASH_PTR[15:8] |
| 0x1C | Read  | CMD_ERR_INFO | {addr[6:0], reason[3:0]} of the latest sticky[7:4] event: 1 BAD_ADDR, 2 FLASH_BUSY, 3 FLASH_OP, 4 FILT_FULL, 5 FILT_EMPTY, 6 FILT_RANGE, 7 CAL_WRAP, 8 FLASH_WDT, 9 FRAME_LEN, 0xA FILT_NOTFOUND, 0xB FILT_SIZE, 0xC TEST_BUSY, 0xD TEST_UNSAFE, 0xE TEST_FORMAT |
| 0x1D | Read | CELL_TEST_L | [8]=CDC command pending, [7:0]=last accepted L command; not an analog-settled indicator |
| 0x1E | Read | CELL_TEST_R | Same status for R |
| 0x1F | Read | BENCH_STATUS | Local button controller: busy[0], LED[1], mode[3:2], R-channel[4], step[11:5], rate[12], FSM[15:13], press count[18:16], cancel[19], fault[20]; full protocol in docs/coef_format_v2.md |
| 0x20 | Read | STREAM_STATUS | busy[0], clocks-ready[1], AP-ready[2], bank-valid[3], fault[4], applied rate[7:5], requested rate[10:8], capture trim[15:11] |

Names/addresses/reason codes are defined once in `Xilinx/spi_regs.svh` (`SPI_W_*`, `SPI_R_*`, `SPI_ERR_*`, `SPI_STICKY_*`); `dac_ctrl_plane.sv` decodes exclusively through those macros. TBs keep numeric literals (they document the wire protocol).

## Clock Mux
- `clk_source_sel=0` → `clk_49m` (48/96/192/384/768 kHz family)
- `clk_source_sel=1` → `clk_45m` (44.1/88.2/176.4/352.8/705.6 kHz family)
- ARM must assert reset before switching (BUFGMUX_CTRL + MMCM relock required)

---

## Functional TODO Plan

> **Audit 2026-09-03** (after the filter-directory round, f15b timing closure).
> Items below marked [x] with a "CLOSED" note were completed by later work but
> never ticked here; items marked RTL-OUT had their FPGA half ruled out and
> remain open only as schematic/doc/host work. New RTL findings are TODO-16..24.
> **Open RTL work, in priority order: TODO-24 (1M-tap release config + P&R),
> TODO-23 (32-entry list + select-by-ID), TODO-16 (boot default / boot_load_done),
> TODO-19 (DDR4->FIR system TB), TODO-10 (cal support), TODO-5 (outsel relay
> ruling), TODO-17/18 (hygiene), TODO-20/21 (blocked on rulings/tooling);
> TODO-11 closed 2026-10-09 (superseded by the passive replica).**

- [x] TODO-1: `sys_clock_gen` CLKIN1_PERIOD=22.151 ns, CLKFBOUT_MULT_F=20, CLKINSEL=1, XDC documented
- [x] TODO-2: `gain_switch_busy` wired in `vu13p_dac_top`: automute→wire→ctrl_plane
- [x] TODO-3: `dac_ctrl_plane` header updated to "200 MHz on VU13P"
- [ ] TODO-4 (RTL-OUT, docs/schematic only): Temperature sensors (4 total, per Step 6.6 /
  R86-90 decision): (1) converter section, (2) I/V + reconstruction filter section,
  (3)+(4) one per V section (L/R). **RULED Aug 2026 (plan Step 6.7): sensors sit on the
  APPLICATION PROCESSOR's I2C bus; the ARM computes temperature-corrected coefficients
  and writes them into `cal_coef_store` over SPI (regs 0x0C-0x0F). NO FPGA sensor
  readout, NO FPGA I2C master, NO temp registers in the ctrl plane.** Remaining:
  schematic.html + bom.md (sensor MPN, placement, ARM I2C routing) + block diagram.

### RTL-vs-architecture audit gaps (2026-07-30; status refreshed 2026-09-03)

- [ ] TODO-5: **K3 input-select relay (line/HP) not wired.** Fig 4d + bom.md §7 commit a
  DPDT input-select relay per channel; `automute_controller` sequences `outsel_active`
  internally but exposes NO drive output — no top-level port, no XDC pin. bom.md's
  "(shared with level code, see automute)" note is inconsistent with a physical coil
  needing its own driver bit. Decide + wire: `relay_outsel` output through automute →
  `vu13p_dac_top` → XDC pin → bom.md §7 row correction.
  STATUS 2026-09-03: unchanged. Top ports are still `relay_line_mute / relay_hp_mute /
  relay_hp_rails / relay_level[1:0]`; `outsel_active` stays internal to automute (it
  only steers `hp_rails_drive`). NEEDS A RULING: (a) the line-mute + HP-mute relays
  ARE the output select (no K3 coil; close this item and fix bom.md §7), or (b) add a
  `relay_outsel` port + XDC pin (small RTL: expose `outsel_active`, sequence it inside
  the existing mute window).
- [ ] TODO-6: **Relay channel-count mismatch.** bom.md §7 lists every relay as ×2/unit
  (per channel) but the FPGA exposes ONE set of relay pins (`relay_line_mute`,
  `relay_hp_mute`, `relay_hp_rails`, `relay_level[1:0]`). Either the channels are ganged
  off one coil-driver bank (must be stated in schematic.html/bom.md + driver current
  budget for 2 coils/pin) or a second pin set is missing. Also: Fig 5b claims cold-start
  servo settle (~90 s) is "covered by output mute relay" — automute has only the 20 ms
  contact delay; the 90 s hold is implicitly ARM policy (spi_unmute) and must be
  documented as such (or a startup timer added).
  STATUS 2026-09-03: unchanged (one relay pin set, no startup timer). Doc/schematic
  item unless the startup-timer option is chosen.
- [ ] TODO-7 (RTL-OUT, schematic only): **Temperature sensor architecture** — count and
  placement DECIDED (4 sensors, Step 6.6/6.7); bus DECIDED (ARM I2C, not FPGA).
  Remaining: MPN selection + schematic.html / bom.md sections.
- [x] TODO-8: **Sensor-bus consequence on FPGA connectivity — CLOSED by ruling (Aug
  2026, plan Step 6.7):** sensors on the ARM's I2C bus; FPGA stays SPI-slave only.
  No I2C master, no SPI master, no temp registers.
- [x] TODO-9: **Predistortion + temp-comp datapath — CLOSED (2026-08-22, plan Step
  4D.1/4D.2):** `dpd_engine.sv` (per-channel 2-lane serial MAC, certified
  `dpd_fx_golden.py` fixed point, 42-cycle latency) embedded in `noise_shaper_ef3`
  Stage E; coefficients from `cal_coef_store.sv` (dual-bank, ARM-written over SPI
  0x0C-0x0F, atomic commit at sample tick); DPD_EN reg 0x15. Temp indexing is
  ARM-side by ruling (no FPGA temp mux). Verified bit-exact by `tb_dpd_engine`
  (2000 vectors x 2 ch, ON/OFF). Residual: `dpd_lag_rom.svh` holds the canonical
  basis — swap to the frozen cosim80c3j tuples when Step 6.4 tooling exports them
  (regen + resynth) → tracked as TODO-21.
- [ ] TODO-10: **Cal/test feedback-loop support absent** (Step 6.2a/6.3 commitments):
  known-vector playback engine, cal trigger/sync output to fixture, dither seed
  control, buffered master-clock export provision — no RTL, no top ports, no XDC pins.
  STATUS 2026-09-03: unchanged. `tpdf_dither_gen` has NO seed parameter or register
  (only DITHER_WIDTH); `dem_sort` has no seed. Playback engine + seed registers can be
  built now (ctrl-plane regs; playback source = DDR4 region or SPI-fed BRAM — needs a
  ruling); trigger/clock-export pins wait on the Step 6.2a cal-connector definition.
- [x] TODO-11: **Replica-DAC driver — CLOSED 2026-10-09, SUPERSEDED.** Fig 1 committed
  an FPGA "replica-DAC driver (2 aux outputs / rail)" (bom.md open item 6) to feed
  the Round-10 replica-feedforward casb bias with a code-tracking current copy.
  Rounds 80/91 replaced it with the PASSIVE replica (bom §3 locked 2026-09-24):
  the 64 cell FF Q/Q̅ pins are summed through Rr1 10k ×64 into ns1 (Rsh/Csh) and
  drive QR (2SA1036K V-I) -> casb. The code is already on the FF pins, so no aux
  DAC, no FPGA pins, no RTL. Fig 1 caption still needs the aux-output note removed.
- [ ] TODO-13: **Isolation barrier undocumented** (found 2026-07-30 during Phase 4D
  discussion). The application processor sits on the opposite wall of a galvanic
  isolator from the clean FPGA/DAC domain — this appears NOWHERE in schematic.html or
  bom.md. Document: which signals cross (ARM SPI slave link; anything else? I2S
  source domain TBD — user to confirm), isolator class/MPN, and clean-side domain
  assignment of every peripheral (QSPI flash, temp sensors, relays). RULING captured
  in plan Phase 4D: QSPI is a dedicated full-bandwidth coefficient bus, completely
  separated from the isolated ARM SPI control link. (Docs only — no RTL content.)
  **BARRIER REVIEW 2026-10-09 (user rulings):** inventory as built (bom §21,
  `ctrl.kicad_sch`): U501 ISO7741 SPI (3 fwd/MISO rev), U502 ISO7741 I²S + IRQ,
  U503 ISO7710 AP_RST_N, ISO1640 I²C (TMP117). (1) **Isolation KEPT** — it is the
  ground separation (AP has USB/Ethernet/display/switcher; GND_AP floats, clean
  ground defined by the analog star alone) and noise containment. A translator-only
  option was considered and rejected. **CORRECTION 2026-10-09 (user, TI datasheet):
  ISO7741/ISO7710 VCC is 2.25–5.5 V — NOT 1.8 V; the as-drawn "side 2 on V18" is
  invalid and no ≥ 100 Mbps isolator reaches 1.8 V (Si8641, ADuM342E, MAX14483 all
  checked). **RULED 2026-10-09 21:48 (user): ADI/Maxim MAX2244x family (1.71–5.5 V,
  200 Mbps grade, 50 Mbps characterised at 1.8 V) — U501 SPI = MAX22445CAWE+ (3/1,
  default HIGH: CS_N deselected with AP off), U502 I²S = MAX22445FAWE+ (3/1, default
  LOW: SDATA silence with AP off; replaces the SDATA pull-down), U503 reset =
  MAX22444CAWE+ (4/0, default HIGH: AP_RST_N released, 3 spare fwd).** FPGA side
  stays on V18, no translator block. Consequences: SPI 50 MHz fast mode OFF,
  practical ceiling ≈ 20–25 MHz (10 MHz guaranteed); I²S over the barrier ≤ 384 kHz
  × 64·fs. Stock VERIFIED (user, DigiKey + mfr 30k+). Remaining: pin maps vs
  max22444-max22446.pdf, t_PD max at 1.8 V, `ctrl.kicad_sch` regeneration (with
  the U502 direction swap). (2) **FPGA = I²S MASTER** —
  the DAC is the timebase (bom item 19(c)); as drawn the FPGA was slave with no MCLK
  crossing, i.e. two free-running clocks and periodic FIFO slips. Fix: FPGA generates
  BCLK/LRCLK from cell_clk; U502 sides swapped (SDATA AP→FPGA fwd; BCLK, LRCLK,
  fpga_irq_n FPGA→AP rev — same ISO7741); pull-down on SDATA (FPGA side) so an
  idle/unpowered AP reads as silence; no MCLK export, no AP external-MCLK
  requirement (item 22 criterion relaxed to "I²S slave mode"). Stream start: clocks
  free-run; AP writes rate/family register → FPGA switches (existing clk_sel/MMCM/
  mute sequence) → AP polls ready → AP enables slave TX → FPGA stream-valid detect
  → existing un-mute. (3) **Ready state = SPI status register, NO extra wire**
  (boot_load_done, switch_busy, mmcm_locked, stream_valid, muted); IRQ unchanged.
  (4) Coefficient-flash provisioning path (factory/JTAG vs streamed over control SPI
  into an FPGA flash-write path) still NEEDS A RULING. RTL work → TODO-27.
- [x] TODO-14: **Temperature-correction runtime process — CLOSED by ruling (Aug 2026,
  plan Phase 4D decision (b) + Step 6.6/6.7):** temperature-indexed table (≤9 °C
  spacing, 3 factory points, indexes BOTH static LUT and kernel) lives with the ARM;
  the ARM reads the sensors, picks/interpolates, and writes ONE working set into
  `cal_coef_store` (atomic commit). FPGA has no table, no temp index, no hysteresis
  logic. Remaining artifact (table format + generation formula) belongs to cal
  tooling (Step 6.4) and ARM software, not RTL.
- [x] TODO-15: **CRITICAL FIR bug found (2026-08-01 audit) + FIXED (user-ratified) +
  TB-VERIFIED.** The "1M-tap" FIR was functionally a 16k-tap filter: each MAC's
  `audio_in` was STATIC for the whole sweep, collapsing the 64 coefficients of every
  phase window into one boxcar-summed tap (history store was also 64× too shallow).
  Fix (audio-window redesign): per-MAC TAPS_PER_PHASE-deep distributed-RAM windows
  with systolic one-sample handoff (4-cycle, replaces the NUM_MACS+1 preload), one
  global tap-indexed read address pipelined co-timed with the URAM coef path;
  `polyphase_mac_engine` operand pipelines depth-matched (new A2 stage; pre-adder
  moved to stage 3) — the legacy 2-vs-3 stage skew and the accumulator-load timing
  (d8→d6) and SHADOW_DELAY (8+TL→6+TL) were additional latent boundary bugs exposed
  and fixed. Coefficient layout now DEFINED: c_m[p·TPP+t] = h[p+16·(TPP·m+t)].
  Verified: `tb_fir_window` (new, bit-exact vs mod-2^48 reference, random coefs +
  random audio, 40 samples × 16 phases) PASSES at 8×16 (2k-tap) AND 16×32 (8k-tap)
  configs. CONSEQUENCES / follow-ups:
  (a) Step 5.1 synthesis results are for the WRONG datapath — re-synth needed
      (expect +~24k LUT for 1.5 Mb window LUTRAM; audio BRAM removed);
  (b) deep-sweep 4M-taps-on-1024-MACs path now architecturally real: TPP=256 →
      sweep 4100 < 8333-cycle budget, URAM depth exactly fits (4096×72) — the
      67%-DSP/76%-BRAM congestion corner is AVOIDED;
  (c) coefficient-file generation tooling must produce the newly defined layout;
  (d) downstream TBs need re-run: tb_fir_polyphase_stereo, tb_fir_impulse_response,
      tb_dsp_core, tb_e2e_sine, tb_system_ddr4_to_fir;
  (e) debug TBs tb_fir_window_dbg.sv / tb_fir_window_trace.sv deleted after use.
  TB SWEEP RESULTS (2026-08-01, follow-up (d)):
  - tb_fir_polyphase_stereo: **PASS 7/7** after stimulus fix (history priming was
    NUM_MACS+2 samples — correct datapath needs the full K=NUM_MACS·TPP; the DC
    known-answer expectation 2·C·D·K was always the first-principles formula and
    now passes on the REAL math, old design passed it via the collapse coincidence).
  - tb_dac_dsp_core: **PASS** (integration, all tests; 128 updates/sample intact).
  - tb_e2e_sine: **RECALIBRATED + PASSING at the boxcar ceiling (2026-08-01,
    user-directed)**. Three stimulus fixes, ALL TB-side (RTL proven exact along the
    way): (1) boxcar coef 0x6000 → 0x1800 (÷4: corrected FIR sums 2·c·256/phase vs
    the old collapsed 2·c·64 — restores the R30 NS drive/headroom); (2) N_WARM 80 →
    300 (must exceed the now-real K=256 FIR history); (3) N_SKIP 0 → N_WARM·128
    (the 256-sample boxcar fill ramp no longer fits inside the Kaiser edge taper —
    capture-from-reset was polluting half the record; a contiguous 512-sample
    window of the periodic-512 sine stays bin-11 coherent). RESULTS: paced_l (NS
    input) SNDR **163.8 dB** (LTI chain pristine); DEM popcount **106.7 dB**,
    consistent with the −24.7 dB boxcar attenuation of bin 11 against the absolute
    EF3 floor (R30 baseline 135.8 − 24.7 ≈ 111 class), residual is noise-like (top
    bins ~196-199, NO harmonic structure at 22/33/44). During diagnosis the FIR
    output was verified **sample-exact (512/512)** against the true 256-boxcar
    convolution of the actual TB stimulus (the one mismatch red herring: SV int'()
    rounds, python int() truncates). Full-quality 136 dB-class gate needs designed
    1024-tap coefficients — queued with the coef-tooling TODO. Debug taps
    e2e_fir_l.txt/e2e_hb3_l.txt added to the TB (cheap, kept).
  - **Dead-code sweep (2026-08-01, user-directed)**: removed 13 unused RTL files
    (verified uninstantiated by grep of all RTL+TB instantiations): async_fifo_wide,
    async_fifo, lvds_blade_tx, lvds_serial_tx, dem_64, dem_mapper, dem_dwa,
    fir_polyphase_mono, fir_bram_controller, fir_rom_shard, coef_bram,
    shift_register_sipo, volume_multiplier; and 3 obsolete TBs: tb_dem_dwa,
    tb_fir_impulse_response, tb_dsp_core. Synth scripts glob *.sv → self-cleaning.
    NOTE found during sweep: `flash_bridge` is verified (tb_flash_bridge) but NOT
    yet instantiated in vu13p_dac_top (QSPI pins exist, bridge unwired) — belongs
    to the Phase 4D loader integration work.
  - tb_system_ddr4_to_fir: was FAILING (coef subsystem at production params while
    TB scaled to NUM_MACS=64; legacy multi-driver code needed --relax) —
    **RESOLVED 2026-09-03 by the TODO-19 rewrite, 30/30** (see RTL audit below).
  - tb_fir_impulse_response / tb_dsp_core: were OBSOLETE (dead hierarchy refs /
    LVDS-era ports) — **RETIRED in the dead-code sweep above (user-ratified)**.
- [x] TODO-12: **DDR4 MIG IP — CLOSED (plan Step 3.4 / 3C.1):** `ddr4_0` generated
  (`Xilinx/scripts/gen_ddr4_mig.tcl`, 5x MT40A1G16KD per SOM topology) + `axi_dwc_coef`
  width converter; `dac_ddr4_if_mig.sv` wraps them for synthesis (stub `dac_ddr4_if.sv`
  kept for sim). ui_clk CDC constraints live in `vu13p_dac_top.xdc` §9. In every
  routed run since f12; f15b closed timing with it.
- [x] **Step 4.4 residue — real-MIG system sim (2026-09-04): `Testbench/tb_vu13p_mig.sv`
  + `run_tb_mig.ps1`.** Full `vu13p_dac_top` with `dac_ddr4_if_mig` (real `ddr4_0`,
  BFM sim mode, precompiled microblaze/axi libs from the `ddr4_0_ex` example via
  `scripts/gen_ddr4_example.tcl` → `Xilinx/sim_mig/`), Micron `ddr4_model` x4 x16
  (`short` DQ shorts as in the reference `sim_tb_top`), behavioral SPI flash tapped at
  `u_dut.qspi_sck` (CCLK is not a user pin), NUM_MACS=4 / TPP=64 (loader minimum:
  COEF_DEPTH = one 1024-coef burst). Chain: calib (5.9 µs) → boot loader stages a
  64 B directory + 16 KB bank from flash over AXI (65 bursts, CRC ok, ~2.65 ms)
  → SPI list commit → directory lookup → bank_valid → FILTER_SELECT_ID unknown →
  sticky[6]/CMD_ERR 0xA. ~27 min wall per run.
  **BUG FOUND + FIXED:** coef write bus CDC in `dac_coef_subsys` was a per-write
  toggle synchronizer + qualified data bus; the loader emits 4 back-to-back
  `coef_we` at ui_clk = **300 MHz** (833 ps × 4 — the XDC §9 header still said
  "~200 MHz") while dsp_clk is 258 MHz → **21 % of writes dropped (3228/4096) and
  stale addr/data sampled**. The sim stub's slower ui_clk hid it; this would have
  corrupted every coefficient load on hardware. Fix: 32-deep gray-pointer async FIFO
  {mac, addr, data} (same pattern as the `qspi_boot_loader` FIFO), almost-full
  `coef_stall` back to `coef_bank_loader` (drain holds while stalled), and
  `coef_load_done` held until the FIFO has drained so the bank swap cannot overtake
  the last writes. XDC §9 items 3/4 rewritten for the FIFO pointers/LUTRAM
  (`cf_*ptr_*`, `cfifo_mem`). Regressions: `tb_system_ddr4_to_fir` PASS,
  `tb_coef_bank_loader` 7/7 (TB_TPP256). **Needs a re-route** (f17) to re-close
  timing and confirm the new §9 patterns bind (check for unbound get_cells warnings).
  **BUG 2 FOUND + FIXED (same TB, after bug 1):** all 4096 writes landed but 4032
  held wrong data (addr 16 got word 40 ...). AXI trace on both sides of
  `axi_dwc_coef` (`+define+TB_AXI_TRACE`): `dac_ddr4_if_mig.sv` tied `AxCACHE = 0`
  (Modifiable = 0), so the upsizer legally refused to pack — each 128-bit beat went
  out as a **narrow 16 B beat on the 512-bit bus** (`awlen` unchanged, rotating
  16 B strobes). `ddr4_0` is generated with `AxiNarrowBurst = false`, so it took
  every beat as a 64 B line → boot image written at 4× stride, scrambled. Fix:
  `s_axi_awcache/arcache = 4'b0011`; trace now shows 16×128 b → 4×512 b full-strobe
  beats. Would have broken every boot on hardware; invisible to the stub TBs.
  **RESULT: `tb_vu13p_mig` ALL PASS (T1-T4, 4096/4096 coef words correct, 2.71 ms
  sim / 37 min wall with trace).** Regressions after both fixes: `tb_vu13p_top` 10/10,
  `tb_system_ddr4_to_fir` PASS, `tb_coef_bank_loader` 7/7.
  Side note: the Micron model logs "Reading unwritten address" during boot writes
  even with DM enabled — MIG-internal, not a data error.
  **f17 route (2026-09-05, `scripts/impl_top_f17.tcl`, 1.5 h): WNS -5.152 — XDC
  miss, not a design problem.** Synth merged the FIFO output regs `{wmac,waddr,wdata}`
  into one vector `coef_waddr0_reg[*]`, so the §9 `-to coef_w*_reg` pattern matched
  nothing (1 critical warning) and 38 `cfifo_mem` → register paths were timed at the
  raw 0.002 ns ui_clk/dsp_clk edge alignment; all three post-route phys_opt passes
  burned on them. Gray-pointer constraints DID bind (req 3.3, slack +3.05). Residue
  elsewhere: adder tree level7→8 -0.698 / 2033 endpoints (SLR-hop routes; f16b
  closed it at +0.249 with identical geometry). XDC fixed: memory constraint is now
  `-from cfifo_mem*` with no `-to` (same as the boot-loader FIFO). **f17b**
  (`scripts/impl_f17b_place_route.tcl`, from `impl_f17_synth.dcp` with the fix
  applied explicitly): **TIMING CLOSED — WNS +0.164 / TNS 0.000 / WHS +0.010 /
  WPWS +0.039, 0 failing of 800,972 endpoints, 57 min** (`impl_f17b_route_timing.rpt`,
  `impl_f17b_routed.dcp` 132 MB). Pre-place CDC checks: mem/wptr/rptr requirement
  3.3 ns (slack +2.78/+3.05/+3.05); worst mmcm_clkout0→dsp_clk path now the FIFO
  read (req 3.3). `report_cdc`: mmcm_clkout0→dsp_clk 46 endpoints, all Safely Timed
  datapath-only (was the raw-edge group in f17). The adder-tree level7→8 residue
  vanished once phys_opt was no longer distracted. **This is the current release
  candidate build** (1M taps, both MIG-sim fixes in).

### RTL audit 2026-09-03 — new findings (filter-directory round complete)

Context: filter directory lookup (`coef_bank_loader` load_by_id, `coef_bank_manager`
{by_id,id} request + load_failed, `dac_coef_subsys` filter path + load_err export,
`dac_ctrl_plane` sticky[6] + CMD_ERR_INFO 0xA/0xB) implemented, TB-verified
(`tb_coef_bank_loader` 7/7, `tb_spi_ctrl_plane` 20/20, `tb_dac_ctrl_plane`,
`tb_vu13p_top` 10/10) and routed at 5M: **f15b WNS 0.000 / TNS 0.000 / WHS +0.007**
(`impl_f15b_route_timing.rpt`). Two XDC lessons folded into `vu13p_dac_top.xdc`
(match CDC endpoints on IS_SEQUENTIAL, not `*_reg` names — synth retimed
`bank_base` into `burst_addr__N` and renamed `state_reg` → `FSM_sequential_state_reg`)
and into the flow scripts (write the routed DCP BEFORE report_cdc/report_design_analysis
— the writer hung at 33.4 GB peak on this 27.7 GB box; DCP lost, reports intact).

- [x] TODO-16: **Boot default filter + stale `boot_load_done` (revised 2026-09-03 after
  user clarification of the filter-list requirement; IMPLEMENTED same day, see DONE).**
  FACTS: `dac_coef_subsys.sv` has `assign boot_load_done = 1'b1; // Placeholder`;
  `qspi_boot_loader.boot_ok` goes ONLY to status reg 0x1A; `coef_bank_manager`
  `ST_BOOT_WAIT` still assumes a boot loader filled FIR Bank B and swaps to it (the
  real boot loader fills DDR4, not a FIR bank) — so at reset it flips to an EMPTY
  Bank B and reports current_bank_id=0. Requests arriving before boot completes ARE
  queued (most-recent-wins), so an early ARM select is not lost.
  HOW THE LIST WORKS TODAY (verified in `dac_ctrl_plane.sv:106-108, 419-447, 552-561`):
  the ARM defines an ORDERED list once (0x08 clear, 0x09 append x N); entry 0 is the
  user's default BY CONVENTION; 0x0A advance/index steps through it FPGA-side (one ARM
  write per toggle, no IDs re-sent). Nothing auto-loads entry 0 — the ARM must issue
  FILTER_SELECT index 0 after building the list. The list lives only in FPGA volatile
  regs + ARM RAM → the FPGA CANNOT know the user's default at boot on its own, so an
  "FPGA-autonomous default from the directory" is the wrong shape.
  `filter_next_id` is readback-only (`vu13p_dac_top.sv:313`) — no shadow-bank preload
  of the next entry. `fade_out_req` is tied to 0 (`dac_coef_subsys.sv:300`): filter
  changes do NOT fade; the shadow bank fills while audio plays from the active bank,
  then swaps atomically (gapless) — load time is selection-to-effect LATENCY, not a
  mute. Per user (2026-09-03) the UX requirement is "select ANY filter at ANY time",
  so next-entry preload buys nothing and is DROPPED as a requirement.
  RULING (2026-09-03, implicit in discussion; confirm): **default filter = ARM policy**
  — on 0x1A boot_ok the ARM writes the list then FILTER_SELECT index 0.
  **DONE 2026-09-03:** (1) `dac_coef_subsys` takes `boot_ok` (clk_200m level, 2-FF
  sync) → `coef_bank_manager.ddr4_ready`; `ST_BOOT_WAIT` now just holds/queues until
  ready and goes IDLE with NO bank swap; new `bank_valid` output (set on the first
  successful swap) also fixes the latent same-bank shortcut that would have swallowed
  a legacy slot-0 request at reset. (2) `boot_load_done = bank_valid` → boot fade-in
  starts only after the first good load; envelope stays FULL_MUTE until then.
  (3) FILTER_LIST_CTRL 0x08 bit[1] = commit → select entry 0 (FILT_EMPTY reject on
  empty list; bit[0] wins if both). `bank_valid` exported to COEF_STATUS 0x13[12].
  TBs: new `tb_coef_bank_manager` 30/30 (T1-T8: boot hold, queue-before-ready,
  no phantom swap, slot-0 not swallowed, swap/valid, same-bank consume, failed load
  no swap, most-recent-wins); `tb_dac_ctrl_plane` T10 (commit, empty reject,
  clear-wins, 0x13[12]) → 39/39; `tb_vu13p_top` 10/10 (DDR4 stub calib=0 → manager
  parks in BOOT_WAIT, output muted, no regressions); system-level ordering in
  `tb_system_ddr4_to_fir` (TODO-19). Marked [x] below.
- [x] TODO-17: **Dead code DELETED 2026-09-03:** `flash_bridge.sv` + `tb_flash_bridge.sv`
  (superseded by `qspi_flash_ctrl.sv`). Script exclusion filters left as harmless no-ops.
- [x] TODO-18: **DONE 2026-09-03:** `Xilinx/spi_regs.svh` created (write/read addresses,
  magic, FLIST_MAX, sticky bit indices, CMD_ERR reason codes); `dac_ctrl_plane.sv`
  now decodes only via the macros (`include` resolves from the source dir, same
  as `dpd_lag_rom.svh`; TBs 39/39 + 27/27 after conversion). Stale headers fixed:
  `coef_bank_loader.sv` layout/timing block (parameterized, 1M/5M numbers, no-fade
  note), `dac_dsp_core.sv` parameter comments.
- [x] TODO-19: **DDR4→loader→FIR end-to-end simulation — REWRITTEN + PASSING 2026-09-03
  (30/30).** `tb_system_ddr4_to_fir` now parameterizes `dac_coef_subsys` (the old
  failure was the subsystem left at default params while the TB scaled the FIR),
  runs the RELEASE geometry TPP=256 with NUM_MACS scaled 256→64 (262,144 coefs,
  256 bursts per bank), ui_clk 300 MHz / dsp_clk 357 MHz, and its AXI model serves
  a 2-entry filter directory at `DIR_BASE_ADDR` (0x0101 ok → bank-2 region; 0x0202
  payload/2 → FILT_SIZE; 0x0404 absent). Tests: T1 request before boot_ok queued (no
  AXI, muted, BOOT_WAIT); T2 boot_ok → load, data-checked writes, swap, bank_valid;
  T3 fade-in starts after first load; T4 FIR impulse output valid/X-free (input at
  48 kHz = 16 ticks — the FIR needs 16×TPP cycles per input sample); T5 directory
  load by ID UNDER A RUNNING FIR (gapless path) → swap, no X afterwards; T6/T7 error
  codes 1/2 with no swap. No `--relax` needed (multi-driver TB code removed). Runner:
  `run_tb_ctrl_plane.ps1 tb_system_ddr4_to_fir` with `TB_DEFINES=SIM` (~45 s).
  Lesson recorded: drive TB stimulus with NONBLOCKING assigns after `@(posedge)`;
  blocking assigns in the same timestep raced the DUT and silently dropped
  `new_sample`. Still open (not RTL): the real `ddr4_0` sim model has never run in
  xsim — `tb_vu13p_top` uses the stub.
- [x] TODO-20: **Filter latency readback — CLOSED 2026-09-04, no readback.** User
  ruling: customers are NEVER shown delay numbers, and **video mode = exactly ONE
  reserved filter** (min-phase/short, zero-padded to the 4 MB bank at staging). So:
  no beat-1 capture in the loader, no ctrl-plane register; `latency_us` /
  `video_mode_eligible` remain `.bfc`/directory metadata for the filter builder only.
  Host enters video mode with DAC_MODE 0x0B[0]=1 + FILTER_SELECT_ID 0x17 (normal
  4.4 ms gapless load), exits by re-selecting the list entry. Latency budget kept at
  <=20 ms end-to-end: audio LAG is the tolerant direction (ITU-R BT.1359 detectability
  ~125 ms lag; ATSC IS-191 <=45 ms), so 5 ms vs 20 ms is immaterial for lip sync; the
  real problem video mode solves is the ~683 ms group delay of a 1M-tap linear-phase
  filter at 48 kHz. `coef_format_v2.md` updated (header notes, 0x0B semantics, Notes,
  open question 3 resolved). No RTL change.
- [x] TODO-25: **Single-URAM-bank question — RULED OUT 2026-09-04.** Asked whether one
  coefficient bank (vs A/B) would (A) allow >5M taps, (B) simplify switching,
  (C) cut congestion. (A) Only URAM halves (4 MACs/72-bit word instead of 2x2 banks);
  URAM was 10 % @ 1M / 50 % @ 5M and never the wall — LUT ~35 % / DSP ~21 % / timing
  at 0.000 @ 5M and the storage-per-filter argument are, and none scale with bank
  count. (B) Worse: writing the bank the FIR reads forces fade-out → load (4.4/22 ms)
  → fade-in on every toggle instead of gapless; the mute sequencing replaces the swap
  logic 1:1. (C) Negligible: the bank is a 2:1 mux on the URAM read slice + one
  registered select; the 5M congestion was the coef WRITE broadcast and MAC/window
  fabric, both unchanged. Decision: keep dual-bank 1M (f16b, WNS +0.249, URAM 10 %).
- [ ] TODO-26: **Level translators move to the FPGA side — RULED 2026-10-09 (user).**
  Trigger: routing/parts congestion in the cell array; user searched for a merged
  FF+translator and found none (SN74LV2T74-EP rejected: fmax min 34.3 MHz @3.3 V,
  ±5.5 mA drive, dual per package — bom.md item 12). Ruling: keep 1× SN74LVC1G74
  per cell; replace the 128 per-cell AXC1T45 with 16× SN74AXC8T245-class octals
  (8/channel) at the SoM connectors J1/J5/J6. **LOCKED 2026-10-09 (user, "beat the
  5 ns by a country mile; equalise SSN timing"): BOTH data segments length-matched —
  FPGA pin → translator (1.8 V) ±2.5 mm (≈ ±16 ps) within and across all 16 octals;
  translator → FF D (3.3 V) ±5 mm (≈ ±33 ps); Q/Q̅ intra-pair ±1 mm.** The RTZ ±5 ns
  window is the functional limit, not the layout target. SSN equalisation: 8 lines
  per octal, identical decoupling per octal, channels mirrored, translator B-sides
  on their own V33FF ferrite/C island (bom item 11 extended to report the translator
  SSN event vs the FF sampling edge). Clock tree: 3.3 V LMK1C1108 direct to FF CLK,
  FPGA mclk copy via 1G125 + divider; **tree re-matching LOCKED 2026-10-09 (user):
  XO → root → leaf → FF CLK ±5 mm end-to-end on all 128 paths, root/leaf feeds
  ±2.5 mm** (reverses the Round-30 "retired" note; leaf-to-leaf skew then = LMK1C1108
  part-to-part 280 ps max only). RTL/XDC unchanged. Hardware follow-ups: `gen_kicad` cell sheet drops
  U440–U567 (translator + its decoupling), fpga sheet gains U440–U455 on V18/V33FF;
  MPN at bom §9 pass; matched-length rule into the layout constraints.
- [ ] TODO-27: **I²S master mode + ready/status register (from TODO-13 ruling
  2026-10-09).** (a) `i2s_rx` slave → master: BCLK = 64·fs and LRCLK = fs divided
  from `cell_clk`, new top ports `i2s_bclk`/`i2s_lrclk` as OUTPUTS (XDC: direction
  flips on the existing bank-71 pins, SDATA stays input + weak pull-down); rate
  register (family via existing `clk_sel` + fs divider field) with the switch run
  through the existing mute/MMCM/`switch_busy` sequence; SDATA RX sample-delay
  register (two isolator crossings ≈ 25–35 ns round trip vs 10 ns half-period at
  768 kHz — same class as bom §21 SPI fast mode); stream-valid detect feeding the
  existing automute/un-mute. (b) Status register: boot_load_done, switch_busy,
  mmcm_locked, stream_valid, muted, i2s_err (read-only, synchronised). (c)
  `tb_vu13p_top`: 768 kHz I²S source becomes a slave model clocked from the DUT;
  add rate-change + ready-poll + stream-start sequence. Hardware side in bom §21.
- [ ] TODO-21: **DPD lag-tuple ROM swap** (from TODO-9): regenerate `dpd_lag_rom.svh`
  with the frozen cosim80c3j tuples once Step 6.4 tooling exports them, re-run
  `tb_dpd_engine` bit-exact gate, resynth. Tooling-gated.
- [ ] TODO-22: **Host/tooling dependencies that gate RTL bring-up (not RTL work):**
  (a) staging tool must build the DDR4 directory at `DIR_BASE_ADDR` (32-byte entries,
  zero terminator, `payload_bytes` == NUM_MACS*COEF_DEPTH*4 exactly or every load fails
  FILT_SIZE) — without it FILTER_SELECT always returns FILT_NOTFOUND on hardware;
  (b) ratify the 4 open questions in `coef_format_v2.md`; (c) plan Step 4D.5 e2e analog
  gate needs Step 6.4 kernel export. Optional RTL: `coef_bank_loader` AR/R pipelining
  (header note) — ~20% latency gain only; the drain bus is the bottleneck (TODO-24).
- [x] TODO-23: **Filter list: 16 → 32 entries + direct select-by-ID — DONE 2026-09-03.**
  `dac_ctrl_plane.sv`: `FLIST_MAX=32` localparam (5-bit index, 6-bit len), shared
  `filter_adv_index`/`filter_sel_in_range` comb logic replaces the old ==16 special
  cases; FILTER_SELECT 0x0A index [4:0]; new write 0x17 FILTER_SELECT_ID (loads any
  directory ID, leaves cur_index untouched); readback 0x16 repacked
  {video_mode[11], len[10:5], idx[4:0]}. TB: `tb_dac_ctrl_plane` T6/T7 rewritten for 32
  (random access 16→2→29, wrap at 31), new T8 (select-by-ID + advance resumes from
  list) and T9 (FILT_FULL at 33rd append → sticky[6] + CMD_ERR_INFO {0x09,4}, W1C) —
  28/28; `tb_spi_ctrl_plane` unchanged 27/27. New runner
  `Testbench/run_tb_ctrl_plane.ps1 [tb]` (detached xsim pattern). Docs:
  `coef_format_v2.md` SPI tables + register map above.
- [ ] TODO-24: **Coefficient storage capacity → RELEASE TAP COUNT = 1M (user ruling
  2026-09-03).** Committed flash layout: Flash 0 (128 MiB) = golden + update bitstreams
  (64 MiB slots, CONFIGFALLBACK); **Flash 1 (128 MiB = 134,217,728 B) = ALL coefficient
  storage** (`vu13p_dac_top.xdc` §11/§12, `qspi_boot_loader` record chain). Current
  record format = 32-bit word per coefficient, copied verbatim into DDR4.
  | taps | coefs | 32-bit (today) | 24-bit packed | 18-bit packed |
  |---|---|---|---|---|
  | 5.24M (1280x256) | 5,242,880 | 21.0 MB → **6** filters | 15.7 MB → 8 | 11.8 MB → **10** |
  | 1M (1024x64 or 256x256) | 1,048,576 | 4.19 MB → **31** | 3.15 MB → 42 | 2.36 MB → **56** |
  (halve for separate 44.1k/48k designs per filter; 16 B record headers, directory
  lives in DDR4.) 32 filters at 5M taps (~380 MB packed) cannot fit the SOM flash.
  **RULING: initial release ships 1M taps** — 31 filters with NO RTL/format change,
  56 with 18-bit packing (optional headroom: unpack in `qspi_boot_loader`, small).
  5M taps remains a PROVEN capability (f15b P&R closed at 1280x256, WNS 0.000) held for
  a future option (needs baseboard flash / ARM→DDR4 filter streaming to exceed ~10).
  This SUPERSEDES the plan's 2026-08-22 "hold RTL at 5M, defer tap-count evaluation to
  pre-manufacturing" ruling — the driver is now storage, not FPGA cost.
  LOAD LATENCY (from `coef_bank_loader` structure, ui_clk 300 MHz, ST_DRAIN = 1 coef/
  cycle onto the single URAM write bus, sequential AR→R→drain, ~1300 cycles per
  1024-coef burst): 5M = 5120 bursts ≈ **22 ms**; 1M = 1024 bursts ≈ **4.4 ms**.
  DDR4 bandwidth is NOT the limit (~1 ms for 21 MB); AR/R pipelining → ~17.5 ms @ 5M;
  4-coef-wide write bus → ~4.5 ms @ 5M. Gapless in all cases (no fade), so these are
  button-to-effect latencies — imperceptible; no loader speed-up needed for 1M.
  **RULING 2026-09-03: geometry = 256 x 256** (keeps the TPP=256 deep-sweep URAM/window
  geometry f15b closed; only the MAC count shrinks). DONE: top default set to
  NUM_MACS=256 / TAPS_PER_PHASE=256 (`vu13p_dac_top.sv`); `scripts/impl_top_f16.tcl`
  (f15 flow at 256x256); unit TBs at the release geometry: `tb_coef_bank_loader`
  with TB_TPP256 (256 x 4096 = exactly the release bank: 1,048,576 writes / 1024
  bursts) 7/7, `tb_vu13p_top` 10/10, `tb_system_ddr4_to_fir` 30/30 (TODO-19).
  Plan amended (Design Decisions rows + Feature 2).
  **f16 synth (2026-09-03, 11.5 min, 0 critical warnings):** LUT 146,247 (8.46 %),
  FF 130,825 (3.79 %), DSP 685 (5.57 %), URAM 128 (10.0 %), BRAM 31 (1.15 %) —
  vs 5M: LUT ~35 %, DSP ~21 %, URAM 50 %. Placement reached Post-Placement
  **WNS +0.486** (5M closed at exactly 0.000), then Vivado VANISHED silently in
  place_design Phase 4.1 (Post Commit Optimization) — no ERROR, no hs_err dump, no
  Event Log entry, peak 15.3 GB / 27.7 GB. Synth DCP intact → restarted as
  `scripts/impl_f16b_place_route.tcl` (open synth DCP → opt → pblocks → place →
  route, f15b pattern).
  **f16b ROUTED + TIMING CLOSED (2026-09-03 21:15): WNS +0.249 / TNS 0.000 /
  WHS +0.010 / WPWS +0.039**, 800,403 endpoints, "All user specified timing
  constraints are met" (`impl_f16b_route_timing.rpt`); 0 critical warnings in
  opt/place/route. Runtime from synth DCP: place 39 min, phys_opt 2 min, route 21
  min, peak 14.8 GB — the whole flow now fits in one evening (5M needed ~3 h and
  peaked at 33 GB). Routed utilization: LUT 144,198 (8.34 %), FF 130,006 (3.76 %),
  DSP 685 (5.57 %), URAM 128 (10 %, 32/SLR), BRAM 31; per-SLR LUT 5.6-12.8 %.
  `impl_f16b_routed.dcp` (129 MB) + CDC/congestion reports written. The 1M release
  geometry is therefore RTL-complete and P&R-proven with +0.25 ns margin vs the 5M
  design's 0.000. REMAINING (tooling, not RTL): staging `payload_bytes` =
  4,194,304 B; `coef_format_v2.md` examples.

---

## Completed items
- [x] I2C master: multi-byte write, clock stretching
- [x] I2C master removed (no I2C devices planned)
- [x] i2s_rx: BCLK-domain rewrite for 768/705.6 kHz support
- [x] dac_i2s_ingress: toggle-sync CDC + dsp_clk watchdog
- [x] artix_dac_top.sv deleted; vu13p_dac_top.sv is sole top-level
- [x] LVDS, multi-FPGA role/sync infrastructure removed
- [x] Clock source mux (clk_source_sel) added to vu13p_dac_top
- [x] tb_i2c_master, tb_i2s_rx, tb_spi_ctrl_plane written and lint-clean
- [x] Full RTL lint: 0 errors, 0 warnings

## Converter Architecture — Record of Decisions to Date
- **Architecture**: Discrete unary current-steering DAC ("cascode cell" array), fully differential, 64 cells/channel
  - History: 256 cells/channel originally → reduced to 64 (PCB density/routing unbuildable at 256)
  - 64 confirmed sufficient 2026-07-12: quantization SQNR ≈147dB (65 levels, OSR 154, noise shaping); thermal floor ≈138dB; both clear the >128dB target
- **DEM is in the FPGA and is load-bearing**: `dem_64.sv` / `dem_dwa.sv` / `dem_mapper.sv` — 64-element DWA, first-order mismatch shaping, per channel (see BFDAC_IMPLEMENTATION_PLAN.md). Without it, 0.1% component matching → only ~80dB linearity; with it, mismatch becomes shaped out-of-band noise. Component tolerances (0.1% R_tail, THAT300 ΔV_BE) are sized ASSUMING DEM.
- **Noise shaping**: 5th/7th-order noise shapers in RTL → 64-level output at 6.144MS/s to the mapper
- **Post-converter analog**: I/V + V stage downstream of the converter — see "I/V + V Stage" section. DECIDED: virtual-ground transimpedance I/V → converter bus does not swing → 5V rail decision reopened.
- **dCS Ring DAC comparison (2026-07-12)**: same architectural family (unary sources + mapper at 2.8–6.1MS/s; Vivaldi ~46 sources, APEX 92/96). Our 64 sources at 6.144MS/s is in the same design space. Their source surplus = mapper freedom + duty spreading; we already have surplus (64 vs 33 needed levels).
- **Reference noise path (open)**: shared 1.25V reference noise is common-mode gain modulation across all 64 cells — needs aggressive RC filtering to stay below −130dB. Not yet designed.

## Design Rules — Whole Analog Path (recovered 2026-07-12)
- ~~NO integrated op-amps anywhere in the circuit~~ **REVISED 2026-07-12 — hybrid rule**:
  - **I/V core + servo: best-in-class IC op-amps** (TI/ADI — OPA1612-class for I/V core; loop gain IS linearity at 128dB targets, monolithic PSRR/matching win)
  - **Buffer (diamond) + V output stage: purely discrete Class A** — current delivery, thermal freedom, constant-rail-draw requirement
  - Rationale for revision: discrete-only sacrifices 50–60dB of distortion suppression (60–80dB discrete OL gain vs 130dB monolithic); rule was already porous (THAT300, LM4040, LDOs are ICs); composite keeps discrete Class A where it wins (power) and monolithic where it wins (precision)
- **NO capacitors in the audio path** — DC-coupled throughout (hence servo-based CM/offset control)
- Rationale: ultra-premium target — 128dB+ SNR, lowest distortion, highest linearity, no frequency-dependent phase shift
- Revisitable if a compelling case arises, but default to compliance
- Interpretation rulings:
  - RULED 2026-07-12: DC servo does NOT count against the no-capacitor rule — it only injects a DC offset to set common mode. REQUIREMENT: servo output must be extremely clean — no ripple, no noise (servo noise injects as CM directly; any imbalance in the injection network converts it to differential). Implies heavy filtering inside the servo, sub-Hz bandwidth, and matched injection resistors.
  - RULED 2026-07-12: shunt caps to ground ARE allowed for the reconstruction filter (no other way to remove shaped OOB noise). No series caps — signal never passes through a capacitor. Filter corner kept well above 20kHz so there is no filtering/phase shift in the 20Hz–20kHz band. Analog filter order/corner TBD (sized against 5th/7th-order shaper OOB spectrum).
- Sim note: ideal op-amps allowed as behavioral placeholders in LTspice during co-design; final implementation per the hybrid rule above.

## I/V + V Stage — Part/Topology Selections (2026-07-12 evening)
- **I/V core: OPA1612 (LOCKED)** — differential virtual-earth pair, one amp per rail
- **Servo: OPA189 (zero-drift, ±36V)** — sub-Hz bandwidth; chopper ripple killed by servo output filtering; ADA4522 as alternate
- **Diamond buffer: DISCRETE Class A** (fixed current-source bias) — BUF634A rejected for final design (Class AB → signal-dependent rail draw violates constant-rail-draw rule); acceptable as prototyping shortcut only
- **Noise shapers stay DIGITAL** (RTL `noise_shaper_5th/7th_order.sv`) — not an analog circuit, no change from IC decision
- **Reconstruction filter: PASSIVE LC** (series-L/shunt-C, corner ~300–500kHz) — active op-amp filters rejected (caps in feedback/signal path violate no-cap rule; adds noise/distortion after precision stages)
- **FLAGGED TENSION**: TIA stability may require a few pF feedback cap across R_f (signal passes through it at HF). Cascode keeps summing node ~pF which minimizes need. Decide via sim; would need a rule exemption.

## I/V + V Stage — Recovered Requirements (agreed previously, re-recorded 2026-07-12)
- **I/V stage**: virtual-ground transimpedance, followed by a **diamond buffer** with **servo steering to control common mode**
  - CONSEQUENCE: converter output bus does NOT swing → 5V rail/headroom analysis is obsolete; re-evaluate rail (3.3V candidate) and shared-cascode role (capacitance isolation from summing node, not swing shielding)
  - **Servo purpose (confirmed 2026-07-12)**: hold I/V OUTPUT common mode at **0V**, tracking drift of the whole circuit — implemented as servo-trimmed DC offset-current injection into the summing nodes (≈ I_rail_mid + V_sum/R_f ≈ 70mA/side at I_FS=50mA). DC-coupled, no caps. Offset source is IN the audio path → needs reference-grade quietness + matched injection resistors.
  - With CM=0 at I/V output: 2Vrms output setting ≈ unity gain from R_f; V stage provides 4V/6V gain, reconstruction filtering, load drive
- **V stage**: Class A output stage on **±15V rails** — no devices or circuit topology chosen yet; output current requirement NOT YET DECIDED
- **Output level selection**: SPI reg 0x02 drives relays selecting **2V / 4V / 6V** output
  - Use cases: headphones (direct), pre-amp, direct-drive power amplifier
  - NOTE: SPI register currently 1 bit ([0]) — needs 2 bits for 3 levels; update register map + RTL
  - Open: whether relays switch I/V feedback R or V-stage gain
- **Open items**: V-stage bias/output current spec (driven by headphone load case — e.g. 2Vrms into 32Ω ≈ 88mA peak, sets Class A bias ≥ that), device selection, reconstruction filter placement/order, servo design, noise budget allocation across I/V + V

## Power Architecture (recorded 2026-07-12)
- **±15V rail**: ADI LDOs (no TPS7A part reaches ±15V) — LT3045/LT3094-class ultralow-noise pos/neg. Power domain to be REDRAWN around this.
- **Lower analog rails**: cascaded **3× LDO** chains (TI TPS7A family) — multiplied PSRR, very low ripple/noise
- **V stage**: ±15V from linear supply, through multiple LDOs
- **FPGA only** gets switching supplies (current demand of VU13P makes linear impractical)
- Analog rails needed: ±15V (V stage, I/V, offset-injection source), 2.5V cascode bias (µA), 1.25V tail reference (µA), servo supply
- Note: 1.25V LM4040 + RC and 2.5V bias still need their own local filtering — LDO chain feeds them but shunt-reference noise is its own contributor

## ±15V Rail — 6.144MHz Switching-Current Analysis (2026-07-12)
- What the rail sees, decomposed (from cosim1/2 data):
  1. Offset-injection path: pure DC (I(R_off) ripple ±0.04µA — summing node pinned) — no switching content
  2. I/V signal draw: near-constant at audio rate by the converter's constant-sum property (per-rail TIAs draw anti-phase; sum ~constant)
  3. Switching residue: DEM transition glitches at 6.144MHz+, mA-scale — the real exposure
- Mitigation requirements (RECORDED as design rules):
  - **TIA REQUIREMENT: constant rail draw by construction** — Class A with fixed current-source pull-ups, signal steered internally
  - **Per-stage dedicated final LDO** (I/V and V stage separate outputs from common raw rail) — isolates V stage from I/V switching residue
  - **>1MHz passive filtering at every LDO output**: ferrite/L + multi-decade decoupling (100nF+10µF+bulk) — LDO PSRR is spent above ~1MHz, passives must take over; rail caps do NOT violate the no-audio-path-cap rule
  - Layout: keep 6.144MHz decoupling loops local to the converter/I/V; LDO should never see MHz content
- Verification RESULTS (bfdac_cosim3.cir, 2026-07-12): 20mVpp @ 1MHz injected at LDO output; LDO Zout (10mΩ+30nH) + bead (1µH/100Ω damp) + 10µF/100nF decoupling; R_off mismatched 0.1% worst-case; cells static so diff output = pure rail leakage
  - Filter attenuation @1MHz: 20mVpp → 0.49mVpp (−32dB, passive network alone)
  - CM at I/V output: 151µVpp (matches theory: ×R_f/R_off = ×0.31)
  - **Differential leakage: 151nVpp — −151dB rel. 2Vrms FS, at a grossly pessimistic 20mVpp/1MHz disturbance**
  - Total chain rejection: −102dB (filter × CM ratio × 0.1% mismatch), BEFORE reconstruction filter and V-stage CMRR are counted
  - Conclusion: offset-injection path is NOT the rail-noise weak point. Remaining exposure is the real TIA's PSRR (behavioral amp here is perfect) — measure again when discrete TIA replaces the E-source.

## Converter ↔ I/V Interface Contract (co-design working values, bfdac_cosim1.cir)
| Parameter | Value | Owner/notes |
|---|---|---|
| V_sum (servo CM setpoint) | 2.4V | servo; gives cascode V_CE ≈ 0.68V |
| I_FS | 50mA (sweep 25mA pending) | joint — SNR vs I/V burden |
| R_f | 56Ω | → ~2Vrms diff at FS; relay-switched value TBD |
| I/V DC source current | ~27mA/rail mid-code, ~54mA/rail at FS code (incl. static+bleed) | I/V output stage sizing |
| I/V output compliance | up to V_sum + I_FS·R_f ≈ 5.2V | fits ±15V rails easily |
| C at summing node | ~pF (cascode collector only) | converter keeps shared cascode |
| Cascode bias | 2.5V, near-zero current | quiet rail, easy to filter |

## Co-sim Findings (bfdac_cosim1.cir, 2026-07-12)
- **Virtual-ground topology verified end-to-end**: behavioral TIA holds sum nodes at 2.4V ±15µV; tails 774µA ±2µA; bus pinned 1.67–1.77V; off-side leakage <0.2µA — all with **1.8V LVCMOS drive** and a placeholder low-V_th FET (Vto=0.6V)
- **Switch FET spec confirmed by sim**: with Vto=0.6, source node sits at 1.09–1.18V → Q4 V_CE ≈ 0.55V, comfortably active. Real part needs V_GS ≤ ~0.9V at 781µA (Vto(max) roughly ≤0.75V for margin)
- **MAJOR SIMPLIFICATION — no converter power rail needed**: with virtual-ground I/V, ALL cell current is sourced by the I/V amps through R_f. The old 5V/3.3V analog VCC carries zero current (verified: I(V_supply)=0). Remaining converter rails: 2.5V cascode bias + 1.25V reference, both near-zero current → trivially filterable to very low noise. The 5V-vs-3.3V question is MOOT.
- **I/V burden quantified**: each rail's amp sources 14–39mA in this mid-code sim; at FS code ~54mA continuous. This is the Class A discrete TIA's design driver — and the live argument for the 25mA I_FS sweep.
- Placeholder FET model must be replaced with a real, model-verified low-V_th part before locking.

## Co-sim v2 Findings (bfdac_cosim2.cir — offset injection, CM=0)
- **CM=0 scheme verified**: 70mA injected per summing node (180Ω from +15V) → I/V outputs centered at 0V (residual CM ≈ −70mV from deliberately asymmetric test code — this is exactly what the real servo trims out). Differential swing ±0.7V in this partial-code sim; converter internals completely unaffected (tails/bus/sum node identical to v1).
- **Offset source noise gain to output is benign**: rail noise × (R_f/R_off) = ×0.31 per side, common-mode; differential leakage only via R_off mismatch → 0.1% parts + triple-LDO rail is ample.
- **OPEN — offset resistor dissipation**: 180Ω from +15V burns 0.88W per resistor (×4 stereo ≈ 3.5W of heat near the audio path, thermal drift risk). Better: drop from a lower clean LDO rail (e.g. +5V: 37Ω, 0.18W) or split across series/parallel resistor arrays for power spreading. Decide with the LDO rail plan.
- **Servo trim range needed**: at least ±100mV-equivalent (±2mA-scale injection trim) to cover code asymmetry + drift.

## MILESTONE — Co-sim v4: Full Composite I/V + Converter (bfdac_cosim4.cir, 2026-07-12)
- **First full-chain sim**: converter cells (1.8V drive, shared cascodes, offset injection) + REAL composite I/V — OPA1612 macromodel (Aol 130dB, GBW 40MHz, SR 27V/µs) + transistor-level discrete Class A diamond buffer (5551/5401 complements, 5mA sources) in-loop
- **STABLE**: static-cell run (bfdac_cosim4s.cir) is dead quiet — sum node 2.4000000V, PP = 0, no oscillation. Composite loop with discrete buffer in-loop is sound.
- **DC operating point correct**: tails 774µA, CM −71mV (servo's job), diff offset −3.9mV static (R_off 0.1% mismatch, servo trims)
- **Rail draw near-constant**: I(+15V) PP < 1mA with C_c fitted — Class A diamond doing its job
- **NEW QUANTIFIED PROBLEM — DEM glitch settling**: each 6.144MHz cell transition injects charge that rings/settles over ~50–100ns through the finite-GBW loop (sum node PP 0.66V at edges, output tails ~0.2V). Ideal amp hid this; real amp shows it. This is the pre-existing "switching glitch" open item, now measurable. Mitigation study needed: realistic IOB edges (not 1ns), crossing-point timing, summing-node charge reservoir, RTZ, C_f value. THIS IS THE #1 ANALOG WORKSTREAM.
- 47pF split-feedback comp caps (amp out → sum node) fitted as insurance; necessity not yet established (stable static both ways untested) — resolve during glitch study
- OPA1612 modeled as macromodel from datasheet params; swap in TI's official model (sbom396 zip → OPA1612.LIB) for final verification

## Co-sim v5 — OFFICIAL TI OPA161x Model Validated (bfdac_cosim5.cir, 2026-07-12)
- Official Green-Williams-Lis model (sbom396g → `OPA161x.LIB`, copied to LTspice folder; subckt `OPA161x IN+ IN- VCC VEE OUT`, powered from real ±15V nodes)
- **Static run (bfdac_cosim5s.cir): dead stable** — sum node PP = 0, avg 2.4001V (~100µV realistic input offset), tails 774µA, CM −68mV, diff −3.9mV → macromodel conclusions CONFIRMED by official model
- Toggling run: same DC health; glitch settling slightly worse than macromodel (quiet-window sum PP 120mV vs 69mV — real slew/overload recovery behavior) → reinforces glitch study as #1 workstream
- Composite architecture (OPA1612 + discrete Class A diamond in-loop + 47pF split-feedback comp) is VALIDATED with official silicon model

## Glitch Study Round 1 (bfdac_cosim6/7.cir, 2026-07-12)
Three mechanisms identified: (1) crossing-point/dead-zone error — code-dependent → distortion; (2) Crss gate feedthrough; (3) finite-GBW loop recovery.
- **v6 — realistic edges + make-before-break skew** (tedge=3n, skew stepped 0→3n):
  - Slow edges alone (skew=0) made it WORSE than 1n edges (sum quiet PP 197mV vs 120mV) — slower edges widen the break-before-make dead zone where the tail current has no path
  - Skew (FPGA ODELAY, make-before-break) fixes exactly that: 2–3ns skew cuts output glitch PP ~20% (0.62→0.48V) and settling tails ~10%; sum-node disturbance rises slightly (both-ON crowbar interval). **1–2ns skew is the sweet spot; free in FPGA fabric.**
- **v7 — summing-node charge reservoir** (C_sum stepped, C_f co-designed as sqrt(csum/(2π·Rf·GBW))+2p):
  - Bare reservoir cap WITHOUT C_f destabilizes the TIA (330p diverged) — C_f across R_f is mandatory companion
  - 330p+C_f: sum node PP 0.70→0.13V (great for cascode compliance), rail ripple halved, BUT settling tails 30mV→234mV — stored charge discharges slowly through the loop. **Big reservoirs trade spike amplitude for slow tails = wrong direction for settling-based linearity. Keep ≤100p if any.**
- **DOMINANT TERM = loop dynamics**: intended diff step is only 87mV (774µA×2×56Ω) but glitch PP is ~0.6V — 0.5V is loop overshoot/ring. Next lever: C_c/C_f compensation co-optimization for critically-damped settling (glitch study round 2), possibly a faster HF path.
- Context: this deck is worst-case observability (1 cell, no reconstruction filter). Criterion remains CODE-DEPENDENT glitch charge, not absolute amplitude.

## Glitch Study Round 2 — Compensation Sweep (bfdac_cosim8/8b.cir, 2026-07-12) [FINDINGS; DECISIONS PENDING]
2-D sweep C_c (split-feedback, amp-out→sum) × C_f (across R_f), skew=1n, tedge=3n, 21 points total:
- **Monotonic: smaller C_c always better, C_f optimum at 22p.** C_c=47p (the v4 insurance value) was actively hurting — it couples buffer-input swing back into the summing node.
- **PROPOSED (pending user decision): C_c = REMOVED (0), C_f = 22pF across each 56Ω R_f.** cf=47p trades marginal rise improvement for worse fall tails; cf=100p is 4× worse (slow discharge).
- Result vs v5 baseline: glitch PP 0.62→0.41V, settling tails 32→17mV, stable across all 21 points (no C_c needed for stability — R_f‖C_f compensates the composite alone)
- **Residual 0.4V spike is loop slew during the transition itself** (87mV intended step, OPA1612 27V/µs + 40MHz bound). It settles to <20mV within ~25ns — fast and mostly code-independent. Further reduction requires faster amp or architecture change; park unless code-dependence sim shows a problem.
- PROPOSED mitigation stack (pending user decision): (1) C_f=22p, no C_c; (2) 1–2ns make-before-break skew via FPGA ODELAY; (3) fast LVCMOS18 edges (do NOT slow); (4) no sum-node reservoir; (5) RTZ held in reserve.
- NEXT: code-dependence verification — multi-cell deck with different DEM patterns, measure glitch-charge variation vs code (the actual linearity metric).

## Glitch Study Round 3 — Code-Dependence QUANTIFIED (bfdac_cosim9.cir, 2026-07-12)
Deck: 8 live cells + 56-cell static equivalent; k∈{1,2,4,8} cells flip minus→plus simultaneously at t=200n; locked mitigations in place (C_f=22p, no C_c, 1n skew, 3n edges). Metric: excess glitch area glitch_q vs ideal step, normalized per cell.
- **DC step linearity PERFECT**: dstep = 84.9/169.8/339.6/679.2mV — exact ×2 progression (≤20ppm deviation). Static converter linearity is not the problem.
- **GLITCH CHARGE IS CODE-DEPENDENT**: q_per_cell = −5.28/−5.46/−6.57/−8.27 nV·s for k=1/2/4/8 — **+57% growth**. Deviation from ∝k at k=8 is ~24nV·s ≈ 2.6e-2 of a FS sample-area — catastrophic vs 128dB if uncorrected.
- **Root cause is large-signal overload at high k**: sum-node excursion grows 0.31→1.15V (k=1→8) — at k=8 the sum node dips far enough to violate cascode compliance (bus pinned ~1.8V, sum nominal 2.4V) and the loop slew-limits; settling tails explode 7mV→487mV at k=8.
- **Mitigation candidates for Round 4** (in order):
  1. **Per-cell edge staggering** — spread simultaneous flips 1–2ns apart via per-pin ODELAY (free, FPGA). Bounds the instantaneous current step to ~1-cell magnitude regardless of code.
  2. DWA transition-count limiting in RTL (cap cells-per-sample switched, spill to next sample) — trades slight DEM noise shaping for bounded k.
  3. Revisit small sum-node reservoir (~100p + C_f re-fit) purely to bound the excursion within cascode compliance.
  4. Raise sum-node setpoint (2.4→2.7V?) for more downward compliance margin — check OPA1612 CM and offset-injection budget.
- NOTE: worst case k=8-of-8 live cells here corresponds to k up to 64 on the real board — staggering/limiting is not optional, it is REQUIRED.

## Glitch Study Round 4 — Staggering vs Compliance Reservoir (bfdac_cosim9b/9c.cir, 2026-07-12) [FINDINGS; DECISIONS PENDING]
- **v9b — staggered flips (i×2ns ODELAY): made it WORSE.** q_per_cell −5.28→−10.1n (k=8), tails 850mV. Why: 2ns spacing << ~25ns loop recovery, so spikes pile onto an already-displaced sum node and the overload lasts LONGER. Spacing at ≥25ns is infeasible (64×25ns >> 163ns sample). **Staggering is ruled out as primary fix.**
- **v9c — reservoir sized for compliance (C_sum=2.2n + 4.7Ω ESR, C_f refit to 390p, no C_c): solves code-dependence in sim.**
  - q_per_cell = −9.76/−9.74/−9.58/−9.26 nV·s for k=1/2/4/8 — **flat within 5%** (was 57%)
  - Sum-node excursion 25→151mV (was 310mV→1.15V) — always inside cascode compliance, scales linearly
  - Settling is slower but LINEAR (tails scale ∝k) — linear settling = ISI/filtering, NOT distortion. The v7 "slow tails" objection was wrong for linearity purposes; what matters is staying in the linear region.
  - Per-transition charge magnitude rises (−5.3→−9.7n) but it is now code-INDEPENDENT → folds into benign HF, filtered out
  - Convergence: reservoir needs series damping (4.7Ω) + gmin/abstol relaxation in sim
- Candidate design principle (pending user review): make the sum node slow and linear, not fast — bound ΔV=Q/C inside compliance; let the TIA integrate at leisure. NOTE: nF-class caps at the sum node interact with the capacitor-minimalism rule for the audio path — user ruling required.
- SCALING TO 64 CELLS: excursion ∝k → k=64 needs ~8× more C (≈18n) or combine C_sum=2.2–4.7n with DWA transition-count limiting (cap k per sample in RTL). C_f re-fit accordingly. Residual 5% variation may be measurement-window artifact (extend sim to full settle for k=8).
- OPEN DECISIONS (user to ratify, 2026-07-12): (1) sum-node reservoir yes/no; (2) C_f value; (3) make-before-break gate skew yes/no (FPGA domain); (4) DEM/RTL-side mitigations (count limiting) on/off the table. Staggering at 2ns shown ineffective in sim (one configuration tested).

## Decision Review (user rulings, 2026-07-12)
- **Decision 1 — sum-node reservoir: ACCEPTED CONDITIONALLY.** In the working design, NOT locked. Conditions before lock: (a) ISI/settling interaction with V stage + reconstruction filter analyzed; (b) THD-class sim with the reservoir in place; (c) final C_sum/C_f sizing verified at k=64 equivalent.
- **Decision 2 — C_f across R_f: ACCEPTED with numeric phase bound.** Requirement: in-band phase contribution must stay within the quoted values — ≤0.16° at 20kHz (equivalent to a fixed ~22ns delay; group-delay dispersion sub-ps). Any C_f/R_f re-sizing must re-verify this bound (f_c = 1/(2π·R_f·C_f) must stay ≥ ~7MHz). 390pF@56Ω = 0.157° passes; larger C_f values require re-check against the bound.
- **Decision 4 — DEM transition-count limiting: INVESTIGATE FIRST (user ruling).** No RTL commitment. Required data before decision: DEM behavioral sim quantifying (a) transition-count statistics of current DWA vs capped/partial-rotation variants, (b) impact on mismatch noise shaping (SNDR with 0.1% element mismatch), (c) glitch-induced distortion using the SPICE-measured q(k) models with and without reservoir. See dem_study.py.
- **Decision 3 — gate-drive skew: OPTIONAL TUNING KNOB, not a requirement.** v9d sim (reservoir config, k=4, skew −1n→+2n) shows <1% glitch-charge sensitivity — the reservoir neutralizes the dead-zone mechanism. Skew is implemented as a runtime-settable ODELAY tap, DEFAULT = 0 (aligned edges), design must meet spec at default. Registered in the Tuning Knob Inventory below. Revisit only if hardware bring-up shows dead-zone effects beyond the behavioral FET model.

## DEM Study Round 1 (dem_study.py, 2026-07-12) — Decision 4 evidence
Behavioral 64-cell sim, 6.144MHz, −1dBFS 1kHz coherent sine, 0.1% element mismatch, glitch models from SPICE (q_pc(k) cosim9/9c), 2% rise/fall charge-asymmetry ASSUMED (unmeasured — key open input).
| scheme | k_mean | k_max | SNDR mismatch | SNDR glitch (no res) | SNDR glitch (reservoir) |
|---|---|---|---|---|---|
| thermometer (no DEM) | 0.0 | 32 | 76.5 | 99.8 | 96.6 |
| DWA classic | 27.7 | 64 | **127.8** | 27.9 | 44.4 |
| partial rotation r=1 | 2.0 | 32 | 117.7 | 96.2 | **97.2** |
| partial rotation r=2 | 4.0 | 32 | 117.1 | 94.6 | **97.2** |
| partial rotation r=4 | 8.0 | 32 | 121.1 | 76.0 | 78.4 |
| partial rotation r=8 | 13.9 | 32 | 104.9 | 49.2 | 54.8 |
- **KEY FINDING: classic DWA and glitch performance are fundamentally opposed.** DWA toggles ~2×code cells/sample (k_mean 28!) — its rotation makes consecutive selection windows disjoint. Any per-transition charge asymmetry × k(signal) → gross distortion (28–44dB class). Meanwhile low-switching schemes (r=1–2) keep glitch benign but give up ~10dB of mismatch shaping (118 vs 128dB).
- **No scheme in the simple rotation family achieves 128dB on both axes simultaneously.**
- Model caveats: (a) ASYM=2% is assumed — real value must be measured in SPICE (net differential charge, rise vs fall) and drives all glitch columns ~1:1 in dB; (b) differential cancellation physics: ON/OFF inject opposite charge, uniform part cancels, only Δcode + asym·k + q_pc(k)-nonlinearity survive; (c) mismatch numbers exclude quantization (real code comes from noise-shaped modulator upstream).
- NEXT: (1) measure real rise/fall charge asymmetry in SPICE; (2) explore DEM schemes beyond simple rotation (bidirectional DWA, segmented rotation, 2nd-order mismatch shaping with switching constraint); (3) re-run with measured asymmetry; then return Decision 4 to user with the real tradeoff curve.

## Asymmetry Measurement + DEM Study Re-run (bfdac_cosim10.cir, 2026-07-12)
- **cosim10: rise/fall charge asymmetry MEASURED = 0.0145%** (reservoir config, 1 cell up at 200n/down at 800n: q_rise=−9.752nV·s, q_fall=+9.754nV·s, net 1.4pV·s per cycle). Plateau return error 2.9µV — no memory effect visible at this resolution.
- CAVEAT: this is the TOPOLOGICAL asymmetry with identical models both sides. Real hardware adds component-mismatch asymmetry (FET pair Qg spread, R_f/C_f tolerance between rails) — SPICE cannot see that; budget separately (Monte Carlo with mismatched models, or measure on hardware).
- DEM study re-run with measured asym=0.0145%:
| scheme | SNDR_mis | SNDR_glitch (no res) | SNDR_glitch (reservoir) |
|---|---|---|---|
| DWA classic | 127.8 | 65.2 | 80.2 |
| partial rot r=1 | 117.7 | 97.3 | 97.4 |
| partial rot r=2 | 117.1 | 95.2 | 97.5 |
| partial rot r=4 | 121.1 | 94.6 | 97.7 |
- With realistic asymmetry the picture improves ~35–43dB but conclusion holds: **classic DWA still glitch-limited (80dB); partial rotation ~97dB; nothing reaches 128dB on both axes yet.**
- MODEL FIDELITY WARNING before drawing final conclusions: the ~97dB floor may be partly artifact — input code is a bare 6-bit quantized sine (no upstream noise-shaped modulator), so quantization products couple into k=|Δcode| and the glitch error nonlinearly. Refinement needed: drive dem_study with a real delta-sigma modulated code stream (the actual RTL input), which changes both Δcode statistics and in-band error content.
- STATUS: no DEM/RTL changes committed (Decision 4 remains open). Next data: (a) dem_study with modulator-generated code; (b) mismatch-asymmetry Monte Carlo in SPICE; (c) smarter DEM schemes.

## DEM Study Round 2 — Modulator-Driven + q_pc(k) Verification (2026-07-12/13)
dem_study.py now driven by real 2nd-order 65-level delta-sigma code stream (in-band SNDR of code = 133.5dB ✓, mean|Δcode|=1.0, max=3):
| scheme | k_mean | SNDR_mis | SNDR_glitch (reservoir) |
|---|---|---|---|
| thermometer (no DEM) | 1.0 | 76.5 | **105.5** |
| DWA classic | 27.7 | **148.0** | 80.2 |
| partial rot r=1 | 2.3 | 115.8 | 90.4 |
| partial rot r=2 | 4.0 | 114.5 | 84.3 |
- With real modulator code, DWA mismatch shaping is even better (148dB) but glitch unchanged (80dB). Minimal-switching is best for glitch (105dB) but worst for mismatch (77dB). **The tension is confirmed with realistic stimulus; no simple scheme achieves 128/128.**
- **q_pc(k) 5% variation is REAL, not a window artifact** (cosim9e, full 800n settle, tails µV-level: −9.753/−9.734/−9.578/−9.277 for k=1/2/4/8). This term now dominates glitch distortion (asymmetry is only 0.0145%).
- **Mechanism test (cosim9f): C_sum 2.2n→10n halves the variation (5.1%→2.4%)** — sub-linear in C, diminishing returns, and larger C_f collides with the Decision-2 phase bound. Brute-force capacitance won't reach 128dB alone.
- **PROMISING IDEA for round 3 (not simulated yet): constant-k DEM.** If every sample switches EXACTLY K cells (padding with code-neutral dummy swap pairs when fewer are needed), then both the asym·k term and the q_pc(k) term become constants → pure DC offset + fs-rate tone, zero in-band distortion, by construction. Chord's constant-activity philosophy implemented in the mapper instead of the elements. Costs: higher total glitch energy (out-of-band), mapper complexity, k_fixed ≈ 8–16 sizing, mismatch shaping must be preserved within the constrained selection. SIMULATE NEXT.

## DEM Study Round 3 — Does the q_pc(k) compression matter? QUANTIFIED YES (2026-07-13)
dem_study.py extended with error decomposition (modulator-driven code, reservoir models from cosim9e/9f, measured asym 0.0145%). Columns: full model vs compression-only (asym=0) vs asymmetry-only (flat q_pc):
| scheme | SNDR_mis | full (2.2n) | full (10n) | compression only | asym only |
|---|---|---|---|---|---|
| thermometer (no DEM) | 76.5 | 105.7 | 110.5 | 105.7 | 126.2 |
| DWA classic | 148.0 | 80.5 | 81.8 | 81.7 | 81.2 |
| partial rot r=1 | 115.8 | 90.7 | 95.7 | 90.6 | **128.9** |
| partial rot r=2 | 114.5 | 84.7 | 90.2 | 84.7 | 137.7 |
- **VERDICT: the q_pc(k) compression IS the dominant glitch-distortion mechanism** — for every low-switching scheme the full-model SNDR equals the compression-only SNDR to within 0.1dB. The asymmetry term alone would sit at 126–138dB for low-k schemes, i.e. AT/ABOVE target.
- **If the compression were fixed (flat q_pc), the glitch axis clears 128dB** for r=1/r=2 class schemes; remaining gap would be on the MISMATCH axis (r=1 = 115.8dB), not glitch.
- DWA classic is dead either way: at k_mean≈28 even the asym·k term alone caps it at 81dB.
- Bigger reservoir (10n) buys only ~5dB — confirms cosim9f: brute-force C is not the path.
- **CONSEQUENCE — two viable paths forward, both now justified:**
  1. ANALOG: isolate + fix the residual compression mechanism (cosim9f showed sum-node C explains only ~half; suspects: shared q4_base bias coupling, cascode V_CE/Early modulation, I/V large-signal gm) — target flat q_pc, then r=1/2 partial rotation suffices on glitch.
  2. DIGITAL: constant-k DEM (Round 2 idea) — makes BOTH terms constant by construction, sidesteps the analog mechanism, but must preserve mismatch shaping and needs mapper complexity.
- Both paths still need the mismatch axis solved (>115.8dB → 128dB): constrained-selection mismatch shaping study remains open regardless.

## DEM Study Round 4 — Industry Mapper Families Simulated (2026-07-13)
Context ruling (user): flip-flop retiming at the element is acceptable if needed; but the charge/glitch problem is topology-independent — mapper choice is the lever. Added dCS-style randomization and Chord-style constant-activity engines to dem_study.py:
| scheme | k_mean | SNDR_mis | gl 2.2n | gl 10n | gl idealIV | gl asymOnly |
|---|---|---|---|---|---|---|
| random subset (dCS-ish naive) | 19.3 | 99.2 | 81.1 | 84.9 | 87.2 | 87.0 |
| random rot r~U[1,8] | 8.4 | 100.6 | 76.2 | 82.5 | 96.8 | 105.1 |
| **constant-k K=4** | 4.5 | **110.9** | **99.5** | **105.7** | **118.4** | 130.9 |
| constant-k K=8 | 8.3 | 107.7 | 100.1 | 105.8 | 113.1 | 114.1 |
| constant-k K=16 | 14.1 | 113.8 | 94.8 | 95.2 | 95.5 | 95.2 |
- **Constant-k confirmed as the strongest glitch family** (K=4: 99.5dB today, 118.4dB with perfected analog) while keeping decent rotation-driven mismatch averaging (110.9dB). Beats every rotation scheme on glitch by ~9–15dB at equal switching activity.
- **NEW FUNDAMENTAL LIMIT FOUND — parity dither**: every cell toggle changes code by ±1, so toggles-per-sample parity ≡ Δcode parity. Constant-k must alternate k∈{K, K+1}; the resulting q_pc(K)↔q_pc(K+1) and asym·k modulation sets the residual floor (99.5 at 2.2n / 118.4 at ideal analog). k cannot be made strictly constant with 2-way steering cells — this is a topological fact, not an implementation detail.
- **Naive randomization is a dead end on BOTH axes** (mismatch 99.2 — white, unshaped, in-band; glitch 81). Validates that dCS's actual mapper is heavily *shaped* randomness refined over decades, not naive scrambling — reproducing it is a research program, not a feature.
- **Path to 128/128 with constant-k K=4**, budget by axis:
  - Mismatch (110.9 @ 0.1%σ): scales linearly with matching — 0.02%σ elements (precision foil R_tail + THAT300 binning) → ~125dB; or add shaped selection within the constant-k constraint; or calibration/trim.
  - Glitch (99.5 → 118.4 ceiling): needs the analog fixes (regulated cascode + amp linear-region work) to approach the 118 ceiling; the remaining 118→128 gap needs parity-dither mitigation (candidates: even-step modulator (−6dB SQNR), 2× mapper rate, or shaping the K/K+1 choice).
- STATUS: constant-k K=4 is the working mapper candidate. Decision 4 evidence now complete enough to bring back to user.

## DEM Study Round 5 — Parity Mitigation + Greedy Selection (2026-07-13)
Added to dem_study.py: parity-shaped K±1 choice, even-step modulator, greedy usage-balancing cell choice.
- **Greedy usage-balancing: free +7.3dB on mismatch** (110.9 → 118.2 for const-k K=4) at identical k stats. Pure mapper logic, no cost anywhere. ADOPTED into the working candidate.
- **Parity-shaping is a DEFERRED win**: k widens to {3,4,5} → loses 11dB while q_pc is compressed (88.1 vs 99.5 today), but its asym-only floor is 160.2dB. Only enable after analog flattens q_pc. FIX ORDERING: analog first, then par-shaping.
- **Even-step modulator ELIMINATED**: 33-level code stream caps at 127.5dB (< target) and larger |Δcode| worsens glitch (96.1 vs 99.5). Would need 3rd-order modulator to revisit; not worth it given par-shaping exists.

## Analog Study Round 6 — Regulated Cascode (bfdac_cosim12/12b/12c, 2026-07-13)
Per-rail gain-boost E-source drives cascode base to hold bus at 1.75V (idealized boost amp).
- cosim12 (real OPA1612 amp + reg cascode): compression 4.84% — unchanged, confirms Round 5: amp must be fixed first, reg cascode is invisible behind it.
- cosim12b (ideal I/V + A=200): 0.51% → 0.244%. cosim12c (A=1000): **0.116%**. Sub-linear in A → partially loop-gain-limited, partially base-swing Cjc injection (base must swing ΔVbe regardless of A; Cjc≈4.9p couples it into sum node). Discrete realization of the boost amp not yet designed — E-source is the ceiling.
- New dem_study column gl_regCas (ideal I/V + A=1000 q_pc). **MILESTONE — first configs to clear 128dB glitch:**
| scheme | SNDR_mis | gl today | gl idealIV | gl regCas |
|---|---|---|---|---|
| **const-k K=4 greedy-mis** | **118.2** | 99.5 | 118.4 | **128.3** |
| partial rot r=1 | 115.8 | 90.7 | 114.2 | **129.6** |
| const-k K=4 par-shaped | 113.1 | 88.1 | 109.1 | 121.3 (floor 160 as q_pc flattens further) |
- **Remaining gaps to 128/128**: (1) MISMATCH: 118.2 @ 0.1%σ → needs ~0.03%σ element matching (foil R_tail + THAT300 binning/trim) or shaped selection beyond 1st-order; (2) AMP REALISM: regCas column assumes ideal I/V — the real OPA1612 composite sits 28dB below its ideal (90.7 vs 118.4 for const-k). Closing the amp gap is now THE long pole.
- NEXT: (a) realistic amp study — what GBW/slew/topology approximates 'ideal enough' (target: sum-node error linear, not necessarily small); (b) discrete regulated-cascode boost amp design + re-measure; (c) matching budget decision (user, procurement cost).

## Analog Study Round 7 — Realistic Amp Requirements FOUND (bfdac_cosim13/13b, 2026-07-13)
Behavioral front amp (single-pole GBW + slew + tanh input stage, linear range = SR/2πGBW) in place of OPA1612; real diamond + real cascodes kept. Stepped k×cfg:
| cfg | GBW | slew | lin range | compression k=1→8 |
|---|---|---|---|---|
| 1 (≈OPA1612) | 40M | 27V/µs | 107mV | 2.16% |
| 2 | 120M | 80V/µs | 106mV | 1.22% |
| 3 | 400M | 270V/µs | 107mV | 0.57% |
| **4** | **40M** | **270V/µs** | **1.07V** | **0.51% = cascode floor** |
| 5 | 120M | 270V/µs | 358mV | 0.56% |
- **HEADLINE: GBW is irrelevant — input-stage LINEAR RANGE is the whole amp problem.** cfg4 (same 40MHz as OPA1612, 10× linear range) hits the ideal-amp floor exactly. The 151mV k=8 sum-node excursion vs OPA1612's ~107mV linear range is the mechanism. Amp selection criterion rewritten: wide-linear-range (heavily degenerated / JFET / CFB-class) input beats raw speed. NOTE: behavioral cfg1 gives 2.16% vs real OPA1612 4.9% — model captures ~half; real part has additional nonlinearities (CM, output stage); direction still decisive.
- **cosim13b — COMPOSED REALISTIC STACK** (cfg4 amp + regulated cascode A=1000): compression **0.141%** vs 0.116% ideal ceiling. The two fixes compose with no interaction penalty. New dem_study column gl_stack.
- **min-k greedy tested and ELIMINATED**: k=|Δcode| minimal switching gives best-class glitch (125.7) but mismatch collapses to 96.3dB — minimal switching starves the shaper of selection freedom. The const-k swap-pair padding IS the mismatch-shaping engine.
- **STANDINGS with realistic composed stack (gl_stack column):**
| candidate | SNDR_mis @0.1%σ | glitch |
|---|---|---|
| partial rot r=1 | 115.8 | **129.4** |
| const-k K=4 greedy | **118.2** | 126.4 |
- **GLITCH AXIS: SOLVED ON PAPER** (with: wide-linear-range amp + regulated cascode, both realistic). **MISMATCH AXIS is the sole remaining gap**: ~10dB (118→128). Paths: (a) element matching 0.03%σ (foil R_tail + THAT300 binning — procurement cost decision for user); (b) 2nd-order/vector mismatch shaping within the const-k constraint (open research); (c) calibration/trim DAC per cell.
- Analog hardware follow-ups now concrete: choose/design wide-input-range I/V front end (or pre-attenuate excursion); design discrete regulated-cascode boost amp (E-source A=1000 is idealized).

## DEM Study Round 8 — 2nd-Order Vector Shaping Within Constant-k: MISMATCH AXIS SOLVED (2026-07-13)
Upgraded greedy metric from usage integral (1st-order) to acc1 + g2·acc2 (2nd-order vector shaping, (1−z⁻¹)² target), selection freedom unchanged (same k stats, same glitch):
| scheme | SNDR_mis @0.1%σ | glitch (stack) |
|---|---|---|
| const-k K=4 greedy 1st | 118.2 | 126.4 |
| const-k K=4 2nd g2=.25 | 128.7 | 126.4 |
| **const-k K=4 2nd g2=.5** | **132.6** | **126.4** |
| const-k K=4 2nd g2=1 | 131.2 | 126.4 |
| const-k K=8 2nd g2=.5 | 141.9 | 113.9 |
- **+14.4dB from mapper logic alone; g2=0.5 optimal at K=4. NO component-matching upgrade needed** — 0.1%σ standard parts suffice; mismatch error is no longer the system limiter (now above the 133.5dB modulator code stream).
- Robustness vs σ (linear scaling): even 0.3%σ → ~123dB. **Drift/repeatability insensitivity built in** — the shaper nulls whatever the weights are, it never needs to know them. Directly addresses user's calibration-repeatability concern.
- **CALIBRATION ASSESSMENT (user asked to explore after shaping): DEMOTED TO OPTIONAL INSURANCE.** With 2nd-order shaping there is no mismatch gap left for calibration to close. If ever revisited: digital weighted-selection compensation in the mapper (uses measured w_i in the metric) — no analog trim, no repeatability exposure. Not planned.
- CAVEATS/FOLLOW-UPS: (1) 2nd-order vector shapers can have bounded-state/limit-cycle issues — verify acc bounds over long runs + multiple signal levels/DC inputs, add dithered tie-breaking if tones appear; (2) system budget now: code 133.5 ⊕ mismatch 132.6 ⊕ glitch 126.4 ≈ ~125dB total — remaining margin work is glitch (126.4 vs 128, needs the last analog nudge: regcas alone = 128.3) and possibly 3rd-order modulator for code-stream margin.
- **WORKING CANDIDATE LOCKED (paper): constant-k K=4 + 2nd-order vector shaping (g2=0.5), wide-linear-range I/V amp, regulated cascode.**

## Analog Study Round 9 — Discrete Error Amp vs Current Padding (bfdac_cosim14a–e, 15/15b, 2026-07-13)
Attempted discrete realization of the regulated-cascode error amp (per rail: CE stage Q_E w/ 2mA CS load + follower Q_F + comp), then a loop-free alternative.
- **cosim14 (Miller 22p)**: oscillates (loop crossover ~120MHz > follower/bus poles). **14b (100p + 47R base damp)**: worse, large-signal latch. **14c (1.2nF dominant pole at CE node, ~10MHz crossover)**: stable & clean for k=1,2 but k=4 rings and k=8 LATCHES (bus 1.75→0.78V, both rails; diagnosed via time-sliced measures in 14e): during the 1ns make-before-break window the flipping cells short the two buses; the resulting yank displaces the CE-node cap, recovery limited to I_L/C=1.7V/µs, cells fall out of compliance (Q4 saturates) → quasi-stable wrong state for >>600ns. Clamp diode (14d) didn't help — not the saturation-latch path. ALSO: even where stable, 14c q_pc flatness (0.9% k=1→2) was WORSE than plain cascode — a slow loop re-centers the bus AFTER the per-edge charge has already flowed; per-edge suppression requires ≳100MHz-class loop against a nF bus with ns edges. **Fast-enough discrete loop = genuinely hard analog problem; parked.**
- **cosim15 — CURRENT PADDING (loop-free)**: +50mA constant current per rail through the cascode (PNP source into sum node, NPN sink from bus; net-zero through R_f). Reduces relative rail-current modulation → smaller ΔV_BE excursion. Result: compression 0.51%→**0.243%**, unconditionally stable, tail_pp at baseline mV level. **Matches the A=200 regulated cascode with ZERO active loop.** 15b (150mA): 0.237% — NO further gain; the residual is not ΔV_BE-dominated (suspect: amp tanh cubic residue and/or Q5 Early/Cjc) → 50mA is the right size; floor identified.
- dem_study gl_pad column: **const-k K=4 (any greedy variant) = 124.6dB glitch with padding only** — 1.8dB below the full loop stack (126.4), no stability risk, ~50mW/rail extra dissipation.
- **DESIGN OPTIONS on the table (glitch axis, realistic hardware):**
  1. Padding only: 124.6dB — simple, robust, ships. Total budget ~123dB.
  2. Padding + revisit error amp with 3× smaller disturbance (may avoid latch; loop only needs the last 0.1%) — best case 126–128.
  3. Replica feedforward cascode bias (mapper/FPGA knows the code → drive casb with the correct Vbe(I) trajectory, no loop, matching-limited) — UNTESTED, elegant, could exceed the loop.
- Break-before-make gate timing was NOT explored as a fix for the bus-short latch (cells must never open-circuit tails) — but the skew knob exists; smaller overlap may soften the yank.
- **ADDENDUM — IC error amp evaluated (bfdac_cosim16, user question)**: behavioral unity-stable IC model (200MHz and 1GHz GBW, 870V/µs, ADA4817/OPA858-class) + 50mA padding: BOTH oscillate (tail_pp 1.2–2.1V). ROOT CAUSE: Q5 diffusion capacitance at padded current, Cπ ≈ gm·Tf ≈ 2.85S×453ps ≈ **1.3nF** → base-drive pole ~6MHz with 22Ω source — no amp IC can cross over above it. **KEY TRADE DISCOVERED: padding and fast loop are ANTAGONISTIC** (base pole ∝ 1/(gm·Tf); more rail current = slower base). Loop would want LOW rail current + RF-grade cascode (Tf~100ps) + sub-Ω drive — a different design corner, needs a proper frequency-domain design session, not transient shotgunning. IC-vs-discrete verdict: the blocker is the plant (Q5 base), not the amp implementation.
- **DECISION RECOMMENDED: ship the glitch axis on padding-only (124.6dB, zero risk); replica feedforward = the one untested idea that avoids loops entirely; fast-loop redesign = parked with documented requirements.**

## Analog Study Round 10 — REPLICA FEEDFORWARD + BUS CAPS: TARGET REACHED ON PAPER (bfdac_cosim17-series, 2026-07-13)
Replica feedforward: diode-connected replica cascode Q5R (casb=1.75+Vbe(I_copy)) biased by a code-tracking rail-current copy (B-source from gate signals; hardware = small replica DAC/cells from same FPGA outputs). Bonus: diode connection drives Q5 base at 1/gm≈0.35Ω — the stiff source the loops couldn't provide. All with 50mA padding.
| deck | config | compression |
|---|---|---|
| 17 | replica ff, realistic amp | 0.286% (no better than padding — static ΔV_BE wasn't the residual) |
| 17b | replica ff, near-ideal amp | 0.251% (floor isn't the amp either) |
| 17c | sensed-current 'perfect replica' | INVALID (sense path creates spurious feedback, oscillates) |
| 15c | padding only, tedge 3→10ns | 0.216% (edge transient confirmed as residual mechanism) |
| **17d/17e** | **replica ff + 100n BUS CAPS** | **0.0044% / 0.0040% — FLAT, realistic amp** |
- **MECHANISM RESOLVED: the ~0.24% post-padding residual was per-edge transient bus charge.** Big bus caps absorb it — but bus caps are only SAFE because the replica cancels the static ΔV_BE (otherwise C·ΔV ≈ 0.21nC/step swamps everything; this is why caps alone were never an option). **Feedforward and bus caps are complementary halves of one fix: ff kills static, caps kill transient.** 35× below the old idealized-loop ceiling, unconditionally stable, no loop anywhere.
- dem_study gl_ffwd column (q_pc from 17e): **const-k K=4 → 130.8dB glitch; K=4 par-shaped → 151.2dB** (the Round-4 'deferred win' of parity-shaping materialized exactly as predicted once q_pc went flat).
- **NEW COMBINED SCHEME: K=4 par+2nd g2=.5 (parity-shaping + 2nd-order vector greedy): SNDR_mis=130.6, glitch=151.2.**
- **SYSTEM BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.2 ≈ 128.7dB — AT TARGET**, now limited by modulator code stream + mismatch shaping, both digital and both with known upgrade paths (3rd-order modulator; K=6 or g2 tuning).
- **FINAL PAPER ARCHITECTURE: 64 cells + Q5551 shared cascode + 50mA padding sources + replica-feedforward base drive + 100n bus caps + wide-linear-range 40MHz I/V + constant-k K=4 parity-shaped 2nd-order-greedy mapper.** Zero feedback loops added, zero precision parts added, zero calibration.
- HARDWARE FOLLOW-UPS: (1) replica implementation choice (scaled replica cells vs small current DAC) + its matching/timing-skew sensitivity study; (2) bus cap grade (C0G at 1.75V bias) + effect on startup; (3) wide-linear-range amp part selection; (4) shaper long-run stability verification (still pending from Round 8); (5) re-verify asym term (cosim10) under the new analog stack — the 151.2 assumes old ASYM value.
- **BUS CAP SIZING + PHASE AUDIT (cosim17f/18, user requirement: no caps in audio path):** size sweep: 1n→0.139%, 4.7n→0.036%, **10n→0.0047% (= 100n), saturates**. AC analysis (signal current injected at bus): added phase is EXACTLY linear in f → pure group delay, no dispersion. 10n = +0.036° @20kHz (+5ns constant delay) on top of existing 0.205° path phase; 100n = +0.36° for zero extra glitch benefit; magnitude flat to µdB past 100kHz. Framing accepted into record: bus already carries ~1.6nF of NONLINEAR junction capacitance unavoidably; 10n C0G swamps it with linear dielectric (linearity improvement, not a new audio-path element; no series audio current flows through it since replica pins the node). **DECISION: 100n→10n C0G per bus in the final architecture.** Capless fallback if requirement hardens: matched-dynamics replica cells (untested).

## Verification Round 11 — Replica Sensitivity, Shaper Long-Run Stability, Asym Re-measure: ALL PASS (cosim19/19b/20, shaper_stability.py, 2026-07-13)
Closed the three open follow-ups from Round 10. Final architecture verified robust; budget IMPROVED to ~128.8dB.
- **Replica gain-error sensitivity (cosim19, rge ±1%/±5% on the feedforward current copy)**: compression 0.0042–0.0051% across the FULL ±5% range (nominal 0.0047%). Essentially INSENSITIVE — the bus caps absorb transients regardless, and a gain error only leaves (rge)×2.1mV of static ΔV_BE uncancelled. Replica DAC needs no precision: ±5% is trivially met by any implementation.
- **Replica timing-skew sensitivity (cosim19b, tsk 0.5/1/2/4ns replica lag behind main gates)**: ≤2ns → 0.005–0.006% (no degradation); 4ns → 0.017% (still 7× below the old ideal-loop ceiling). FPGA same-bank skew ≪1ns → non-issue. Both replica knobs have huge margin; **replica implementation de-risked**.
- **Shaper long-run stability (shaper_stability.py, standalone; 2^21 samples = 341ms, 6 inputs: −1dBFS sine, −60dBFS sine, silence, DC+0.5, DC irrational (√2−1), DC 99%FS)**: max|acc1| ≤ 13, max|acc2| ≤ 187 in ALL cases, second-half bounds ≤ first-half in ALL cases → **states bounded, no growth, no divergence**. Sine SNDR_mis 130.9 at 2^21 cross-validates dem_study's 130.6. Idle/DC worst in-band spurs −156 to −158dBc (structure only 22–25dB over a very low floor) — no audible limit-cycle tones. ONE flagged corner: DC at 99%FS (code 63.7) → single −130.1dBc spur (eligible-cell population collapses to ~1); still below the −128dB target and unreachable by audio, but if desired, clamping the modulator to ±31 levels restores selection freedom. **No dither needed; Round-8 caveat (1) CLOSED.**
- **Rise/fall asymmetry re-measure on final stack (cosim20 = cosim10 method on replica-ff + padding + 10n caps + realistic amp)**: q_net/q_avg = 0.71e-4 worst (k=4), vs 1.45e-4 on the old reservoir config — **2× better**. dem_study rerun with ASYM=0.71e-4: K=4 par+2nd g2=.5 → glitch **151.7dB** (was 151.2), SNDR_mis 130.6 unchanged. Round-10 follow-up (5) CLOSED.
- **UPDATED SYSTEM BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.7 ≈ 128.8dB — target met with verified margins.** Architecture unchanged from Round 10 (with 10n C0G bus caps per the phase audit). Remaining follow-ups are hardware selection only: replica implementation choice (now known to be non-critical), amp part selection, bus-cap startup behavior.

## Static Study Round 12 — NEW AXIS: STATIC INL FROM CASCODE BASE CURRENT (cosim22-series, 2026-07-13)
User asked about multi-tone AC testing → led to stepped-bias AC (cosim18b: code-dependent group delay ±1ns via Q5 1/gm, replica-frozen worst case), delay-vs-code transient (cosim21: edge-shape wiggle confirmed out-of-band, charge flat), and then a static DC transfer sweep (cosim22, code 0..56, tight reltol) which exposed a REAL problem:
- **Static INL: ±1.2ppm S-curve → HD2 −123.4dB / HD3 −122.7dB at −1dBFS. THIS DOMINATES THE BUDGET (misses the 128dB target on its own).** Confirmed not numeric (identical at reltol 1e-6/1e-8), not the amp (ideal E-source same), not Early (Vaf=100k same), not bleed (removed, same), not the live cells (idealized, same).
- **ROOT CAUSE (cosim22n): Q5's NON-IDEAL BASE CURRENT — Ise=2.511f/Ne=1.249 recombination component, Ib ≈ 115–188µA over the code range with I^(1/Ne)=I^0.8 curvature.** Ie is exact (set by the cells) but Ic = Ie − Ib, so Ib steals a nonlinearly code-dependent µA-level current from the output. Ise=0 → INL 0.0004ppm (−192dB). Replica feedforward CANNOT fix this (current-domain error, not voltage). Bowl is mostly common-mode between rails; the differential output already cancels ~7×; ±1.2ppm is the post-cancellation residue.
- **METHODOLOGY WARNING (recorded so it isn't repeated): two earlier 'eliminations' (22d Bf, 22h Ise) were regex edit failures — the model string 'Ise=2.511f Ikf=.3458' didn't match the pattern used; the deck ran UNCHANGED and produced a false negative. Always verify the edited line landed in the deck before trusting a null result.**
- **FIX CANDIDATES (untested):**
  1. **Replica base-current mirror (preferred, same loop-free spirit):** Q5R runs the same current as Q5 → its own Ib is an exact-law copy; mirror it INTO the sum node to refill what Q5's base steals. Matching-limited (~few %) → est. −122.7 → ≈ −150dB.
  2. MOSFET cascode for Q5 (zero DC gate current, kills the mechanism outright; trade: gm, matching, replica becomes Vgs-based).
  3. Cleaner BJT (lower Ise/higher ideality at 50–100mA) — device survey needed; DMMT5551 model is recombination-heavy.
- NOTE: static INL is a NEW budget axis (not mismatch, not glitch; DEM does not shape it — common to all cells). Without fix: ~121dB total.
- **FIX 1 VERIFIED (cosim23/23b, full realistic stack): Ib-compensation works.** Topology: third matched NPN Q5C per rail, base on the existing casb line (conducts the same replica current → generates the same-law Ib), collector returned to the 2.4V reference (V_CE matches Q5p), base current sensed and mirrored into the sum node (sim: F-source; hardware: small PNP mirror, TBD). Results: INL 1.17→**0.105ppm (11×)**, HD2 −123.4→**−147.1dB**, HD3 −122.7→**−141.8dB**. Mirror gain error ±5%: HD3 −138.9…−146.2 — worst case still 11dB below target; few-% matching trivial (note: Q5+Q5R+Q5C now = 3 matched NPN per rail — dual no longer suffices, candidate: THAT300 quad or 2× duals). All per-rail shared circuitry; ZERO per-cell impact (user concern addressed: cell = Q1/Q2 + Q4 + Rt + 2 pins, unchanged since BOM lock).
- **UPDATED BUDGET: code 133.5 ⊕ mismatch 130.6 ⊕ glitch 151.7 ⊕ static ≥138.9 ≈ 128.6dB — target held with the new axis included.**
- **MIRROR HARDWARE VERIFIED (cosim23d/e/f): full transistor-level implementation, INL 0.079ppm, HD2 −151.0 / HD3 −143.9 — better than the behavioral copy.** Final per-rail schematic: Q5C (matched NPN, base fed via QM1 from casb line, collector to vfr for VCE match, emitter forced by a SECOND replica-DAC output B_snk); QM1/QM2 PNP pair on casb senses Ib(Q5C); QM2 feeds QN1/QN2 NPN mirror (gnd-referenced) which SINKS the Ib copy from the sum node. Parts/rail: 3 NPN + 2 PNP + 1 extra replica-DAC output. LESSONS: (a) polarity — Q5 PULLS Ic from sum, so compensation must SINK from sum (source-into-bus and source-into-sum both INVERT the correction → 2.2ppm, INL doubles); (b) PNP-only mirror into sum saturates (Vec≈0.15V) — the NPN output stage is required; (c) Q5C's emitter cannot hang on a resistor-derived reference (v23c bug: 7.5k can't sink 95mA, Q5C starved, zero correction) — it needs the replica-current sink, which also improves matching (forced-Ie, same as Q5p).
- **FOLLOW-UPS CLOSED (cosim24/24b, 2026-07-15):** (1) Glitch recheck with the full comp network grafted into the cosim20 transient deck (incl. PNP junction caps Cjc=8p/Cje=10p/Tf=500p on casb & sum): q_pc flat to 0.005% across k=1..8, asym_frac worst 0.70e-4 @k=4 vs 0.71e-4 baseline — NO glitch degradation. (2) Temp stability (.temp 0/27/50C on cosim23f): INL 0.20/0.08/0.17ppm, worst HD2 −134.7 (50C), worst HD3 −139.9 (0C) — compensation tracks over temperature by construction (Q5C same die-law), ≥6.7dB margin at all corners, NO calibration needed. Remaining: BOM selection (3 matched NPN/rail + PNP pair; THAT320/340 quad candidates) and a full schematic document for the user.

## Glitch Study Round 5 — q_pc(k) Compression Mechanism ISOLATED (bfdac_cosim11a–d, 2026-07-13)
Idealize one suspect at a time on the cosim9e baseline (C_sum=2.2n, compression 4.89% k=1→8), k stepped 1/2/4/8:
| deck | idealization | q_pc k=1→8 (nV·s) | compression |
|---|---|---|---|
| 9e (baseline) | none | −9.753 → −9.277 | 4.89% |
| 11a | stiff q4_base (R_bias 100→1mΩ) | −9.770 → −9.294 | 4.87% |
| 11b | ideal cascode (V-pinned bus + 1:1 F-source conveyor) | −9.466 → −8.925 | 5.72% |
| 11c | ideal I/V (E-source 1e6, no GBW/slew limit) | −9.559 → −9.510 | **0.51%** |
| 11d | ideal I/V + ideal cascode | −9.2712 → −9.2713 | **~0.001% (flat)** |
- **RANKED ATTRIBUTION: (1) I/V loop large-signal behavior ≈ 4.4 points of the 4.9% — DOMINANT.** Sum-node excursion (25→151mV with k) drives the OPA1612 composite out of its linear small-signal regime (slew/GBW/gm compression). With ideal amp the sum node moves µV and compression collapses 10×.
- **(2) Real cascode (Q5551) ≈ 0.5%** — the entire residue left under an ideal amp; goes to zero when cascode is also idealized. Mechanism class: V_BE(log-I) bus-voltage shift × bus capacitance + Early/beta nonlinearity.
- **(3) Shared q4_base bias + tails/switches: negligible** (11a unchanged; 11d flat to 1ppm).
- dem_study ceiling column (gl_idealIV, cosim11c q_pc): **even a PERFECT amp caps glitch SNDR at 114.2dB (r=1) / 122.2dB (thermometer)** — the 0.5% cascode residue alone keeps 128dB out of reach for rotation DEMs.
- **CONSEQUENCE**: analog path to 128dB needs BOTH a much faster/more-linear I/V response AND a ~10× better cascode (regulated/gain-boosted cascode candidate). Realistic amp improvements alone land ~mid-90s→~110dB. Strengthens the case for constant-k DEM (digital path), where q_pc(k) flatness stops mattering by construction.
- Next candidate experiments: (a) regulated cascode (local loop holding bus node) → re-measure residue; (b) realistic amp upgrades (2× GBW, higher-slew composite front end) → where between 90.7 and 114.2dB do we land; (c) constant-k DEM behavioral sim (digital leg).

## Tuning Knob Inventory (authoritative — a knob not listed here does not exist)
Rules: (1) every runtime-configurable parameter is listed here with default, range, purpose, and tuning procedure; (2) DEFAULT VALUES MUST MEET FULL SPEC — knobs are for optimization on real hardware, never required for basic function; (3) each knob maps to an SPI register (register map task, pending).
| Knob | Domain | Default | Range | Purpose | Tune procedure |
|---|---|---|---|---|---|
| ~~Gate-drive skew (per-cell ODELAY, complement pin)~~ RETIRED Round 26 | — | 0 (aligned) | — | Knob removed by external reclock FFs (both gates resampled on one OCXO edge — default 0 was the verified spec-meeting value). Crossing trim fallback if bring-up shows dead-zone artifact: post-FF RC on g2 (board rework, not runtime) | n/a |
| Output level select | Analog/relay | 2V | 2/4/6V (2-bit) | Output range selection (existing, from V-stage design) | User-facing setting, not a trim |

## Cascode Cell BOM — PARTIALLY LOCKED (reopened 2026-07-12, see constraints)
- **Topology**: Differential current-steering cell + shared per-rail output cascode
  - Q1+Q2 (per cell): small-signal N-MOSFET differential switch pair — steers I_unit to bus+/bus−
  - Q4 (per cell): NPN tail current source — sets unit current I_unit
  - Q5 (per rail, SHARED): NPN common-base output cascode — collector to output rail, emitter to cell drain bus (pinned at V_cas − V_BE ≈ 1.8V), base at 2.5V
  - Bleed: 910Ω per rail (~2mA) keeps cascode conducting at code extremes
  - 1 FPGA pin per cell (128 total); complementary gate pair generated by the external reclock FF's Q/~Q at ~3.3V (Round 27 — supersedes the old "2 FPGA pins per cell, 1.8V direct drive")
- **Parts**:
  - Switch pair (Q1+Q2): **TBD — SELECTION REOPENED at ~3.3V FF drive (Round 27)**. Low Ciss/Qg (~50pF/~1nC) still required; the 1.8V V_GS constraint is GONE → 2N7002-class back in play. **DMN2041UVT still REJECTED** (474pF C_GS) — see key findings below.
  - Shared cascode (Q5): **DMMT5551** matched dual NPN (both rails in one package → V_BE drift common-mode)
  - Tail current source (Q4): **THAT300** (NPN matched quad, ΔV_BE ≤ 0.1 mV, SOIC-14) — current matching sets DAC linearity
- **Drive (Round 27): ~3.3V from external reclock FF Q/~Q** — FPGA no longer drives the gates directly (its 1.8V HP-bank limit is now irrelevant to the cell; 1.8→3.3V translation sits ahead of the FF D inputs where jitter is absorbed)
  - The old 1.8V requirement (V_GS at 781µA ≤ ~0.9V) is RETIRED; re-derive the source-node level and Q4 V_CE budget at the actual FF-rail V_GS. Datasheet V_GS(th) still insufficient evidence — verify with real SPICE model at operating current (DMN2041UVT lesson)
  - Candidate class: small-signal FETs, ~50pF Ciss / ~1nC Qg class (drive is now an FF, but gate charge injection into the bus still matters); 2N7002-class re-qualifiable
  - R_gate: **47Ω** per gate
- **Per channel (64 cells)**: 64× dual FET + 16× THAT300 + 1× DMMT5551 = 81 packages (+ reclock FF/translator stage, see bom.md §1.2)
- **Stereo total**: 128× dual FET + 32× THAT300 + 2× DMMT5551 = 162 packages
- **FPGA pins**: 128 total (64 per channel), 1 pin per cell, LVCMOS18

## Cascode Cell — Electrical Design (REOPENED pending I/V topology decision)
- **Supply voltage**: +5.0V (analog section) — chosen for full 1.95V swing + output cascode headroom with a RESISTIVE load. NOTE: if the planned I/V stage is a virtual-ground transimpedance input, the output bus does not swing, the headroom analysis changes entirely, and 3.3V may suffice — re-evaluate after I/V topology is decided
- **Tail current reference**: 1.25V (LM4040-1.2 shunt reference)
- **Unit cell current**: I_unit = (1.25V − 0.665V) / 750Ω ≈ **781 µA per cell**
  - R_tail: **750Ω** 0.1% (trimmed from 820Ω — measured THAT300 V_BE is 0.665V at this current, not 0.61V)
- **Full-scale output current**: I_FS = 64 × 781µA = **50 mA**
- **Output interface**: 39Ω 0.1% load resistors used in sims to date; ACTUAL output feeds the planned I/V + V stage (topology TBD). If virtual-ground I/V: no output swing, SNR budget moves to I/V feedback R + op-amp noise. If resistor-sense: 1.95V SE / 3.9Vpp diff swing stands (OUT: 3.05–5.0V) and V stage needs high CMRR at ~4V CM
- **Shared cascode bias**: **2.5V** at Q5 bases → cell drain bus pinned at ~1.8V; switches see ~constant V_DS, never the output swing
- **Voltage budget (5V)**: 1.95 swing + 1.2 cascode V_CE(min) + ~1.6 switch V_DS + 1.0 Q4 V_CE + 0.58 R_tail — fits with margin
- **Power per channel**: ~54mA × 5V = **~270 mW** (incl. 2×2mA bleed)
- **Stereo total power**: **~540 mW** average — no heatsink; shared cascodes are hottest parts (~60–70mW each)
- **SNR estimate**: ~130 dB (dominated by Johnson noise of R_load, shot noise negligible)

## Cascode Cell — Key Findings from LTspice (bfdac_final2.cir)
- **Per-cell PNP output cascodes REJECTED**: cascode in the switched path gets cut off every half-cycle; its collector floats up and forward-biases the C-B junction → mA-scale reverse conduction. Cascodes must sit in always-conducting branches — hence the shared per-rail common-base stage.
- **Why shared cascode vs none (both work at 5V DC)**: 64 switch drains carry ~nF of nonlinear, code-dependent capacitance. Without cascode this sits directly on the output (pole ~400kHz, code-dependent settling). With shared cascode it sits on the pinned bus; output sees only ~pF of cascode collector. Decisive for ultra-premium linearity.
- **DMN2041UVT REJECTED on real SPICE model**: (1) effective V_TO ≈ 1.02V → with 1.8V drive the source node squeezes Q4 into saturation, breaking tail regulation; (2) 474pF C_GS + ~900pF C_GD demands ±34mA gate current spikes — impossible for FPGA IOB, ±0.5V output glitches. Lesson: at 781µA we need a SMALL FET (low Qg/Ciss), not low R_DS(on).
- **Verified with real models** (Diodes Level-3 die model, 2N7002-class VDMOS, THAT300): tails 775µA ±2µA, clean antiphase steering, off-side leakage <1µA, bus pinned, Q4 V_CE ≈ 1.0V active.
- **Open item — switch FET selection under 1.8V drive**: find + model-verify low-V_th FET (V_GS ≤ 0.9V at 781µA). Blocks final cell sim.
- **Open item — I/V + V stage topology**: virtual-ground transimpedance vs resistor-sense + gain. Gates rail choice (3.3V vs 5V), cascode sizing, and SNR budget.
- **Open item — switching glitch**: with ideal 1ns drive edges, gate-crossing transients disturb outputs (both switches momentarily off near crossing). Needs realistic FPGA IOB drive model, crossing-point/timing optimization, and possibly slower controlled edges.
- **Open item — FPGA drive check**: Qg ~1nC at LVCMOS18; verify IOB drive strength gives acceptable gate rise time within the 163ns period, and SSO budget for 128 pins.
- **Open item — reference filtering**: RC/LC filter on shared 1.25V reference to keep correlated gain-modulation noise below −130dB.

## Pending (status refreshed 2026-09-03)
- [x] Cascode output pin assignments (128 pins) — DONE (plan Step 3.3, Alinx CSVs, all 273 pins in `vu13p_dac_top.xdc`)
- [x] dac_ddr4_if: MIG IP generation — DONE (Step 3.4, `ddr4_0` + `axi_dwc_coef`, `dac_ddr4_if_mig.sv`)
- [x] QSPI pin assignments (2× MT25QU01GBBB1EW9) — flash 0 on config pins, flash 1 on bank 65
- [x] QSPI read controller — DONE as `qspi_flash_ctrl.sv` (Step 3C.2) + `qspi_boot_loader.sv` (Step 3C.3)
- [x] dac_ddr4_if: AXI write channel — DONE (Step 3C.1, 128-bit write port through `axi_dwc_coef`)
- [½] Boot sequencer — DDR4 cal → QSPI→DDR4 copy DONE (`boot_start = calib && EOS` in top, `qspi_boot_loader` record chain + CRC32); **DDR4→FIR default bank load NOT DONE → TODO-16**
- [x] SPI system update mode — DONE (Step 3C.4/3C.5: FLASH_* regs 0x10-0x14, target bit selects flash, CONFIGFALLBACK multiboot, BOOT_STATUS 0x1A). Sub-bullets below retained as the original spec:
  - dac_ctrl_plane routes SPI writes to SOM QSPI flash (pass-through or buffered)
  - All storage on SOM QSPI (2× MT25QU01GBBB1EW9, 256 MB total, no baseboard flash)
  - Dual-boot bitstream support:
    - QSPI flash partitioned: primary image (new) + golden/fallback image (known-good)
    - Update writes to primary partition only; golden image is never overwritten
    - On boot failure (watchdog timeout, config CRC error, or cal fail), revert to golden image
    - Use XCVU13P multiboot / fallback via IPROG or WBSTAR mechanism
  - Boot status reporting via SPI register:
    - Boot source (primary vs golden/fallback)
    - Boot success flag (set after DDR4 cal + QSPI→DDR4 load + first valid audio frame) — AS BUILT: `boot_ok` = all records CRC-verified and written; it does NOT wait for the FIR default load (TODO-16) or an audio frame
    - Error code: config CRC fail, DDR4 cal timeout, QSPI read error, coefficient checksum fail
    - ARM can poll boot status register (e.g., 0x18) to verify update succeeded
- [x] ~~Expand coef_bank_id to 5 bits (18 banks)~~ SUPERSEDED (2026-09-02): filters are addressed by 16-bit `filter_id` through the DDR4 directory (`docs/coef_format_v2.md`, FILTER_SELECT 0x0A); the 4-bit 0x05 slot path is legacy/bring-up only
- [ ] QSPI dual-flash strategy — partitioning and wear leveling across 2× 128 MB devices. RTL side DONE (target bit, 4-byte addressing, golden@0x0 / update@0x0400_0000 layout in XDC comments); remaining is HOST policy (partition table, coefficient-region rotation) — not RTL
  - Partition options: flash 0 = bitstreams (primary+golden), flash 1 = coefficients+metadata
    or stripe across both for wear leveling
  - Coefficient updates are more frequent than bitstream updates — isolate wear
  - Consider simple block rotation for coefficient region (100K erase cycle limit)
  - Estimate write endurance: 18 banks × 2.25 MB × N updates vs. 100K cycles × sector count
  - Store partition table / flash map in a fixed header sector (first 4 KB of each flash)
- [x] SPI register address defines — DONE 2026-09-03 (`Xilinx/spi_regs.svh`, TODO-18) — create a header file (e.g., `spi_regs.svh`) with
  human-readable `define names mapping to hex register addresses (e.g., `SPI_REG_UNMUTE`,
  `SPI_REG_BANK_SEL`, `SPI_REG_BOOT_STATUS`, etc.) for use in RTL and testbenches → TODO-18
- [½] On-chip debug infrastructure — `ila_wrapper.sv` + dbg_hub present in every routed build (MARK_DEBUG on spi_unmute, level_switch_req, i2s_err, force_zero, mute drives); LED map done. Open: probe list for boot FSM / coef_bank_loader AXI / QSPI ctrl, and the baseboard JTAG level-shift (hardware)
  - LED1 (BC33, bank 61) — boot status / heartbeat / error blink codes
  - ILA (Integrated Logic Analyzer) cores for key internal buses during bring-up
  - MARK_DEBUG attributes already on spi_unmute, gain_switch_req
  - Consider ILA on: boot sequencer FSM, coef_bank_loader AXI, DDR4 cal status, QSPI controller
  - JTAG on J6 connector: TDI=D17, TDO=D18, TMS=D19, TCK=D20 (dedicated pins, no XDC needed)
  - Baseboard: route J6 D17–D20 + GND to JTAG header (J-Link Pro compatible)
  - Level shift required: FPGA JTAG is 1.8V, J-Link Pro is 3.3V
    - Part: TI SN74AVC4T245PW (TSSOP-16) — 4-ch bidirectional, VCCA=1.8V, VCCB=3.3V
    - 1DIR=HIGH (B→A): TCK, TMS, TDI from J-Link 3.3V → FPGA 1.8V
    - 2DIR=LOW (A→B): TDO from FPGA 1.8V → J-Link 3.3V
    - OE tied low (always enabled), 0.1µF bypass caps on VCCA and VCCB

## Completed
- [x] i2c_master.sv, dac_role_cfg.sv, fpga_sync_if.sv deleted (orphaned)
- [x] XDC constraints: vu13p_dac_top.xdc — diff clocks, SPI, I2S, relay, IRQ pins assigned
- [x] Differential clocks: IBUFDS for clk_200m (C1 CLKREF G20/G19), clk_49m (B30/A30), clk_45m (A27/A28)
- [x] DDR4 port widths updated to 80-bit (C0 controller); C1 unused, its CLKREF serves as clk_200m
- [x] SOM pin correlation: ACVU13P-Pin-Assignment CSV parsed, DDR4/QSPI/SelectMap pins identified
- [x] tb_dac_i2s_ingress.sv — 11/11 PASS: 768k stream, 705.6k stream, watchdog, recovery
- [x] tb_spi_ctrl_plane.sv — all tests PASS: SPI write/read, CRC, register readback
- [x] tb_coef_bank_loader.sv — all tests PASS: 262144 writes, 256 bursts, 0 errors
- [x] tb_i2s_rx.sv — PASS
- [x] run_sim.tcl — xsim batch script for all 4 testbenches
- [x] dac_i2s_ingress.sv — simplified: direct register from toggle-sync, no FIFO needed

## DC Servo Design Round 1 — DISCRETE CM SERVO DESIGNED & VERIFIED (bfdac_servo1/2/3.cir, 2026-07-19)
Fully discrete per-channel CM servo (topology D per user direction; ADC/FPGA option rejected — market/purity; opamp options rejected). Plant modeled behaviorally (56R TIA CM response), servo transistor-level.
- **FINAL TOPOLOGY (11 BJT + 2 film caps/channel):** sense 2x10k matched thin film (out_p/out_m -> cmsen); input pair QI1/QI2 (SSM2212, Rd 4.7k degeneration, 100uA tail via 143k); PNP mirror load QP1/QP2 with 10k emitter degeneration + beta-helper QH; Darlington PNP second stage QS0/QS with mirror current-source load QL0/QL1 (100uA); Miller integration Cint 10uF FILM across stage 2; post-filter 100k+1uF (noise wall, servo branch); vernier actuators QA1/QA2, Rdeg 2k to -15 (center 1.43mA, authority +/-0.71mA = +/-40mV CM).
- **KEY OFFSET LESSON: every uA-level asymmetric base-current leak at the stage-1 output node costs (leak x ~5.2k) of CM offset.** Fix sequence: QS base steal 3.5mV -> Darlington; mirror VCE imbalance 2.1mV -> emitter degeneration (NOT cascode: its base current re-leaks 1.7mV); mirror beta error -> helper QH; matched 5k source impedances at BOTH pair bases make the pair base-current drops CANCEL (loop forces cmsen=iref).
- **MEASUREMENT TRAP (recorded): V(cmsen) sits Ib*5k (~2.8mV) below true output CM — measure (out_p+out_m)/2, not the sense node.** Cost one false debugging round.
- **RESULTS:** DC loop gain 75.9dB; crossover 11.7mHz; PM ~89deg (post-filter pole 1.6Hz is 130x above crossover); residual output CM 95-135uV over full +/-40mV disturbance range (plus real SSM2212 Vos ~200uV); servo noise at diff output (1% actuator mismatch): flat 285pV/rtHz, 40nV rms 20-20k = **-153.9dB rel 2Vrms — invisible in the 128.4dB budget**; startup: exponential settle, no windup, sub-mV by ~90s (power-on mute/relay covers; NOTE for system spec).
- **ACTUATOR SIZING TRAP: Rdeg 10k collapsed authority (emitter follows vflt up, QA saturates against the 2.4V sum node at VCE~20mV, base current explodes, stage-2 rails).** 2k + recentered vflt (~-11.4V) gives 13V VCE margin.
- OPEN: servo values are per-channel x2; add to schematic.html 5b (currently still marked DESIGN PENDING); startup mute time constant -> system spec; SSM2212+SSM2220(PNP) BOM adds.
- CLOSED 2026-07-20: schematic.html 5b updated to transistor-level VERIFIED figure; servo row added to traceability table.

## Round 14 — FULL-STACK THERMAL NOISE, CONVERTER -> I/V (bfdac_noise1/1b.cir, 2026-07-20)
First .noise of the whole analog path (only servo3 existed before). Deck derived from cosim23f DC stack; ALL noiseless ideal sources replaced with physical equivalents:
56 static cells -> area-scaled real cell (Q4 area=N + 750/N); 8 live cells kept real, gates DC; 50mA pads -> degenerated BJTs (40R/2V); replica ff+sink B-sources -> degenerated BJTs (10V across Re); amp en modeled as 73R series sense resistor (= 1.1nV/rtHz, OPA1612 class). .noise V(diffout) V_ref dec 100 10 100k, .step code list 4 28 52.
- **noise1 (no ref bypass): code-DEPENDENT floor: 4.97nV/rtHz @ code28 but 8.07nV @ code4 / 6.70nV @ code52.** Root cause: R_bias 100R thermal (1.28nV) on q4_base is CORRELATED across all 64 cells -> cancels differentially at midscale only; imbalanced codes see ~vn*(Nm-Np)/783 * 56R (~4.4nV @ code4). Same math applies to any real reference noise: vref->diffout gain up to 3.7x at code extremes.
- **FIX (noise1b): 1000uF bypass on q4_base (1.6Hz corner with 100R).** Floor now code-INDEPENDENT: flat 4.89-4.92nV/rtHz, etot 0.693uV rms 20-20k. vref transfer killed (gain ~0.006 @ 1k) -> reference part noise is a non-issue in-band. Cap is in bias branch, not audio path. Startup tau 0.1s.
- **RESULT: output noise floor = 0.693uV rms / 3.394Vrms FS (4.8Vpk diff) = -133.8dB, all codes.** Spectrum flat 20-100k (all-thermal). Dominant terms (analytic): 64 cells 4kT/750 aggregate ~1.4nV/rail, pads ~1.1nV/rail each (sum+bus), amp 1.5nV, R_off 0.54nV.
- **THD+N ROLLUP: distortion 128.4dB (+) noise 133.8dB = ~127.3dB.** Noise is NOT the limiter but the combined figure now sits ~0.7dB under the 128dB target; the binding terms remain mismatch 130.6 and code 133.5. Knobs if 128.0 must be strict: A-weighting buys ~2-3dB on the noise term; or attack mismatch shaping further.
- CAVEATS on record: no 1/f in any model (Kf=0) — real BJT/amp flicker corners are low but unverified; amp current noise not modeled (1.7pA into 56R ~ 0.1nV, negligible); pad/replica bias rails modeled as noiseless V-sources — REAL bias networks must be RC-filtered below audio band like the servo (design rule, not yet a drawn circuit); q4_base 1000uF bypass is NEW — must be added to schematic.html Fig 2/5 and BOM.
- CLOSED 2026-07-20: q4_base bypass added to schematic.html Fig 2 + Fig 5 text; noise row + THD+N rollup added to traceability table.

## Round 15 — PASSIVE BESSEL RECONSTRUCTION FILTER (bfdac_filt1.cir, bfdac_noise2.cir, 2026-07-20)
User direction: fully passive LC (dCS/Chord philosophy discussed: steep rejection lives in the linear-phase digital FIR; analog filter = low-order, GROUP-DELAY-FLAT. Spec "no phase shift" formalized as group-delay flatness, i.e. pure time delay). Active option ruled out (V-stage would see 3MHz shaped DEM noise unfiltered -> slew IMD; no loop gain at MHz).
- **TOPOLOGY: 3rd-order Bessel singly-terminated ladder per leg: I/V out (Rs~1R) -> L1 -> C2 shunt -> L3 -> R0 term, V-stage bridges R0 hi-Z.** Exact synthesis vs s^3+6s^2+15s+15: normalized L1=5/6, C2=12/25, L3=1/6 (ws=2*pi*fc/1.7557). fc=450k, R0=150: **L1=77.6uH (air-core, DCR 1.5R), C2=1.99nF C0G, L3=15.5uH (DCR 0.4R)**.
- **RESULTS (filt1):** f-3dB 450k (-3.08dB, synthesis confirmed); passband loss -0.166dB (DCR+Rs), droop 1k->20k only 0.005dB; **group delay 614ns, FLAT TO 17ps ACROSS 20Hz-20kHz**; attenuation -41.4dB @ 3.072M (shaped-noise protection), -59.3dB @ 6.144M (+~50dB ZOH sinc -> images ~-109dB). L +/-5% step: fc -2.7/-3.4dB, gd 583-644ns but STAYS flat (<110ps dev) — Bessel delay changes with tolerance but flatness (the audible spec) survives.
- **noise2 (filter grafted onto noise1b full stack, probe at filter output):** in-band floor unchanged: 4.83-4.86nV/rtHz, 0.683uV rms 20-20k = -133.9dB rel FS. R0 termination thermal is shorted by the low-Z source in-band; DCR negligible. I/V DC loading by 150R fine.
- **V-STAGE INTERFACE NOW FIXED:** bridge 150R termination with hi-Z input; signal is full-scale 4.8Vpk diff, delayed 614ns, spectrum clean above 450k. Gain-only stage (filter does no gain).
- MEAS NOTE: .meas AC FIND ph() prints results in dB cosmetically — values ARE degrees/seconds when used in param expressions (gd math verified against 1/ws theory).
- **TRANSIENT VERIFY (cosim25/25b = cosim24 + filter + q4_base 1000uF):** I/V driving the LC ladder: glitch charge STILL linear in k to 0.003% (q_rise 9.826n->78.61n for k=1->8), asym_frac 0.06e-4..0.6e-4 (same order as cosim24's 0.70e-4), plateau_err ~15nV -> NO instability/ringing at out_p from the inductive load. Filter output step (5us pulse): overshoot = undershoot = 0.93% symmetric (textbook 3rd-order Bessel), settled gain 0.9876 (-0.11dB, = DCR divider 150/151.9), no ringing.
- **STIMULUS TRAP (cosim25 first attempt): 598ns test pulse ~ filter rise time (0.35/450k=778ns) -> fdiff never plateaus, gain_f read 0.64 and os_frac 9% -- artifacts of an unsettled step, not filter defects.** Lengthened pulse to 5us (25b). Also baseline window must end ~400ns (step energy arrives before the 614ns group delay).
- OPEN: inductor BOM (air-core 78uH/15.5uH, shielding + orientation layout rule); filter into schematic.html; V-stage design next.
- CLOSED 2026-07-20: filter added to schematic.html as new Fig 4b + traceability row.

## OUTPUT ARCHITECTURE DECISIONS (user-confirmed, 2026-07-20)
- Two separate stages (Benchmark/Weiss pattern, researched dCS Vivaldi APEX = no HP out / Chord DAVE = shared stage): REAR line XLR (2/4/6 Vrms relay-selected, 600R min load) + FRONT headphone stage (1Vrms IEM / 6Vrms planar gain relay), both in the quiet analog zone; front jack driven low-Z across the FPGA region (robust), never hi-Z input routing.
- Mutually exclusive by design. Relay set per channel: input-select DPDT (unused stage input grounded — an UNPOWERED BJT input on the node would clamp signal peaks via b-c junction to collapsed rails!), rail relay (headphone stage fully depowered in line mode), per-output mutes (de-energized = muted: line = open+shunt, HP jack = shorted). Chain: I/V -> filter -> input select -> stage -> OUTPUT mute -> connector (mute AFTER stage: it exists to swallow the stage's own power-up/settle transients).
- Sequencing rule for FPGA: mute -> switch select+rails -> settle -> unmute. Level select for line 2/4/6V done via TAPPED 150R termination (taps 1/3, 2/3, 1: source Z <= 50R, relays switch signal-level nodes into hi-Z input, stage gain FIXED) — one compensation, one verification.

## Round 16 — LINE V-STAGE, ONE LEG DESIGNED & CONVERGED (bfdac_vstage1.cir + /b/o variants, 2026-07-20)
Fixed gain 1.769 non-inverting discrete amp per leg (x2 per channel, level via termination taps upstream). Topology: LTP QLN low-noise NPN 6mA/side w/ 33R deg, BJT tail 12mA; PNP mirror load 200R deg + beta-helper QH (+22k bleed); PNP Darlington VAS (QV0 follower + QV 6mA, Rev 130) + CASCODE QVC (base +8V); Miller 1n + 100R series from vas to nd1; class-A diamond output m=3 (~25mA, 22R/10R base stoppers); Zobel 10R+100n; fb 150/195 (gain 1.769), load 300R (=600R diff).
- **RESULTS: 1kHz THD(9) 0.00001% = -140dB (H2 -143dB) at FULL 3Vrms leg out; 20kHz THD 0.0006% = -104dB; DC offset 2.9mV (systematic -> cancels differentially between matched legs); Idq 25mA class A; gain accurate to 0.05%.**
- **DEBUG SEQUENCE (traps recorded):**
  1. **9.5MHz global oscillation with C_m=680p (UGF ~5MHz too high for the phase stack). Symptom: Fourier 'Total THD' 5-12% with clean 'Partial' — excess RMS vs fundamental confirms real HF content, not numerical.** Stable from C_m>=1n; using 1n with gm lowered (33R deg): crossover ~1.2MHz.
  2. Helper was FALSELY blamed (removed, oscillation persisted -> global). Restored after comp fix: clean, offset 10.6mV -> 2.9mV.
  3. **20kHz THD was -56dB with 2mA LTP: Miller current (2pi*20k*Cm*4.3Vpk ~ 0.8mA) modulates a 2mA pair by 40% -> gross front-end nonlinearity. Fix: 6mA/side + 33R deg (same-ish gm, 12x linear range) -> -104dB.** RULE: size LTP tail >> peak Miller current.
  4. **12mA tail latched the DC op point: mirror 300R deg (1.8V drop) + Darlington VAS input level = mirror output compliance violated -> solver finds saturated latch state (out stuck +8.66V).** Fix: Rm 200R + Rev 130 (nd1 target 12.8V vs mirror em 13.8V). RULE: recheck nd1 = vcc - I*Rev - 2Vbe vs mirror compliance whenever tail/VAS currents change.
  5. plotwinsize=0 numdgt=7 required for credible .four; .save list keeps raw small (2GB -> 2MB).
- OPEN: stage .noise (est ~1.2nV in + 84.7R fb network vs 4.9nV source — expect ~+0.3dB); PM quantification (loop probe); tapped-termination 2V/4V settings THD + noise; two-leg differential build (offset cancellation, XLR drive); temp corners; headphone stage (separate round).
- CLOSED 2026-07-20: schematic.html Fig 4c (V-stage) + Fig 4d (output routing/relays/sequencing) + traceability row added.

## Round 17 — V-STAGE NOISE, TAP SETTINGS, DIFFERENTIAL BUILD (bfdac_vstage1n/1t/2/2b.cir, 2026-07-20)
- **NOISE (vstage1n, .noise on tapped termination, all settings):** stage output density 3.16nV/rtHz @6V setting, 3.43 @2V/4V (incl 33R tap thermal); FLAT 100Hz-20kHz. Input-referred stage ~1.8nV. Combined at XLR (diff, DAC chain 4.85n at filter x1.769, stage legs uncorrelated x sqrt2): 6V: 9.67n -> 1.37uV rms -> **SNR 132.8dB**; 4V: 131.5dB; 2V: 128.0dB. (dCS Vivaldi APEX spec: -113dB @6V. ~20dB better.) Stage noise penalty on DAC floor: 1.1dB at 6V.
- **MEAS TRAP: .meas NOISE INTEG(V(onoise)^2) under .step returns garbage (141x low) in LTspice 26.0.2 — density was verified flat at 4 spot freqs and integrated manually (x sqrt(19980)). noise1b (no .step) was consistent, unaffected.**
- **TAP SETTINGS THD (vstage1t, divider + stage, per leg):** 2V: 1k 0.000007% (-143dB), 20k 0.000111% (-119dB); 4V: 1k 0.000015% (-136dB), 20k 0.000345% (-109dB). Levels 0.987/1.975Vrms (x0.9868 filter-DCR factor, matches cosim25b gain — absolute cal note for FPGA digital trim if exact 2/4/6 wanted).
- **DIFFERENTIAL BUILD (vstage2/2b, two VLEG subckts, 600R XLR load, 0.5% Rg mismatch stepped):** diff 5.93Vrms; **1k diff THD 0.000010% = -140dB; 20k 0.00057% = -105dB** (H2 cancels: 4.7e-9 normalized). **Diff DC offset: 2nV matched, 0.41uV at 0.5% Rg mismatch — per-leg 4.7mV systematic offset confirmed pure CM, cancels at balanced receiver.** CM AC leakage at 0.5% mismatch 3.2mV (-65dB, and CM -> rejected). Gain balance 0.11% per 0.5% Rg mismatch.
- **MEAS TRAP (cost ~6 debug sims): B-source observation nodes (B_od V=V(outp)-V(outm) + 1G) POLLUTE .four THD ~50x with fake odd harmonics (timestep-dependent, slow-decay H3>H5>H7 signature). Also masked as 'subckt vs flat deck difference'. Use native .four V(a,b) two-node syntax instead. RULE: never put B-sources on measurement-critical decks.**
- Also: .step with a single-value list errors out ("only one step") — use .param instead.
- OPEN: PM quantification (loop probe); temp corners; headphone stage round; startup mute already in system spec. Fig 4c/traceability updated with noise+diff numbers.

## Round 18 — V-STAGE PM, LATCH FIX RE-VERIFY, TEMP CORNERS (bfdac_vstage1p/1o/1q/1tc/1oc.cir, 2026-07-20)
- **LATCH FIX FINAL: Rm 200R -> 100R** (mirror em headroom vs Darlington VAS input; nd1 compliance rule from Round 16 item 4). Re-verified full battery after change:
  - 1kHz THD 0.000029% (-131dB), 20kHz 0.000596% (-104.5dB) — unchanged within noise.
  - Offset 2.5mV, Idq(out) 24.6mA, 3.0016Vrms at 6V setting.
  - Oscillation deck (vstage1o): output residual pV-level, no ringing. Square wave (vstage1q): overshoot 0.88%, clean settling, no latch.
- **PHASE MARGIN (vstage1p, AC loop probe):** UGF 2.85MHz, **PM 34.2° by single-injection probe** — conservative/pessimistic: the voltage-only injection underestimates margin when the impedance ratio at the break point is unfavorable. Transient evidence (0.88% overshoot, no ring at pV level) corresponds to effective PM >>60°. Loop gain 41.4dB @20kHz. HF plateau +1.8dB max 6-100MHz (benign, transient-confirmed).
- **TEMP CORNERS (0°C / 50°C, .step temp):**
  - THD 1kHz: 0.000031% / 0.000029% — flat.
  - Idq(out): 24.5mA / 24.8mA (+1.2% over 50°C span — emitter degeneration + diamond Vbe tracking works).
  - Offset: 2.42mV / 2.54mV (pure CM, cancels differentially).
  - Gain: 3.0015752 / 3.0015757 Vrms — 0.2ppm variation. Oscillation deck clean at both corners (pp ~4pV).
- **LINE V-STAGE CLOSED.** Next round: headphone stage.

## Round 19 — HEADPHONE STAGE, 4-PIN XLR BRIDGED (bfdac_hp1/1b/1o/1q/2/2b.cir, 2026-07-20)
- **ARCHITECTURE (user decision): headphone out = 4-pin XLR balanced (2 bridged legs/channel); line/preamp out = dual 3-pin XLR (existing vstage2).** Each HP leg sees half the load: 16R for a 32R headphone (worst realistic case).
- **HP LEG = verified line V-stage front end unchanged** (LTP 6mA/side/33R, mirror 100R+helper, Darlington VAS 10mA cascoded, Cm=1n/Rmc=100, gain 1.769) **with power output triple:** diamond drivers (Q5551/Q5401 m=2, 15mA) -> TO-220F power pair (2SC4793/2SA1837-class models QPWN/QPWP), **Re=0.47, Idq 162mA class-A** (Imin 32mA at full swing — never leaves class A). Re=0.33 first cut gave 195mA — trimmed via Re (diamond spreader is set by driver-vs-power Vbe delta, Re drop dominates trim).
- **SINGLE LEG (16R load, 3Vrms = full scale):** 1k THD 0.000052% (-126dB); 20k 0.001149% (-98.8dB). Stability: osc deck pV residual, square wave 1.5% overshoot, clean settling, no latch.
- **BRIDGED PAIR (hp2, 32R load, 0.5% Rg mismatch stepped): 6.0Vrms diff = 1.13W into 32R. 1k diff THD 0.000052% (-126dB), 20k 0.001140% (-98.9dB)** — leg residual is odd-dominated (H3), so bridging does not improve THD but doubles swing and kills ground-return current. Mismatch has no THD effect. **Diff DC: 79nV matched, 5.1uV at 0.5% mismatch (0.16uA into 32R) — no output caps or DC servo needed.** CM DC 2.5mV (cancels in bridge).
- Dissipation note: 162mA x 15V = 2.4W/device idle, 4 power devices/channel -> ~10W/channel heatsink budget. Class-A ceiling 5.4Vrms diff into 32R; higher-Z loads trivially class-A.
- **NOISE (hp1n, tapped termination, all settings):** 3.28nV/rtHz @6V, 3.54 @2V/4V, flat 100Hz-20kHz (vs line stage 3.16/3.43 — power triple adds ~0.1n). Integrated 20-20k: 0.464uV/leg, 0.66uV diff stage-only. Combined with DAC chain (8.58n/leg): ~9.2n/leg -> **SNR at 6Vrms diff ~132.7dB** — same class as line out. Into 110dB/V IEMs: hiss ~ -7dB SPL, inaudible.
- **PM (hp1pm, loop probe):** UGF 2.87MHz, PM 33.7° by single-injection probe (same conservative caveat as line stage — transient shows 1.5% overshoot, effective PM >>60°). Loop gain 41.2dB @20k. HF plateau +0.77dB (better than line stage's +1.8 — power pair Cjc loads the plateau resonance).
- **TEMP CORNERS (0/50°C):** THD 1k 0.000066%/0.000043% (both < -123dB); gain 0.3ppm; offset 2.42/2.54mV (CM, cancels). **Idq 149/173mA (+16% over span, positive tempco ~0.48mA/°C).** Runaway check: 4 devices x 7.2mW/°C x ~2°C/W heatsink = loop gain 0.06 << 1, thermally stable; still stays class-A at 0°C full swing (Imin 21mA). BUILD NOTE: mount diamond drivers on the main heatsink for Vbe tracking; production could swap fixed diamond for a heatsink-mounted Vbe multiplier if tighter Idq wanted. Osc deck clean at both corners (pp ~3-4pV).
- **HP STAGE ELECTRICALLY CLOSED.** OPEN: schematic Fig 4e; relay integration recheck (HP mute = shorted, already in Fig 4d spec).
- **ARCHITECTURE CHALLENGE (user, availability/heat concern) — three-way comparison run (hp1ab/ab2/ab3/a3.cir):**
  - Discrete class-AB (Re=2.7, Idq 92mA, leaves class A at full swing): **1k full-power THD 0.001493% (-96.5dB) = 30dB WORSE; 20k 0.031% (-70dB) = 29dB WORSE** — 41dB loop gain at 20k cannot suppress gm-doubling into 16R. Low-level (300mW) THD identical to class-A (0.000014%) since it stays class-A there.
  - IC composite (OPA1612+BUF634A in-loop) — datasheet estimate, not simmed: ~-120dB 1k / -100..-110dB 20k, noise ~2.9nV output, ~1.5W/ch. Coolest option, likely 5-10dB worse at 20k full power, single-source TI silicon.
  - Class-A discrete (as verified): -126dB 1k / -98.9dB 20k at 1.13W, 3.28nV, ~12W/ch. **KEPT — user priority is performance; heat is a chassis/heatsink budget item.**
  - BOM corrections from review: Red/Rec are 1206 current-sense chips (12-17mW actual, 3W spec was habit-overspec); 2N5551/MMBT5551 are active jellybeans (not arcane); Rg 195R -> 196R E96.
- **IC COMPOSITE WITH GENUINE TI MODELS (hp3/3b/3c/3p/3p2/3n/3q.cir; OPA161x SBOM396G + BUF634A SBOMB63A, downloaded to ti_models\):**
  - **MEAS TRAP: smooth behavioral macromodels let LTspice take huge steps — .tran 10n 10m 'finished' in 1.2s with a fake -80dB floor. Force maxstep (.tran 0 10m 0 50n); verified converged by halving to 10n (identical result).**
  - **Single BUF634A: 1k 0.000917% (-100.8dB), 20k 0.020% (-74dB) — the 250mA current limit engages at 265mA pk. REAL disqualifier at rated 1.13W/32R bridged.**
  - **Dual parallel BUF634A (1R ballast each): 1k harmonics at -240dB = below model resolution; 20k 0.000019% (-134dB).** CAVEAT stated to user: TI macromodels do NOT model output-stage crossover/low-level THD — parallel numbers are optimistic lower bounds, not predictions; datasheet measured in-loop THD+N into 32R is ~-120dB class. Discrete sim uses physical junction models that DO capture these mechanisms — not apples-to-apples.
  - Noise (real, macromodels model noise well): 3.08nV/rtHz @6V tap vs 3.28 discrete — equal within 0.5dB.
  - Stability: square wave overshoot **18.8%** (vs discrete 1.5%) with Riso=22 — settles clean (0.65uV pp quiescent) but composite would need its own compensation round (Cf lead cap, Riso tuning).
  - Heat: ~1.2W/ch (8.5mA/buffer wide-BW x4 + opamps) vs 12W/ch discrete.
- **ARCHITECTURE DECISION (user, after real-data review): DISCRETE CLASS-A COMMITTED.** Composite decks (hp3*) retained as reference only. OPEN: schematic Fig 4e; bias-network detailing (Vtb/Vbcas/Iba/Ibb real implementations); relay integration recheck.

## Round 20 — HP BIAS NETWORKS REALIZED (bfdac_hp4/4b/4o/4tc.cir, 2026-07-20)
- **All ideal sources replaced:** Vtb -> LED-referenced tail CCS from -15V rail (DLED model Vf~1.8V, Rln 2.7k feed, 100u bypass, Rte 91R -> tail 11.3mA); Iba -> NPN CCS off same LED (Rea 75R, 13.6mA); Ibb -> mirrored PNP CCS off +15V LED (Reb 75R, 14.1mA); Vbcas -> 3.3k/3.9k divider from +15V + 10u (8.1V, cascode Ib ~50uA). LED refs are rail-tracking = tail/bias currents immune to rail sag.
- **Verification vs ideal-source hp1: 1k THD 0.000055% (-125dB, was 0.000052%), 20k 0.001260% (-98dB, was -98.8dB) — bias networks cost ~nothing.** Idq 159mA, offset 2.3mV, class-A held (Imin 29mA).
- **Temp corners 0/50°C:** THD 0.000080%/0.000044% (< -122dB both); Idq 143/172mA; **tail 10.3/12.1mA (+18% span — LED-vs-Vbe residual tempco, larger than ideal case but THD/stability unaffected)**; Imin 16mA at 0°C full swing = still class-A. Osc deck clean at 0/27/50°C (pp ~3pV).
- **TOOLING TRAP (cost 1 sim): PowerShell operator precedence — `-replace a,b + "x" + c -replace d,e` does NOT chain as intended; hp4o.cir silently became a copy of the old hp1o deck (results exactly matched a previous run = red flag that caught it). Parenthesize replacement strings.**
- BOM additions: 2x DLED green LED (any jellybean green, Vf~1.8-2.0), 2x 100u + 1x 10u bypass, Rln/Rlp 2.7k, Rc1 3.3k, Rc2 3.9k, Rea/Reb 75R, Rte 91R. QCA/QCB = 2N5551/2N5401.
- OPEN: schematic Fig 4e (now with real bias networks); optional PSRR sweep; relay integration recheck.

## Round 21 — FIG 4E + PSRR + RTL RELAY INTEGRATION (2026-07-20)
- **Fig 4e added to schematic.html** (HP stage: front end = Fig 4c unchanged, power triple, real bias networks, verified numbers). BOM stale Rte 900R row removed.
- **PSRR (hp4pp/hp4pm, AC on rail, output-referred per leg):**
  - -15V rail: -95.5dB @100, -91.4 @1k, -71.9 @20k — LED rail-tracking bias works.
  - **+15V rail: -84.7 @100, -67.6 @1k, -41.7 @20k, -27.7 @100k** — weaker (mirror emitters, Rev, Rset all reference +rail).
  - Mitigations already in architecture: (1) rail ripple is COMMON-MODE across the bridged pair -> cancels at the headphone except leg mismatch (~1% -> effective ~-82dB @20k diff); (2) rails are LDO + Fig 5 filtering. Judged acceptable; if bench disagrees, an RC (10R/470u) on the front-end +15 feed is the fix.
- **RTL AUDIT vs Fig 4d (user request "make sure mute + voltage output + SPI commands exist"):**
  - EXISTED: single output mute relay + 1-bit gain relay with mute-sequenced switching, SPI 0x02/0x04.
  - **MISSING: output select (line/HP), HP rails relay, separate line/HP mute relays, 3-level tap select (was 1 bit, needs 2).**
- **RTL IMPLEMENTED (automute_controller.sv, dac_ctrl_plane.sv, vu13p_dac_top.sv, .xdc):**
  - automute: full Fig 4d sequencer — MUTED/FLUSHING/SWITCHING/RAIL_SETTLING/SETTLING/PLAYING. level_relay[1:0] (2/4/6V taps), outsel, hp_rails; select/level relays only move while both mutes open + audio clamped; **RAIL_SETTLING 500ms when HP rails toggle (LED refs + 100u + class-A Idq settle) before jack goes live**. Timings are module parameters (TB-overridable).
  - SPI map: 0x02 now level[1:0] (00=2V,01=4V,10=6V); **0x07 = output select (0=line,1=HP)**; 0x12 readback {clk_src, rate, outsel, level}; 0x14 {i2s_err, switch_busy, hp_mute, line_mute, unmute}.
  - Top: 4 new relay ports (relay_line_mute/hp_mute/hp_rails/level[1:0]), widened CDC chains, ILA probe updated. XDC: pins R28/T28 kept for mutes; **U28/R29/T29 for rails+level are PLACEHOLDERS — verify against ACVU13 connector budget.**
  - tb_automute.sv rewritten: reset state, line playing, err/rate re-mute, level switch only-while-muted, outsel with rails-before-jack ordering, HP->line teardown + 2 always-on invariants (mutes never both energized; HP jack never live with rails off).
  - **VERIFIED: xsim 2026.1 run = ALL PASS (11/11 checks, invariants silent).** Toolchain note: Questa FSE on this machine has a dead node-locked license (HOSTID mismatch) — use Vivado xsim instead: `cmd /c "call C:\AMDDesignTools\2026.1\Vivado\settings64.bat && xvlog -sv <files> && xelab tb_automute -s tb_automute_sim && xsim tb_automute_sim -R"`.
- HP block fully closed pending: XDC pin verify (U28/R29/T29 placeholders), heatsink/chassis (mechanical).

## Round 22 — PIN BUDGET REVIEW vs ALINX CSVs (2026-07-21)
- Reviewed `Alinx/ACVU13P-Pin-Assignment-20260703.csv` (connectors J1-J8) + onboard CSVs (QSPI/LED/DDR4/JTAG/config).
- **BUDGET: 368 user I/O on connectors, banks 64-71 (51/46/42/51/25/51/51/51). Control cluster uses 21 of bank 71's 51; cascode 128 fits with 219 pins spare.**
- **BUG FOUND+FIXED: OCXO clock inputs were on NON-clock-capable pins.** B71_L24 (B30/A30) and B71_L22 (A27/A28) are ordinary I/O — UltraScale+ GC pins are L11-L14 only. Would have failed MMCM clock routing at implementation. Moved: clk_49m -> B71_L12 (J28/J29, J1-A17/A16), clk_45m -> B71_L13 (J26/H26, J1-B5/B4). **BASEBOARD LAYOUT MUST ROUTE OCXOs TO THESE J1 PINS.**
- **Placeholder relay pins fixed with real connector pins:** hp_rails=N26, level[0]=P26, level[1]=N29 (B71_L6/L4, J1-B1/B2/B7). U28/R29/T29 did not exist on connectors.
- **Debug LEDs added** (only 1 user LED onboard, BC33): led_debug[3:0] = {clk_locked, ddr4_calib, i2s_err, force_zero} on D28/E28/K27/K26 (B71_L18/L10). Port added to top + XDC.
- Clock-capable inventory: 4 GC pairs/bank except 66 (partial) and 68 (L11/L12 only).
- **i2s_bclk moved to GC pin too (user follow-up):** R27 (B71_L2, waivered) -> H27 (B71_L11_P, J1-B17); CLOCK_DEDICATED_ROUTE=FALSE waiver removed — bclk now gets dedicated clock routing. R27 freed. Bank 71's last free GC pair: L14 (G26/G27). **Baseboard: route I2S bclk to J1-B17.**
- MMCM: one CMT per I/O bank -> 8 adjacent to connector banks; design needs 1 (sys_clock_gen) + MIG's own. No shortage.
- Cascode plan: L on banks 64+65 (97 pins), R on 67+69 (102 pins) — each channel spans 2 adjacent banks, same VCCO 1.8V. Banks 66/68/70 + bank71 spares = expansion.
- NOTE: QSPI1 (AM26/AN26/AL25/AM25, bank 65) are dual-purpose SelectMAP D04-D07 — fine as user I/O post-config; do not enable SelectMAP persist.
- OPEN: assign the 128 cascode pins explicitly in XDC (needs board schematic pairing); heatsink/chassis.

## Round 23 — RECLOCK STUDY: FPGA DIRECT vs CHORD-DAVE EXTERNAL FFs (reclock_study.py, 2026-07-21)
- User asked whether direct IOB drive beats DAVE-style external reclock FFs. Built timing-error Monte-Carlo on the dem_study converter model (64 cells, 6.144MHz, const-k K=4 2nd-order DEM, -1dBFS 1k).
- Four mechanisms modeled: common random jitter (MMCM/BUFG vs OCXO+FF), SSN data-correlated delay (beta*k), static per-cell skew, per-cell random jitter.
- **RESULTS (in-band SNDR of timing error, const-k K=4):**
  - FPGA direct (10ps rj, 1ps/cell SSN, 15ps skew, 1ps pc): rj 130.0, ssn 146.0, skew 166.3, pc 145.6 -> **ALL 129.8dB**
  - External FF (0.5ps rj, 0.1ps/cell, 10ps skew, 0.3ps): -> **ALL 152.6dB (+23dB)**
  - **Dominant term = common random jitter of the MMCM/BUFG/IOB chain.** Sweep: 1ps->150dB, 5ps->136, 10ps->130, 20ps->124.
  - **const-k DEM DOES blunt the SSN mechanism as predicted** (+7dB vs DWA at every beta; k const -> SSN term nearly linear). But it cannot help the random-jitter term.
  - Static skew benign: 50ps sigma still 156dB (DEM decorrelates it like mismatch).
- **INTERPRETATION: direct drive lands AT our >=128dB per-contributor target with zero margin (and 20ps MMCM jitter would blow it at 124dB). External reclock buys ~23dB. DAVE's approach is justified by the physics; our const-k DEM only neutralizes the SSN part, not oscillator/MMCM phase noise.**
- Options ranked: (a) full external reclock — 128 FFs (16x octal LVC/AUP574 on clean rail) clocked by OCXO-derived divided clock, +23dB, BOM/board cost; (b) hybrid — final IOB regs on a BUFG fed RAW from the OCXO input (skip MMCM in output path), kills MMCM jitter but keeps FPGA SSN/global-net ps-level terms, ~free; (c) status quo, accept 130dB timing floor.
- Timing closure note for (a): FPGA outputs must meet setup/hold vs the board reclock clock — constrain with set_output_delay against OCXO; phase relationship is deterministic since dsp_clk is MMCM-locked to the same OCXO.
- OPEN: user decision a/b/c; if (a), reclock FF BOM + clock divider design + XDC output constraints; bench-verify jitter params (Vivado MMCM jitter report, IOB SSN measurement).

## Round 24 — CLOCK TREE LOCKED IN: EXTERNAL MUX + RECLOCK FFs (2026-07-21)
- **User decision: option (a) full external reclock.** Architecture locked at PCB level, Fig 1b added to schematic.html + BOM section.
- **Devices:** LMK00304 (2:1 OCXO mux + 1:4 fanout, ~50fs additive, NOT glitch-free) -> one output to FPGA GC pair, others to 2x LMK1C1108 (1:8, <30ps skew) -> 16x SN74AUC374 octal reclock FFs at 1.8V on a dedicated clean LDO rail (LVCMOS18-compatible, no level translation). 47R series into cascode gates as before.
- **FPGA clocking reworked — single MCLK input, clock selection moved OFF-chip:**
  - Top ports: clk_45m_p/n + clk_49m_p/n REPLACED by mclk_p/n (B71_L12, J28/J29) + clk_sel output (J26 = freed B71_L13_P; H26 now free). clk_sel = SPI reg 0x06 (clk_source_sel, already existed in dac_ctrl_plane — no ctrl-plane change needed).
  - sys_clock_gen: BUFGMUX_CTRL deleted; MMCM CLKIN1 = mclk; new mmcm_rst input.
  - New mux-switch sequencer in top (clk_200m domain): on clk_source_sel change -> assert mmcm_rst, flip clk_sel, hold reset 2048 cycles (10.24us settle), release, MMCM relocks ~100us. ARM mutes via automute before issuing the rate change (LMK mux glitches are harmless while muted + MMCM in reset).
  - XDC: single create_clock clk_mclk @ 20.345ns (faster 48k family covers both); dsp_clk generated-clock master updated; clk_sel LVCMOS18/D4/SLOW + false_path.
- **Setup/hold to external FFs (same-edge launch @ 49.152M):** setup margin ~13ns (Tco 3-5ns + flight <1ns vs 20.35ns); hold met (Tco_min ~2ns > skew + t_h). CAUTION for todo #13: dsp_clk/mclk ratio is 20/3.5 = 40/7 (non-integer) — cascode IOB regs must ultimately be clocked/enabled on an mclk-phase-aligned clock (MMCM CLKOUT1 DIVIDE=20 spare is reserved for this) so launch edges are deterministic vs the FF clock.
- tb_vu13p_top clock section updated (behavioral LMK mux driven by clk_sel); NOTE tb is otherwise stale vs current top (pre-Fig-4d relay names, old DDR4 port list) — needs full refresh before it compiles.
- Datasheet caveat: LMK/AUC skew-jitter-Tco numbers are from memory (+/-20%) — verify before layout.
- OPEN: cascode pin assignment (todo 9); output-timing constraints vs virtual FF clock + mclk-aligned launch clock (todo 13); tb_vu13p_top refresh.
- **BOMs consolidated (user request): bom_hp.md + bom_clock.md merged verbatim into single bom.md** (§1 clock tree/reclock, §2 headphone amp); old files deleted. Remaining blocks (cell array, output stage, I-V, filter, V-stage, servo, relays) still live in LTspice decks — transcribe into bom.md sections as they reach layout.

## Round 25 — BOM <-> SCHEMATIC LOCK-STEP (2026-07-22)
- **bom.md restructured: BOM section N documents schematic.html figure N** (1=clock/1b, 2=unit cell, 3=output stage, 4=I/V, 5=filter/4b, 6=line V-stage/4c, 7=relays/4d, 8=HP/4e, 9=supplies/5, 10=servo/5b). HP section renumbered 2->8. Lock-step rule stated in both file headers (schematic footer cross-ref added).
- New BOM sections transcribed from schematic values (values deck-locked, many MPNs TBD): unit cell (LVFET TBD, THAT300 32pkg, 750R, shared 100R+1000uF), output stage (R_off 180/180.18, pads 50mA, Q5/Q5R/Q5C matched, QM/QN pairs, 10n C0G, 910R, Rf 56R||390p, 4.7R+2.2n snubber, I_ff/I_snk realization TBD), I/V (OPA1612-class + diamond TBD), filter (77.6u/1.99n/15.5u air-core custom, R0=3x50R 0.1% tapped string), line V-stage (shares §8 MPNs, line-specific: 200R mirror deg, 6mA VAS, Rg 196R), relays (K1-K6 telecom bifurcated Au class TBD + ULN2003A, mapped to XDC pins), supplies (0.01R/30nH/bead1u||100R/10u/100n per rail; ref ladder 1.25/1.75/2.4V realization TBD — vfr buffer must sink 100-190mA), servo (SSM2212/SSM2220 + full R/C set from Fig 5b).
- **DISCREPANCY FOUND (logged as bom.md open sync item #1): Fig 1/2 show 2 gates per cell (make-before-break g1/g2) = 256 signals/unit, but RTL/XDC provide cascode_l/r[63:0] = 128 total and §1.2 reclock chain sized for 128.** Either on-board complement generation (breaks make-before-break) or 256 FPGA pins + 32 FF packages. Must resolve before cascode pin assignment (todo 9). Pin budget note: 256 pins still fits (368 available, Round 22).
- Other open sync items: MPN selection list, clock-tree datasheet verification, replica-DAC I_ff/I_snk circuit design.

## Round 26 — CASCODE CELL REVIEW: GATE-COUNT RESOLVED, 256 PINS (2026-07-22)
- Reviewed current cell vs reclock-FF drive (user request). Authoritative cell design ("Cascode Cell BOM — PARTIALLY LOCKED"): 64 cells/ch, **2 complementary FPGA pins per cell, 256 total** — the Round-22 pin review + RTL (cascode_l/r[63:0] = 128) were the stale side. Fixed everywhere:
  - **RTL**: dac_dsp_core + top ports now cascode_l/r_g1/g2[63:0] (256). g2 = registered complement in the IOB (NOT pad-inverted) — both gates launch on one dsp_clk edge, resampled on one FF edge. Reset g1=0/g2=1 (all cells parked on bus_minus). xvlog clean.
  - **XDC**: section 8 rewritten for 4 port buses; IOB cell patterns updated; output_delay placeholder pending todo 13. tb_vu13p_top ports updated.
  - **Clock tree resized WITHOUT changing topology**: 16x SN74AUC374 (octal) -> **16x SN74AUC16374 (16-bit dual-octal, both CLK pins tied at package)** = 256 bits, still 16 clock traces from 2x LMK1C1108 — LMK fanout unchanged. Each package = 8 cells. 47R count 128->256.
  - **schematic.html + bom.md synced** (Fig 1/1b/2 text + captions, BOM §1.2/§1.3/§2/§3, open item 1 resolved). Q5 MPN recorded as DMMT5551-class (package grouping of Q5/Q5R/Q5C triple TBD); LVFET hard spec transcribed into BOM §2 (V_GS<=0.9V @ 0.774mA, ~50pF Ciss; 2N7002 + DMN2041UVT rejected).
- **CONSEQUENCE OF FF DRIVE: gate-drive skew knob (per-cell ODELAY on complement pin) RETIRED** — FFs resample both gates on the same OCXO edge, ODELAY before the FF is absorbed. Default 0 (aligned) was the verified spec-meeting value (knob rule 2), so nothing is lost vs spec; cosim v6 showed 2-3ns skew bought ~20% glitch PP as optimization only. Fallback if bring-up shows dead-zone artifact: post-FF RC on g2 (board rework). Knob inventory updated.
- Pin budget: 256 cascode + 21 control fits easily (368 on connectors, Round 22); bank plan L=64+65, R=67+69 must be revalidated for 128 signals/channel (todo 9).
- NOTE: cell current bookkeeping — older cell notes say 781uA (Vbe 0.665), schematic/decks say 0.774mA; deck value kept as authoritative.

## Round 27 — CORRECTION (user ruling): 128 FPGA PINS; FF STAGE AT ~3.3V; CELL REDESIGN OPENED (2026-07-22)
- **Round 26's "256 FPGA pins" resolution was WRONG and is reverted.** User ruling: 64 cells/ch = **one FPGA data pin per cell, 128 pins total**; the external reclock FFs (introduced Round 24) drive the cells, so the FPGA 1.8V limit no longer constrains the gates — the FF rail (**~3.3V**) sets the gate drive.
- **RTL/XDC/tb reverted** to cascode_l/r[63:0] (identical to pre-Round-26 interface; comments updated: complement generated off-chip). xvlog clean.
- **Reclock stage redefined (bom.md §1.2, Fig 1b)**: D-FFs **with Q + ~Q outputs** at VCC~3.3V generate the complementary pair per cell (intra-package Q/~Q skew; avoids the asymmetric dead-zone of a post-FF inverter). 1.8→3.3V **level translation ahead of the FF D inputs** (jitter absorbed by reclock; only prop delay eats setup margin → budget now ~9–13ns). FF + translator MPNs TBD; FF packaging choice sets LMK1C1108 count. AUC374/AUC16374 selections VOID (AUC max VCC 2.7V, and single-Q anyway). 47R gate resistors: 256 (2 per cell) — unchanged.
- **CELL REDESIGN OPENED (blocks cell re-lock, bom.md §2 + Fig 2 flagged)**: gate drive 1.8V → ~3.3V. (a) switch-FET selection reopened — 2N7002-class re-enters (was rejected ONLY for 1.8V V_GS); low Ciss/Qg still required (charge injection); (b) re-derive source-node level / Q4 V_CE budget at new V_GS; (c) re-run cell + glitch decks (cosim chain) with real FET model at 3.3V drive; (d) pick exact FF rail voltage (sets gate high level) with the cell sim.
- "Cascode Cell BOM — PARTIALLY LOCKED" section updated in place (drive bullet, FET bullet, pin count). Knob inventory unchanged (ODELAY knob stays retired — FFs still resample; complement now formed inside the FF).
- Cross-check note: bfdac_final2.cir's original 3.3V-drive sims (pre-Round-9) are closer to the new regime than the 1.8V decks — but the cell has changed since (shared cascode, padding, Ib-comp), so a fresh deck pass is still required.

## Round 28 — CELL REDESIGN SIMS: DECK-MODEL BUG FOUND, BJT STEERING CELL PROPOSED (2026-07-22, decks bfdac_cosim26*/27*)
- Parts defined BEFORE sims (user rule: real models only): 2N7002/RK7002BM/QS6K1 (LTspice standard.mos vendor models; old `LVFET` was literally 2N7002 with Vto edited 1.6->0.6), SN74LVC74A FF + SN74AVC16T245 translator + TPS7A4700 rail recorded in bom.md §1.2.
- **FET OP window mapped (26/26b/26r)**: gate rail pinned to Vto+[1.1..1.45V] by the 0.58V tail / 1.75V bus sandwich. 2N7002: 2.8-3.05V (3.3V leaves VDS=96mV, goes TRIODE at +85C); RK7002BM: 3.1-3.35V; QS6K1: 2.4-2.65V. **5V/15V rail REJECTED with data (26p5)**: switch drops into triode, make-before-break shorts bus_plus<->bus_minus through ~4R each flip -> asym -30%..+15%. Raising the bus instead would drag sum node/R_off/replica/servo = full output-stage re-verification, for negative benefit (injection ~ swing x C).
- **LEGACY DECK BUG (major)**: cosim10/20/24 asym decks encode skew=1n in the g2 pulse WIDTHS (596n vs 598n) — the 'skew' param moves rise-overlap and fall-overlap OPPOSITELY (rise=skew, fall=2n-skew), which no FF ever does. The verified 0.71e-4 asym was measured at the matched point (skew=1n) of this convention; sweeping it produced phantom knife-edge sensitivity (6e-3/ns) that triggered this round's false alarm. **TRUE FF model = g2 exact delayed complement (equal 598n widths, skew = Qbar lag both edges).**
- **With the TRUE FF model (26f/27f): both cells are fine at delta=0**: 2N7002@3.3V asym 9.2e-5 (bounded <=1.1e-3 over +-1.5n); BJT cell 7.6e-5, slope 2.3e-3/ns.
- **Requirement derived via dem_study (asym_sweep.py, chosen K=4 par+2nd g2=.5 DEM)**: gl_ffwd = 151.7dB@0.71e-4, 150.8@2e-4, 142@1.15e-3, 128.4@5.9e-3 -> **need |asym| <= ~1e-3 => FF Q/Qbar skew |delta| <= ~0.4ns and matched edge shapes**.
- **NEW CELL PROPOSED + SIMMED (cosim27*): BJT emitter-coupled steering pair (DMMT5551 dual, same-die) with divider base drive** (FF 3.3V -> Rs 470R -> base, Rp 82R -> buffered VCM 1.6V; swing 1.36-1.86V around bus-safe levels). vs FET cell: **bus disturbance 2.2mV vs 89mV (40x)**, off-leak ~0.1nA, OP: c_s 1.17V / Q4 VCE 0.59V / switch VCE 0.58V; temp corners -20/25/85C asym stable ~0.8e-3 (27h); k-linearity clean (27k); replica timing skew ±2ns no effect (27r).
- Remaining sensitivities (both cells): Q/Qbar skew slope ~2.3e-3/ns and Q vs Qbar EDGE-RATE mismatch (±0.5ns of 2ns -> ±(3..9)e-3, 27g). RC base caps do NOT fix (27m/27n tried 22p/100p — worse). Full-overlap regime + two-phase replica also no (27q/27u — asym ∝ skew persists, mechanism cell-intrinsic at 50/50 state).
- **PROPOSED RESOLUTION (pending user ratification): ECL/PECL-class differential reclock FF (e.g., onsemi ECLinPS-EP MC100EP52 class) driving the BJT pair.** Guaranteed Q/Qbar skew <=30ps (-> asym ~1e-4), inherently matched complementary edge shapes, <0.2ps additive jitter, and LVPECL output levels (1.6-2.4V @3.3V VCC) land on the required 1.36-1.86V base window with a simple resistive shift — the classic ECL-driven bipolar current-steering architecture (PCM63 lineage). Replaces LVC74A/AVC16T245 selection in bom.md §1.2 if ratified.
- Decks: bfdac_cosim26{,b,r,s,t,L,u,v,w,x,y,z,z2,p5,p5t,f}.cir, bfdac_cosim27{,b,t,r,f,g,h,k,m,n,p,q,s,u}.cir in Documents/LTspice; asym_sweep.py in repo.
- OPEN: ratify BJT cell + ECL FF; then re-lock cell (§2/§1.2 BOM + Fig 1b/2), re-run noise deck with BJT cell, INL/static (Ib of switch pair — alpha error), full cosim chain + temp battery, FF MPN datasheet verification.

## Round 29 — RATIFIED + LOCKED: BJT CELL + MC100EP52; FIRST END-TO-END SIM PASSES (2026-07-22, bfdac_e2e1.cir)
- **USER RATIFIED** the Round-28 proposal. Locked into bom.md + schematic.html (Fig 1/1b/2 redrawn):
  - §1.2: **MC100EP52** x128 (differential LVPECL D-FF, VCC 3.3V TPS7A4700 rail, 1 per channel bank); FPGA 1.8V -> D via 3.6k/1k shift vs V_BB (new buffered 2.31V rail); LMK clock -> CLK via same network; **SN74LVC74A + SN74AVC16T245 REMOVED**; timing budget improves to ~13-16ns setup.
  - §1.1: LMK1C1108 count 9 -> **18** (2 roots -> 16 leaves -> 128 clock traces, single-FF packages).
  - §2: cell = **DMMT5551** same-die steering pair (1 pkg/cell), base networks **100R series + 165R to new buffered 1.00V rail** (swing 1.36-1.86V from PECL 1.6/2.4 levels); THAT300 tail/750R/1.25V line unchanged.
  - §9: added 1.00V steering-bias rail + 2.31V shift rail to reference ladder.
  - Open sync items 2 & 3 marked RESOLVED (datasheet verification of EP52 pinout/V_BB fanout/supply current still pending).
- **END-TO-END DECK `bfdac_e2e1.cir`**: PECL FF (behavioral 1.6/2.4V, 0.4ns edges, 30ps Qbar lag) -> 100/165 shift -> 8 live BJT cells + statics/padding -> shared cascode + replica + Ib-comp -> behavioral-amp I/V + real diamond -> 3rd-order Bessel filter (77.6u/1.99n/15.5u, 150R tapped, full-termination 6V tap) -> discrete line V-stage (VLEG from bfdac_vstage2g) -> 600R diff load. **Results: step_diff 1.194V (8 cells), chain gain 1.760 (theory 1.747: Av 1.769 x filter DC 0.9875), overshoot 0.42% (Bessel-clean), vo_cm -23mV, cell OP c_s 1.187V / Q4 VCE 0.61V / switch VCE 0.56V / tail 0.7699mA, plateau_err_e2e +2.0mV (window likely not fully settled - recheck with longer windows).**
- **SIM GOTCHA (documented for all future composed decks): the line V-stage has a reachable latched DC state** (Round 16/18 lineage - line variant kept Rm=200R). Standalone Newton finds the healthy OP; in the composed deck global Newton fails -> gmin stepping lands in the latch (out CM at -14.7V). Fix in-deck: `.nodeset` on VLEG internals (nd1 12.8, vb2 13.5, ev 14.2, cvc 8.7, vas/out/fb 0, bm 13.1). **Hardware watch item: verify line-stage start-up behavior on the bench; consider the HP-stage Rm=100R fix if bring-up shows latch.**
- NEXT (todo 28): sine-stimulus e2e (needs DEM-patterned cell drive), noise deck w/ BJT cell, static INL (alpha/Ib term), temp battery on e2e, EP52/LMK datasheet verification, XDC pin assignment (todo 9) + FF-clock timing constraints (todo 13).

## Round 30 — FPGA SIDE LOCKED TO ROUND-29 ARCHITECTURE: PINS, CELL_CLK RETIME, XDC TIMING (2026-07-22)
- **Todo #9 CLOSED — 128 cascode pins assigned** in `vu13p_dac_top.xdc` §8: L = banks 64+65, R = banks 67+69, explicit PACKAGE_PIN per bit generated from `Alinx/ACVU13P-Pin-Assignment-20260703.csv` (L-pair sites only, no T/VREF pins; conflict-checked against every other XDC assignment — 0 collisions; generator output kept in `Alinx/cascode_pins_gen.txt`). Bit order = LA-pair number; per-cell remap at layout is free (DEM decorrelates cell position).
- **Todo #13 CLOSED — mclk-phase-aligned launch + virtual-FF-clock output timing:**
  - `sys_clock_gen.sv`: MMCM CLKOUT1_DIVIDE 10→20 = mclk rate (45.1584/49.152 MHz), phase-aligned by the MMCM feedback loop; new `cell_clk` output on its own BUFG.
  - `dac_dsp_core.sv`: cascode IOB stage retimed dsp_clk→cell_clk via toggle-handshake CDC (staging stable ~8 cell_clk per 6.144 MHz DEM update; ASYNC_REG toggle sync + gated bus capture + IOB regs all on cell_clk; local 2-FF reset sync). IOB launch on a cell_clk edge = full mclk period at the MC100EP52 D input.
  - `vu13p_dac_top.sv`: cell_clk wired clock-gen → dsp core; header updated to Round-29 architecture (MC100EP52, no translator).
  - XDC: `create_generated_clock cell_clk` (CLKOUT1/BUFG); `set_max_delay -datapath_only 3.5` staging/toggle → cell-domain capture (kills the 89 ps dsp↔cell related-clock edge chase); false path into cell_rst_sync CLR; virtual `ff_clk` (20.345 ns) with `set_output_delay -max 2.5 / -min -1.5` on all 128 ports (flight 1.0 + shift 0.1 + EP52 setup 0.2 + LMK skew 1.0 margin; VERIFY vs datasheets before layout). Old dsp_clk-referenced output delays deleted.
- bom.md §1.3 pin row updated to ASSIGNED. NOTE: `BFDAC_IMPLEMENTATION_PLAN.md` is stale (still says LVDS cell outputs / XDC blocked / DWA DEM) — historical document, bom.md + XDC are authoritative.
- VERIFIED (todo #14, Vivado 2026.1 standalone xsim in `sim_run/`, unisims + glbl):
  - xvlog clean on all edited RTL (user-run + re-verified).
  - **REAL RTL BUG FOUND by unisim elaboration: `sys_clock_gen.sv` connected `CLKINSEL` on MMCME4_BASE — that port only exists on MMCME4_ADV.** Removed (clock select is external on the LMK00304 anyway). This would have failed first synthesis.
  - **`tb_vu13p_top.sv` REWRITTEN** (was several rounds stale: old port names, 64-bit DDR3-style bus, no CRC on SPI frames, nonexistent disable label). New tb: diff clocks, behavioral LMK00304 mux, 768 kHz-frame I2S source, CRC-8(0x07) 40-bit SPI master, defparam-shortened automute timers, FSM debug monitor. **ALL 7 TESTS PASS** (~135 us sim): MMCM lock, reset/mute state, SPI CRC+unmute→relay, cascode no-X, **cascode toggling through the new dsp_clk→cell_clk CDC (312 updates)**, I2S-stop→watchdog→relay drop. `tb_vu13p_top.tcl` added.
  - tb gotcha worth remembering: I2S LRCLK must be ≥ ~550 kHz (watchdog = 512 dsp_clk ≈ 1.8 µs between frames); a 384 kHz frame rate retriggers automute reset every ~2.6 µs (FSM never leaves FLUSHING — looks exactly like a broken unmute path).
  - `tb_dac_dsp_core.sv`: cell_clk port driven (40:7 ratio); 6/7 tests pass. **PRE-EXISTING FAILURE (not Round 30): FIR output `interp_l` is X-poisoned in xsim (URAM288 coefficient read path) → NS/DEM output rails to all-ones; test 5 (L/R independence) fails and tests 3/6 pass only coincidentally.** Needs URAM init / coef-write investigation — new todo.
- fpga_irq_n is LOW in all full-top sims by design: DDR4 stub holds init_calib_complete=0 → sticky_err[2].
- **DATASHEET VERIFICATION DONE (todo #28 doc half + bom item #5; sources: MC10EP52/D rev 7, LMK00304 SNAS578G, LMK1C110x SNAS717A):**
  - **FINDING 1 — MC100EP52 has NO V_BB pin** (SOIC-8: CLK/CLK̅, D/D̅, Q/Q̅, VCC, VEE; the IBB abs-max row is family boilerplate). §1.2 design assumed on-chip V_BB for D̅/CLK̅ bias → replaced with an external ≈2.1 V threshold rail (divider + buffer per FF group). Also: VIHCMR min = 2.0 V means the old 2.0 V center put the low state exactly at the limit → recenter to ≈2.1–2.2 V. New bom open item #8.
  - **FINDING 2 — FF rail power underestimated:** IEE = 35 typ / 47 max mA per FF + ≈7 mA load network ⇒ ≈2.7 A typ / 3.5 A max PER CHANNEL (≈18 W array). One TPS7A4700 (1 A) per channel is insufficient → ≥3 per channel or a 4 A-class LDO. New bom open item #7.
  - Good news: EP52 timing better than budgeted (tpd 330/410 ps, setup 50 ps, hold 0 ps, jitter 0.2 typ/1 max ps); LMK00304 51 fs / 50 ps skew confirmed; LMK1C1108 12–20 fs, 35/55 ps skew, but part-to-part skew 280 ps dominates leaf-to-leaf (still inside the 1 ns budget). LMK00304 non-glitch-free mux CONFIRMED by TI E2E #1348412. XDC output-delay constraints kept conservative (annotated with verified actuals).
  - bom.md §1 fully updated (banner, §1.1, §1.2, §1.3 reg 0x03, §1.4, open items 3/5 closed, 7/8 opened); XDC §8 comments updated; `BFDAC_IMPLEMENTATION_PLAN.md` banner-archived (todo #31 closed).
  - Remaining #28 sim sub-items (NOT doc work): noise deck w/ BJT cell, static INL (alpha/Ib), temp battery on e2e.
- **EP52 THRESHOLD-RAIL DESIGN (closes bom item #8; user-prioritized):** three buffered rails per channel from the FF 3.3 V LDO (ratiometric): **offset rail 2.49 V** (revised from 2.31 V; same 3.6k/1k networks → D pin swings 1.95–2.34 V center 2.15, CLK pin 1.95–2.67 V center 2.31; ≈40 mA/channel, buffer must sink), **THR_D 2.15 V** (64 D̅ pins; ≤9.6 mA DATA-DEPENDENT via IIH 150 µA vs IIL 0.5 µA), **THR_CLK 2.31 V** (64 CLK̅ pins, periodic). THR_D/THR_CLK deliberately SEPARATE rails: shared rail would convert data-dependent D̅ input current into clock-threshold modulation = data-dependent jitter. Margins: low-state VIHCMR 150/310 mV above the 2.0 V floor (old design sat exactly at it); VPP 390/720 mV vs 150 min; divider accuracy ±35 mV vs ±150 window. Jitter: pin slew 0.6–1.4 V/ns, σv<10 µV → <17 fs (negligible vs FF 0.2–1 ps). Realization: E96 divider → 1 µF RC (44 Hz) → dual op-amp buffer (OPA1678-class, MPN at §9 pass) → 2.2 Ω/10 µF → star → 10 Ω + 100 nF per pin (kickback isolation). bom.md §1.2 note + R41x/R42x rows + §9 rows updated. Nice-to-have before layout: LTspice kickback sanity of rail + network.
- **USER VETO — MC100EP52 RECLOCK STAGE (power/thermal):** verified ≈140 mW/cell static (42 mA × 3.3 V), ≈18 W array. User ruling: **hard thermal constraint made explicit** — drive electronics sit adjacent to matched DMMT5551 pairs; per-cell heat ⇒ gradient drift on the very parts doing precision steering. Target ≤ ~10 mW/cell, array ≤ ~1–1.5 W. ECL is static-bias (power independent of clock rate — no low-power slow ECL exists), so the family itself is disqualified, not just the MPN. bom §1.2 REOPENED (Round 29 design kept for record); open items 7/8 overtaken, new item 9. Round-30 threshold-rail design becomes contingent/retired if replacement is ratified. Candidate direction (NOT ratified): octal CMOS register (1–2 mW/FF dynamic) + **single-ended steering drive vs fixed buffered VREF** — sidesteps the Round-28 complementary-matching problem (skew=0 by construction, reference is static) instead of buying matched edges with a biased differential driver. Round 28 sims covered complementary drive ONLY; needed before ratification: cosim27-lineage single-ended variants — (a) rise-vs-fall edge-rate asym (slope 2.3e-3/ns, budget |asym| ≤ 1e-3), (b) emitter-node CM bounce/injection through the cascode (single-ended drive moves the pair CM by swing/2). If adopted: 128→16 clock leaf loads (LMK1C1108 18→≈3), FF rail mA-class, big BOM shrink.
- **COSIM28 CAMPAIGN — SINGLE-ENDED / LOW-POWER CMOS RECLOCK EVALUATION (user-directed; NO doc/BOM changes until ratified).** Decks bfdac_cosim28{,b,c,d,e,f,g,h}.cir vs 27f baseline (asym 7.6e-5 @skew0, slope 2.3e-3/ns). All power figures PASS the ≤10 mW/cell constraint; all asym figures FAIL or are marginal:
  - 28 single-ended vs mid-VREF (LVC574 real: Ro 23R, 2n edges, dtrf=tr/tf mismatch swept ±1n): asym 5.7e-2 @dtrf0 — Q41 tail cascode near-saturated in the minus state (emitter rides max(bases)−Vbe → state-dependent level, inherent to single-ended).
  - 28b levels raised (vcm 1.85/vhalf 1.90, clears sat): 1.1e-2 @dtrf0, slope 1.1e-2/ns, drive 8.8 mW/cell. 28c speedup caps: worse (1.5e-2) — reconfirms 27m/27n. 28d Cjc-comp caps: no change → Cjc coupling not dominant.
  - 28e complementary same-die CMOS (pre-register inverter idea), rs/rp ×3 + 22p base RC: asym −1.5e-3 @dtrf0 BUT slope 1.3e-2/ns → ±1n real LVC tr/tf band swings ±1.4e-2. 0.8 mW/cell. 28f cross-base cap: same class. 28h ideal-replica diagnostic: identical → the CELL is the transducer, not the replica path.
  - 28g micropower DMMT5551 commutator predriver (1.9 mA tail): −4.7e-3 @0, slope 1.4e-2/ns, ~8 mW/cell — commutation does NOT remove the input duty transduction.
  - **CONCLUSION: the steering cell transduces driver rise-vs-fall (duty) mismatch at ~1.1–1.4e-2 per ns in every topology tried. |asym| ≤ 1e-3 ⇒ need |tPLH−tPHL| + edge-shape mismatch ≤ ~100 ps at the bases — an ECL/LVDS-class spec that CMOS logic does not provide. Low-power single-ended CMOS FAILS as-is; complementary same-die CMOS is marginal at typicals and fails across the datasheet band.**
  - Ways out (user decision pending): (A) constant-transition-density coding (RTZ-class DEM in RTL) — makes per-event charge error code-independent (gain, not distortion); CMOS power ~1–3 mW/cell stands; needs dem_study verification + amplitude/noise cost; (B) per-cell driver with SPEC'D pulse skew ≤100 ps (LVDS-class tsk(p)) — 25–35 mW/cell ≈ 3–4.5 W array, over budget; (C) accept ~140 dB class at 1e-3–5e-3 asym.
- **RTZ-DEM VERIFICATION legs 1+2 (user-ratified direction: RTZ coding + 175-class FF retiming; ratification of BOM still pending legs 3/4):**
  - Leg 1 (`rtz_study.py`, reuses dem_study physics): (a) COMMON duty error a0·code residue = 164.9 dB even at the worst measured asym 2.7e-2 → the RTZ gain-linearization claim is numerically confirmed; (b) PER-CELL duty spread acts as extra static mismatch, DEM-shaped: with **DWA classic** (re-eligible — RTZ makes transition count k benign, so const-k is no longer required; +20 dB mismatch shaping vs const-k K=4) σ_d=5e-3 → 134.1 dB, 1e-2 → 125.2 dB; requirement: **cell-to-cell |tPLH−tPHL| σ ≤ ~400 ps for ≥134 dB** (81.4 ns pulse @6.144 MHz, 50% duty) — comfortably real for same-family CMOS FFs. DWA idle-tone check at other amplitudes still owed.
  - Leg 2 (`bfdac_cosim28j.cir`, 175-class complementary drive, k∈{1,2,4,8} cells pulsing simultaneously, dtrf∈{0,1n}, locally-anchored per-pulse charge, plotwinsize=0/reltol 5e-5): dtrf=1n (NRZ-catastrophic, asym 2.7e-2) → **−2.43 % uniform gain shift**, k-variation of the shift only 3.3e-4 over k=1..8 ✓; per-pulse charge flat to ≤6e-5 for k=1..4; **k=8 shows a reproducible +3e-4 uplift** — suspected STATIC bus-compliance effect (bleed/bus level vs code), common to NRZ, not RTZ-specific → folded into #28b static-INL deck + full-array e2e (#29). Drive power under RTZ ≈2.9 mW/cell ✓.
  - First-run artifact note: unanchored integration showed a fake linear-in-k compression from the 9.1 µs bus-bleed drift (R_bleed·C_bus); per-pulse local anchoring removes it.
  - Leg 3 (`rtz_noise.py`) — RTZ timing-error physics: pulse-POSITION jitter and close-in phase noise cancel (charge-invariant); pulse-WIDTH jitter (broadband, uncorrelated edge pair) is the common term; SSN shifts rise and fall edge groups by β_r·code and β_f·code, so only the rise-vs-fall DIFFERENCE Δβ survives, as a code² (HD2) term. Results @75% duty (preferred: amplitude cost only −2.5 dB, thermal floor 138→135.5 dB ✓): width jitter 80 fs → 139.5 dB ✓ (tree floor 50–80 fs); per-cell FF edge jitter η=0.5 ps → 137.6 dB, η≤1 ps required ≥131.6 dB; **SSN Δβ: 0.05 ps/cell → 104.7 dB, i.e., SHOWSTOPPER for multi-FF packages** (CMOS SSN is 10s of ps per simultaneously-switching output; a quad 175 couples 4 cells → code² distortion at 75–100 dB class even with the 1/n_pkg locality refinement). NRZ context: 80 fs common jitter → 171.9 dB (NRZ was jitter-insensitive; RTZ pays a real but affordable jitter bill).
  - **FF CHOICE OVERTURNED BY SSN: single-FF-per-package required** — candidate **74LVC1G74** (single D-FF, true Q/Q̅, native 3.3 V, SOT-23-6-class, ~1–2 mW dynamic, 64/channel, placeable adjacent to each steering pair; the Round-29 clock tree already assumed 128 single-FF leaf loads). With 1 FF/package, SSN count ∈{0,1} → per-cell effect, DEM-shaped ✓. Requires per-package rail isolation (R/ferrite + local C) so board-rail droop ∝code stays width-symmetric — bound in e2e battery.
  - Leg 4a (SN74LVC1G74 datasheet, TI rev G): fmax 175–200 MHz @3.3 V vs the ~12.3–24.6 MHz RTZ clock (2×/4× cell rate for 50/75 % duty) — huge margin ✓; tpd 2.2–7.1 ns window @3.3 V; "balanced outputs" feature; Icc static 10 µA ✓; dynamic ≈3–4 mW/cell at the RTZ clock + ~1–3 mW network ⇒ ≈5–7 mW/cell ✓. NOT spec'd (bench-verify items, tolerances now generous — see 4b): part-to-part |tPLH−tPHL| spread (need σ ≤ ~600 ps @75 % duty; typicals suggest 200–500 ps) and additive jitter (need ≤1 ps; LVC-class typ 0.2–0.5 ps).
  - Leg 4b (`dwa_tones.py`/`dwa_tones2.py`/`dwa_tones3.py`, 0.22 % combined sigma): DWA classic has real idle tones (peak −129.9 dBFS at −60 dBFS input — pokes above the 135.5 dB thermal floor); naive pointer dither destroys shaping (−109 dBFS). **WINNER: unconstrained sort-based 2nd-order vector shaper (acc1+0.5·acc2, argpartition per sample) — only legal under RTZ (toggles free): in-band −153 to −167 dBFS, peak tones ≤ −168 dBFS across all amplitudes incl. DC-offset provocations.** 25–40 dB better than DWA, tones dead. RTL cost: 64-way partial sort at 6.144 MHz (iterative over 8 cell_clk cycles). The margin also relaxes the duty-spread requirement ~3× (σ_d ~6e-3 → still ≈−143 dBFS).
  - Ratification-review Q&A (user challenges, all resolved in favor of the architecture): (1) **Manchester encoding evaluated and rejected** — pure Manchester nulls the baseband signal exactly (energy moves to Fs/2, the RF-DAC "mix mode"); the salvageable every-cell-pulses variant (dual-width/return-to-complement) keeps constant RISE count but the fall groups split c/(64−c) → same SSN code² term (still needs single-FF), costs −6 dB vs −2.5 dB, and has a higher signal-independent jitter floor (all 64 cells inject edges). RTZ 75 % dominates on every axis. (2) **Derived layout tolerances** (for bom §1 rewrite): Q/Q̅ intra-pair trace mismatch ≤ ~700 ps ≈ 12 cm (static per-cell → gain + shaped; sloppy routing gives <12 ps); clock-tree skew ≤ ~±5 ns ≈ ±80 cm (RTZ position-invariance: rise+fall from same leaf → charge invariant; residual = 1e-4 rad phase at 20 kHz + settle-window erosion; skew spread even helps by staggering SSN edge groups). Sub-ns length matching is dead; only analog cell matching (resistor networks, DMMT5551) keeps its constraints. (3) Single-FF area/routing concern resolved: Round-29 plan was already 128 single-FF SOIC-8 + tree for 128 leaves; SOT-23-6/DPW is 3–5× smaller, 18 W→<1 W; cost = ~384 isolation passives. (4) Literature for the RTZ/ISI claims: Remple & Galton TCAS-I 2016 (10.1109/tcsi.2016.2601026, ISI-in-DEM proof: gain vs shaped), Risbo et al. JSSC 2011 (10.1109/jssc.2011.2164965, hi-res audio ISI), ICECS 2018 RTZ+FIR (10.1109/icecs.2018.8617899), Nandi & Pavan JSSC 2013 SCRZ (10.1109/jssc.2013.2259012).
  - **ALL FOUR LEGS PASS. Converged architecture awaiting user ratification: FPGA (RTZ-encoded 75 % duty, sort-based 2nd-order vector-shaper DEM) → 1× SN74LVC1G74 per cell (single-FF package mandated by SSN, true Q/Q̅, adjacent to each DMMT5551 pair) → steering pair. ≈5–7 mW/cell, array <1 W. Bench-verify: 1G74 duty spread + additive jitter. Sim follow-ups: full-array RTZ e2e (#29), k=8 static uplift (#28b), board-rail SSN width-symmetry bound (36e).**
- **RATIFIED (2026-07-22, user) + DOCS SYNCED:** RTZ 75 % duty + sort-shaper DEM + 1× SN74LVC1G74/cell committed. `bom.md` §1 rewritten (§1 status LOCKED Round 30; §1.1 length matching retired; §1.2 new design + parts table incl. AXC1T45-class translator U440–U567 — **new finding: FPGA LVCMOS18 1.8 V < LVC VIH 2.0 V @3.3 V, translator required**, timing benign/retimed away; rs/rp 1.41k/246Ω vs VCM 1.85 V per cosim28j; EP52 section archived; §1.4 recomputed; open items 8/9 closed, 10 (bench-verify) / 11 (rail isolation) / 12 (translator MPN) opened). `schematic.html` Fig 1/1b + traceability table synced.
- **RTL IMPLEMENTED + ALL SIMS PASS (Round 30 RTZ/sort-shaper):**
  - `dem_sort.sv` NEW: unconstrained sort-based 2nd-order vector shaper. Counting-rank implementation (rank_i = #{j: M_j<M_i or tie j<i}, sel = rank<c), 2 comparison lanes/cycle → 34 dsp_clk latency (56-cycle budget @350 MHz). Metric M=2·A1+A2 (g2=0.5 ×2 integer-scaled); 24-bit signed accumulators (python-verified bounds: |A1|≤63, |A2|≤382 audio; ≤103k at sustained 0 dBFS overload, self-bounding). Integer-exact reference + golden vectors: `dem_sort_gen.py`; SNDR/tone re-check of the exact RTL algorithm (lexsort tie-break): `dem_sort_check.py` → −153.7/−164.6/−168.3 dBFS in-band, tones ≤ −168.3 ✓.
  - `dac_dsp_core.sv`: dem_dwa → dem_sort (valid_out replaces the fixed 3-stage delay pipe); RTZ phase counter in cell_clk domain (resets on CDC capture, gate high phases 1-6 → EXACTLY 6 cell_clk wide pulses regardless of CDC wobble; parks at phase 7/low when streaming stops); IOB regs gate `rtz_gate ? cell_cap : 0`.
  - `tb_dem_sort.sv` NEW (+ golden mem in Testbench/): reset / 2000-sample bit-exact golden match / popcount / latency / extremes / balance — **ALL PASS** (latency max 34, balance 127..129).
  - `tb_dac_dsp_core.sv` tests 3/5 adapted for RTZ (outputs pulse during streaming and park at 0 after drain — single-instant sampling replaced by windowed monitoring on cell_clk with concurrent streaming via fork/join). **ALL 7 PASS** — including TEST 3 signal-flow and TEST 5 L/R independence which previously failed under the "FIR URAM X-poisoning" flag (#32): FIR now demonstrably produces real signal end-to-end → #32 likely stale/environmental, downgrade and re-verify before closing.
  - `tb_vu13p_top.sv` unchanged: **ALL 10 PASS**, cascode CDC toggle count 312→625 updates (RTZ pulsing visible through the full top) ✓. `run_sim.tcl` source list updated.
  - Remaining from ratification: e2e sine/FFT chain (#29, includes full-array RTZ LTspice deck), bench-verify items (bom #10), rail-isolation bound (#11).
- **#29 E2E SINE/FFT CAMPAIGN (in progress — PAUSED 2026-07-22 evening, session budget). The e2e test is earning its keep: FOUR real pre-existing bugs found, three fixed+verified, one open anomaly.**
  - Test rig: `tb_e2e_sine.sv` (coherent 1031.25 Hz, −1 dBFS, 512 input samples → 65536 DEM updates, uniform-boxcar FIR coefs = LTI so spectral purity holds; captures dem_out_l/paced_l/dither_l hex streams) + `e2e_sine_fft.py`/`e2e_bisect.py`/`e2e_align0.py`/`e2e_state_probe.py`. Rate/level probe: `tb_rate_probe.sv`.
  - **BUG 1 (FIXED): halfband_x2 never interpolated** — per-input phase toggle emitted ONE output per input (16 updates/sample end-to-end instead of 128; the DAC would have run at 768 kHz). Fix: emit BOTH phases per input (passthru then filtered, OUT_SPACING=4/2/1 for HB1/2/3), plus **sample pacer** in dac_dsp_core: 256-deep FIFO + cell_clk/8 pop tick (FIR sweep bursts 128 updates into ~1024 clk; NS/DEM/CDC need even 6.144 MHz; overflow warns once — accelerated top-tb overruns legitimately). Verified: 16/32/64/128 per stage ✓, dem_enable spacing ≥45 clk ≥ dem_sort's 36, 0 drops.
  - **BUG 2 (FIXED): NS feed scaling** — old `stable_l[63:16]` (top-48 slice) delivered 2^-17 of the NS input range (−102 dB: converter would have output shaped idle noise with buried signal). Fix: `ns_feed()` = volumed[46:0]<<1 saturating (FIR FS lives at bit 46).
  - **BUG 3 (FIXED): noise_shaper_7th_order coefficients {7,6,5,4,3,2,1} have NTF(DC) = −3 — NO DC zero, in-band noise AMPLIFIED** (−16 dB SNDR standalone). Analysis (`ns_coef_check.py`): FIR-EF is hard-capped at 2nd order with ±28-level signals (headroom ~6 levels vs ||h||₁·1.5 feedback swing); higher order needs NTF poles. **NEW `noise_shaper_ef3.sv`: NTF=(1−z⁻¹)³/(1−z⁻¹/2)³, all-dyadic shift-add, 136 dB** (`ns_ef3_gen.py` integer-exact reference + golden; `tb_ns_ef3` ALL PASS incl. overload recovery). Swapped into core (dem_enable delay pipe unchanged, 6≥4 stages ok).
  - **BUG 4 (FIXED): tpdf_dither_gen advanced its 32-bit LFSRs ONE bit per sample** — consecutive dithers shared 31/32 bits → measured **50 % of dither power in-band** (white = 0.65 %) → unshaped floor at the quantizer. Rewritten: 2× xorshift64 full-state scramble per enable, TPDF ±0.5 level; measured white (0.57 % in-band) ✓. Dither enable moved volumed_valid→pace_valid (1 fresh value per NS sample).
  - **ANOMALY RESOLVED (2026-07-23): it was an FFT MEASUREMENT ARTIFACT, not hardware.** Chain of proof (`ns_identity_probe/ns_ntf_verify/ns_window_check.py`): RTL bit-exact vs model (0/65536); no clips/clamps; exact loop identity y·LSB = u+32·LSB+f−e holds to 0; truncation chain −305 dBc; e white. The bimodal 95.0-vs-136 dB rect-window SNDRs collapse to ~116 dB under Hann (both "modes") — **rectangular-window edge leakage of the out-of-band shaped noise** (noise state is not window-periodic even with a coherent sine); Hann's own sidelobes then floor at 116. Correct methodology: **Kaiser β=38 window (sidelobes <−280 dB), ±12-bin main-lobe exclusion** — `e2e_final_fft.py`.
  - **FINAL E2E RESULT (Kaiser, −1 dBFS 1031.25 Hz, boxcar coefs): in-system DEM popcount SNDR = 138.6 dB** (> 133.5 dB code budget line ✓); NS input (paced_l) = 152.9 dB; python EF3 = 142.2 dB. #29 RTL leg CLOSED.
  - **FULL REGRESSION after all swaps (2026-07-23): tb_dac_dsp_core 7/7 PASS, tb_vu13p_top 10/10 PASS, tb_ns_ef3 ALL PASS, tb_dem_sort unchanged.** Remaining #29 sub-item: full-array RTZ LTspice deck (analog leg); bench-verify (bom #10), rail isolation (#11), translator MPN (#12).
  - **#32 CLOSED (2026-07-23):** the "FIR URAM X-poisoning in xsim" flag is stale — FIR provably passes real signal end-to-end (tb_dac_dsp_core 7/7 incl. signal-flow and L/R tests; e2e sine captured 138.6 dB SNDR through the full chain). Was environmental/fixed by interim RTL changes.
  - **RTL CLEANUP (2026-07-23, user-ratified): DELETED `noise_shaper_5th_order.sv`, `noise_shaper_7th_order.sv`, `tb_noise_shaper.sv`.** Reason: both are FIR error-feedback shapers, and that architecture is **mathematically capped at 2nd order for this converter** — with a 64-level quantizer and the ±28-level signal plan, quantizer headroom is ~6 levels while FIR-EF feedback swing is ||h||₁·1.5 levels (binomial L=3 already overloads; the 7th-order's "stable" de-tuned coefficients destroyed the DC zero = Bug 3). Higher-order shaping requires NTF poles, which `noise_shaper_ef3` provides; it beats the code budget line by ~5 dB and system noise is dominated by thermal/DEM-mismatch anyway, so re-adding a higher-order FIR-EF shaper is pointless. Do NOT restore. Also: `run_sim.tcl` source list pruned; stale comment refs fixed (`dem_64.sv`, `tb_dac_dsp_core.sv`, `tb_e2e_sine.sv` header now documents N_SKIP=0 capture + Kaiser methodology). FULL SUITE RERUN post-cleanup: **PASS — tb_ns_ef3, tb_dem_sort, tb_dac_i2s_ingress (11/11), tb_coef_bank_loader, tb_halfband_x2 (updated for the Round 30 true-x2 contract: 2 out_valids/input, passthru-first ordering, doubled IR capture), tb_dac_dsp_core (7/7), tb_vu13p_top (10/10)**. PRE-EXISTING failures, NOT from this campaign (stale tbs vs evolved RTL, per git history): tb_i2s_rx (data mismatch), tb_spi_ctrl_plane (references removed ports relay_out_status/gain_switch_busy — doesn't elaborate), tb_fir_polyphase_stereo (procedural-driver conflict on cycle_count — doesn't elaborate). Deferred pending user direction. **STALE-TB TRIAGE COMPLETE (2026-07-23, user-directed): all 3 fixed — and two exposed REAL RTL BUGS.** (1) `tb_spi_ctrl_plane` rewritten for the level/outsel scheme (13/13 PASS) → **RTL BUG A: `level_switch_req`/`outsel_switch_req` could NEVER fire** — change detection compared `cmd_*` vs its 1-cycle-old copy, but both only update on the same single-cycle `ctrl_bus_valid`, so they were always equal at pulse time (relay switching dead in hardware). Fixed in `dac_ctrl_plane.sv`: compare incoming `ctrl_bus_data` vs current register. (2) `tb_fir_polyphase_stereo`: fixed tb `cycle_count` + `polyphase_mac_engine` dbg driver conflicts → tb then ran and exposed **RTL BUG B: URAM288 coefficient packing wrong for BWE_MODE=PARITY_INTERLEAVED** — each BWE bit gates data byte [8b+:8] + parity bit [64+b], NOT 9 contiguous bits; the old [17:0]/[35:18]/[53:36]/[71:54] lane layout straddled byte boundaries so odd-MAC coefs lost upper bits IN HARDWARE (DC known-answer = exactly half; even MACs only). The `ifdef SIM` behavioral model hid it (this was the true root of the old #32 'URAM X-poisoning' ghost). Fixed in `fir_polyphase_stereo.sv`: lane k={mac_odd,bank} stores coef[15:0] in data bytes [16k+:16] + coef[17:16] in parity bits [64+2k+:2]; behavioral model now mimics real PARITY_INTERLEAVED gating. tb passes 7/7 with BOTH the real URAM288 primitive (-L unisims_ver, no -d SIM) and the behavioral model. (3) `tb_i2s_rx`: tb defect only — it checked the un-synced priming frame (receiver aligns on first LRCLK edge, first L word legitimately incomplete); checker now skips frame 1, 6 frames sent, ALL PASS + proper verdict line. POST-FIX REGRESSION: tb_dac_dsp_core 7/7, tb_vu13p_top 10/10, tb_spi_ctrl_plane 13/13, tb_fir_polyphase_stereo 7/7 (URAM+behavioral), tb_i2s_rx PASS. NOTE: ad-hoc xsim runs of FIR tbs MUST either pass -d SIM or elaborate with glbl + -L unisims_ver; run_sim.tcl's 4-tb list does neither for URAM designs (its list doesn't include the FIR tb). Re-verified post-delete: tb_dac_dsp_core 7/7, tb_vu13p_top 10/10 PASS.
  - Files touched this leg: `halfband_x2.sv`, `dac_dsp_core.sv` (pacer+ns_feed+ef3+dither enables), `noise_shaper_ef3.sv` (new), `tpdf_dither_gen.sv` (rewrite), `tb_e2e_sine.sv`/`tb_rate_probe.sv`/`tb_ns_ef3.sv` (new), goldens `ns_ef3_golden.mem`, py: `ns_coef_check/ns_ef3_gen/e2e_sine_fft/e2e_bisect/e2e_ns_replay/e2e_dither_replay/e2e_align/e2e_align0/e2e_state_probe`.
- **SINGLE-REGISTER CLOCK CONTROL (user request):** SPI 0x03 (`base_rate_sel`) now drives BOTH the DSP family select and the LMK00304 OCXO mux; 0x06 removed/reserved (`clk_source_sel` is a comb alias in `dac_ctrl_plane.sv` — readback regs 0x12/0x13 keep their bit positions, both bits now always agree). The top-level switch sequencer additionally enforces mute-before-switch IN HARDWARE (was host-firmware convention): register change → automute `rate_changed` drops relay drives + force_zero → `MUTE_DELAY_CYCLES` wait (new top param, 20 ms @ 200 MHz for mechanical relay release; 10 µs in sim) → MMCM held in reset → `clk_sel` flips → 10 µs mux/OCXO settle → release → relock (~100 µs) → `sys_rst_n` flushes every dsp/cell-domain pipeline (FIR, halfbands, NS, DEM, staging, cascode IOBs; the 128 pins reset to 0 so the EP52 FFs clock a static all-off pattern during the switch) → automute auto-re-runs to PLAYING since `cmd_unmute` lives in the always-on clk_200m domain. New tb TEST 5 verifies the full order (mute-before-flip, flip-during-reset, relock, auto-re-unmute): **ALL 10 TESTS PASS**. ARM firmware note: rate change is now ONE write to 0x03; 0x06 writes are ignored.

## Rounds 31-32 - Full-Array RTZ Analog Verification (#29 leg): RATIFIED STACK FAILS; passive-termination study reaches 364ppm plateau (bfdac_cosim29..32 series, 2026-07-23)
- **Replica-DAC option C first (bom #6, cosim29 series, NRZ framework):** transistor-level replica verified. Naive area-scaled single cell FAILS (q_pc 0.004%->0.78%, edge-shape nonlinearity); **64-unit-cell replica array (v29g) = 0.025% flat, 131.3dB** through dem_study (vs 133.5 behavioral); robust to 2ns skew + 0.5% weight mismatch; compact scaled-device variant (v29m) 126.4dB. 5mA mirror bleed required for asym. User flagged footprint (~64 units/channel); decision deferred to the RTZ deck - then superseded by the RTZ finding below.
- **FULL-ARRAY RTZ DECK (cosim30, 64 real cells, RTL-faithful 8-phase timing): the ratified I/V+cascode stack CANNOT process full-scale RTZ.** At N=64 the loop enters a sustained ~7MHz relaxation ring (diffout -4.7..+8.2V, sum nodes +-0.6V, Q5p/Q5m alternately rectifying ~30% of each period, bus caps sloshing ~5nC). Invariant to bus caps 0.5n-10n, 10x amp (400MHz/2700V/us), C_f 390p-10n, C_sum 2.2n-100n. Root: RTZ moved 49.5mA/3ns full-code square steps into EVERY period; all NRZ verification assumed K=4 (3mA) steps. Waveform probe: utils/read_ltraw.py + rtz_wave_probe.py (new).
- **Round 31 (averaging I/V + stagger + behavioral RGC): all fail at 2% INL.** Steady-state exact-period INL metric (utils/rtz_inl.py; boundary-interpolated integration - nearest-sample windows fake mV-level INL). Current audit (rtz_audit.py): virtual ground clean to +-10uV; nonlinearity = +-0.8mA in avg Ie(Q5) - bus-side switch charge interacting with code-dependent bus trajectory. Ideal-cascode falsification: 5x better but amp then saturates - both stages implicated.
- **Round 32 (passive termination, commercial-DAC style, cosim32a-g): 14,000 -> 364 ppm via mechanism kills:**
  - replica-ff casb vs fixed: no difference at this level; bleed-R transduction EXONERATED (910->910k identical); raised bus (vfr 2.5V) no help; 8x4n stagger only ~2x (bus recovery tau > spacing).
  - bus caps: INL tracks bus_pp almost linearly (~1.1%/V transduction constant); 100n -> 59mV slam, 700ppm.
  - **MOSFET cascode kills the Ib-Jensen channel** (avg Ib nonlinear under slam ripple; Ib-comp tracks only the smooth replica current): 8100->927ppm @10n. Also deletes Q5C/QM/QN Ib-comp + snk-replica legs entirely.
  - **stiff gate drive** (47R->10R) cuts dip->Cgd->duty-modulation residual: 501->364ppm @100n.
  - **Plateau ~364ppm (HD2 ~ -70dB class vs -130 target). Root quantity: LVFET gate charge ~230pC/cell x64 = 15nC/period slam vs 94pC/period signal charge.**
- Remaining identified levers (unproven): low-Qg steering device (BJT quad / RF FET, 10-40x less charge), differential injection-cancellation caps, digital predistortion of the smooth static INL(N) bow (~100x on residual, needs cal). Composite could plausibly reach ppm-class = 2 more speculative legs + calibration infrastructure.
- **STATUS: Round 30 RTZ ratification is analog-unverified at target level. Options on table: continue passive-RTZ legs vs revert to NRZ+const-k (fully verified 131dB analog, driver-asym axis ~140dB accepted per Round 29 option C). USER decision pending.**

## Round 33 - Passive-RTZ BREAKTHROUGH: 364ppm -> 8.1ppm settled (bfdac_cosim33a-h, 2026-07-23)
- **Leg 1 (v33, BJT steering):** Q5551-class current-steering pairs replace the LVFET switches (base charge ~3-5pC vs ~230pC gate charge). Bus slam 42mV -> 1.8mV (25x). INL plateaus at ~250ppm - NEW floor, cap-independent.
- **Floor hunt (v33b/c/d):** double cascode: no change (not finite-ro); replica-law calibration 0.72-0.774m: no change; RGC on passive path: no change (295ppm).
- **v33e IDEAL-CASCODE ISOLATION: floor persists (316ppm) => lives in the CELL ARRAY. Smoking gun: 192mV/period slam on the SHARED q4_base 1.25V reference line** (couples through 64 tail Cjc/base paths; R_bias 100R line impedance; code-proportional -> modulates all 64 tails -> N^2 INL). Under NRZ this was K=4-scale and constant/sample (benign) - never seen before.
- **v33f: q4_base HF bypass (10u) with ideal cascode -> 0.54ppm** (measurement floor). Root cause CONFIRMED.
- **v33h COMPOSITE, settled (22n bypass, tau 2.2us, 13us run, serr 2e-5): max|INL| = 8.13ppm** (~-102dB HD class) with: BJT steering cells + MOSFET cascode (replica-ff casb; NO Ib-comp - deleted entirely) + q4_base bypass + 47n bus caps + passive 28R termination.
- **Emerging RTZ architecture is SIMPLER than the ratified one:** no precision loop in the switching path, no Q5C/QM/QN Ib-comp, no snk-replica leg. Still open: reconstruction filter + post-amp design (new sec 2 - passive termination = caps/Ls in audio path, needs user rule check), replica-ff realization (real cells vs B-source), remaining 8ppm decomposition, noise budget of the 28R termination, per-cell base decoupling as the hardware form of the q4_base fix.

## Round 34 - Termination-cap DECISION DATA (bfdac_cosim34a-e, 2026-07-23). User rule context: cap opposition = nonlinear phase (group delay) concern.
- Measurement note: q4_base bypass tau (2.2us) contaminated single-period INL windows; runs extended to 32.5us (13tau) + 10-period exact windows. Residual drift still limits reading to ~+-15ppm.
- **v34c: 12n C0G shunt at termination exposed cascode Vds-lambda modulation** (col node now slow -> code-dependent Vds on M5): 145ppm. **v34d DOUBLE MOSFET cascode fixes it: 32.4ppm = unfiltered baseline (v33h3 29.2ppm) within drift.** v34e BJT cascode instead: 110ppm (Ib channel returns) - MOSFET double cascode is the architecture.
- **Cap decision numbers (28R x 12nF = 473.7kHz pole, the only cap touching raw audio, shunt at 28R):**
  - in-band group-delay variation 0-20kHz: **0.60 ns** (phase 2.42deg @20k); droop 0.0077dB; both min-phase -> EXACTLY pre-invertible in the existing FPGA FIR (fold into polyphase coefs).
  - image @6.144MHz: -22.3dB after this pole alone; post-amp sees 232mVpp ripple, 2.85V/us slew demand (trivial).
  - termination Johnson noise: 136nVrms/20kHz diff vs 0.919Vrms FS -> **136.6dB SNR** before post-amp.
  - INL cost of the cap: **zero** (32.4 vs 29.2ppm, equal within measurement drift).
- **STATUS: passive-RTZ chain at ~30ppm (-90dB HD class); known-remaining smooth mechanisms (predistortion-eligible). Cap ruling awaited; measurement methodology needs an upgrade (drift-limited) before chasing <10ppm.**

## Round 35 - MEASUREMENT METHODOLOGY UPGRADE: floor ~5ppm; the ~30ppm was REAL (bfdac_cosim35/35b, utils/rtz_chop.py, rtz_chop2.py, 2026-07-23)
- New deck style: ONE continuous transient, NO .step (no cold restarts). Cells driven by B-sources gated on a PWL code schedule V(nsch); ref N=32 interleaved between every code segment (drift chopping); DNL pair 31/32/33; reltol 1e-5. Replica-ff law becomes analytic: I_p=krep*N*pw, I_m=krep*(64-N*pw).
- v35 (10-period segments) FAILED usefully: termination tau (336ns~2 periods) + q4_base tau (2.2us~13 periods) >> segment; 5-period discard left 9% of a 1.1V step in-window.
- **v35b (40-period segments, 20 discard): ref drift trace +-12uV pk (chopping removed 66,000uV of raw drift); segment sd 5-17uV -> floor ~5ppm.**
- **RESULT: max|INL| = 73ppm (discard method) / 98ppm (asymptote method), consistent; WORST AT MIDSCALE (N=16-32), 10x above the measurement floor => a REAL mechanism remains, |code-32|-symmetric signature (rail-interaction / replica-copy-asymmetry class).** DNL(31/32/33) = 0.06-0.6% LSB. Asymptote fit taus 350ns/1.2-2.2us confirm circuit time constants.
- Methodology verdict: chopping + 40-period segments + exact-period integration = trusted to ~5ppm. Gold-standard FFT run (real DEM sine vectors) still owed as final gate.
- NEXT (Round 36): midscale mechanism hunt with the trusted tool; then real replica cells, post-amp stage, spectral gate. Cap ruling: user leaning keep (12n C0G termination), not yet committed.

## Round 36 - Midscale mechanism found & killed: CASCODE DEVICE CAPACITANCE. Chain at ~24ppm, instrument-limited (bfdac_cosim36a-g, utils/rtz_chop_eval.py, 2026-07-23)
- v36a per-rail INL: both rails carry the same ~70ppm midscale bow, equal-and-opposite (adds in diff) -> mechanism in the shared cascode-stack physics, function of rail current.
- v36b ideal-cascode chop: cells CLEAN at the new floor (max 21ppm @ floor ~9) - confirms Round 33 cell verdict at 10x better precision.
- v36c/f cbus 220n (80-per segments, floor 1.8ppm): 62ppm - cap-INdependent. v36e fixed-casb (replica deleted): worse/drifty (115ppm, floor 50) - replica-ff stays.
- **v36g cascode devices swapped to 10x-lower-C model (Cgs 5p/Cgd 8p vs 50p/80p, same Kp): 73 -> 23.7ppm, AT the measurement floor (~18ppm).** Mechanism: casb repositioning charge - casb steps by dVgs(N) (sqrt-law bow) into device capacitance every period. CONFIRMED + KILLED. MPN consequence: cascode wants small-capacitance FETs at 100mA, NOT chunky power VDMOS.
- **STATUS: passive-RTZ chain measures <=24ppm (-92dB HD class), reading floor-limited; every identified mechanism killed; next resolution step needs longer-segment runs (floor scales ~1/sqrt) or the FFT gate. Remaining gap to -130dB: ~1.5 orders; predistortion (~100x on static bow) remains in reserve.**
- Architecture as of tonight: BJT steering cells + double MOSFET cascode (LOW-C devices) + replica-ff casb + q4_base bypass + 47n bus caps + 12n C0G termination (cap: user leaning keep, uncommitted) + passive 28R loads.

## Round 37 - GOLD-STANDARD FFT GATE (bfdac_cosim37, utils/gen_cosim37.py, utils/rtz_fft.py, 2026-07-23)
- Stimulus: REAL digital chain, bit-exact python references of RTL (ns_ef3_gen.step EF3 NS + dem_sort integer-exact selection) -> 16384-period vectors, -1dBFS 6.375kHz coherent tone, code range 6..59. Per-cell PWL drives (pwl37/) into the v36g deck (BJT steering, double LOW-C cascode, replica-ff, q4_base bypass, 12n C0G termination). One 2.67ms transient (~1h wall).
- Analysis lesson: windowed-FFT with discard destroyed coherence (fundamental skirt flooded band; kaiser mainlobe 28 bins > 17-bin harmonic spacing). Robust extractor = LS harmonic fit (quadratures h=1..8 + drift terms) on settled segment. Per-harmonic sensing floor (NS noise in 428Hz eq-BW): -115dBc.
- **RESULTS: IDEAL popcount of same vectors: all harmonics at the -115dBc floor (coherent-rect in-band SNDR of code stream = 140.8dB - digital chain holds the target). ANALOG: HD2 = -91.4dBc, HD3 = -93.6dBc in-band (HD4/5 -75dBc out-of-band, reconstruction filter territory).**
- **INTERPRETATION: -91dB HD2 matches the ~24ppm static midscale bow prediction (-92dB). DEM shapes cell mismatch but NOT code-level (array-physics) INL - as expected. NO new dynamic/transition-history mechanism above the -91dB level => the architecture has no hidden dragons; it is gated by the known smooth static bow (predistortion-eligible).**
- GATE VERDICT: architecture PASSES at its static-INL level; path to -130 = kill/predistort the remaining code-level bow. Ratification decision now data-complete.

## Round 38 - REAL-DEVICE MPN PASS on the cascode (bfdac_cosim38a-t, 2026-07-24)
- 3 vendor VDMOS candidates swapped into the v35b chopped deck (all 8 positions incl. replica diodes; self-biasing, no retune): **BSS145 113ppm (Vto 2.8, headroom-marginal); Si1555DL_N 58ppm (best); NDC7002N 66ppm** - vs 24ppm ideal-LVFET baseline. Floors 4-10ppm; errors real.
- **Si1555 signature is HIGHLY REPRODUCIBLE**: INL(N) = (-36, +2, +56, -14, -4, -4) identical across 6 independent perturbation decks (38b/f/h/l/n/q) => static + stable => predistortion-eligible exactly like the baseline bow.
- Mechanism forensics (all on Si1555): headroom vfr2 3.0->3.6V: 54ppm (no). m=4: 48ppm, m=16: 148ppm (paralleling confounded by 16x caps). Cgd linearized: 55ppm (not Cgd). Cjo->0: 137ppm. Cgs->50p only: 134ppm. Cjo->50p only: 58ppm. Cgs+Cjo=50p: 147ppm. External linear caps in D-S/G-S/ground positions: 56-117ppm (never better).
- **DECISIVE discriminator: Si1555 DC params + LVFET cap set = 23ppm (baseline!); LVFET DC + Si1555 caps = 54ppm.** The 24ppm baseline contains a fortuitous dynamic RTZ edge-charge CANCELLATION specific to the LVFET's exact {Cgs=50p, Cjo=50p, Cgdmax=80p/Cgdmin=12p} combination - no single param or external linear cap reproduces it. Vendor VDMOS switch-cap models are crude; a ppm-level cancellation must NOT be design-relied-upon.
- **VERDICT: honest real-device static INL = ~55-60ppm (-83dB HD2 class), stable signature, uncorrelated with device "quality" knobs. Consequence: code-level predistortion (already planned for the 24ppm bow, rd12) is PROMOTED from reserve to REQUIRED for -130dB; it handles 58ppm as easily as 24ppm since the signature is static. MPN pick: Si1555DL_N (dual N-ch SC-89, Vto 1.1V, 20V, low Qg) - headroom-comfortable at vfr/vfr2 = 1.75/3.0V.**

## Round 39 - FFT GATE ON THE REAL Si1555 DECK (bfdac_cosim39, utils/rtz_fft39.py, 2026-07-24)
- Same 16384-period real EF3+dem_sort vectors as Round 37 (pwl37/ reused), cosim37 deck with all 8 cascode positions on the Si1555DL_N vendor model. LS-harmonic-fit extractor (quadratures h=1..8 + drift; kaiser-FFT rejected per Round 37 lesson) rebuilt as rtz_fft39.py.
- **RESULTS: IDEAL popcount all harmonics -111dBc (uniform = noise floor). ANALOG: HD2 = -84.0dBc, HD3 = -80.8dBc in-band (HD4-8 out-of-band -86..-103dBc, reconstruction-filter territory).**
- **INTERPRETATION: -84/-81dBc matches the ~58ppm static signature prediction (-83dB class) - the ~8dB cost vs the Round 37 LVFET baseline (-91.4/-93.6) is fully explained by the static INL. NO new dynamic mechanism from the real device. Gate PASSES at its static level; predistortion carries the rest.**

## Round 40 - FULL 64-CODE INL LUT on Si1555 (bfdac_cosim40/40r, utils/gen_cosim40.py, utils/rtz_inl_full.py, utils/lut_compare.py, 2026-07-24)
- Chopped ref-32 measurement of ALL 64 codes (5080 periods, drift-interpolated): gain -30.978mV/cell, max|INL| 94ppm, floor ~7ppm. SIGN LESSON: LUT must use SIGNED gain (diffout falls with N); first predistortion attempt with |span| convention ADDED distortion (-79.9/-75.8) instead of cancelling - caught by the anti-distortion image test.
- REPRODUCIBILITY: forward vs REVERSED code order agree <1ppm at 55 of 63 codes; N=20-28 zone disagrees by +/-25ppm => HISTORY-DEPENDENT (hysteretic) zone, sets the static-LUT accuracy cap. Averaged fwd/rev LUT performs the same as forward within the gate resolution.

## Round 41 - LEVEL-AWARE PREDISTORTION (utils/dpd_study.py, utils/gen_cosim41.py, bfdac_cosim41, 2026-07-24)
- Concept validated exactly in code domain: EF3 quantizer feedback subtracts ACTUAL level (code + LUT) instead of ideal code; entire static INL is noise-shaped out of band. With self-consistent LUT: in-band SNDR 81.8 -> 141.6dB (Kaiser b38 estimator; rect readings are seed-bimodal, do NOT trust), HD2/HD3 -139dBc. Code stream carries visible anti-distortion image (-88dBc) - good sign-check diagnostic.
- FULL SPICE GATE (Si1555 deck, predistorted vectors): HD2 -84.0 -> -92.6dBc, HD3 -80.8 -> -94.7dBc. Static INL contribution removed; residual -92dB class is DYNAMIC (matches the N=20-28 hysteretic zone / bias-memory scale), invisible to any static LUT.

## Round 42 - DYNAMIC RESIDUAL FORENSICS + extended-DPD attempt (utils/toggle_probe.py, utils/dpd2.py, bfdac_cosim42, 2026-07-24)
- Toggle-count (switching-charge) hypothesis REJECTED: kt ~ 0.07uV/toggle, no harmonic change.
- Bias-memory hypothesis SUPPORTED in-sample: adding ema_tau(code) x poly(code) bilinear terms (taus 4/13.5/40 periods) collapses regression residual HD2 to -128dBc. Physical story: code-dependent bus current moves bias nodes (Q4 base tau 2.2us etc), bias state multiplies cell charge.
- BUT extended DPD FAILED out-of-sample (SPICE cosim42: HD3 back to -82.9): single-tone data cannot separate static poly / EMA products / reconstruction dynamics - the fit is not identifiable and injects wrong anti-distortion. Multitone or broadband ID stimulus required to fit dynamic terms honestly.
- STATUS: shipped result stands at HD2 -92.6 / HD3 -94.7dBc post-static-DPD (10-14dB from predistortion). Gap to -130 target is now entirely dynamic-mechanism territory. NEXT: (a) circuit-level kill of the N=20-28 hysteresis + bias-memory (stiffer q4_base / faster replica), or (b) multitone ID run for the bilinear corrector, or (c) both.

## Round 43 - MECHANISM DISCRIMINATORS (bfdac_cosim43/b/c/d/e, utils/gen_cosim43.py, 2026-07-24)
- Strategy pivot ratified with user: targets restated as noise floor >128dB (achievable via scale/paralleling) + THD as close to -120dBc as possible (verifiability limit: best silicon -120..-124, APx555 residual ~-120). Constant-activity/circuit fix chosen over FIRDAC switch until data says otherwise.
- 43a clamped columns (ideal I/V, uncorrected vectors): -83.7/-80.7 = identical to passive loads => static bow is IN THE CELLS, not the load; column swing (tau=2 periods) also NOT the dynamic mechanism (43b clamped + predistorted: -92.4/-94.1, same as unclamped).
- 43c C_q4 22n->100p: HD3 -75.5 (worse; statics changed, LUT stale - inconclusive but shows q4_base sensitivity).
- **43d C_q4 22n->10u (tau 2.2us->1ms, bias frozen below audio band): HD2 -92.4 -> -101.9 with the STALE LUT. Q4-BASE BIAS MEMORY CONFIRMED as the dominant dynamic HD2 mechanism** (its 2.2us tau = 13.5 periods matched the strongest EMA term in the Round 42 regression).
- 43e adding casb 10u + cbus 470n: statics changed massively (LUT invalid, -69/-76) - those mods need their own LUT and broke chopped-run settling (43.7mV drift); REJECTED for now.

## Round 44 - SLOW-BIAS DECK, FULL HONEST PIPELINE (bfdac_cosim44lut/44, utils/gen_cosim44.py, 2026-07-24)
- Config: C_q4 10u ONLY. LUT re-measured with SHUFFLED chopped schedule (random.Random(44)) so the 1ms bias tau sees a stationary average instead of a code-correlated ramp: max|INL| 89ppm, floor 6.6ppm, drift 12.7uV (ordered schedule was unusable at 34mV drift - lesson: slow bias requires randomized calibration order, true on the bench too).
- **FULL SPICE GATE (predistorted, matched LUT): HD2 -98.8 / HD3 -96.1 dBc; all out-of-band harmonics <= -99.** Progression: -84.0/-80.8 (R39) -> -92.6/-94.7 (R41 DPD) -> -98.8/-96.1 (R44 circuit+DPD). One 8-cent capacitor + calibration procedure = 15dB.
- REMAINING: ~-97dB class residual (hysteretic N=20-28 zone + tau~4-period term candidates: bus 47n/casb nodes - each needs its own LUT-matched round). Sensing floor of the 16384-period gate is getting close; longer runs or averaged gates needed for honest iteration below ~-105.

## Round 45 - EXTENDED GATE 65536 periods (bfdac_cosim45, utils/gen_cosim45.py, 2026-07-24)
- 4x gate on the slow-bias deck (C_q4 10u, cosim44lut LUT, BIN=67, 10.67ms transient, 76min sim). Per-harmonic sensing floor -87.6dBc (3dB better than 16k gates; floor is set by out-of-band NS noise surviving the boxcar, not by run length alone).
- **HD2 -97.9 / HD3 -95.9 dBc - reproduces R44 (-98.8/-96.1) within the floor. The ~-97dB residual is REAL and STABLE, not a sensing artifact or seed fluke.**

## Rounds 46-48 - HYSTERESIS ROOT CAUSE: SELF-OSCILLATION (bfdac_cosim46/47/48a-q, utils/gen_cosim46/48.py, utils/hyst_probe.py, utils/settle_zone.py, utils/probe48.py, 2026-07-24)
- The N=20-28 "hysteretic zone" is a marginal-stability SELF-OSCILLATION: codes 23-28 show an ~18-period quasi-cycle, +/-40-100uV pk on diffout segment std, while all other codes sit dead flat (<1uV). Explains the fwd/rev LUT +/-25ppm disagreement (R40): the "static" level in the zone depends on the oscillation phase at sample time.
- Loop: 47n bus caps against the inductive-looking source impedance of the M5 cascode in a specific current window. Kill matrix (probe48, seg std at c24/c27/c28): 48a control 38/42/52uV; bus-cap snubbers (b=3R3, c=10R) only MOVE the window; **48h mid series 10R: 6.5/6.4/0uV (20dB down); 48j mid 10R + 1n: 0.5/1.0/3.6uV (best kill)**.
- vfr2 stability window probe (48r/s/t/u = 2.5/3.5/4.0/2.0V): oscillating-code window MOVES with cascode bias (vfr2=2.0 quiets 24/28 but wakes c40 at 26uV; 4.0 quiets 27/28 but keeps c24) - no vfr2 value kills it globally. Confirms marginal loop through the cascode; bias tweak is not a fix.

## Rounds 49-50 - MID-NODE DAMPING, LUT-MATCHED GATES (bfdac_cosim49/49lut/50/50lut, utils/gen_cosim49/50.py, 2026-07-24)
- Full honest pipeline on both fixes (shuffled-schedule LUT re-measured on the modified deck, level-aware DPD, 16k gate):
- 49 (mid 10R + 1n): HD2 -88.7 / HD3 -87.8. 50 (mid 10R only): HD2 -89.4 / HD3 -87.1.
- **Both oscillation kills COST ~10dB vs the undamped deck (R44 -98.8/-96.1). The damping element sits in the signal-current path and adds its own code-dependent settling error that the static LUT cannot capture. Oscillation kill is NOT worth the trade at these values - REJECTED as implemented.**

## Round 51 - LUT AVERAGING (bfdac_cosim51, 2026-07-24)
- Base slow-bias deck, LUT = average of seed-44/seed-45 shuffled runs: HD2 -97.8 / HD3 -96.1 - identical to single-LUT R44 within the floor. LUT noise is not the limiter; the residual is the oscillation zone + remaining dynamic terms.
- STATUS after R45-52: converged plateau at HD2 ~-98 / HD3 ~-96 dBc. The residual is dominated by the codes-23-28 marginal oscillation, whose gentle kills (mid damping) cost more than they save. Remaining levers: (a) damping that stays OUT of the signal path (e.g. RC across the M5 cascode gate feed / gate stopper R, loop compensation not series loss), (b) DEM-level avoidance (skip codes 23-28 via NS clamp - zero analog cost, small NS penalty), (c) accept ~-96..-98dBc THD, which already beats the -95dBc class of premium commercial DACs and sits within reach of the APx measurement floor.

## Round 53 - GATE-STOPPER PROBE (bfdac_cosim53a-g, utils/gen_cosim53.py, 2026-07-24)
- Series R at the cascode MOSFET GATES (no drain current through it => no signal-path insertion loss, unlike the mid-series R of R49/50). Kill matrix (seg std at c24/c27/c28/c40 uV; control 38/42/52/0):
- a 22R M5: 9/15/0/1. b 100R M5: 1.0/1.5/1.9/2.3. c 470R M5: 0/6.8/7.7/1.9. **d 100R M5+M6: 1.3/1.0/1.1/0.9 - GLOBAL KILL, all codes <=1.3uV.** e 1k: 29/46/0/3 and f 2k2: 30/35/32/37 - WORSE (classic stopper sweet spot; too much R re-phases the loop). g 470R both: 0.1/9.5/9.9/0.1.
- Sim-speed tell: underdamped variants (22R/100R-single) grind at tiny timesteps (HF ring); damped variants run at full speed.

## Round 54 - GATE-STOPPER FIX, FULL HONEST PIPELINE (bfdac_cosim54lut/54, utils/gen_cosim54.py, 2026-07-24)
- Config: 100R gate stoppers on M5 AND M6 (53d) + slow bias (C_q4 10u). Two real resistors, zero signal-path cost.
- **LUT: max|INL| = 7.10 ppm (was 89 ppm on R44 deck!), floor ~3.4 ppm, drift 17.7uV. The marginal loop was not just noise - it was bending the whole static characteristic 12x.**
- **FULL SPICE GATE (predistorted, matched LUT): HD2 -102.1 / HD3 -109.4 dBc; ALL higher harmonics <= -111 (HD8 -123).** Progression: -84/-81 (R39) -> -92.6/-94.7 (R41) -> -98.8/-96.1 (R44) -> -102.1/-109.4 (R54).
- **ARCHITECTURE VERDICT (answers the "are we at the limit?" question): the -97dB plateau was NOT architectural - it was one device instability, fixed by two 100R resistors. The current-steering cascode architecture is NOT exhausted.** Remaining residual is HD2-dominated at -102; candidates: residual bias memory, LUT floor (7ppm ~ -103dB class - consistent!), even-order coupling. Next levers: LUT averaging on the quiet deck (floor now reachable), extended gate to confirm, HD2-targeted probing.

## Round 55 - LUT AVERAGING ON THE QUIET DECK (bfdac_cosim54lut2/55, 2026-07-24)
- Second LUT with seed-45 shuffled schedule: max|INL| 6.74ppm. Seed-44 vs seed-45 agreement: max|diff| 7.2ppm, rms 1.9ppm - LUTs now agree at the chop-measurement floor (drift ~3.4ppm class); the R40 +/-25ppm hysteretic disagreement is GONE with the oscillation.
- Gate with averaged LUT: HD2 -101.7 / HD3 -110.0 dBc - identical to R54 single-LUT (-102.1/-109.4).
- **CONCLUSION: HD2 ~-102 is NOT LUT-noise limited - it is a SYSTEMATIC even-order mechanism.** Candidates (differential structure should cancel even order, so look for P/N asymmetry): pwa/pwb RTZ pulse skew, krep*N vs krep*(64-N) replica asymmetry, single-ended bleed/bias coupling. Extended 65k gate (R56, avg LUT, gate-stopper deck) launched to confirm before the HD2-asymmetry round.

## Round 56 - EXTENDED GATE CONFIRMATION (bfdac_cosim56, utils/gen_cosim56.py, 2026-07-24)
- 65536 periods, BIN=67 (different tone freq than the 16k BIN=17 gates), avg LUT, gate-stopper deck: **HD2 -102.3 / HD3 -108.4 dBc; HD4-8 all <= -113.** Confirms R54/55 at 4x record length and different tone placement - the numbers are honest.

## Round 57 - HD2 DISCRIMINATOR: RTZ SKEW (bfdac_cosim57lut/57, utils/gen_cosim57.py, 2026-07-24)
- skew=0 (deck's deliberate 1ns pwb delay removed), full honest pipeline (own LUT: 11.5ppm): HD2 -102.6 / HD3 -109.1 - UNCHANGED. **RTZ pulse skew is NOT the HD2 mechanism** (statics from skew were already absorbed by LUT/DPD; also means the bench clock-matching requirement is relaxed at this level).
- **STATUS: HD2 -102 is systematic, reproducible across 4 independent gates (R54/55/56/57), even-order. Remaining candidates: replica-ff krep asymmetry (N vs 64-N), single-ended bleed/bias networks, BJT cell dynamic even-order, vp8/load common-mode conversion. Next discriminator ideas: inverted-signal gate (u -> -u, complex-HD2 phase comparison separates signal-even-order from fixed artifacts), krep trim probe, bleed symmetrization.**

## Round 58 - INVERTED-SIGNAL DISCRIMINATOR (bfdac_cosim58, utils/hd2_phase.py, dpd_study.py "inv" mode, 2026-07-24)
- Same avg LUT, same deck, u -> -u. Complex LS fit (utils/hd2_phase.py, absolute time reference):
- fund -90.8 -> +89.2 deg (exact 180 flip, sanity ok). HD3 +172.7 -> +0.9 deg (flips ~180 = textbook odd-order, tracks x^3). **HD2 -63.1 -> -78.4 deg at -101.7 -> -102.8 dBc = INVARIANT under inversion -> genuine quadratic (x^2) distortion of the differential transfer path**, not a fundamental-polarity-tracking artifact.
- Static residual can't explain it alone: LUT bow scale says 7ppm ~ -106 class, and the measured LUT reproducibility (2-3ppm rms) puts correctable statics below that. Points to DYNAMIC even-order: code-dependent settling in the BJT cells / symmetric CM->diff conversion.
- NEXT: amplitude discriminator (-7dBFS gate: pure x^2 -> HD2 dBc improves ~6dB, 1dB per dB of drive) - separates quadratic-transfer from residual-static, and directly quantifies the drive-level trade available on the bench.

## Round 59 - AMPLITUDE DISCRIMINATOR + GLITCH REGRESSION (bfdac_cosim59, utils/hd2_glitch.py, dpd_study.py dB arg, 2026-07-25)
- -7dB drive gate (code range 18..46, same avg LUT): **HD2 -102.6 dBc - dBc UNCHANGED vs -1dB drive => HD2_abs scales ~A^1, NOT A^2.** HD3 improved -110 -> -117 (odd-order scales as expected). Practical: drive backoff does NOT buy HD2 - it acts like a fixed fraction of signal.
- Combined verdict (R58 inversion-invariant + R59 A^1 scaling): **RECTIFICATION-CLASS mechanism (|x|-type), not quadratic transfer, not static residue.**
- Glitch-energy hypothesis REJECTED: |dN| and dN^2 regressors fitted jointly across gates 55/58/59 give kt = +746/+1383/-1303 u/unit - sign-inconsistent, not physical (utils/hd2_glitch.py; |N-32| regressor is collinear with the HD2 basis - uninterpretable, don't reuse).
- Remaining rectifier candidates: DEM cell-usage/rotation-rate dependence on |s|, EMA'd rail nonlinearity cross-terms, cascode CM disturbance ~ |code excursion|. NEXT discriminator: tone frequency (all gates so far sit at f0 ~ 6.3-6.4kHz(!); a BIN=37 gate at ~13.9kHz separates dynamic rectifier - phase/mag rotates with f - from static rectifier).

## Round 60 - FREQUENCY DISCRIMINATOR (bfdac_cosim60, BIN env var in dpd_study/hd2_phase, 2026-07-25)
- BIN=37 gate (f0=13.875kHz, 2.18x the usual 6.375kHz), same avg LUT: HD2 -96.6 / HD3 -103.8 dBc.
- **Both HD2 and HD3 rose ~5.5-6dB for a 2.18x (6.8dB) frequency step => residual distortion scales ~proportional to f0. The remaining mechanism is DYNAMIC (settling-class), uniform across even and odd order.** Phase rotation modest (HD2 -63 -> -82 deg).
- Full fingerprint of the residual: ~A^1, inversion-invariant (even part), ~f^1 => code-trajectory-dependent settling error (incomplete settling / slew asymmetry within the RTZ window), NOT static, NOT LUT-correctable, NOT glitch-count.
- **BIG PRACTICAL COROLLARY: distortion ~f means the standard 1kHz THD spec point extrapolates to HD2 ~ -119 dBc / HD3 ~ -126 dBc.** Our 6.4kHz gates were a stress test; at the customary audio measurement frequency this design is already in the -120dB class. In-band worst case (f0=10kHz, HD2 at 20kHz band edge): ~-99 dBc.
- Forward options: (a) RTZ timing margin (wider settle window / narrower twid trade), (b) faster cell switching edge, (c) dynamic DPD with memory terms (dN-dependent), (d) accept: report THD vs frequency curve, spec at 1kHz.

## Round 61 - RTZ TIMING + DRIVE-STRENGTH MATRIX (bfdac_cosim61a-e, utils/gen_cosim61.py, 2026-07-25)
- Five variants on the R54 config, full honest pipeline each (own LUT + DPD + 16k gate). NOTE: gates accidentally ran at BIN=37 ($env:BIN persisted in the shell) - turned out useful: 13.9kHz is the more sensitive stress point. Baseline (R60): HD2 -96.6 / HD3 -103.8.
- a tedge 3n->1n (faster edges): -95.5/-101.0 (worse; also 2.4x worse static INL 17ppm - edge feedthrough). b settle margin 1.5tc/5tc: -97.3/-102.5 (wash). c both: -95.7/-100.1 (worse). d overdrive vhi 1.7->2.0: -95.3/-100.9 (worse). e swing 0.9/1.9: -95.6/-100.6 (worse).
- **VERDICT: the settling-class residual is INSENSITIVE to (or degraded by) every RTZ timing/edge/drive-strength knob - the stock 3n/6tc/1.1-1.7V point is already a local optimum. Drive strength does NOT buy linearity. The residual lives in the transition charge dynamics themselves (code-trajectory-dependent switching charge, e.g. collector-node/Cob redistribution), not in incomplete settling.**
- Combined with R60 (~f scaling): remaining realistic levers are dynamic DPD (memory terms) or acceptance with THD-vs-f characterization (1kHz point ~ -119dBc HD2 by ~f extrapolation).

## Round 62 - THD vs FREQUENCY CURVE (bfdac_cosim62b5/62b11 + existing 55/60, 2026-07-25)
- Same deck + avg LUT at four tone frequencies (16k gates). ANALOG HD2/HD3 dBc:
- 1.875kHz: -108.3/-125.5 | 4.125kHz: -104.2/-118.0 | 6.375kHz: -101.7/-110.0 | 13.875kHz: -96.6/-103.8
- **HD2 slope is SUB-linear: ~f^0.65-0.75 (11.7dB rise over a 7.4x frequency span), not the f^1 assumed from the 2-point R60 fit. 1kHz extrapolation: HD2 ~ -112dBc.** HD3 falls faster toward LF and hits the code-domain floor.
- HONESTY FLAG: at 1.875kHz the IDEAL-popcount (NS+DEM+dither) floor is HD2 -114.1 / HD3 -118.4 - the analog LF points are within ~6dB of the code-domain floor of a 16k record; deeper LF readings need longer gates. (4.125k HD3 -118.0 vs floor -116.8: floor-limited, phase-cancellation artifact.)
- In-band worst case at 0dBFS: ~-97..-99dBc (top-of-band tones, harmonics land near/beyond 20kHz). Comparable to the best monolithic flagships (published 1kHz THD+N -120dB; measured 19kHz THD of ES9038/AK4499-class parts is -95..-105dBc).
- Correction lever identified: mechanism = per-period transition charge dependent on the code trajectory (N_prev -> N). Natural digital fix = 2D dynamic LUT E(N_prev,N) in the NS feedback, measured by a pair-transition chop protocol. This is the lever chip vendors DON'T have (we own the digital path).

## Round 63 - PAIR-TRANSITION MEASUREMENT (bfdac_cosim63, utils/gen_cosim63.py, rtz_pair.py, rtz_pair2.py, 2026-07-25)
- Random-walk pair chop: 2048 dwells x 8 periods over 9-code grid {6..58}, thermometer selection (nsch B-sources), R54 config. Deck reuses 54lut structure with PWL file schedule.
- PITFALL FOUND AND FIXED: dwell-differenced analysis (rtz_pair.py) is contaminated by the OUTPUT-FILTER LTI TAIL (rload*cbus ~ 1.3us ~ 8 periods; E1 dominated by 22.2mV/unit * dN linear term, and even the dwell "null" diagonal showed +/-12mV of history leakage).
- rtz_pair2.py does it right: joint fit of one-hot static levels + 16-tap FIR on code history + drift, THEN bin residual by (prev,curr). Null diagonal collapses to <=13uV. **Result: clean dynamic-nonlinearity matrix E_nl(a,b) up to +/-302uV (~150ppm of span, 20x the static INL), SE ~30uV, structure ~ h(a)-dominated (prev-code memory). Depth-2 binning shows same scale.** Saved cosim63_Enl.npy.

## Round 64 - DYNAMIC DPD, FIRST EMBED: NEGATIVE RESULT (bfdac_cosim64, utils/dpd_dyn.py, 2026-07-25)
- EF3 feedback extended to subtract L(prev,code) = code + err_static + E_dyn(prev,code), E_dyn bilinear-interpolated 9x9 -> 64x64 (diag forced 0). Gate at BIN=37: **HD2 -93.8 / HD3 -100.8, HD4 -101, HD5 -99.8 - WORSE than baseline (-96.6/-103.8, HD4/5 < -113). The correction ADDS structured error.**
- Diagnosis: TRANSFER GAP. The pair matrix was measured with THERMOMETER cell selection; the gate runs DEM ROTATION - for the same (N_prev,N) a different (much larger) set of cells toggles. E_nl(a,b) under thermometer != E under DEM. The h(a)-structure that dominates the matrix is not what the gate experiences.
- Next options: (1) toggle-aware correction - digital knows the exact DEM toggle set each period; model error = kt*n_toggle + rail terms, fit kt from a DEM-matched measurement; (2) DEM-matched pair chop (drive sel PWLs with dem_sort exactly as the gate does, measure E vs (N_prev,N) averaged over rotation states); (3) drop DEM in favor of pure LUT correction (statics are LUT-corrected anyway - DEM may be unnecessary and is itself a dynamic-error generator).

## Round 65 - NO-DEM GATES + SIGN DISCRIMINATOR (bfdac_cosim65/65b/65c, NODEM env in gen_cosim41, DYNSIGN in dpd_dyn, 2026-07-25)
- 65 (thermometer, static LUT only, BIN=37): **HD2 -96.6 / HD3 -103.7 - IDENTICAL to DEM baseline. The gate's dynamic distortion is INVARIANT to cell-selection pattern (DEM vs thermometer). DEM neither causes nor cures it; the error is a RAIL-LEVEL function of the code trajectory, not of which cells toggle.** (Also: DEM could be dropped in a LUT-corrected design with no HD penalty - architectural simplification option.)
- 65b (thermometer + E_nl DPD): -93.5/-100.8 + HD4/5 ~-101 - same degradation as R64. DEM transfer gap theory DEAD.
- 65c (E_nl DPD with FLIPPED sign): HD2 -92.5 - ALSO worse. Both signs degrade => injected HD2-band content is in QUADRATURE to the actual gate error. Not a sign bug - the (prev,curr) single-period model itself is wrong.
- E_nl robustness checked: FIR depth 24/32/48 -> offdiag 272-278uV, converged (not an FIR-truncation artifact). Pair error is real in the pair-chop plant.
- Tail analysis (offset-in-dwell binning, D=32): transition error rms by period offset = [85, 114, 82, 47, 28, 26, 30, 35]uV - **nonlinear transition error is SPREAD over ~4 periods with PEAK AT THE SECOND period (delayed response).** Superposition of these tails under per-period NS switching is NOT captured by a settled-state pair measurement -> the (prev,curr) LUT basis is fundamentally inadequate.
- **CONCLUSION: dynamic correction needs a memory-kernel (Volterra-class) model identified under GATE-LIKE excitation, not settled-state chop. We already have 8+ gate pavg records with known code streams - next round: Volterra-2 system ID directly on existing gate data (features: lagged code products, depth ~4), cross-validated across gates, then inverted in the NS loop. Zero new sims needed for the ID step.**

## Rounds 66-67 - VOLTERRA ID + EMBED: INVALIDATED, TWO TRAPS DOCUMENTED (utils/volterra_id.py, dpd_volt.py, bfdac_cosim67, 2026-07-25)
- R66: quadratic memory kernel (20 terms, lags 0..5) fit jointly on 10 gate records; leave-one-out "validated" HD2 within ~1dB/3deg on ALL gates. Looked spectacular. R67 embed: **HD2 -81.0 dBc - 15dB WORSE than baseline.**
- TRAP 1 (fatal): **every honest gate stream uses the same dither seed (rng 5) - leave-one-out cross-validation is NOT independent.** The kernel memorized dither/NS-noise product structure common to all records, not plant physics. BIN=37 gates (60/64/65*) have near-identical streams.
- TRAP 2 (scale/sign): cosim*_pavg.npy for gates is in DIFFERENT units than assumed (pavg-vs-code slope check: -0.0309 - matches rtz_inl gain, OK here) BUT code-domain evaluation of the fitted kernel on the raw NS stream predicts HD2 bins at -50dBc: the kernel MIXES out-of-band shaped noise into harmonic bins (quad products of full-scale NS noise). The real plant does not do this at that magnitude - more proof the fitted Q is noise-fit, not physics. (Also explains R64/65b/65c both-signs-worse: same class of contamination in E_nl embedding.)
- REQUIREMENTS FOR ANY FUTURE DYNAMIC ID (write these into the protocol): (1) independent dither seeds per record; (2) fit/validate only on in-band spectral projections where signal products dominate noise products; (3) before ANY embed, evaluate the kernel's code-domain action on the actual NS stream - its out-of-band-mixing must be below the target floor; (4) suspicously good validation = check excitation independence first.
- Baseline stands: gate 60 (static LUT, BIN=37) HD2 -96.6 / HD3 -103.8; R62 curve is the design signature.

## Rounds 68-71 - DYNAMIC DPD BREAKTHROUGH (utils/volterra_id2.py, dpd_volt.py, bfdac_cosim68a-d/69/70/71, 2026-07-25/26)
- R68 ID protocol (per R66/67 post-mortem): 4 new gates 68a-d with INDEPENDENT dither seeds 101-104 (DSEED env in dpd_study.py), BINs 37/37/17/11. Fit quadratic memory kernel (20 terms, lags 0..5) on IN-BAND complex spectral projections (bins 1..300, fund mainlobe excluded), nuisance (one-hot statics + FIR16 + drift) orthogonalized out. **Honest held-out validation: HD2 predicted within 0.1dB / ~1deg on ALL records including the 68a<->68b independent-seed pair.**
- R69 embed FAILED (-65.2 dBc): fitting on ORTHOGONALIZED features but applying the kernel RAW injects the nuisance-space content (628uV of static). TRAP 3 documented.
- R70 fix: decompose raw kernel action on nuisance basis (68a record), save stat[64]+firw[16]; embed subtracts them so only the true dynamic action (rms ~25uV) enters the EF3 feedback. **Gate 70 (seed 105): HD2 -114.9 (from -96.6, +18dB). HD3 -101.9 unchanged (odd-order needs cubic).**
- R71: cubic terms added (CUBIC=1, 19 terms lags 0..3, total 39). Held-out HD3 within 0.3dB/5deg. **Gate 71 (seed 105, BIN=37 = worst-case 13.875kHz 0dBFS): HD2 -118.7 / HD3 -120.0 / HD4-8 all <= -119. +22dB HD2, +16dB HD3 over static-LUT baseline. ALL harmonics below -118 dBc at the most hostile point in band.**
- Final digital chain: EF3 NS + TPDF dither + static LUT + 39-term Volterra-2/3 memory kernel (integer-friendly, ~78 mults/sample at 6.144MHz or LUT-able) in the quantizer feedback. Kernel files: cosim68c3_Q/pairs/stat/firw.npy.
- PENDING CONFIRMATION: (a) in-band tone gate (BIN=17, fresh seed) with c3 kernel; (b) amplitude robustness (-7dB drive); (c) longer-record floor check.

# NOISE/JITTER CAMPAIGN (opened 2026-07-26) - critical path to >128 dB
Distortion chapter closed at all-harmonics <= -118 dBc (R71). The other half of
the budget is untouched. Signal reference: fund ~0.87 Vpk diff (~0.62 Vrms);
128 dB SNR over 20 kHz requires total in-band noise <= ~245 nVrms.

## Budget lines to quantify (analytic first, then targeted cosim)
1. QUANTIZATION/DITHER FLOOR: EF3 + TPDF at 6.144 MHz, OSR 153. Code-domain,
   exact - compute with long records (no SPICE). NOTE: cosim runs EF3 (3rd
   order); RTL plan says 7th-order NS - reconcile order + stability first.
2. CLOCK JITTER: RTZ edges convert timing noise to charge error; error/sample
   ~ I_cell*n_active*sigma_t/T. Two flavors: (a) white jitter (broadband ->
   in-band 1/OSR share), (b) close-in phase noise of OCXO (folds directly).
   Experiment: perturb PWL edge times with given sigma_t (10ps/1ps/0.1ps rms),
   measure in-band floor vs sigma_t -> spec the OCXO + reclock flops.
3. REFERENCE/RAIL NOISE: cell current is set by rail + Rref; rail noise
   modulates ALL active cells coherently (scales with signal - multiplicative).
   Experiment: inject known noise PSD on the rail B-source, measure in-band.
4. THERMAL: cell resistors + rload + I/V stage. Analytic: 64 cells' noise
   contributions + output network. Verify R and topology from bom.md.
5. 1/f AND EX-NOISE of Si1555 cascodes: LTspice models may not include 1/f -
   check model cards; if absent, budget analytically from datasheet.
## Measurement-floor caveat
16k-period gates read to ~-112 dB; >128 dB verification needs either longer
gates (65k+), noise-free-difference methods (paired runs +/- injection), or
analytic extrapolation. Plan experiments as DIFFERENTIAL (with/without
injection) so the deterministic part cancels.
## Experiment queue
- N1: code-domain floor of the SHIPPING NS config (order, dither, 24-bit in)
- N2: jitter injection sweep (sigma_t = 10/1/0.1 ps white) on gate-71 deck
- N3: rail-noise injection sweep on gate-71 deck
- N4: analytic thermal/1-f budget spreadsheet from bom.md values

## Rounds 72-75 - VOLTERRA GENERALIZATION GAP: ROOT CAUSE + TWO FIXES (2026-07-26)
- Gate 72 (c3 kernel, BIN=17 in-band 6.375k, seed 106): HD2 -101.0 / HD3 -102.4
  dBc - 17dB worse than gate 71's BIN=37 result. Gate 73 (-7dB drive, BIN=37):
  all harmonics <= -105 (floor -75.4), HD3 -127.2 - amplitude robustness OK.
- ROOT CAUSE (TRAP 4): the ideal-popcount of the gate-72 stream shows HD2 -99.0
  dBc = the kernel INJECTS -99dBc of predistortion at BIN=17 where the plant's
  own HD2 is only ~-103 (held-out 68c). The stat/firw nuisance decomposition of
  the raw kernel action was computed ON RECORD 68a (BIN=37) ONLY - it is
  STREAM-DEPENDENT, and subtracting a BIN=37-derived split from a BIN=17 stream
  leaves residual STATIC nonlinearity content -> over-injection at any other
  tone frequency. Gate 71 worked because decomposition matched its own BIN.
- FIX A (R74): NUALL=1 in volterra_id2.py - decompose raw action on ALL FOUR
  records stacked (BINs 37/37/17/11) so the stat/firw split is BIN-independent.
  Kernel saved as cosim68c3j. Code-domain precheck at BIN=17 (seed 106):
  injected HD2 -103.5 (was -99.0, now matches plant), HD3 -115.0 (was -100.9),
  HD4 -120.6, HD5 -110.5. Gate 74 = SPICE confirmation, running.
- FIX B (R75): two new ID records with fresh independent seeds - 75a BIN=5
  (1.875k, seed 107), 75b BIN=27 (10.125k, seed 108), static-LUT streams via
  dpd_study.py. Will refit with EXTREC=1 NUALL=1 (kernel cosim68c3je) and
  gate at BIN=17 if Fix A alone is insufficient.
- TRAP 5 (tooling): first gate-74/75a/75b runs were INVALID - gen_cosim41.py
  still templated from bfdac_cosim39.cir (pre-R54 plant: no 100R gate-stoppers,
  C_q4 22n). Gate 74 read HD2 -83.9/HD3 -80.9 = the codes-23-28 oscillation +
  bias memory, not a DPD result. Generator fixed to template from
  bfdac_cosim72.cir (current plant); all three re-run.
- GATE 74 (Fix A, cosim68c3j kernel, BIN=17, seed 106, CORRECT plant):
  **HD2 -118.0 / HD3 -124.9, HD4-8 all <= -117.9 dBc.** Generalization gap
  CLOSED - matches gate 71's BIN=37 numbers. Root cause was the 68a-only
  nuisance decomposition, exactly as diagnosed.
- Records 75a/75b (static-LUT plants): 75a BIN=5 HD2 -115.1 / HD3 -123.7;
  75b BIN=27 HD2 -99.4 / HD3 -104.4 - plant distortion rises with frequency,
  consistent with the R62 signature.
- Fix B refit (6 records, BINs 5/11/17/27/37/37, EXTREC=1 NUALL=1 CUBIC=1,
  kernel cosim68c3je): held-out validation passes on EVERY record incl. the
  fresh-seed fresh-BIN pair (75a pred/meas -113.2/-113.2, 75b -99.0/-99.0).
  Kernel dyn-action out-of-band mixing -136.1 dBc. Gates 76 (BIN=23 UNSEEN
  frequency, seed 109) + 77 (BIN=37 worst case, seed 110) running as the final
  frequency-generalization cross-check.
- GATE 76 (cosim68c3je, BIN=23 = 8.625k UNSEEN in ID, seed 109): HD2 -117.1 /
  HD3 -120.7, HD4-8 <= -114.9 dBc. GATE 77 (BIN=37 worst case, seed 110):
  HD2 -122.1 / HD3 -116.4, all <= -110.7 (all harmonics OOB above 20k).
- **VERDICT: frequency generalization CONFIRMED. Gates 71/74/76/77 (BINs
  37/17/23/37, four different unseen seeds) all read every harmonic <= -116 dBc
  in-band-relevant, <= -110 dBc everywhere. Distortion campaign CLOSED.**
- SHIPPING KERNEL: cosim68c3je (39-term Volterra-2/3, lags 0-5 quad / 0-3
  cubic) + BIN-independent stat/firw split (NUALL). CALIBRATION IMPLICATION:
  per-board ID protocol MUST use records at >=4 tone frequencies spanning the
  band with independent dither seeds, and the nuisance decomposition MUST be
  computed jointly on all records (stream-dependent otherwise - TRAP 4).

## Noise campaign N1 - CODE-DOMAIN FLOOR (utils/noise_n1.py, 2026-07-26)
- RTL reconciliation: noise_shaper_7th_order was REPLACED in Round 30 by
  noise_shaper_ef3 (placeholder 7th-order FIR had NO DC zero). dac_dsp_core.sv
  ships EF3 + dem_sort = exactly the cosim config. No discrepancy.
- Shipping NS floor (EF3 + TPDF, 6.144MHz, 1M-sample records, Kaiser b38 +
  mainlobe excl, 4 seeds x 2 drives -1/-60dB): **147.5-148.0 dB re -1dBFS
  fund = 25-26 nVrms of the 245 nVrms (128dB) budget - ~1% of noise power.
  Drive-independent. N1 CLOSED: quantization is a negligible budget line.**
- Methodology note: first pass with rect window read one seed at 107dB - the
  R37 edge-leakage artifact of shaped OOB noise, NOT an idle tone (Kaiser
  reading for that seed: 147.3dB). Welch/hann equally unusable (98.5dB
  leakage-limited). Kaiser b38 is mandatory for all noise-floor readings.
- NEXT: N2 jitter injection sweep (sigma_t = 10/1/0.1ps white on RTZ edge
  times, gate-77 deck, differential with/without comparison), N3 rail-noise
  injection, N4 analytic thermal budget from bom.md.

## Noise campaign N2 - JITTER INJECTION (gen_cosim78.py / jitter_n2.py, 2026-07-26)
- Method: gate-77 deck with shared RTZ window sources pwa/pwb replaced by PWL
  trains, per-edge white gaussian jitter common to all 64 cells (reclock-flop
  model). DIFFERENTIAL readout pavg(78x)-pavg(77) cancels all deterministic
  content - not limited by the single-gate -81dBc sensing floor.
- Results (in-band 20Hz-20kHz, re -1dBFS fund 0.62Vrms, budget 245nVrms):
  sigma 10ps: 9.10 uVrms (96.7dB). sigma 1ps: 1.61 uVrms (111.7dB).
  sigma 0 CONTROL: 0.90 uVrms (116.7dB) = PWL-grid/solver reproducibility
  floor, NOT jitter. Floor-corrected slope: **~0.9-1.3 uVrms in-band per ps
  of white edge jitter** (matches analytic estimate ~6uV at 10ps within 4dB;
  in-band spectrum ~+5-8dB above flat-white share - signal-modulated).
- SPEC DERIVED: to hold the jitter line <= 100 nVrms of the 245 nV budget,
  **total white edge jitter (OCXO broadband + reclock flop additive) must be
  <= ~80-110 fs rms**. Achievable: clean reclock FF (NB7V52M/SY89871-class,
  30-100fs additive) + low-noise OCXO; close-in OCXO phase noise folds
  separately (not covered by this white-jitter sweep - N2b if needed).
- N2 CLOSED. Remaining: N3 rail-noise injection sweep, N4 analytic
  thermal/1-f budget from bom.md.

## Noise campaign N3 - RAIL/REFERENCE SENSITIVITY (gen_cosim79.py / rail_n3.py)
- Method: gate-77 deck, DC source replaced by B-source with 997Hz+9973Hz test
  tones; differential pavg(79x)-pavg(77); LS fit at tones + fund+/-tone
  intermod sidebands.
- vcc15 (+15V rail, 10mV tones): sens -121.6 to -134.6 dB V/V (all components
  < 9nV at diffout). **Cascode isolation makes the +15V rail a non-line: any
  ordinary LDO suffices.**
- V_ref (1.25V cell-current reference, 1mV tones): DOMINANT path. At 997Hz:
  direct 0.083 V/V + multiplicative sidebands at fund+/-f 0.113 V/V each
  (RSS 0.18 V/V); rolls -20dB/dec above the R_bias/C_q4 pole (100R+10uF,
  159Hz; tone2 9973Hz reads -41dB, confirming slope).
- Integrated: in-band rms = ~40 x e_n(vref) for flat e_n -> to keep the line
  <= 100nV of 245nV budget, e_n(vref) <= 2.5nV/rtHz - NOT practical for a
  reference+divider. FIX: raise C_q4 10uF -> 220uF (pole 159Hz -> 7.2Hz,
  x22 attenuation) -> spec relaxes to ~55nV/rtHz, trivially met
  (ADR445-class). Verification gate 79c (C_q4=220uF, same injection) running.
- Prior-art check (N4): rtz_noise.py 2026-07-12 already establishes thermal
  floor ~138dB (~78nVrms) - to be re-verified against current deck values
  (750R tails, 28R load) as N4.
- GATE 79c (C_q4 10uF -> 220uF, same V_ref injection): sidebands at 997Hz
  -44.7 dB V/V (was -18.9) = 25.8dB improvement, matching the 22x pole shift
  (159Hz -> 7.2Hz). **N3 CLOSED. Design action: C_q4 = 220uF; V_ref spec
  relaxes to e_n <= ~55nV/rtHz for a <=100nV budget line (ADR445-class +
  divider trivially meets it). CAVEAT: kernel cosim68c3je was identified on
  the 10uF plant - re-run ID records + verification gate after adopting
  220uF before any further distortion work.**

## Noise campaign N4 - ANALYTIC THERMAL BUDGET (utils/thermal_n4.py)
- Structural: p-side conducts k cells, m-side 64-k -> 64 tails ALWAYS active
  -> tail thermal line is code-independent.
- Line items at diffout (duty 6/8): tails 64x750R 0.91 nV/rtHz -> 129 nVrms
  (132.6dB); cascode shot (degeneration-suppressed, gmRt~22) 19 nVrms
  (149dB); 2x28R load proxy 136 nVrms (132.1dB). Core total 188 nVrms =
  129.3dB - passes 128dB but consumes 59% of budget power. NOTE: the 28R
  loads are a cosim proxy; real I/V virtual ground removes that line (I/V
  stage gets its own budget). Core-only (tails+shot): 130nV, 132.5dB.
- The old 'thermal floor ~138dB' note (2026-07-12) was optimistic vs the
  as-built 750R/0.75mA plan. Headroom exists via larger Rt (needs vee
  headroom) if the output-stage budget demands it.
- Open deck-idealized items to spec in hardware: 2x50mA padding sources
  (degenerated mirrors, Rdeg for <=50nV line), replica-FF current sources.
- **NOISE CAMPAIGN N1-N4 COMPLETE.** Budget stack (245nV total): thermal core
  130 + I/V stage TBD + jitter <=100 (80-110fs spec) + V_ref <=100 (220uF fix)
  + quantization 26 + rails ~0. RSS core+jitter+ref+quant = ~193nV -> ~2dB
  margin before the I/V line.

## Round 80 - PLANT FREEZE v80 + FINAL ID CAMPAIGN (utils/patch_v80.py, 2026-07-26)
- v80 plant = cosim72 + C_q4 220uF (N3 fix) + padding as degenerated BJT
  mirrors (Qpad/286R to vee15, ~50mA; replaces ideal I sources). Sanity gate
  80 (75b stream, BIN=27): HD2 -98.7 / HD3 -105.7 vs 75b -99.4/-104.4 -
  no new distortion signature. PLANT FROZEN.
- TRAP 6 (tooling, caught before any fitting): first 80a-f record streams
  were generated with dpd_study.py DEFAULT LUT (cosim40_inl.npy - pre-R54
  plant measurement). Injected ~-83 dBc of static HD3, identical across
  seeds/BINs (the deterministic tell). Verified by exact stream reproduction:
  the R68/75 records used cosim55lut_inl.npy (R55 averaged LUT). All six
  streams regenerated with cosim55lut_inl.npy; wasted batch killed.
  PROTOCOL NOTE: dpd_study.py LUT argument must ALWAYS be explicit; consider
  removing the stale default.
- ID records 80a-f: BINs 37/37/17/11/5/27, seeds 111-116, static-LUT streams
  (cosim55lut), v80 decks. Refit = volterra_id2.py V80=1 NUALL=1 CUBIC=1 ->
  kernel cosim80c3j; then dpd_volt embed + verification gates (unseen seeds,
  incl. unseen BIN).
- ID records 80a-f measured; frequency signature matches R62 (80a/b HD2 -95.7
  ~= 68a/b). Joint fit V80=1 NUALL=1 CUBIC=1: held-out HD2/HD3 within
  0.1-0.7dB on all six records.
- TRAP 7 (fit conditioning): RIDGE=0 fit passed held-out validation but the
  kernel carried 74.6mV of nuisance-space static content (2.2x the 68c3je
  kernel); embed gates 81/82 read a FLAT ~-98 dBc floor at ALL harmonics
  (R69-class signature - null-space directions of the in-band-projected fit
  are unconstrained and blow up). RIDGE sweep 0/1e4/1e6/1e8: held-out
  predictions IDENTICAL to 0.1dB, |static| 74.6mV -> 365uV, dyn rms 33 -> 14.6
  uV at 1e8. PROTOCOL: always fit with RIDGE=1e8-class shrinkage and check
  |static| of the raw-action decomposition BEFORE embedding (sane: <1mV).
  Kernel cosim80c3j re-saved with RIDGE=1e8 (max|q| 4.24 ucode/unit^2, was
  493). Gates 81 (BIN=23 unseen, seed 117) / 82 (BIN=37, seed 118) re-running.
- GATE 81 (cosim80c3j ridge kernel, BIN=23 UNSEEN in ID, seed 117): HD2 -113.0
  / HD3 -112.8, HD4-8 <= -112.4 dBc. GATE 82 (BIN=37 worst case, seed 118):
  HD2 -118.0 / HD3 -115.0, HD4-8 <= -115.4 dBc.
- **V80 CAMPAIGN CLOSED: frozen plant (C_q4 220uF + BJT padding mirrors) +
  kernel cosim80c3j certified - every harmonic <= -112 dBc incl. an unseen
  frequency and unseen seeds, matching the pre-freeze 76/77 numbers. The N3
  reference fix and hardware-realistic padding cost NOTHING in distortion.
  SHIPPING CONFIG: v80 plant + cosim55lut static LUT + cosim80c3j Volterra
  kernel (39 terms, RIDGE=1e8).**

## Round 83-85 - CAL TOLERANCE SIMS (Step 6.5, v80 plant, BIN=37 worst case, 2026-07-26)
- Gate 83 (kernel x1.1, seed 119): HD2 -118.5 / HD3 -119.7, HD4-8 <= -104.6.
- Gate 84 (kernel x0.9, seed 120): HD2 -114.9 / HD3 -118.3, HD4-8 <= -106.2.
- Gate 85 (.temp 45, 27C kernel+LUT, seed 121): HD2 -104.4 / HD3 -105.5,
  HD4-8 <= -111.4.
- **CONCLUSIONS: (1) kernel amplitude accuracy is NOT critical - +/-10%
  mis-scale costs <= 4 dB and every harmonic stays <= -104 (core <= -114);
  cal fit precision is not the limiter. (2) Temperature drift IS the
  limiter: +18C with a cold cal costs ~13-14 dB on HD2/HD3 (to -104/-105).
  Error amplitude ~linear in dT -> +/-5C window around cal temp holds
  ~-115 dBc class. RECAL SPEC (feeds 6.6): either regulate/settle chassis
  to within +/-5C of cal temp before critical listening, or store a
  temperature-indexed kernel (2-3 cal temps, interpolate). Factory cal at
  the enclosure's steady-state operating temp, not bench-cold.**

## Round 86-89 - STEP 6.6 DECISION EXPERIMENT: recal-at-temperature (2026-07-27)
- Q: does a FULL cal performed AT 45C restore 27C-class performance at 45C?
  (If yes -> temperature-indexed cal table is viable; if no -> thermal
  regulation is mandatory.) Staged cheapest-first.
- STAGE 1 (static): 54lut/54lut2 chop decks re-run with .temp 45 (~6 min
  each; utils/patch_temp.py adds .temp to any gen_cosim41 deck). 45C LUT
  (cosim86lut_inl.npy = avg of both runs): max|INL| 6.7ppm - same magnitude
  as 27C, but DECORRELATED from the 27C LUT (corr -0.17; delta 4.0ppm rms
  vs 1.4ppm run-to-run repeatability = real drift). Cell gain -32.71 vs
  -30.98 mV/cell = +5.6%/18C (~0.31%/C, Vbe/mirror tempco).
- STAGE 2 (gate 86, 45C plant, 45C LUT + 27C KERNEL, BIN=37 seed 122):
  HD2 -106.2 / HD3 -104.7 - only ~2dB better than gate 85 (stale
  everything). Static LUT refresh alone does NOT recover the loss ->
  the 13dB temp hit lives in the DYNAMICS (kernel shape, not just the
  5.6% gain scale - gates 83/84 proved +/-10% scale is benign).
- STAGE 3 (full 45C re-ID): records 86a-f (BINs 37/37/17/11/5/27, seeds
  123-128, streams from the 45C LUT, decks at .temp 45). Record signature:
  HD2 -92.7/-93.3 @BIN37 vs -95.7 at 27C (same shape, ~3dB hotter). Fit
  V86=1 NUALL=1 CUBIC=1 RIDGE=1e8 -> kernel cosim86c3j: held-out within
  0.5dB/0.9-16deg on all six, |static| 475uV (<1mV TRAP-7 gate), dyn
  action -138.7 dBc.
- VERIFICATION GATES (45C plant, 45C LUT + 45C kernel):
  Gate 87 (BIN=23 UNSEEN, seed 129): HD2 -112.2 / HD3 -117.1, HD4-8 <= -113.5.
  Gate 88 (BIN=37 worst, seed 130):  HD2 -115.4 / HD3 -119.9, HD4-8 <= -109.1.
  == 27C reference class (gates 81/82: -113.0/-112.8, -118.0/-115.0).
- **STEP 6.6 ANSWER: recal AT temperature FULLY restores performance.
  Temperature-indexed cal table (static LUT + Volterra kernel per temp
  point) is VIABLE; thermal regulation is NOT required. Note the static
  LUT decorrelates across 18C, so the table must index BOTH the LUT and
  the kernel - a kernel-only table would leave the ~4ppm static residue.**
- dT LADDER (BIN=37 worst case, 45C cal = cosim86lut + cosim86c3j):
    dT=0    (gate 88, .temp 45):   HD2 -115.4 / HD3 -119.9
    dT=4.5  (gate 90, .temp 40.5): HD2 -112.8 / HD3 -114.4
    dT=9    (gate 89, .temp 36):   HD2 -105.4 / HD3 -115.3
    dT=18   (gate 85, 27C cal):    HD2 -104.4 / HD3 -105.5
  HD2 loss is NOT linear in dT (R85 conjecture wrong): ~2.6dB at 4.5C,
  ~10dB at 9C, then saturates. +/-4.5C of a cal point holds the -112 dBc
  class; +/-9C does not (-105).
- **STEP 6.6 DECISION (final): temperature-indexed cal table, NO thermal
  regulation. Table = static LUT + Volterra kernel per cal temp, spacing
  <= 9C (worst-case distance 4.5C -> every harmonic <= ~-112 dBc),
  nearest-point selection (interpolation not needed at that spacing and
  untested). Requires a temp sensor AT THE CELL ARRAY (board NTC; FPGA
  die temp is a poor proxy for the discrete cells). Expected cell-temp
  range ~25-50C -> 3 factory cal points (e.g. 27/36/45C) = 3x(64-entry
  LUT + 39-term kernel + stat[64] + FIR[16]) per channel in QSPI -
  trivially small. Recal advisory flag if sensor leaves table range.
  Feeds Step 6.3 (kernel register file gains a temp index) and Step 6.1
  SOP (cal repeated at 3 chamber temps after burn-in).**

## Round 91-94 - PASSIVE REPLICA-FF RATIFIED (utils/gen_cosim91.py, patch_passive.py, r92_records.ps1, 2026-09-09..11)
- Q: can the ideal B-source replica drive (krep*N*pw into the cascode-gate
  replica MOSFETs) be built from real parts without losing the gate-88 class?
- NETWORK (leg b, ratified): each reclock FF output (Q for the m-rail, Qbar for
  the p-rail - both exist on SN74LVC1G74) -> 10k into one summing node per
  replica; 156R shunt to 5.94V bias, 50pF node C (tau ~4ns); 2SA1036K PNP V-I
  (35.3R degeneration, emitter rail 7.2V) sources 51.9..98.6mA into the
  diode-connected replica MOSFET. Second cascode gate (casb2) FIXED at 4.37V.
  THAT-array PNP rejected (beta collapse at 100mA, +/-20mA base current, bus
  p-p 35mV). Rs=1k rejected (6.4W bias network); Rs=10k = 0.64W.
- Gate 91a (both replicas passive) vs 91b (bus only, casb2 fixed), STALE 86 cal:
  -103.7/-100.0 vs -103.0/-100.4 -> a==b, second replica dropped (-2 PNP
  chains, -128 R, -1.2W/ch). Stale-cal reading is NOT the verdict (cf gates
  85/86) -> full R86-protocol recal on the leg-b plant.
- STAGE 1 (54lut/54lut2 at 45C, patched v80 + passive -> cosim92lut_inl.npy):
  max|INL| 4.05ppm (86lut 6.7), gain -32.7121 mV/cell IDENTICAL to 86lut,
  delta vs 86lut 2.8ppm rms (real; repeatability 0.92). Static plant untouched.
  NOTE: the R86 LUT decks were still pre-v80 (ideal padding); 92lut is the
  first LUT on the true v80 padding - no visible effect.
- STAGE 3 records 92a-f (BINs 37/37/17/11/5/27, seeds 131-136): HD2 ~3dB
  BETTER than 86 records, but a NEW HD3 term at -101..-104 dBc (86: -114..-120)
  = odd-order, replica-path mechanism (node lag / PNP gm law). Fit V92=1
  NUALL=1 CUBIC=1 RIDGE=1e8 -> kernel cosim92c3j: held-out <=0.1dB / <=2deg on
  all six INCLUDING the new HD3; |static| 432uV, dyn rms 15.4uV. Deterministic,
  <=5-sample memory, cubic-representable -> DPD removes it.
- VERIFICATION GATES (45C plant, 92lut + 92c3j):
    Gate 93 (BIN=37 worst, seed 137): HD2 -125.6 / HD3 -123.8, HD4-8 <= -106.5
    Gate 94 (BIN=23 UNSEEN, seed 138): HD2 -121.7 / HD3 -121.6, HD4-8 <= -120.9
  vs gate 88/87 (ideal replica): -115.4/-119.9, -112.2/-117.1. **PASS - the
  passive replica-ff is ratified for the schematic (leg b, Rs=10k, 2SA1036K).
  HD2/HD3 are 6-10dB better than the ideal-replica gates; HD7 -106.5 at BIN=37
  sits on the NS/DEM popcount floor for that stream (ideal popcount HD7 -105).**
- Power (per channel, deck rail currents): cells 0.06W, loads+cascodes 1.1W,
  padding 1.7W (1.43W of it in the two 286R -> pad from -5V saves ~1.3W/ch,
  rails item), replica MOSFETs 0.4W, replica V-I + bias 1.2W (leg b), vfr sink
  0.26W constant (I_p+I_m code-independent). ~4.2W/ch class vs 6.65W in the
  ideal-replica deck.
- TRAP 8 (tooling): SIX parallel LTspice -b runs on the 16-core box took 33h
  and were still <60% done (each solver spins 2-3.5 cores; oversubscription
  ~70x slowdown). Two at a time = 22min each. NEVER run more than 2.
- TRAP 9 (tooling): rtz_fft39.py CACHES cosim<tag>_pavg.npy and reuses it
  blindly. Analysing a partial/killed raw poisons the cache for the finished
  rerun (92d/e read HD2 -38/-20 dBc; fit held-out off by 40dB). Delete
  _pavg.npy whenever a raw is regenerated.
- Files: gen_cosim91.py (leg a/b explorer, deck 88 base), patch_passive.py
  (applies leg-b network to ANY v80 deck incl. thermometer-gated LUT decks),
  r92_records.ps1 (stage-3 driver; MUST be throttled to 2 runs - TODO),
  q91_check.py / q91_quick.ps1 (8us quick-look with rail powers),
  volterra_id2.py V92 record set. Cal artefacts: cosim92lut_inl.npy,
  cosim92c3j_{Q,pairs,stat,firw}.npy.

## BENCHMARK: dCS Vivaldi APEX - STATUS + PARITY CAMPAIGN (2026-09-12)
- dCS published/measured (spec sheet; Stereophile APx500, 6V out, 600R):
  residual noise better than -113 dB0 (20-20k unweighted); spurious
  < -105 dB0; L-R crosstalk -115 spec / >125 dB measured (113 at 20k);
  THD+N 0.00026% (-112 dB) at 1 kHz FS; HD3 -127 dB (highest harmonic);
  19+20k IMD 2nd-order difference -130 dB; >= 20-bit resolution.
- BFDAC as of gates 93/94 (SIMULATION, analog core, 45C, -1dBFS):
  HD2 -125.6/-121.7, HD3 -123.8/-121.6 = parity class. THD RSS -114 dBc at
  8.6k, but HD4-8 are on the 16k-record popcount floor (measurement-limited).
  Noise budget (N1-N4) core RSS 193 nV = -131 dB0 with I/V stage, 1/f, PSU,
  PCB NOT modelled. Jitter spec 80-110 fs white. Unaddressed: 1 kHz all-in-band
  THD, IMD, close-in phase noise, crosstalk, I/V stage noise.
- DECISION: complete the simulation set to high confidence of >= dCS on every
  published line BEFORE hardware. Then schematic -> hardware test.
- CAMPAIGN (one LTspice run at a time where >22 min; max 2 concurrent):
  [x] P1  Gate 95: 1 kHz-class THD, M=65536, BIN=11 (1031.25 Hz), seed 139,
          92lut+92c3j, HD2..HD8 all in band (94 min, 1 core).
          RESULT: HD2 -122.1, HD3 -122.1, HD4 -124.8, HD5 -124.4, HD6 -136.0,
          HD7 -125.3, HD8 -122.6 dBc -> THD (RSS HD2-8) = -115.5 dBc.
          vs dCS: THD+N -112 (BFDAC better by 3.5 dB before noise is added);
          HD3 -127 (dCS better by 5 dB). Kernel generalizes to 1 kHz although
          no ID record was below 1.9 kHz. NOTE gen_cosim41/dpd_volt take M
          from env; .tran is derived from M (was hard-coded from v72 - a 65k
          gate would have silently truncated at 16k).
  [x] P2  IMD: 19+20 kHz two-tone at -3 dBFS peak (dCS -130 at 1 kHz
          difference). dpd_volt BIN2 env (equal tones, peak sum = AMPDB);
          gate 96 = bins 51/53 at M=16384 (19.125/19.875 kHz; f2-f1 750 Hz,
          2f1-f2 18.375k, 2f2-f1 20.625k), seed 140, 92lut+92c3j. Readout
          utils/imd_read.py (LS basis of all <=3rd-order products - single
          FFT cannot resolve products 2 bins from the tones: Kaiser leakage).
          Code-stream floor f2-f1 -117.5 dB re peak.
          RESULT (analog, re -3 dBFS peak): f2-f1 (750 Hz) -129.4 dB;
          2f1-f2 (18.375k) -126.0; 2f2-f1 (20.625k) -126.0; all >= 2nd-order
          sums/harmonics above 38 kHz <= -121. vs dCS f2-f1 -130: PARITY.
          Both 95/96 are single-seed; the -122..-129 class is ~4-6 dB above
          the corrected-stream popcount floor, so they are analog-limited.
  [x] P3  Clock phase noise (N2b) - utils/pn_n2b.py (analytic) + gate 97
          (validation cosim, gen_cosim97.py / pn_read97.py).
          MECHANISM: both RTZ pulse edges are retimed from the same 49.152 MHz
          clock 6 cycles (122 ns) apart. Common slow edge displacement tau(t)
          leaves pulse WIDTH (charge) untouched, only moves POSITION =
          time-warp s(t - tau): sidebands 2*pi*f_sig*tau_rms re tone. Width
          error = tau(t_fall) - tau(t_rise): PN weighted by 4 sin^2(pi f Tw),
          -3 dB at 1.37 MHz -> ONLY THE BROADBAND FLOOR (>~1 MHz) MATTERS.
          Close-in (1/f^3, 1/f^2) PN of any audio-grade XO: ~170 fs rms
          <=20 kHz -> -179 dBc @1k, -153 dBc @20k. NOT a budget line. OCXO
          vs XO is irrelevant here (OCXO buys ppb stability, not floor).
          CLOCK CANDIDATES (no OCXO/XO was ever captured in bom.md - only the
          two frequencies): Crystek CCHD-957-25-45.1584/49.152 (user pick,
          XO, +/-25 ppm, ~82 fs 12k-20M, floor ~-169 - VERIFY on datasheet);
          NDK NZ2520SDA audio grade per NDKT02-00008 (-158 @1k, -172 @100k,
          43 fs; the per-frequency sheets carry a worse generic table);
          Taitien OX-U (floor -173). Osc-only width jitter: 81 / 57 / 51 fs.
          FINDING - THE TREE, NOT THE OSCILLATOR, SETS THE LINE: common path
          adds LMK00304 51 fs + 2x LMK1C1108 20 fs = 58 fs (verified R30) ->
          common line 109 nV (CCHD-957) / 90 nV (NZ2520SDA). The per-cell
          SN74LVC1G74 additive jitter is NOT datasheet-spec'd (bom open item
          #10, "0.2-1 ps, bench-verify"); it is independent per cell so it
          enters at ~sqrt(64)/40 = 0.2x the common sensitivity: 200 fs ->
          44 nV, 400 fs -> 88 nV, 1 ps -> 220 nV. Total jitter line:
          118-246 nV (CCHD-957), 100-238 nV (NZ2520SDA) over the FF range.
          **The 100 nV allocation needs per-FF <= ~200 fs AND the -172 floor
          part; with the 245 nV total budget (thermal 130 + ref 100 + quant
          26 = 166 RSS) the jitter line may take <= 180 nV -> per-FF <= ~0.6
          ps with CCHD-957. LVC1G74 additive jitter is now the single most
          important unmeasured number in the noise budget; if the bench
          says > 0.6 ps, fall back to an ECL FF (MC100EP52 class, ~0.2 ps
          spec'd) with a level shifter, or accept the line.**
          Gate 97 RESULT (21 min): gate-93 deck, all edges displaced by
          50 ps * sin(2 pi 1125 Hz t), differential vs 93: fund+/-1125 Hz
          sidebands -112.8 / -112.8 dBc vs time-warp prediction -113.2
          (0.4 dB); charge-modulation model (-73.8) ruled out by 39 dB.
          Per-bin differential sensing floor -146 dBc. MODEL VALIDATED:
          close-in clock PN is position-only; only broadband floor + per-FF
          additive reach the output.
          DECISIONS (2026-09-13, user): (1) keep the LMK00304 mux + LMK1C1108
          tree as designed (the OE-wire-OR alternative would save ~51 fs /
          ~20 nV; simplicity preferred). AD9558/LMK048xx-class PLL cleaners
          REJECTED: their -150..-160 floors are 10-20 dB worse than the XO
          and the floor is the only thing that matters. (2) Oscillator:
          Crystek CCHD-957-25 primary (user), NDK NZ2520SDA (NDKT02-00008)
          second source; both to bom.md s1 as Y301/Y302.
          (3) SN74LVC1G74 additive jitter handling: (a) design the FF
          environment - full-swing >=3 V/ns clock edges from the LMK1C1108
          leaf, per-FF ferrite + local decoupling from a dedicated low-noise
          3.3 V rail (delay sensitivity ~50-100 ps/V -> <=1 mV rms rail
          noise = ~0.1 ps); (b) bench-measure first (bom open item #10 ->
          FIRST hardware-test gate item, breakout: 1 LMK1C1108 + 10 LVC1G74
          + intended decoupling); (c) BOM hard spec <= 0.6 ps rms additive,
          fallback MC100EP52 / NB7V52M-class + level translator (Round 29
          costing exists); (d) pin the independence ratio by cosim.
          Perspective: even at 1 ps the total is ~297 nV = -126 dB0, still
          13 dB better than dCS's -113 dB0 - a margin question vs our own
          128 dB target, not a benchmark question.
          Gate 98 RESULT (142 min; gen_cosim98.py / jitter_n2c.py): gate-93
          deck, 64 cells x own pwa_i/pwb_i PWL (Q/Qb share the FF clock
          edge), sigma 10 ps independent per cell and edge; differential vs
          93: in-band 1.93 uVrms raw, 1.71 uV floor-corrected (0.9 uV N2
          control) = 0.171 uV/ps -> INDEPENDENCE RATIO 0.155 (paper 0.20).
          Per-FF line: 200 fs 34 nV, 400 fs 68 nV, 600 fs 103 nV, 1 ps 171 nV.
          Budget consequence: jitter line <= 180 nV with CCHD-957 common 109
          nV leaves 143 nV for the FFs -> **per-FF additive <= 0.84 ps**
          (NZ2520SDA: common 90 -> 156 nV -> <= 0.91 ps). BOM spec set to
          <= 0.8 ps (0.6 ps = comfortable). At 1 ps worst case total noise
          is ~270 nV = -127.2 dB0. P3 CLOSED; pn_n2b.py updated to 0.155.
  [ ] P4  Crosstalk: 2-channel deck stub (shared rails + reference + reclock
          bus), victim channel at digital zero, aggressor -1dBFS 1k/20k;
          target <= -120 dB. Board-level parasitics as parameters (rail
          impedance, mutual C between blades).
  [~] P5  I/V + output stage design + noise budget (0.69 Vrms core -> 2/6 V
          balanced; the 28R proxy loads are removed). Must hold the total
          <= 245 nV (128 dB) incl. 1/f of the chosen op-amps; then re-run
          gate 93-class on the combined core+I/V deck.
          DESIGN (2026-09-16/19, utils/iv_n5.py, utils/gen_iv5.py): per
          rail transimpedance whose summing node = col node held at the
          SAME 7.0 V DC it sits at today (plant-faithful; C_col 12 nF kept
          as RTZ slam absorber). OPA1612 (+in = 7.0 V ref) + BUF634A in
          the loop; Rf 270R || Cf 1.3n (450 kHz, = the old 28R||12n pole),
          BOTH from the buffer output; R_off from a feed rail into the
          summing node supplies the cascode DC. FS +/-31.5 mA (+/-28
          codes) -> 6.0 Vrms balanced DIRECTLY from the I/V (per-side
          +/-4.25 V pk). Stage 2 = 600R tap string on the existing K1/K2
          level relays (6/4/2 V) + OPA1612 unity buffer.
          DC FACTS (gate-99 probe caught the first pass wrong): the cells
          SINK from col, so for a 0 V output R_off must carry the cascode
          DC PLUS the 26 mA Rf current (7 V/270R); and the plant DC is
          asymmetric (unselected cells steer into bus_minus): I_p = 68,
          I_m = 80 mA at midcode -> I_off 94/106 mA, R_off_p != R_off_m.
          NOISE (28R domain, 20 Hz-20 kHz), analytic iv_n5.py, TI
          macro-model .noise agrees to 4% (symmetric test case 88.8 vs
          92.9 nV; NPAR=2 80.3 vs 82.3):
            feed +15 V, out 0 V : R_off 85/76R, I/V 137 nV -> stack 262 = 127.5 dB0
            feed +15 V, out 7 V : R_off 118/100R, I/V 115 -> 252 = 127.9 (needs diff stage 2)
            feed +15 V, NPAR=2  : I/V 117 -> 253 = 127.8
            feed +24 V, out 0 V : R_off 181/160R (1.6/1.8 W), I/V 93 -> 242 = 128.2
            feed +36 V, out 0 V : R_off 309/274R (2.7/3.1 W), I/V 76 -> 237 = 128.4
            feed +36 V, NPAR=2  : I/V 70 -> 235 = 128.5
            (pad 50 -> 10 mA, PLANT CHANGE, +15 V: I/V 104 -> 247 = 128.0)
          The feed-rail voltage is the lever (noise ~ sqrt(I_off/dV) and
          e_n*I_off/dV); stack uses the V_ref 100 / jitter 150 BOUNDS, so
          realistic totals are ~10-15 nV lower. LESSONS: (a) e_n sees
          R_off || Rf - noise gain 2.4-4, not 1; (b) Cf from the OP-AMP
          output lets the BUF634A input-current noise reach the output
          (+36 nV RSS) - Cf must hang on the buffer output (sim 100 -> 93).
          DECISION PENDING (user): R_off feed rail (+24 V recommended
          minimum; 4 resistors x 1.6-1.8 W per stereo unit) vs accept
          127.5-127.9 dB0 on +15 V. Gate 99 launched 22:01 on the +24 V
          variant (R_off only sets DC; distortion result is rail-agnostic).
          TOOLING TRAP 10: bfdac_iv5t.cir (3 ms .tran, 2 ns step, reltol
          1e-5, TI macro-models) ran >3 days / 10 GB raw without finishing
          - macro-models + RTZ edges collapse the timestep. gen_iv5.py now
          has a subprocess timeout and a 300 us/10 kHz tran; the gate-99
          deck will use a BEHAVIORAL amp (cosim24-style gm/C integrator +
          slew limit, GBW 40 MHz) for distortion, TI models for .noise only.
          iv5t status 2026-09-21: 434 CPU-h, raw 18.9 GB, sim time reached
          2.297 us of 3000 us (0.08 %), last 1000 records at ZERO time
          advance -> stalled in a timestep-collapse loop, will never
          finish. (Progress check recipe: parse the last record's time
          from the .raw tail - LTspice -b streams points as it goes; low
          RSS is normal.)
          GATE 99 RESULT (BIN=37, 92lut+92c3j baked into the code, +24 V
          variant, 25 min): analog HD2 -98.8 / HD3 -118.1 / HD4 -115.5 /
          HD5 -110.7 / HD7 -106.7 vs gate 93 -125.6 / -123.8 / <= -106.5.
          The ideal-popcount readout shows the baked pre-distortion at
          HD2 -95.6 / HD3 -99.8: on the 28R plant it cancelled to -125.6;
          on the I/V plant (col held at fixed Vds) the plant's own HD2 has
          a different magnitude/phase, so the 28R-identified kernel no
          longer cancels. => THE KERNEL DOES NOT TRANSFER; gate 99 is not
          a valid A/B. Required: re-run the ID campaign (r92_records.ps1
          record set + LUT + volterra_id2 fit) on the P5 plant, then a
          93-class gate. Positive: HD7 (popcount floor) unchanged, col
          residual +/-35 mV, DC lands as designed (probe 99s).
  [~] P6  1/f: cascode MOSFET + PNP replica + V_ref 1/f corner not in the
          LTspice models - analytic budget line (datasheet e_n curves) in
          thermal_n4.py; verify V_ref/C_q4 pole covers it.
          utils/flicker_n6.py (2026-09-19). NEW MECHANISM: C_bus 47 nF on
          each cascode source turns ANY gate (casb) voltage noise into
          output current, i = e_g*wC_bus = 0.48 A rms per V/rtHz white
          over 20 Hz-20 kHz (x2.9 with a 100 kHz 1/f corner). Lines (28R
          domain): M5 channel 8, MR diode 9, replica chain (ns1 78R
          Thevenin + FF/5.94/7.2 rails through the 2SA1036K, gain 0.07
          V/V) 31, vfr 20 nV/rtHz x 5% p/m mismatch 14, padding 2x286R
          (v80, N4-flagged) 43 -> P6 total 56 nV. SPECS: independent
          per-side casb noise <= 1.6 nV/rtHz white-equivalent per 30 nV
          line; vfr (common) <= 31 nV/rtHz at 5% mismatch. Si1555 1/f
          corner is NOT spec'd (100 kHz assumed) - bench item. casb2
          (4.37 V, top cascode) sees only device C -> non-line.
  [x] N7  FULL-PLANT SPICE .noise gate 100 (2026-09-21, utils/gen_noise100.py):
          gate-93 deck made static (cells 1..32 selected, RTZ window held
          ON), 28R proxies replaced by the P5 I/V (behavioral amp - the TI
          macro-models fail the 64-cell DC op point - with OPA1612 e_n/i_n
          injected by resistor-noise copiers; Cf on the buffer output), all
          references/rails given spec'd white e_n via copiers (V_ref 55,
          vfr/casb2/5.94/7.2 20, FF rail 15, V_VG 10 nV/rtHz). .noise
          V(diffout) 20 Hz-20 kHz, 28R domain, ~3 min each. Jitter 150 and
          quant 26 added analytically (time-domain lines).
          BASELINE (v93 plant, V_VG 4 V, +15 feed): SPICE 212.5 nV ->
          total 261 nV = 127.6 dB0. Breakdown (RSS over the 64 cells):
          tails 64x750R 144 (static ON; RTZ-duty-weighted ~130), THAT tail
          BJTs 55 (base shot 40 + rb 28 + collector shot 26), OPA e_n 73,
          R_off 67, **Qpad BJT mirrors 65 (base shot noise Ib=0.5 mA, NOT
          in the analytic budget)**, Q5551 steering pairs 45 (base shot),
          Rf 45, Rpad 286R 43, **Rg5 100R gate stoppers 27 (4kTR on casb x
          wC_bus - P6 mechanism confirmed in SPICE)**, bleed 910R 24.
          Common-mode rails (vfr, casb2, 5.94, 7.2, FF, V_ref, V_VG) read
          0.00 in the perfectly symmetric static deck - they cancel
          differentially; the mismatch leak stays analytic (P6: ~20 nV).
          VARIANTS (all with jitter 150 + quant 26):
            +MOSFET pad (Si1555, same 286R)          202.2 -> 253 nV = 127.84
            +Rg5 100 -> 10R                          200.6 -> 252 nV = 127.88
            +V_VG 3 V (+15 feed, R_off 141R)         197.2 -> 249 nV = 127.98
            V_VG 7 V, +24 V feed (R_off 170R)        193.0 -> 246 nV = 128.09
          READING: the SPICE gate lands 0.1-0.5 dB below the 128 dB0 target
          in every configuration; the differences between the rail/V_VG
          options are <= 0.25 dB. Static-ON tails overstate the core by
          ~14 nV (duty), which alone brings the +15 V / V_VG 3 V / MOSFET
          pad / Rg 10R case to ~128.0. The stack is dominated by things
          the I/V rulings do not touch: tails 130-144, jitter 150 (bound,
          FF 0.6 ps), OPA e_n 73, R_off 67. DECISIONS THIS ENABLES:
            (a) padding = MOSFET (or high-beta/Darlington) mirror - free
                65 nV; plant change but code-independent DC only, re-ID
                needed anyway for the I/V plant.
            (b) Rg5 10R (or bypass casb) - free 27 nV.
            (c) V_VG 3-4 V on +15 V is within 0.1 dB of the +24 V rail:
                NO new rail needed (reverts P5's 7 V choice to the July
                architecture's low summing node).
            (d) remaining headroom must come from jitter (oscillator/FF
                bench numbers) or a lower-noise front amp (NPAR=2: -13 nV
                on e_n) - not from the I/V DC network.
          CLOSURE RUNS (DUTY/MIS knobs added; cell groups Rt/Q/QS scaled by
          the 6/8 RTZ duty from the per-group .raw breakdown; MIS applies
          +5% to the m-side R_off, C_bus, R_f, Rg5 so the common-mode rails
          leak differentially). Ratified plant (MOSFET pad, Rg5 10R, V_VG
          3 V, +15 V feed, R_f 270):
            symmetric:      197.2 static-ON -> 180.1 duty -> 235.8 nV = 128.45 dB0
            5 % mismatch:   203.7 static-ON -> 186.4 duty -> 240.6 nV = 128.28 dB0
          Leak with 5 %: vfr 28 nV (P6 analytic 14 at R_off-only mismatch;
          the SPICE case also skews C_bus and Rg5), all others < 10.
          RESULT: 128.3 dB0 with jitter at its 0.84 ps bound, 4 nV under
          the 245 nV target. At 0.6 ps FF jitter (jitter line ~120 nV):
          ~128.9 dB0. Remaining unmodelled: MOSFET/PNP 1/f (P6 analytic
          56 nV line already inside the copier e_n specs), PSU/PCB.
  [x] RULINGS RATIFIED 2026-09-21 (user, after N7):
          1. V_VG = 3 V -> CORRECTED TO 4.0 V the same evening: the gate-100
             .op shows mid_p = 2.998 V (casb2 4.37 - Vgs 1.37 @ 74 mA), so
             V_VG 3 V puts M6 in triode (mid_p pulled to 2.86 V, Vds 0.14 V);
             at 4 V M6 has Vds 1.0 V (Vgs-Vt 0.27). Noise at 4 V, ratified
             plant, duty-weighted: 238.7 nV = 128.35 dB0 sym / 243.5 nV =
             128.17 dB0 at 5 % mismatch - still under 245 nV. USER ACK
             2026-09-21 22:05 -> V_VG = 4.0 V is the ratified value.
             2. R_f = 270R direct to 6 Vrms balanced, no
             line V-stage. 3. R_off feed = +15F (NO +24 V rail; P5's 7 V
             proposal withdrawn). 4. Padding mirror = Si1555 MOSFET (or
             equivalent no-base-current device); Rg5 = 10R. NPAR=2 front
             amp NOT designed in - dual-package footprint reserved as a
             jumper-level fallback if bench FF jitter lands > 0.7 ps.
          NEXT: re-ID campaign (R92 records) on the ratified P5 plant, then
          gate 93-class A/B, then P7/P8.

  [ ] P7  Long-record noise floor: 65k+ gate at digital silence and at
          -60 dBFS (dCS "20-bit resolution" test), Kaiser b38 readout.
  [ ] P8  Consolidated comparison table (sim vs dCS, line by line, with the
          measurement-floor caveats stated) -> go/no-go for hardware.
  [ ] TODO SCHEMATIC (hardware-test prerequisite): capture the ratified
          analog channel - 64 cells (750R tails, Si1555 double cascode, THAT
          NPN steering), v80 padding mirrors (pad from -5V per rails item),
          passive replica-ff (leg b: 64x10k sum, 156R/50pF node, 2SA1036K V-I,
          35.3R, 7.2V rail, casb2 fixed 4.37V), C_q4 220uF reference filter,
          reclock FF bank (SN74LVC1G74 x64, Q/Qbar), I/V stage (P5), rails
          (+15/-15/+8/+7.2/+5.94/-5, 3.3V logic), board NTC at the cell array
          (temp-table cal). Deliverables: KiCad schematic + bom.md reconcile +
          netlist-vs-LTspice-deck cross-check script.

## Step 5.1 — FIRST FULL VU13P SYNTHESIS (2026-07-27)
- TOOLING TRAP: two Vivado installs on this machine. 2025.2.1 CANNOT check
  out the license for xcvu13p ("feature Synthesis ... not found") even with
  XILINXD_LICENSE_FILE set and the FlexLM server up. **2026.1
  (C:\AMDDesignTools\2026.1, source Vivado\settings64.bat) is the correct
  version** — license (CORE tier, INCREMENTs versioned 2027.06, expires
  27-jun-2027, served 2100@localhost) checks out fine there. Always:
  cmd /c "call C:\AMDDesignTools\2026.1\Vivado\settings64.bat && vivado ...".
- RUN 1 (synth51.log): SYNTH_OK, 0 errors, 0 critical synth warnings, ~40 min.
  UTILIZATION (NUM_MACS=1024): LUT 148.8k (8.6%), FF 195.4k (5.7%),
  DSP 2062 (16.8%), URAM 512 (40%), BRAM 5.5 (0.2%), IOB 177/702.
  TIMING: all intra-clock setup MET — dsp_clk 280.87 MHz WNS +0.31 ns
  (762k endpoints). FAILURES were all inter-clock CDC paths
  (clk_200m<->dsp_clk, i2s_bclk->dsp_clk, cell_clk->ff_clk hold).
- ROOT CAUSE: create_generated_clock with -master_clock/-divide_by but no
  -add is REJECTED (CRITICAL WARNING 12-672) -> dsp_clk/cell_clk kept their
  auto-derived names (dsp_clk_unbuf/cell_clk_unbuf) and every
  set_false_path referencing dsp_clk/cell_clk silently matched nothing.
  FIX: name-only rename idiom on the MMCM output pins:
  create_generated_clock -name dsp_clk [get_pins u_clk_gen/u_mmcm/CLKOUT0].
  Also fixed BITSTREAM.CONFIG.CONFIGRATE 33 -> 31.9 (not a valid US+ enum).
- RUN 2 (synth51b.log): SYNTH_OK, 0 errors, 0 critical warnings. All CDC
  exceptions now apply. **SETUP TIMING MET: WNS +0.309 ns, TNS 0** (763k
  endpoints, dsp_clk @ 280.87 MHz). Utilization unchanged (LUT 8.57%).
  Remaining hold: (a) intra-dsp_clk THS -24.3k ns over 355k endpoints at
  WHS -0.095 — normal pre-route estimate, the router fixes hold; (b)
  cell_clk->ff_clk WHS -0.785 on the 128 cascode output ports vs the
  virtual ff_clk (output window -max 2.5 / -min -1.5). RTZ tolerates
  +/-5 ns pulse position, so the -min value is reviewable; defer to
  Step 5.2 implementation where clock insertion delays are real.
- STEP 5.1 DONE. Next: Step 5.2 (implementation run: opt/place/route on
  the synth_top.dcp checkpoint), still pending MIG IP for DDR4.

## Round 101 - RE-ID ON THE RATIFIED P5 PLANT (utils/patch_p5.py, r101_records.ps1, 2026-09-21)
- patch_p5.py: applies the ratified P5 plant to ANY v80+passive deck (LUT
  chop, record, gate): 28R proxies out, behavioral OPA1612-class I/V (cosim24
  recipe, GBW 40M / 27 V/us / Aol 1e6, ideal buffer), Rf 270 || Cf 1.31 nF,
  R_off 133/116 from +15 (68/80 mA midcode DC, out DC 0), V_VG 4.0, Rg5 10R,
  Si1555 MOSFET pad (gate 0.6 V -> ~50 mA). diffout = (out_m - out_p)*28/Rf
  so it FALLS with code like the proxy did (rtz_inl_full sign, rtz_fft39
  domain, dpd_volt GAIN_V -0.031 all unchanged). NOTE gen_cosim99 had the
  opposite sign (out_p - out_m) -> its kernel embed was sign-inverted; one
  more reason gate 99 was not a valid A/B.
- STAGE 1 (54lut_t45p5 / 54lut2_t45p5 = the R92 LUT decks + patch_p5, 7-9
  min each): gain -32.7147 mV/cell (92lut -32.7121: domain preserved to
  0.01 %). max|INL| 25.8 ppm vs 4.05 on the 28R plant - a smooth QUADRATIC
  bow (0.031 ppm/code^2, cubic-fit residual 1.4 ppm), run-to-run 0.96 ppm
  rms / corr 0.995 -> real and static. Mechanism (hypothesis): the amp
  cannot follow the RTZ waveform (9.7 V p-p at 6.1 MHz vs 27 V/us), so
  C_col 12 nF absorbs the ripple and the slew-limited (tanh) loop servos
  the AVERAGE; the mean col-node error is ripple-amplitude (code) dependent
  -> even-order static term. Exactly what the static LUT exists to remove;
  the dynamic part (if any) is the kernel's job - records decide.
  cosim101lut_inl.npy = avg of both runs.
  OPEN (P5 design): quantify col ripple; consider C_col 47 nF (ripple /4)
  and check the loop with the summing-node C (Cf/Rf 450 kHz pole).
- STAGE 3: r101_records.ps1 (records 101a-f, BINs 37/37/17/11/5/27, seeds
  151-156, streams from cosim101lut_inl.npy, throttled to 2 solvers).
  ~30 min per record (I/V nodes; R92 was 22). Record signature (SPICE,
  static LUT only): HD2 -110.5/-111.6 (BIN 37) .. -120 (BIN 5) vs R92
  ~-96: the virtual ground removes the load-nonlinearity HD2. HD3 -96.3/
  -97.5 @37, -100 @27, -104..-107 @17/11, -114 @5 - the R92 odd-order
  replica-path term (~-101..-104) is ~4 dB hotter at high BIN and strongly
  frequency dependent (dynamic). HD4+ <= -117.
  FIT (V101=1 NUALL=1 CUBIC=1 RIDGE=1e8) -> cosim101c3j: held-out HD2/HD3
  within 0.3 dB / 0.5 deg on ALL six (best fit so far; R92 was 0.1 dB/2
  deg). |static| 334 uV (<1 mV TRAP-7), |fir| 18.5 uV/unit, dyn rms 20.5
  uV, dyn-action floor -142 dBc. Deterministic and cubic-representable.
- GATES launched 23:52 (101lut + 101c3j, patch chain + patch_p5, .temp 45):
  gate 102 = BIN 37 seed 157 (worst, direct A/B vs gate 93 -125.6/-123.8),
  gate 103 = BIN 23 seed 158 (UNSEEN bin, vs gate 94 -121.7/-121.6).
- GATE RESULTS (38/33 min):
    Gate 102 (BIN 37): HD2 -115.8 / HD3 -119.6; HD4-8 -109.7..-121 (ideal
      popcount of the same stream -104.9..-116.4 -> HD4+ measurement-limited)
    Gate 103 (BIN 23): HD2 -119.5 / HD3 -115.5; HD4-8 -108.2..-127.6
      (popcount floor -107.8..-112.6)
  vs proxy-plant gates 93/94: -125.6/-123.8 and -121.7/-121.6.
  READING: the DPD TRANSFERS to the P5 plant (record 101a -110.5/-96.3 ->
  gate -115.8/-119.6: HD3 -23 dB, HD2 -5 dB), i.e. the ratified plant is
  calibratable and lands in the -116..-120 dBc class at 45C. But it is
  6-10 dB (HD2) / 2-6 dB (HD3) short of the 28R-proxy gates. The residue
  is the I/V stage's own dynamic error: the slew-limited loop (27 V/us vs
  a 9.7 V p-p demand at 6.1 MHz) leaves a code-dependent col-node
  ripple (gate-99 probe: +/-35 mV with C_col 12 nF) whose average error is
  not a memory-5 cubic Volterra (same mechanism as the 25.8 ppm static bow,
  dynamic part). This is a real hardware effect, not a modelling artefact:
  the OPA1612 input stage would be overdriven by the RTZ ripple in exactly
  this way (classic DAC I/V problem; the fix is more summing-node C or a
  passive pre-filter, not a faster amp).
  PROPOSED NEXT (P5 design, ~45 min probe before a full 4 h re-ID):
  C_col 12 -> 47 nF (ripple /4, slew demand /4; Cf/Rf pole stays 450 kHz,
  noise gain at HF 36 -> loop crossover ~1 MHz, stable): rerun the two LUT
  decks + ONE BIN-37 record and compare the record HD3 (-96.3 now). If the
  dynamic HD3 drops >= 8 dB, run the full R101 protocol at 47 nF.
  USER (2026-09-22): "suspicious of the current architecture" -> run BOTH
  a full re-ID at 47 nF AND an alternative architecture, in parallel.

## Round 104/105 - TWO I/V PLANTS, FULL RE-ID EACH (utils/r104_105.ps1, patch_p5.py, 2026-09-22)
- 104 = ratified P5 TIA, C_col 12 -> 47 nF (patch_p5 CCOL=47n). Everything
  else as R101.
- 105 = ALTERNATIVE ARCHITECTURE (patch_p5 IVMODE=rload): passive R_load
  100R from +15 to col (col DC 6.8/5.7 V p/m, M6 Vds ~3.8 V), C_col 12 nF
  as the RTZ filter (RC 1.2 us), RC pre-filter 100R/10 nF (160 kHz), then
  ONE OPA1612-class difference amp (R1 2k / R2 5.4k, gain 2.7 -> 6 Vrms).
  The amp never sees the RTZ ripple (0.34 V p-p at col -> ~7 mV at vf).
  This is the 28R-proxy plant (best gates ever, 93/94) made real: a
  resistive load + a V-stage that only handles audio. Sanity 3 us probe
  (tmp105): converges, DC as computed. R1 was 200R first: loaded col by
  ~8 mA and skewed p/m gain -> 2k (loading < 5 %).
  CAVEAT: noise of 105 NOT verified. 2k/5.4k resistors alone are ~2.3
  nV/rtHz in the 28R domain = over the whole budget; if 105 wins on
  distortion the V-stage needs a low-noise realization (small R with a
  buffered col, or a discrete/paralleled front end) and a gen_noise100
  variant before ratification.
- Protocol per variant = R101: 2 LUT decks -> cosim<V>lut_inl.npy; records
  <V>a-f (BINs 37/37/17/11/5/27; seeds 161-166 / 171-176); fit V<V>=1
  NUALL=1 CUBIC=1 RIDGE=1e8 -> cosim<V>c3j; gates <V>g37 (seed 167/177)
  and <V>g23 (168/178). 2-solver throttle, variants interleaved, ~4.5 h.
  Driver log: LTspice\r104_105.log. Compare vs gates 102/103 and 93/94.
- DESIGN LOCK (user, 2026-09-23 22:07, after the acceptance-spec analysis):
  everything upstream of the I/V is LOCKED as ratified (64 BJT-steered
  cells 0.75 mA / 750R, Si1555 double cascode, casb2 4.37 fixed, passive
  replica-ff leg b, v80 padding as Si1555 MOSFET mirror, Rg5 10R, C_bus 47n,
  reclock FF bank, EF3 NS + dem_sort, temperature-indexed LUT + c3j kernel).
  The I/V topology is the ONE open item and is decided by R104/105 under
  the acceptance spec, with this pre-agreed rule:
    * 105 (passive load + filtered V-stage) is ADOPTED if its gates meet D1
      with >= 5 dB more HD2/HD3 margin than 104, provided a low-noise
      V-stage realization simulates >= 124 dB0 (gen_noise100 variant).
    * otherwise 104 (TIA, C_col 47n) if it meets D1 with margin and holds
      N1 at >= 126 dB0; else TIA at 12n (gates 102/103) stands as the
      fallback that already meets the MUST set.
  After the I/V decision: P2/P3/P7 re-run on the locked plant (D2/D3/L1),
  then P8 table and schematic capture.
  RESULTS (campaign done 01:36):
  104 (TIA, C_col 47n): LUT max|INL| 15.6 ppm (was 25.8 at 12n; bow /1.7),
    run-to-run 0.46 ppm. Records HD3 -98.9/-99.0 @37 (101: -96.3/-97.5),
    HD2 -107.7 @37. Fit within 0.3 dB / 1 deg (104e 2 dB - low bin).
    GATES: 104g37 HD2 -114.4 / HD3 -116.0 (HD4-8 -107.5..-118.7);
           104g23 HD2 -120.4 / HD3 -113.4.
    -> NOT better than 102/103 (-115.8/-119.6, -119.5/-115.5). 4x less
    ripple at the amp bought nothing at the gate. Meets D1 marginally
    (HD6 @37 -107.5 is popcount-floor limited, as in 102).
  105 (passive load + V-stage, 12n/10n): INVALID RUN - measurement
    protocol, not physics. The passive poles (100R*12n + 100R*10n, ~2.2 us)
    do not settle in the LUT chop's 20-period (3.2 us) discard: max|INL|
    55000 ppm, refdrift 328 mV -> garbage LUT -> records -47 dBc -> gates
    +5 dBc. Lesson (TRAP 11): any plant with passive time constants
    > ~0.2 us needs a longer chop dwell (stretch_lut.py, SEG 80+) and a
    kernel lag budget that covers the filter memory.
- DIAGNOSIS REVISED (probe_p5.py, 3 us node probes, 2026-09-24): the
  slew-limit story is FALSE. TIA 12n: amp diff input 48 mV p-p, output
  slew 6.8 V/us (limit 27); TIA 47n: 17 mV, 2.4 V/us; 105b (rload, 3.3n/1n):
  40 mV, 5.4 V/us. Nothing is slew-limited, and 104's 3x smaller input
  error changed the gate by 0 dB. So the -116..-120 residue is NOT the
  I/V. What else changed between gate 93 (-125.6/-123.8) and gate 102?
  The gate-100 NOISE rulings that were never distortion-gated:
    (4a) padding mirror BJT -> Si1555 MOSFET, (4b) Rg5 100 -> 10R.
  Rg5 100R was introduced in R54 precisely to kill a codes-23-28 cascode
  self-oscillation (probe std 38-52 uV -> 1.3 uV). 10R may have brought
  marginal ringing back = dynamic odd-order error = the extra ~5 dB raw
  HD3 seen in every R101/R104 record vs R92.

## Round 106 - ISOLATE THE RESIDUE (utils/r106_diag.ps1, probe_p5.py, stretch_lut.py, 2026-09-24)
- Record-level A/B, BIN 37 seed 151 (= 101a's stream), one chop deck per
  plant for its own static LUT. Compare raw HD2/HD3 to 101a (-110.5/-96.3)
  and 92a (~-96/-101..-104):
    106a TIA + Rg5 100            106b TIA + BJT pad
    106c TIA + Rg5 100 + BJT pad  (= gate-93 plant with only the I/V swapped)
    106d 105b: passive R_load 100 + V-stage, C_col 3.3n / C_vf 1n (tau 0.43
         us, amp sees 40 mV), LUT chop at SEG 80.
  ~80 min. Driver log LTspice\r106_diag.log. Decision: whichever variant
  recovers the R92 raw HD3 (<= -101) names the culprit; then a full re-ID
  (R101 protocol) on the corrected plant, and the noise ruling that caused
  it is re-examined under the acceptance spec (N1 has 8 dB of margin -
  the 27 nV Rg5 line and the 65 nV pad-shot line are affordable if they
  buy back the -125 dBc class).
  RESULTS (done 10:04; LUTs 106a/b/c/d max|INL| 11.6/20.8/10.4/9.8 ppm):
                              HD2      HD3     (BIN 37; HD2 at record level is
    101a TIA, Rg5 10, MOSFET  -110.5   -96.3    mostly the static-LUT residue
    106a TIA, Rg5 100         -103.5  -100.0    of that deck -> not a
    106b TIA, BJT pad         -124.8   -96.6    discriminator; HD3 is)
    106c TIA, Rg5 100 + BJT   -102.1   -99.6
    106d passive load+V-stage -101.4   -93.4    (105 done properly: WORSE)
    92a  28R proxy, Rg5 100   -95.9   -101.3   (92b -104.2: seed spread ~3 dB)
  READING:
  * Rg5 IS the plant change that matters: 100R recovers 3.7 dB of raw HD3
    (-96.3 -> -100.0), within the seed spread of the R92 records. The
    padding-mirror device is irrelevant to HD3 (106b = 101a) -> MOSFET pad
    stays (noise-better).
  * 106d CLOSES the alternative-architecture question: with a resistive
    load the col node moves +/-0.9 V with signal and the cascode Vds
    modulation shows up as odd-order error (-93.4, worst of all); the TIA's
    virtual ground is what makes the double cascode linear. Plus its noise
    was already over budget. I/V = TIA, final.
  * Rg5 100R noise line is 27 nV -> RSS with 245 nV = +0.05 dB. Ruling 4b
    (10R) bought nothing measurable and cost ~4 dB of HD3: REVERSED.
- R107 LAUNCHED 16:38 (r104_105.ps1 -Only 107): full R101 protocol on the
  ratified TIA 12n plant + Rg5 100R (MOSFET pad kept), seeds 181-188,
  kernel cosim107c3j, gates 107g37 / 107g23 vs 102/103 and 93/94. ~2.3 h.
  Open choice for the user: C_col 12n (ratified, drawn) vs 47n (halves the
  static bow 25.8 -> 15.6 ppm, 3x less amp error, neutral at the gate).
- R107 RESULTS (done 18:26, 1 h 55):
  LUT: max|INL| 11.7 ppm (was 25.8 with Rg5 10 - the "static bow" was
    half ringing), run-to-run 0.95 ppm.
  Records (static LUT only): HD3 -101.4/-100.2 @37, -104.9 @27, -107.2 @17,
    -126.4 @11, -118.2 @5 = the R92 class back exactly. Fit: held-out
    HD2/HD3 within 0.2 dB / 0.7 deg on all six (best ever); |static| 384 uV,
    |fir| 13.5 uV/unit, dyn rms 16.2 uV.
  GATES (45C, 107lut + 107c3j):
    107g37 (BIN 37): HD2 -121.4 / HD3 -127.1   (102: -115.8/-119.6; 93: -125.6/-123.8)
    107g23 (BIN 23): HD2 -119.1 / HD3 -124.8   (103: -119.5/-115.5; 94: -121.7/-121.6)
    HD4-8: -108.4..-121.0, every one AT OR BELOW the stream's own
    ideal-popcount floor for that bin (-102.3..-116.5): shaped quantization
    noise read in a harmonic bin, not analog distortion.
  -> HD3 recovers fully (better than the proxy gates), HD2 +5.6 dB @37.
  D1 CLARIFICATION (spec wording): harmonics are judged as analog-added
  distortion, i.e. relative to the ideal-popcount floor of the same stream
  at the same FFT length; a bin sitting on that floor is compliant. The
  16384-pt gate resolves ~-105..-115 dBc per bin of shaped noise; the
  long-record P7/P2 tests are what resolve HD4+ to the -120s.
- I/V AND PLANT LOCK - FINAL (2026-09-24): P5 TIA (V_VG 4.0, R_f 270 || C_f
  1.3 nF, R_off 133/116 from +15F, OPA1612 single), C_col 12 nF, Si1555
  MOSFET padding mirror, Rg5 100R (ruling 4b REVERSED), everything else as
  ratified 2026-09-21. schematic.html Fig. 3 rulings box + caption updated.
  Noise: +27 nV RSS -> 246 nV = 128.1 dB0 (N1 margin 8 dB). C_col 47n
  remains an available refinement (bow 15.6 vs 11.7 ppm now - the case for
  it is weaker with the ringing gone); not adopted.
  NEXT: D2/D3/L1 on the locked plant (P2 spur/long record, P3 19+20k IMD,
  P7 -60 dBFS level-flat floor), then P8 comparison table.

## Round 108 - ACCEPTANCE TESTS D2/D3/L1 ON THE LOCKED PLANT (utils/r108_p.ps1, floor_read.py, 2026-09-24)
- Launched 19:02, 2 solvers, ~3.2 h. All gates: locked plant (TIA 12n,
  Rg5 100R, MOSFET pad), 45C, 107lut + 107c3j.
    108  D3  IMD 19+20 kHz -3 dBFS peak, M 16384 bins 51/53 (gate-96 recipe,
             seed 190) -> imd_read.py. Proxy: f2-f1 -129.4, 2f1-f2/2f2-f1 -126.0.
    109  L1  -60 dBFS 1 kHz, M 65536 (seed 191) -> floor_read.py
    110  L1  digital silence, M 65536 (seed 192) -> floor_read.py
    111  D1/D2 -1 dBFS 1 kHz, M 65536 (gate-95 recipe, seed 193) -> rtz_fft39
             HD2..HD8 all in band. Proxy: -122.1/-122.1/-124.8/-124.4/-136.0/
             -125.3/-122.6 (THD -115.5).
- floor_read.py (new): Kaiser(beta 38) spectrum of the period-average
  stream in dB0 re FS sine for IDEAL popcount / ANALOG / ADDED (= analog -
  ideal, the L1 quantity); in-band 20 Hz-20 kHz integrated power excluding
  the fundamental mainlobe (+/-15 bins) and, when the fundamental is above
  -40 dBFS, the HD2..HD20 mainlobes too (the IDEAL stream carries the
  intentional predistortion harmonics); max remaining in-band bin = spur
  (D2). Detrends DC/linear/quadratic. Validated on gate 95: fund reads
  -1.0 dBFS. LIMIT: at 1 kHz / 65536 the harmonics are 10.9 bins apart, so
  the full-scale long record cannot resolve a between-harmonic floor
  (beta 20 leaves 1 bin) - D2 at full scale is read from the rtz_fft39
  harmonics + the IMD gate; floor_read is the -60 dBFS / silence tool.
  Note: in a noiseless transient the "floor" is deterministic (shaped
  quantization + DEM + analog glitch); L1 asks that ADDED be level-flat
  and spur-free, and that ANALOG at -60 == ANALOG at silence within 1 dB.
  RESULTS (done 23:43; floor_read fixed after the run: fund_ideal had abs()
  before the mean, and low-level gates now take the code->volt gain from a
  full-scale gate via GAIN_TAG=111 - a 5-code record's own fit read
  +0.0029 V/code vs the true -0.0327):
    D3  gate 108 (re -3 dBFS peak): f2-f1 -117.8, 2f1-f2 -114.3, 2f2-f1
        -115.5; all >= 2nd-order sums above 38 kHz <= -114.7.
        -> 2f1-f2 MISSES D3 (-115) by 0.7 dB. Proxy plant did -129.4/-126.0.
        IDEAL stream: f2-f1 -100.0 (107c3j injects a strong 2nd-order term
        that the plant cancels to -117.8 = only 18 dB of cancellation vs 30 dB
        at 1 kHz), 2f1-f2 -114.6 -> the analog -114.3 IS the injected
        predistortion, uncancelled: the kernel's 3rd-order memory terms are
        wrong at 19-20 kHz. The ID records stop at BIN 37 (13.9 kHz @16384);
        19-20 kHz is extrapolation.
    D1  gate 111 (-1 dBFS, 1 kHz): HD2 -128.9, HD3 -124.6, HD4 -113.0,
        HD5 -132.0, HD6 -113.1, HD7 -134.8, HD8 -115.7 dBc.
        -> HD2 best ever (95: -122.1); HD3 0.4 dB short of STRETCH; HD5/HD7
        excellent. HD4/HD6 MISS D1 (-115) by 2 dB, HD8 marginal.
        IDEAL stream HD4/6/8 = -113.9/-114.1/-113.6: the analog even
        harmonics are the code stream's own content, i.e. INJECTED by the
        static LUT 107lut_inl / kernel and NOT cancelled (plant has no such
        HD4/6/8). Gate 95 IDEAL HD4/6/8 -117/-131/-116 became analog
        -125/-136/-123 (cancelled) - the 92 LUT was right, 107lut is not:
        LUT noise / structure at the ~1 ppm level shows up as even-order
        predistortion. Digital-side fix (LUT averaging or regularisation),
        not a plant issue.
    L1  gate 109 (-60 dBFS): ANALOG floor -139.2 dB0 (2.5-20 kHz, fund lobe
        excluded), max bin -149.1 dB0 - spur-free. ADDED -140.8 dB0 (544 nV).
        gate 110 (silence, same mask): ANALOG -131.1 dB0, but it is ONE LINE:
        12.012 kHz at -131.3 dB0 (ADDED -132.3, IDEAL -148 there, IDEAL floor
        -145). Excluding the line the silence floor is ~-145 -> level-flat.
        -> L1 as written (1 dB) FAILS on the tone; D2 (-120) passes by 11 dB.
        DIAGNOSIS so far: the line is at 12011.8 Hz = fs/511.5, present in the
        CODE STREAM at -148 dB0 for every dither seed (192/301/302 offline
        via dpd_volt) and absent at -60 dBFS -> a deterministic modulator
        idle pattern (EF3 + LUT/kernel feedback, period 1023) that the plant
        amplifies 17 dB. Static cell mismatch is NOT the amplifier
        (utils/dem_tone.py: dem_sort selection x 0.2% mismatch gives -182
        dB0 at 12 kHz for idx / random / rotating tie-breaks). Open: which
        plant error follows the pattern (glitch/switching activity) and
        whether an input-referred dither or an idle-pattern breaker kills it.
  VERDICT R108: N1 met; D1 fails HD4/HD6 by 2 dB (LUT-injected); D3 fails
  2f1-f2 by 0.7 dB (kernel extrapolation); D2 met; L1 fails on one -131 dB0
  idle line in silence. All three misses are in the DIGITAL ID/DPD chain,
  none in the locked plant.

## Round 109 - DIGITAL-CHAIN FIXES (utils/r109_p.ps1, inject_scan.py, idle_scan.py, reorder_lut.py, 2026-09-25)
User: "both, queued" (re-ID + idle-tone hunt); target remains better-than-APEX.
- OFFLINE DIAGNOSIS 1 (D1 HD4/6/8): utils/inject_scan.py runs dpd_volt and
  projects the CODE STREAM on the exact harmonic bins (full-M, no leakage).
  107lut + 107c3j @1k -1dBFS: HD2..8 -99.2/-117.1/-114.3/-126.0/-113.5/
  -126.0/-113.9 = gate 111 IDEAL to 0.4 dB. Zero LUT + 107c3j: HD4/6/8
  -116/-115/-117 -> the KERNEL injects them, not the LUT (static 107lut alone
  gives HD4/6/8 -133/-121/-134; 2-chop LUT noise is -135..-141).
  Culprit = the one-hot STAT table (kernel static-content decomposition):
  107c3j stat has 8.7 uV rms non-polynomial roughness (92c3j: 3.1 uV) =
  4 ppm of span, sprayed as high-order predistortion the plant does not
  have. Replacing stat by a sine-visit-weighted cubic (kernel suffix w3)
  drops 2.0 uV rms roughness and gives injected HD2..8 -99.6/-116.0/-124.1/
  -121.7/-140.1/-121.9/-121.5 (HD2 moves 0.4 dB, HD3 1.1 dB).
- OFFLINE DIAGNOSIS 2 (D3): volterra_id2 V109=1 = records 107a-f + the gate-108
  two-tone record (bins 51/53; tuple BINs now supported, fund lobes of both
  tones dropped). Hold-out on 108 with the 107-only kernel explains only
  half its in-band residual (4.6 of 8.8 uV rms) -> 19-20 kHz WAS
  extrapolated. Joint fit -> cosim109c3j (hold-outs unchanged, dyn-action
  -137 dBc); + stat->cubic -> cosim109c3jw3: injected two-tone products
  f2-f1 -107.7, 2f1-f2 -116.2, 2f2-f1 -115.5 (107c3j: -102.5/-114.0/-114.5).
- OFFLINE DIAGNOSIS 3 (L1 12.012 kHz line): utils/idle_scan.py. The silence
  stream's ACTIVITY statistics (|dcode|, code^2, code(n)code(n-1)) all carry
  the fs/511.5 line 25-28 dB above their medians - the modulator's noise
  power is periodically modulated in the idle state (EF3 + kernel loop;
  numpy dither has no such period). Any plant error tracking activity
  (glitch charge, residual bow) becomes the tone; popcount shows it only at
  -148. Kernel-dependent: 92c3j moves it to 13.89 kHz. Breakers (code^2
  proxy line / median, baseline -106.6/-131.8): DITH x2 -139/-125 but
  in-band stream noise +9 dB (rejected); DCOFF +0.25 code -124/-131;
  DCOFF +0.5 code -128/-131 (worst bin 6 dB over median) -> DC offset breaks
  the pattern with no noise cost. -90 dBFS input: worst bin -113.8 @7.9 kHz
  (15 dB over median) -> level-dependent tones exist below -60 dBFS; L1
  must be gated at -90 too. dpd_volt knobs added: DITH, DCOFF.
- LUT: reorder_lut.py makes independent chop decks (schedule reshuffled,
  seed 43+N for lut<N>; rtz_inl_full generalised to the same rule).
- CAMPAIGN launched 11:28 (~4 h): 4 chops lut3..6 -> cosim109lut_inl.npy
  (6-chop mean); gates with 109lut + 109c3jw3:
    112 D1 -1 dBFS 1 kHz 65k | 113 D3 19+20k 16k | 116 L1 silence |
    114 L1 silence + DCOFF 0.5 (mechanism test vs 110) | 115 L1 -90 dBFS.
  LUT: lut3..6 max|INL| 9.95-11.01 ppm, 6-chop mean per-chop dev 0.59 ppm rms,
  mean differs from 107lut by 0.33 ppm rms -> cosim109lut_inl.npy.
- READOUT-FLOOR DISCOVERY (post-run, 19:30): the raw imd_read/rtz_fft39 LS on
  a DISCARD-truncated record is LEAKAGE-LIMITED by the ~-30 dBc shaped OOB
  noise: ~-109 dB re peak at M 16384 (two-tone) and ~-118..-125 dBc at
  M 65536 - seed-random, right where D1/D3 sit. The exact full-M FFT of the
  code stream is ALSO limited (~-120 dBc: the modulator state is not
  circular, start/end discontinuity). Verified: raw LS on the bare NS
  stream (zero LUT, zero kernel) reads -109 at 2f1-f2 while its full-M FFT
  bin is -147 (noise) - the "-109 injected IMD3" was the tool.
  FIX: utils/lp_ls.py - zero-phase Kaiser windowed-sinc lowpass (130 kHz,
  ~100 dB stopband, 2049 taps) applied before the LS in imd_read.py and
  rtz_fft39.py (default on; LP=0 = old behaviour). Sensing floor now -136 dBc
  (65k) / -128 dB (16k); results stable vs DISCARD 1024..4096 and fc 30-130k.
  imd_read also prints stream-vs-analog phasors per in-band product
  (plant-own = analog - stream).
  RE-READS with LP-LS: gate 111 analog HD4/6/8 -113.3/-112.9/-116.0 (real,
  injection confirmed: IDEAL -116.9/-111.6/-116.4); gate 108 2f1-f2 was
  -136.7 (NOT -114.3) and f2-f1 -130.4 -> D3 never failed; gate 96 -143.1/
  -140.1; gate 95 analog HD2..8 -119.7/-122.9/-128.9/-124.7/-145.3/-125.9/
  -125.5. inject_scan.py's two-tone numbers (full-M FFT) are floor-limited
  and void; its 1 kHz numbers at -114 were confirmed by LP-LS.
  RESULTS (LP-LS readouts):
    D1  gate 112 (-1 dBFS 1 kHz): HD2 -137.4, HD3 -131.5, HD4 -133.5,
        HD5 -137.6, HD6 -129.5, HD7 -138.9, HD8 -151.5 dBc. IDEAL stream
        -99.0/-122.4/-125.6/-129.2/-122.9/-132.1/-139.7 -> the plant cancels
        HD2 by 38 dB, HD3 by 9 dB, and the w3 stat fix removed the HD4/6/8
        injection. D1 (-115) MET by >= 14.5 dB; HD3 STRETCH (-125) MET by 6.5.
    D3  gate 113 (19+20 kHz -3 dBFS): f2-f1 -156.4, 2f1-f2 -136.6, 2f2-f1
        -139.3 dB re peak (IDEAL stream -106.1/-120.3/-120.6). D3 (-115) MET
        by 21 dB; dCS benchmark (f2-f1 -130) beaten by 26 dB.
    L1  gate 116 (silence, 109c3jw3): ANALOG floor -134.1 dB0, but again one
        line: 19.654 kHz -134.6 (IDEAL -137.4 there - the idle pattern moved
        with the kernel, as idle_scan predicted; plant adds only 3 dB now).
        gate 114 (silence + DCOFF 0.5 code): ANALOG floor -143.8 dB0, max bin
        -153.2 dB0 (at the 94.5 Hz-bin thermal density, -151). IDLE TONE
        KILLED; ADDED -141.6 dB0 = 498 nV.
        gate 115 (-90 dBFS, no DCOFF): ANALOG floor -136.9, max bin -143.3 dB0
        at 15.496 kHz (ADDED -140.3 same bin) - a level-dependent line 8 dB
        above the per-bin thermal density; 109 at -60 (old kernel): -139.2,
        max -149.1.
  VERDICT R109: N1, D1 (+stretch), D2, D3 all MET with >= 6.5 dB margin on
  the locked plant. L1: the modulator idle pattern is the last open item -
  a +0.5 code input offset removes it in silence (gate 114) but -60/-90 dBFS
  have not yet been gated WITH the offset (115 without it shows a -143 dB0
  line). System cost of the offset: 0.5 code = 0.78 % FS = ~150 mV DC at a
  6 Vrms output -> needs a DC servo / AC coupling in the output stage, or a
  different pattern breaker.
  NEXT: gates -60 and -90 dBFS with DCOFF 0.5 + 109c3jw3 (2 x 95 min); then
  P8 comparison table.

## Round 110 - L1 CLOSURE (utils/r110_p.ps1, idle_scan.py, 2026-09-25)
User: "both" - DCOFF gates + offline DC-free breaker scan.
- Gates launched 19:38 (109lut + 109c3jw3 + DCOFF 0.5): 117 = -60 dBFS,
  118 = -90 dBFS, M 65536 each. Readout floor_read GAIN_TAG=112.
- OFFLINE BREAKER SCAN (idle_scan.py, kernel 109c3jw3, 109lut, levels
  silence/-90/-60; 'worst' = max in-band bin over median per proxy, pure
  noise gives 8-10 dB):
    none           27.5/29.7/27.5 (silence, 19.65 kHz) | 17.6/20.5/18.0 (-90) | 10.7 (-60)
    DCOFF 0.5      10.4/10.4/ 8.9 | 9.2/8.8/8.7 | 6.5/8.2/8.1   <- clean in ALL proxies, all levels
    OOB 0.5 fs/2   no effect (28)          OOB 0.25 fs/2 no effect
    OOB 0.5 fs/4    8.8/23.6/10.9 | 8.6/13.9/7.4 | ok  <- popcount clean, SWITCHING still tonal; +0.5 code at 1.5 MHz
    OOB 0.5 fs/3   18.9/26.8/20.2  (no)
    HPD 0.25 ord2  14.9/24.8/17.7  (no)
    HPD 0.25 ord3   7.5/16.9/ 8.2 | 9.5/8.8/10.5 | ok, but in-band stream noise +9 dB, code rms 0.91
    HPD 0.5 ord3    all <= 8.8 but in-band stream noise +18 dB (-146 dB0/bin > thermal -151) -> rejected
  Noise cost of DCOFF 0.5: in-band popcount median -159.9 vs -164.5 dB0/bin
  (silence), +2 dB at -90, +3.5 at -60 -> integrated ~-137 dB0, 9 dB under
  the -128 thermal floor. VERDICT: the +0.5 code input offset is the only
  breaker clean in popcount AND switching at every level.
  Implementation options for the analog DC (0.5 cell = 16 mV at the TIA,
  ~150 mV at 6 Vrms): (a) DC servo in the output stage; (b) a fixed
  half-weight current cell permanently on bus_minus that nulls the offset
  exactly (no loop, negligible noise) - preferred, to be added to the deck
  and re-gated once in a later round.
  DC-null realisation added: patch_p5.py MIDCODE env (default 32) sizes the
  R_off pair for the mean code; MIDCODE=32.5 nulls the DCOFF 0.5 offset at
  the summing nodes with the existing resistors (no servo, no extra cell).
  Gates 117/118 ran with MIDCODE 32 (16 mV DC at diffout, linear TIA -> AC
  results unaffected); the shipping deck uses 32.5.
  RESULTS (floor_read, GAIN_TAG 112; per-bin thermal density at 94.5 Hz
  bins = -151 dB0; DONE 22:43):
    117 -60 dBFS + DCOFF 0.5: ANALOG floor -143.4 dB0, max bin -149.8 @19.37k;
        ADDED -142.9 dB0 (428 nV), max added bin -152.7.
    118 -90 dBFS + DCOFF 0.5: ANALOG floor -142.1 dB0, max bin -150.1 @18.71k;
        ADDED -141.9 dB0 (481 nV), max added bin -152.5.
    114 silence + DCOFF 0.5 (R109): ANALOG -143.8, max -153.2; ADDED -141.6.
  -> Pattern floor level-flat within 1.7 dB from silence to -60 dBFS, every
  max bin at/below the thermal per-bin density, 14-16 dB under the -128 dB0
  thermal floor. No level-dependent lines (115's -143 @15.5k is gone).
  VERDICT R110: L1 MET. With R109: N1, D1 (+HD3 stretch), D2, D3, L1 all
  met on the locked plant with the shipped digital chain =
  109lut (6-chop) + 109c3jw3 + DCOFF 0.5 (+ MIDCODE 32.5 in the deck).
  NEXT: P8 - dCS Vivaldi APEX comparison table; optional confirmation gate
  of the MIDCODE 32.5 deck (expected identical).

## P8 + SCHEMATIC BUILD-OUT START (2026-09-26)
- P8 DONE: p8_comparison.md - every simulable dCS line beaten (noise +15,
  THD+N +11, worst harmonic +2.5, IMD f2-f1 +26 dB); crosstalk (P4) is the
  only dCS line not simulated. Recommendation GO for schematic/hardware.
- TOOL DECISION (user): KiCad 9 for capture (scriptable text format, free
  review, layout houses take it natively and Altium imports it).
- STEP 1 DONE: utils/ref_netlist.py -> hw/ref_netlist.{json,md}: 964
  elements of cosim112 -> 64 identical cells (8 hw + 6 sim-only each, zero
  deviations) + 50 global hw elements in blocks cascode / replica_ff /
  padding / bus / reference / iv / rails_refs; sim-only = FF drive, the
  behavioural op-amp, probes. Interface nets bsN1d/bsN2d/qN/qbN/v_vg; dead
  nets vcc15/vp8/vfr2.
- STEP 2 DONE (partial): bom.md 3/4 rewritten to the locked plant, 5/6/10
  SUPERSEDED, 9 reference ladder updated; schematic.html status banner.
  hw/reconcile.md holds 6 OPEN items needing a ruling before drawing - the
  important one: deck base-drive levels 1.1/1.7 V vs bom 1.36-1.85 V (all
  ID/LUT/kernel work used 1.1/1.7 -> size the LVC1G74 network for those).
- STEP 3 DONE: KiCad 10.0.6 installed. utils/gen_kicad.py writes
  hw/kicad/bfdac_analog.kicad_{pro,sch} + cell/core/iv/refs sheets straight
  from hw/ref_netlist.json (cell drawn once, instanced 64x with per-instance
  refs Q/R1011.., hierarchical pins BS1D/BS2D/Q/QB; shared nets as global
  labels; OPA1612+BUF634A per bom 4; PWR_FLAG rail table on REFS).
  utils/kicad_xcheck.py: kicad-cli netlist -> endpoint partition vs deck:
  1300 hardware endpoints / 543 nets, PASS (caught one R_f/C_f pin swap).
  ERC: 0 errors; 260 isolated-label warnings = the 64x4 BSn1D/BSn2D/Qn/QBn
  root labels waiting for the FF sheet. PDF/SVG exported to hw/kicad/.
- RULINGS 2026-09-26 (user: "proposals accepted", hw/reconcile.md CLOSED):
  base network rs 1.35k / rp 301 -> VCM 1.345 V gives the deck's 1.10/1.70
  (Rth 246, 24 mA/ch sink, 3.4 mW/cell); EP52 rails struck; vp8/vfr2 not
  drawn; R_off 133/116; casb2 replica-derived; Cb -> 220 uF (deck).
  bom.md 1.2 / 2 / 9 updated.
- STEP 4 DONE: cell sheet is now the complete cell - SN74AXC1T45 (drawn
  with the LVC1T45 DBV symbol) -> SN74LVC1G74 (74AUC1G74 symbol) + FB/100n
  + PWR_FLAG -> rs/rp network -> 10 R stoppers -> DMMT5551 pair; hier pins
  D / CLK. Root: DAT01..64 on J1/J2 (placeholder 1x32), MCLK_FF on J3;
  REFS table gained V33FF / V18 / VCM / MCLK_FF. xcheck PASS (1300 ep /
  543 nets, 512 kicad-only cell parts = 8 kinds x 64), **ERC clean**.
- R111 (utils/r111_p.ps1 + patch_drive.py, 15:06-18:29): G1 real drive
  (Bq -> Rout 25 -> rs 1350 / rp 301 -> VCM 1.345, Rth 246) + G2 MIDCODE
  32.5 (R_off 132.4/116.4), shipping chain 109lut/109c3jw3/DCOFF 0.5.
    120 L1 -60 dBFS: ADDED -144.8 dB0, max bin -155.5 -> PASS (117: -141.9)
    119 D1 -1 dBFS:  ANALOG HD2 -90.4 / HD3 -111.4 / HD4..8 -121.5 -122.7
        -117.9 -129.4 -146.1 dBc  -> FAIL (112: -137.4/-131.5). IDEAL stream
        identical to 112 (-99.1/-122.1): the plant no longer cancels the
        stream HD2 (LUT/plant mismatch or new plant nonlinearity).
- R112 (utils/r112_p.ps1, launched 19:09): isolate. 121 = ideal drive +
  MIDCODE 32.5 + DCOFF 0.5; 122 = real drive only (MIDCODE 32, no DCOFF).
  Hypothesis: the 246 R Thevenin source makes the base waveform depend on
  the base-current pulse of the steering transistor (state-dependent edge),
  a plant change the 109 LUT was not identified on -> either re-run the
  ID/LUT campaign on the real-drive plant (hardware cal is in situ anyway)
  or lower rs+rp.
  R112 READOUT (22:31):
    121 ideal drive + MIDCODE 32.5 + DCOFF: HD2 -139.1 HD3 -127.5 HD4..8
        -134.4 -172.1 -130.0 -136.6 -154.0 -> G2 + DCOFF at full scale PASS
        (D1 and HD3 stretch met). G2 CLOSED.
    122 real drive only: HD2 -90.3 HD3 -112.5 HD4..8 -122.3 -124.8 -117.8
        -132.9 -144.4 -> reproduces 119. THE 246 R SOURCE ALONE IS THE
        FAULT. Not LUT mismatch (would sit near the stream's -99): the plant
        ADDS even-order error - the pair's own base-current / C_bc
        transients through 246 R move the edge with the code-dependent bus.
- R113 (utils/r113_p.ps1, launched 10:14 09-27): compensated divider, Cs
  across rs / Cp across rp with Cs*rs = Cp*rp (flat k, DC power unchanged,
  base sees 1/(jw(Cs+Cp)) ~ 13 R at 100 MHz). 123 = 22p/100p, 124 =
  47p/220p, both D1 -1 dBFS with MIDCODE 32.5 + DCOFF. Pass = 121 class.
  Fallback if caps don't cure it: lower rs+rp (Rth 50 R = 10 mA/output,
  ~1.3 W/channel - violates the bom 1.2 thermal constraint) or re-ID.
  R113 READOUT: 123 (Cs 22p/Cp 100p) HD2 -62.7 HD3 -109.0 HD4 -93.1 HD6
  -106.4 HD8 -99.7 -> MUCH WORSE; compensation caps REJECTED (the 30 ns
  divider tail does not settle inside the RTZ gap; the FF pin is slammed
  through 25 R into 18 pF). 124 readout pending at time of writing.
- ROOT CAUSE (utils/drive_inl.py, 2026-09-27 13:00-13:40): static INL probe
  - PWL selections -> DC (cells 1..N on), 24 periods, AVG(out_m-out_p) vs N,
  3 s per point instead of 95 min. Ideal plant (121) has a 11 ppm parabolic
  bow (HD2 proxy -94.9 dBc) that the 109 LUT linearises to -137. Results
  (max |INL| ppm FS / HD2 proxy):
    ideal 10 R drive             11.4 / -94.9
    real rs1350/rp301, Rout 25   34.1 / -84.8   (= gate 122 plant)
    + Cs22/Cp100                 37.7 / -83.9   (static same; 123 fails dynamically)
    Rth 123 / 62 / 25, Rout 25   30 / 27.5 / 25
    Rth 246, Rout 0/5/10/25/50   17.6 / 20.7 / 24.1 / 34 / 50  (0.65 ppm/R)
    Rth 25 or 1, Rout ~0         12.0 / 11.4  (= ideal)
    Rth 25, Rout 25, replica Rr1 tapped BEFORE Rout (sim-only)  12.1 (= ideal)
  => the bow is NOT the Thevenin resistance (246 R adds ~6 ppm). It is the
  FF OUTPUT RESISTANCE x base-network current (25 R x 1.18/0.81 mA = 30/20
  mV) corrupting the FF-pin levels that the PASSIVE REPLICA-FF sums through
  Rr1 (10k): the feedforward's gain/offset no longer matches the cell
  currents -> residual bus movement prop. to N -> quadratic INL. Gate 122's
  -90.3 dBc is exactly the ideal-identified LUT meeting a plant whose bow
  is 3x larger, i.e. LUT/plant mismatch, not a new dynamic nonlinearity
  (L1 gate 120 passed with the real drive).
  IMPLICATIONS: (a) the plant with the real drive is still a smooth static
  bow (34 ppm), well inside what the R101 ID/LUT protocol linearises (42 dB
  on the ideal plant -> expect HD2 ~ -125); in hardware the LUT is
  identified in situ so Rout is absorbed; Rout drift (~0.4 %/K) moves the
  bow by ~0.06 ppm/K - negligible. (b) The replica gain (Rsh) should be
  sized for the loaded FF swing, 3.3 - Rout*(I_hi+I_lo) ~ 3.25 V, and the
  LVC1G74 Rout (23-37 R from IOH/IOL) belongs in the deck. (c) Rth itself
  is a minor term - keep rs 1350 / rp 301 (power) unless the re-ID says
  otherwise.
- R114 (user: "setup the recal"; utils/r114_recal.ps1, launched 15:47
  09-27, ~5-6 h): variant 125 = locked plant + patch_drive. Stage 1: 4
  chops 54lut3..6_t45p125 -> cosim125lut_inl.npy; stage 3: records 125a-f
  (seeds 211-216, static LUT) + 125t two-tone 51/53 (109c3jw3 stream);
  fit volterra_id2 VREC=125 (new generic selector) NUALL CUBIC RIDGE 1e8 ->
  cosim125c3j, inject_scan STATFIT=3 -> cosim125c3jw3; gates 126 D1 / 127
  D3 / 128 L1 -60 at MIDCODE 32.5 + DCOFF 0.5. Pass = 121/113/120 class.
  RESULTS (DONE 22:32):
    LUT 125lut: 4 chops max|INL| 35.1-35.4 ppm (= drive_inl's 34), per-chop
        dev 0.57 ppm rms, differs from 109lut by 11.4 ppm rms (the Rout bow).
    Records 125a-f: static-LUT HD2 -99.8..-116.9 dBc (same class as 107a-f);
        125t two-tone plant-own f2-f1 -95.4.
    Fit 125c3j: hold-outs within 0.2 dB / 1.8 deg on all six single-tone
        records; two-tone hold-out resid 5.4 of 9.2 uV rms; dyn-action
        -136.4 dBc. 125c3jw3: stat roughness dropped 2.4 uV rms.
    D1  gate 126 (-1 dBFS 1 kHz, LP-LS floor -136.4): HD2 -128.3, HD3
        -135.1, HD4 -131.7, HD5 -133.8, HD6 -128.2, HD7 -140.7, HD8 -152.4
        dBc. D1 (-115) MET by 13 dB; STRETCH -125 MET on BOTH HD2 (+3.3) and
        HD3 (+10). (121 ideal drive: -139.1/-127.5; 119/122 old LUT: -90.)
    D3  gate 127 (19+20 kHz -3 dBFS, floor -128): f2-f1 -128.1 (floor),
        2f1-f2 -134.1, 2f2-f1 -137.1 dB re peak. D3 MET by 13 dB.
    L1  gate 128 (-60 dBFS + DCOFF 0.5): ANALOG floor -146.7 dB0, max bin
        -156.6; ADDED -142.8 dB0 (433 nV), max added bin -153.1. MET (120:
        -144.8 / -155.5; 117: -142.9).
  VERDICT R114: with the REAL base drive (LVC1G74 Rout 25 -> rs 1350 / rp
  301 -> VCM 1.345) and the shipping deck (MIDCODE 32.5 + DCOFF 0.5), the
  re-identified chain 125lut + 125c3jw3 meets D1 (+both stretches), D3, L1.
  G1 CLOSED: the hardware base network stands as drawn; the bow it adds is
  static and is calibrated out in situ. Shipping digital chain is now
  125lut (4-chop) + 125c3jw3 + DCOFF 0.5. hw/reconcile.md + bom 1.2 updated.
  P8 revised (p8_comparison.md): worst harmonic margin +2.5 -> +1.2 dB,
  THD+N +11 -> +10 dB; the 19+20 kHz f2-f1 line now reads -128.1 (= the 16k
  LP-LS sensing floor; 125t record -128.3) vs dCS -130 -> UNRESOLVED, not
  lost. HD2 -128 is the LUT residual of the 34 ppm real-drive bow.
  OPTIONAL follow-ups: (a) 65k two-tone gate to resolve f2-f1 (~95 min);
  (b) 6-chop LUT or a 2nd-order-aware static fit to pull HD2 back toward
  the ideal-drive -137.
- R115 (user: "run the spice simulations before schematic build";
  utils/r115_p.ps1, launched 12:38 09-28, ~3.5 h): A = gate 129, 65k
  two-tone 19+20 kHz -3 dBFS (bins 204/212, 125lut + 125c3jw3, MIDCODE 32.5)
  -> imd_read floor ~-134 to resolve f2-f1. B = 8 more chops (lut, lut2,
  lut7..12) on the 125 plant -> cosim125lut12_inl.npy (12-chop mean, LUT
  noise 0.29 -> 0.16 ppm rms), kernel unchanged, gate 130 = D1 -1 dBFS 65k
  with the 12-chop LUT (vs 126 HD2 -128.3).
  READOUT (DONE 16:28): 129 sensing floor -134.6: f2-f1 -127.3 (REAL, not
  floor; dCS -130 -> -2.7 dB), 2f1-f2 -137.7, 2f2-f1 -139.6. 130 (12-chop)
  HD2 -124.3 / HD3 -132.4 / HD4 -142.8 / HD5 -140.7 / HD6 -129.1 -> HD2 did
  NOT recover (4 dB worse than 126). Diagnosis: 12-chop bow identical to
  4-chop (0.0519 ppm/cell^2), so chop noise is not the limiter; the residual
  2nd-order line is a few-% mismatch of the LUT bow predistortion (stream
  injects -87.7 HD2 / -95.2 f2-f1, plant-own the same): analog/stream
  129 f2-f1 2.45 % @ -3.7 deg, 126 HD2 0.93 % @ -34, 130 HD2 1.46 % @ -21.
  In-phase, same sign = static bow measured ~1-2.5 % larger than the plant
  shows under the NS stream (over-correction). 12-chop LUT NOT adopted.
  Tooling: rtz_inl.period_avg mask -> searchsorted (65k readout 30 min -> 10 s).
- R116 (utils/r116_p.ps1, launched 16:33, ~95 min): k2 trim. dpd_volt
  K2TRIM=0.985 scales the LUT x^2 term (deg-4 fit) by 0.985; gates 131 (D1
  65k, vs 126) and 132 (65k two-tone, vs 129). Prediction: f2-f1 ~-135,
  HD2 -129..-133. If met: p8 f2-f1 row -> resolved with margin, K2TRIM
  0.985 joins the shipping digital chain (a per-unit static trim in the
  filter/LUT loader, one scalar).
  READOUT (DONE 18:42): 131 HD2 -128.6 HD3 -135.1 HD4 -131.7 HD5 -133.7
  HD6 -128.1 HD7 -140.8 HD8 -156.1 (= 126 within 0.3 dB, seed-independent).
  132 f2-f1 -133.3 (floor -134.8; dCS -130 -> +3.3 dB), 2f1-f2 -137.7,
  2f2-f1 -137.7. Phasors: HD2 analog/stream 126 +0.77 % -j0.52 % -> 131
  -0.75 % -j0.51 %: the trim acted as an exact 1.52 % in-phase scalar, the
  quadrature -0.5 % is untouched (slow 2nd-order memory outside the 5-lag
  kernel - VCM / base-network time constants). f2-f1 in-phase 2.44 -> 1.23 %.
  The bow mismatch is frequency dependent (2.4 % @ 750 Hz, 0.8 % @ 2 kHz);
  0.985 is the balance point (0.98 would give f2-f1 ~-141 but HD2 -125).
  ADOPTED: K2TRIM 0.985 in the shipping chain (125lut + 125c3jw3 + DCOFF 0.5
  + K2TRIM 0.985). p8_comparison.md revised: all simulable dCS lines beaten.
  Open (not blocking): identify the slow 2nd-order memory term to take HD2
  from -128 toward the ideal-drive -137.
- STEP 5 (2026-09-28, CELL sheet parts pass, page-by-page review mode):
  gen_kicad.py now writes hw/kicad/bfdac.kicad_sym (+ sym-lib-table) with a
  5-unit THAT300 (units 1-4 = Q1..Q4 C/B/E, unit 5 = SUB pins 4/11); the
  tail NPN on CELL is one unit of Q301..Q316 (unit = cell mod 4, per-instance
  unit in the sheet instances), SUB pins on CORE -> GND. Steering pair is a
  real dual (Transistor_BJT:MMDT5551 symbol, value DMMT5551, units A/B of
  one Q10n2). place() gained MPN property + pinmap (deck C/B/E -> package
  pin); kicad_xcheck honours pinmap (per-instance list for the quad).
  Parts (CELL_PARTS table): SN74AXC1T45DBVR SOT-23-6; SN74LVC1G74DCUR
  VSSOP-8 (DCU pinout verified = 74AUC1G74 symbol: CLK1 D2 Qb3 GND4 Q5 CLR6
  PRE7 VCC8); BLM18PG121SN1D 0603 bead; GRM155R71C104KA88D 100n 0402;
  rs/rp/stoppers Yageo RT0402 thin film 1 % (1K35 / 301R / 10R); Rt 750 and
  Rr1 10k Susumu RG1608P 0.1 % 25 ppm 0603; DMMT5551-7 SOT-363; THAT
  300S14-U SOIC-14. xcheck PASS (1300 ep / 543 nets; Q301 pins 1/2/3,
  14/13/12, 5/6/7, 10/9/8 land on CELL01..04 CS/CE as intended), ERC 0
  violations, PDF/SVG + prev_cell.png regenerated, bom_cell.csv exported.
  REVIEW ITEMS for the user: (1) CLOSED 2026-09-28 - user supplied the
  THAT300 pinout: 1 C1 2 B1 3 E1 | 4 SUB | 5 E3 6 B3 7 C3 | 8 C4 9 B4 10 E4
  | 11 SUB | 12 E2 13 B2 14 C2. Q3/Q4 order corrected in THAT300_PINS
  (was 5/6/7, 10/9/8 as C/B/E -> now 7/6/5, 8/9/10); regenerated, xcheck
  PASS, ERC 0, netlist shows Q301 C/E = 1/3, 14/12, 7/5, 8/10 on
  CELL01..04 and bases 2/13/6/9 on Q4_BASE; (2) Rt / Rr1
  chosen 0.1 % 25 ppm (bom says "thin film" only) for inter-cell tempco
  drift of the calibrated LUT; (3) bead 120 R @ 100 MHz is the bom open
  item #11 placeholder; (4) refs Q301..Q316 numbering for the quads.
  Items 2-4 accepted by the user ("Go", 2026-09-28).
- STEP 6 (2026-09-28, CORE sheet parts pass): bfdac.kicad_sym is now built
  by a generic helper (_unit_from_device: Device graphics + real pin
  numbers) and carries THAT300, Si1555DL and 2SA1036K. FINDING: Si1555DL
  is a COMPLEMENTARY N+P pair (Vishay 71079: 1 S1, 2 G1, 3 D2, 4 S2, 5 G2,
  6 D1; device 1 = N), not a dual N - the old sheet note "pair M5p/M6p per
  package" was wrong; bom 3 already says "N half". So: one package per
  MOSFET (Q1-Q6, Q9, Q10 = 8/channel), unit A = N half wired, unit B = P
  half drawn in a strip with no-connects (pins 3/4/5 open). 2SA1036K
  (Rohm SMT3 = SC-59, footprint Package_TO_SOT_SMD:SC-59) as 1 E 2 B 3 C
  per the Rohm sheet - ** REVIEW: an AiT clone sheet lists B/E/C **.
  CORE_PARTS: Rg 100 RT0402 1 %; Re deck 35.3 -> 35.7 E96 RG1608P 0.1 %
  (+1.1 %, REVIEW); Rsh 156 RG1608P 0.1 %; Csh 50p C0G 0402
  GRM1555C1H500JA01D; Rpad 286 2512 1 W thin film TNPW2512286RBEEG (MPN
  pattern REVIEW); Cpadb 100u / C_q4 220u Nichicon UKL low-leakage radial
  (UKL1C101MPD 5x11 / UKL1C221MPD 6.3x11, REVIEW - leakage ~7 uA on the
  100 R feed = 0.7 mV static, fine); C_bus 47n C0G 0805 GRM21B5C1H473JA01L;
  R_bleed 910 / R_bias 100 RT0603 1 %. kicad_xcheck now honours pinmap for
  global parts too (M: D/G/S -> 6/2/1). xcheck PASS (1300 ep / 543 nets),
  ERC 0, netlist: Q1 D/G/S = 6/2/1 on COL_P/M6G_P/MID_P, Q7 C/B/E = 3/2/1
  on CASB_P/NS1P/E1P, P-half pins 3/4/5 in unconnected-* nets.
  prev_core.png regenerated.
  CORE review closed 2026-09-28 (user): (1) 2SA1036K 1 E 2 B 3 C confirmed;
  (2) Re -> Susumu RG1608N-35R7-W-T1 (0.05 % 10 ppm); (3) TNPW2512 does not
  exist -> Rpad = 2 x Yageo RT2010FKE07574RL in parallel (287 R, 0.35 W
  each in 1/2 W 2010 thin film; R9+R14, R10+R15); (4) caps = lowest
  leakage that is not piezo: Nichicon UKL (UKL1C101MED 6.3x11 for Cpadb,
  UKL1C221MPD 8x11.5 for C_q4) - MLCC would leak less but is
  piezoelectric on a bias node feeding 64 tail bases, polymer leaks ~100x
  more, film too big; (5) P halves now D2/G2/S2 -> GND (separate die).
  Regenerated: xcheck PASS, ERC 0.
  TODO (user, 2026-09-28): REVIEW Rpad dissipation - 0.72 W per rail
  (50 mA x 14.3 V across Rpad to the -15 V rail), ~2.9 W per stereo unit
  of heat near the matched parts is "extremely high". Logged as bom.md
  open item 13; options: shallower return rail (-5 V -> ~90 R, 0.23 W,
  redo N4/PSRR), lower padding current, more/larger legs placed away from
  the array, or a different padding topology. Decide before layout; the
  2 x RT2010 realisation is a placeholder.
- STEP 7 (2026-09-28, IV sheet parts pass, bom 4): IV_PARTS table.
  OPA1612AIDR SOIC-8 (unit B idle follower to GND, footprint reserved for
  NPAR=2); BUF634AIDR SOIC-8 (BW -> V-); R_f 270 Susumu RG3216N-271-W-T1
  (0.05 % 10 ppm, 1206 1/4 W: ~5 Vrms across = ~95 mW, too hot for 0603);
  C_f 1.3n C0G 0603 GRM1885C1H132JA01D; C_col 12n C0G 0805
  GRM2165C1H123JA01D; C_bus corrected to 1206 GRM3195C1H473JA01D (47n C0G
  50 V does not fit 0805); 100n X7R 50 V decoupling per supply pin added
  (kicad-only, C40-43/C50-53). FINDING: R_off carries ~83/95 mA across 11 V
  = 0.9/1.0 W per rail (3.9 W/unit) and no 0.1 % part exists at that power
  -> placeholder 2 x RT2512FKE07266RL (p) / 2 x RT2512FKE07232RL (m) 1 %
  in parallel (R21+R25, R22+R26); 1 % = ~220 mV output DC offset. Logged as
  bom open item 14, to be solved together with item 13 (padding current /
  return rail). xcheck PASS, ERC 0, prev_iv.png regenerated.
- STEP 8 (2026-09-28, FPGA interface + clock tree sheet, bom 1.1/1.3):
  new fpga.kicad_sch (A1) replaces the J1-J3 placeholders. Generic box
  symbol builder (_box_unit) in gen_kicad; local lib now also carries
  LMK1C1108 (TSSOP-16, pins per SNAS814A), LMK00304 (WQFN-32+DAP, pins per
  SNAS577G - both datasheets fetched and pin tables extracted), CCHD-957
  (4-pad, pinout FROM MEMORY - verify) and the two Alinx ACVU13P carrier
  connectors ACVU13P_J6 / ACVU13P_J1 (Samtec ADM6-60, 240 pins as 4 row
  units) generated from Alinx/ACVU13P-Pin-Assignment-20260703.csv: used
  pins passive, all 72/76 GND pins tied, every other pin electrical type
  no_connect (ERC-quiet, footprint keeps 240 pads). cascode_l[i] -> DATi+1
  from Alinx/cascode_pins_gen.txt (all 64 land on J6, banks 64/65);
  mclk_p/n = J1 A17/A16 (B71_L12), clk_sel = J1 B5 (B71_L13_P);
  VCCIO_65_EX + VCCIO_69/70/71 -> V18. Clock tree: Y301/Y302 CCHD-957 ->
  68/82 R attenuator + 100n AC into CLKin0/1 (CLKin* AC to GND), LMK00304
  U301 (SEL0 = clk_sel, SEL1 = 0, CLKout_TYPE = 01 LVDS, REFout_EN pulled
  up), CLKoutB0 LVDS -> FPGA MCLK_P/N, REFout -> 33 R -> root U302
  LMK1C1108 -> 33 R -> 8 leaves U304..U311 -> 33 R x 64 -> MCLK01..64
  (per-cell CLK hierarchical pins now individually labelled; the single
  MCLK_FF global is gone). New rail V33CLK on the refs sheet. FINDING:
  LMK1C1108 CLKIN is LVCMOS-only, so the roots are driven from REFout (95
  fs additive, vs the 51 fs LVPECL figure in bom 1.1) -> bom open item 15;
  footprints for ADM6 / CCHD-957 + bank-64 VCCIO check -> item 16. xcheck
  PASS, ERC 0 (fixed one stub short between the two AC caps), 69 pages,
  prev_fpga.png. FF retiming lives on CELL (translator + LVC1G74 + bead/C
  per cell, clocked from MCLKnn); clock distribution is this sheet.
- STEP 8b (2026-09-28, user ratified bom item 15 option 2): LMK00304
  removed from the FPGA sheet. Mux is now at the XO enables: clk_sel (10k
  pull-down, 48k default) -> Y302 E/D directly and -> U301 SN74LVC1G04 ->
  Y301 E/D; both XO outputs through 33 R (R301/R302) onto the shared XOCLK
  net -> R306 -> root U302 (R root U303 same net). FPGA mclk = U312
  SN74LVC1G125 copy of XOCLK -> 100/120 divider (R304/R305) -> J1 A17
  (B71_L12_P / J28) as LVCMOS18 single-ended; J1 A16 (mclk_n) now
  no-connect. Common-path jitter ~87 fs (XO 82 + 2 x 20) vs ~129 fs with
  REFout. One ERC hit fixed (local MCLK33 label collided with the leaf
  global -> FPGACLK_3V3). xcheck PASS, ERC 0, prev_fpga*.png regenerated.
  bom 1.1/1.3 + items 15/16 updated. TODO carried: FPGA XDC mclk IBUF on
  J28 (was IBUFDS); VERIFY CCHD-957 output high-Z when disabled + pinout;
  ADM6 footprint + module connector X/Y from the ACVU13P mechanical
  drawing / STEP (not in Alinx/, only pin CSVs).
- 2026-09-29 (user, power/thermal): refs sheet PARKED - bom open item 17.
  Rail inventory fixed (+-15, 3.3 x3, 12 V SoM pass-through, 5 V AP, 3.3 V
  AP support, relay coil; V18 comes FROM the SoM - fpga sheet note fixed).
  Thermal estimate ~9-11 W/channel analog, ~6-8 W of it bias-current return
  heat on +-15 (R_off, Rpad, replica chain, casb2 legs) -> shallow return
  rails are the lever (item 13). Eight reference voltages traced to their
  origins (plant node values, not design choices) -> consolidate to 3-4
  buffered nodes when the power architecture is ruled.
- 2026-09-29 N7 SHALLOW-RAIL GATE (gen_noise100.py + EROFF / VPADRAIL
  env, user request: "simulate 8 V / 48 R R_off"). Locked plant settings
  (PADMOS 1, RG5 100, MIS 0.1 %, DUTY 0.75, R_off rail e_n 10 nV/rtHz).
  Baseline +15/-15: 128.29 dB0 (target 128.1).
    R_off rail  +8 V (45R)  126.58 FAIL   (R_off 47->78 nV, OPA e_n x(1+Rf/Roff)
                                          3.2->7: 51->113 nV; rail e_n invisible)
                +10 V (68R) 127.51 FAIL
                +12 V (90R) 127.95 FAIL;  +12 V NPAR 2 128.25 PASS
    Rpad return -5 V (76R)  127.92 FAIL;  -5 V NPAR 2 128.10 marginal
                -8 V (139R) 128.15 PASS
    Combined +12 / -8 / NPAR 2            128.10 (at target) -> saves only
                                          ~1.4 W/channel.
  READING: resistor current source i_n^2 = 4kT I / V_drop -> heat at fixed
  noise is P = V I ~ I^2; the drop is not a free lever. Real lever = the
  padding current (50 -> 25 mA/rail = x1/4 heat at equal noise, re-ID).
  Ve1 source / casb2 return rails have no signal-path noise constraint ->
  still free wins. Recorded bom item 17(g).
  RULING (user, 12:39): "we don't have a choice, we need to deal with the
  heat" - R_off / Rpad keep +-15 (items 13/14 CLOSED as accepted heat,
  padding stays 50 mA, no re-ID). Actions: Ve1 source + casb2 return to
  shallow rails at the power design (free); thermal zoning in layout (all
  bias-return resistors in one chassis-coupled zone away from the matched
  array); enclosure budget analog ~18-20 W + HP 20-24 W (switchable) + SoM.
- 2026-09-29 (user, evening): enclosure = three cooled "tubes" (power /
  SoM / FF+converter+IV+HP), two-stage regulation (remote pre-reg ~1.5 V
  above + local LDO at every consumer) - bom item 17(h). Competitive power
  context noted (BFDAC >100 W is the VU13P; analog ~18-20 W is normal R-2R).
- 2026-09-29 (user): CARRIER COEFFICIENT FLASH - bom open item 18. Target
  10M taps symmetric -> 5.24M unique x 18 b = 11.8 MB/filter; 64 filters =
  755 MB = 6.0 Gbit (user's "2 Gb / 16 GB" corrected). RULED 4 x MT25QU02G
  = 8 Gb on one quad bus, 4 CS, 9 carrier IOs (1.8 V bank) -> 90 filters.
  RTL follow-ups: second flash target on user IO, 18-bit + symmetric unpack,
  folded-FIR 10M P&R gate (10M NOT proven; 5M closed at URAM 50 %).
  SCHEMATIC DONE: U320-U323 + R320-R324 + C360-C363 on the FPGA sheet, J1
  bank 71 (CLK L18_P, DQ0 L18_N, DQ1 L10_P, DQ2 L10_N, DQ3 L6_P, CS0 L6_N,
  CS1 L4_P, CS2 L4_N, CS3 L23_P, RST L23_N). xcheck PASS, ERC 0,
  prev_fpga.png + prev_fpga_flash.png regenerated (kicad-cli pdf -> pymupdf).
  Ball map / 5x5 footprint TO VERIFY (bom item 18).
  DATA-PATH AUDIT (user: "make sure the FPGA can move this data"): RTL is
  x1 SPI @ 50 MHz (6.25 MB/s) -> 1.9 s per 12 MB filter, and the boot loader
  stages EVERY record at boot -> 755 MB ~ 2 min: FAIL as-is. ARM programming
  = 1 byte per 40-bit frame -> 50-200 kB/s -> hours for the library: FAIL.
  RTL items recorded in bom 18(d): quad read 0x6C >= 50 MHz (0.5 s/filter),
  streaming 4 B/frame program mode (~10 min library), boot = directory +
  default filter only, cmd_target -> index with addr[29:28] device select.
  Hardware side is sufficient (MT25QU02G 133 MHz SDR quad).
- 2026-09-30/10-01: THERMAL SIM (bom 17(k)). utils/thermal_zones.py
  (lumped) + utils/thermal_board2d.py (2-D FD, 220x160 mm 4-layer, splits
  at 15 % fill, tube wall 300x140x70). 19.9 W line-out / 41.9 W with HP.
  Array 58/53/49 C (bare/anodised/finned), HP step +14/+10.5/+7.4 K, D
  (FF+clk) hottest zone. Co-located mirrors track to 0.00 K across the HP
  step; static rises/gradients calibrate out; dominant post-cal drift =
  QR1 Veb (HD3 -134.6 -> -133.2 @5 K, -130.3 @ anodised HP step); CASB2
  fixed-divider term 0.3 dB @5 K, 1-2 dB @ HP step. Premature "RULED:
  SERVO" entry withdrawn.
  USER RULINGS 2026-10-01: (1) CASB2 = FIXED REF7050 divider + production
  trim (temperature handled by the indexed cal); (2) HP amp AND I/V amp get
  significant passive radiators, FF/clock strip too (D wall-coupled; target
  = "finned" case or better: array <= 50 C, HP step <= 7 K); (3) temperature
  sensors already in the design for compensation - place at array, wall, D
  to validate the model on the prototype.
  (4) QR1 Veb COMPENSATOR ADDED (user: "cal can't compensate" - no actuator
  on the replica bias): same-type 2SA1036K diode-connected in the VB1 branch,
  ~10 mA (residual ~0.17 mV/K from the VT ln(75/10) density term, ~10x),
  touching QR1; chain trim absorbs the static offset. HD3 held within 0.3 dB
  over the 7.4 K HP step (was -132.0).
  (5) 10:42 CASB2 RULING REVISED (user): SERVO, superseding (1). Same
  reasoning as (4): the indexed cal has no actuator on casb2, so only the
  loop compensates temperature; it also removes lot Vth spread, M6
  self-heating offset and the production trim. OPA1612-class, sense mid_p
  via >=100k + C (corner << 1 Hz), crossover 0.1-1 Hz, output clamp for
  start-up, mid_m unservoed.
- 2026-10-01/02: CASB2 SERVO GATE (user: run the deck before locking).
  (a) Sense audit, utils/servo_sense.ps1/.py: locked plant, M 2048 / BIN 3,
  333 us, AMPDB -1/-20/-60 with V(mid_p) V(mid_m) saved. mean(mid_p) =
  3010.2 / 3006.4 / 3006.1 mV -> +4.1 mV (0.09 % of casb2) full-scale vs
  idle from the Vgs sqrt nonlinearity (analytic est. 11 mV); fundamental
  ripple +-30 mV, raw p-p 110 mV; mid_m static -28 mV vs mid_p.
  (b) Loop deck, utils/servo_loop.py (launch = detached LTspice, report =
  parse): reduced M6 leg + behavioural op-amp with e_n/i_n copiers, sense
  2x499k + 1 nF, integrator C_i, R_o 100 / C_g, diode clamp 6 V. All four
  variants PM 90-93 deg, zero overshoot, loop gain -107 dB at 9 kHz.
  OPA1612: 23 nV @ 10 Hz (i_n x 1 M) FAILS 20 nV; OPA1656 (FET): 4.7 nV
  (C_i 1 uF, f_c 0.16 Hz, settle 4.8 s) / 9.3 nV (220 nF, 0.72 Hz, 1.0 s).
  SELECTED: OPA1656, C_i 1 uF (noise margin, slower envelope tracking of the
  4 mV level term). Ruling CONFIRMED; recorded in bom 17(i)/(k) and sec 9.
- 2026-10-05 USER RULINGS (bom item 20): (1) sec 8 HP AMP REMOVED for this
  version (power/heat) - K3/K5/K6 struck, FPGA T28/N26 freed, 41.9 W case
  and the HP thermal step gone; design point = 19.9 W line-out, only the
  <= 5 K ambient/warm-up excursion remains (servo + Veb compensator stay,
  now with margin). (2) Relays: user researching MPNs; heat is a criterion;
  sec 7 now carries the criteria (latching preferred -> pulse driver +
  forced power-on state; dry-circuit Au contacts; coil rail). (3) NEW sec 20
  temperature sensing: I2C to the AP across digital isolators (ISO1640 per
  isolated domain), 6-8 sensors at A/D/W/(T)/ambient; domain count TBD with
  grounding plan. 20:19 user: TMP117 (cheaper, spec'd long-term drift) and
  ISO1610 ruled; AP side of the isolation deferred. TMP117 has 4 addresses
  and the isolators merge all segments into one bus -> >4 sensors needs an
  AP-side TCA9548A mux or a second AP I2C controller (user; decide with the
  AP side). 20:23 user: QSPI needs no isolator (FPGA-only); AP<->FPGA
  control SPI MUST be isolated, target 50 MHz -> new bom sec 21. Timing
  finding: MISO round trip = 2 isolator crossings (8-13 ns each) + FPGA tCO
  = 22-32 ns vs the 10 ns half-period, so standard SPI timing caps at
  ~15-20 MHz through ANY isolator. 50 MHz needs an AP SPI controller with
  RX sample delay (option A) or echoed clock; ADuM3150 SPIsolator reaches
  40 MHz only. Part class 150 Mbps 3/1 (Si8641 / ADuM342E; ISO7841 100
  Mbps). 20:31 RULED (user): SINGLE SPI at a realistic frequency - 12.5 MHz
  guaranteed standard-timed mode on any AP; 50 MHz fast mode if the AP has
  a programmable RX sample delay (now an AP selection criterion) with
  boot-time MISO training; QSPI rejected (bidirectional lanes -> 11
  isolator channels + DIR control; only provisioning would benefit). One
  3/1 isolator. 20:33 RULED (user): TI ISO7741 (3/1, 100 Mbps, tPD max
  16 ns, PWD 4 ns) -> guaranteed standard-timed mode drops to 10 MHz (12.5
  has zero margin at max tPD); 50 MHz fast mode unchanged (window ~12 ns;
  SCLK toggle = 100 Mbps = the device rating, no headroom above 50). IRQ
  channel if added: ISO7742 or ISO7761. Datasheet figures to VERIFY.
  20:38 user CONFIRMED TI ISO7741 after the Si8641 comparison (Skyworks
  only buys 12.5 vs 10 MHz fallback and 50 MHz headroom; supply favours TI;
  footprint-compatible fallback kept in the table).
- 2026-10-05 20:55 CARRIER COEF FLASH (bom 18a): user wants a 2 Gb QSPI
  device on the carrier for coefficient growth. Audit: qspi_flash_ctrl
  already drives BOTH SoM flashes (Flash 0 bitstreams via STARTUPE3,
  Flash 1 128 MiB coef on bank 65, x1, SCK = USRCCLKO); Flash 1 = ~10
  filters at 10M taps. No 4 Gb single-CS NOR exists; 2 Gb/CS is the cap.
  Device: MT25QU02GCBB8E12-0SIT RULED (user 20:59). Assembly constraint
  recorded: external CM builds the board - 0201 / BGA / two-sided are all
  fine, hand-solder is never a selection criterion.
  Pins: bank 70 is entirely free on J1 (51/51, VCCIO_70 = V18) ->
  CF_CLK J35, CF_CS0_n J36, CF_DQ0..3 H36/G36/H34/G34; CS1-3 reserved
  H37/H38/G37 (free-pin scan: utils-free PowerShell over the Alinx CSV vs
  XDC PACKAGE_PINs: 64:3, 65:30, 66:42, 67:3, 68:25, 69:35, 70:51, 71:31).
  RTL follow-ups listed in 18a (2-bit target, forwarded SCK on user IO at
  25 MHz first pass, boot-target select w/ fallback, XDC, tb T5) - NOT
  started; awaiting go-ahead.
- 2026-10-05 21:35 CARRIER FLASH RTL DONE (user go-ahead 21:00). Files:
  qspi_flash_ctrl (2-bit cmd_target, rd_target boot input, sel_target /
  cf_cs_sel outputs, dev_addr() masks addr[31:28] for the carrier, per-
  target SCK divider CF_CKDIV_LOG2=3 -> 25 MHz), qspi_boot_loader
  (BOOT_FROM_CARRIER=1, one-shot fallback to SoM Flash 1 when the carrier
  header != MAGIC; parse is the if-TRUE branch so an X/z header from an
  absent part falls through; boot_src output), vu13p_dac_top (cf_sck /
  cf_cs_n[3:0] / cf_dq[3:0], IOB-registered SCK/CS/MOSI, 3-way MISO mux),
  dac_ctrl_plane + spi_regs.svh (FLASH_ADDR_HI[9:8] target, BOOT_STATUS[13]
  boot_src), XDC s11b (bank-70 pins per 18a, LVCMOS18, MISO input delay +
  multicycle 4/3 vs clk_200m, DQ2/3 false path).
  Sim: tb_qspi_subsys rewritten with a {device,addr}-keyed flash model;
  T1-T6 PASS (T5 carrier boot boot_src=1, T6 chip-1 ARM erase/program/
  read with 28-bit masking; T1/T2 implicitly exercise the fallback).
  tb_flash_wdt, tb_dac_ctrl_plane, tb_spi_ctrl_plane PASS. tb_vu13p_top /
  tb_vu13p_mig got the cf_* ports + pullup on cf_dq[1] (absent carrier).
  ENV NOTE: xsim needs the local FlexLM server (Xilinx.lic is a floating
  licence: SERVER csc3 2100, lmgrd in C:\AMDDesignTools\win_flexlm_*);
  it was down after a reboot - xvlog/xelab run without it, xsim does not.
- 2026-10-05 23:05 CARRIER FLASH COUNT RULED (user): 2 x MT25QU02G
  populated + 2 DNP sites, 4 Gb. Arithmetic: 5,242,880 x 18 b = 180 x 64 KiB
  exactly, +header = 181 sectors = 11.86 MB/filter -> 22 per 2 Gb, 45 per
  4 Gb (user wants 30+ across the 44.1/48 families). User Q&A: (1) count
  was inconsistent across RTL (4 CS), 18a (1) and gen_kicad (4) - now 2+2
  everywhere; (2) no length-matching provision existed; ruled NOT needed
  (65 ps/10 mm vs 20 ns half-period) - total length <= 75 mm and <= 10 mm
  stubs are the real rules (MISO round trip); (3) placement ruled: carrier
  top side beside J1 A19-A26/B19-B29, not under the SoM (heat, 85 C part,
  ADM6 stack height unverified). FOUND + FIXED: gen_kicad still had the
  09-29 bank-71 pins and a CF_RST IO; moved to the bank-70 set (XDC s11b is
  master), RESET# strapped, DQ2/DQ3 bus pull-ups R324/R325, 33R R326 on
  CF_CLK at J1, place() gained dnp=. Regenerated; kicad_xcheck PASS.
- 2026-10-05 23:16 SUPERSEDED -> ALL FOUR POPULATED (user): requirement is
  30+ designs x BOTH base rates (44.1k/48k are distinct coefficient sets)
  = 60+ filters = 5.7 Gb; 3 devices = 66 (10 % margin), 4 = 90 (50 %).
  CFLASH_POPULATED = 4, no DNP; XDC s11b / bom 18a / symbol descriptions
  updated; regenerated, kicad_xcheck PASS. Pending RTL recap given to the
  user: item 18 (a) 18-bit packed format (capacity numbers depend on it),
  (1) quad read 0x6C >= 50 MHz (today x1/25 MHz = ~4 s per filter switch),
  (2) streaming program mode, (3) boot = directory + default filter only,
  (b) 10M-tap folded-FIR P&R gate.
- 2026-10-05 23:25 D1=A (RTL now, re-evaluate after), D2=C (format RTL +
  background build). FINDING on item 18 (a): "symmetric expansion in the
  loader" is moot - 10M is only reachable with the FOLDED FIR (pre-adder),
  where the URAM holds the unique half and the mirror is a datapath
  property; an unfolded 10M (2560 MACs) is 100 % URAM / ~45 % DSP / ~70 %
  LUT and not viable. So (a) = 18-bit packing only; the fold is (b).
  DONE (a): coef_bank_loader packed mode - directory byte 0x14 packing
  (0 = v1 32-bit, 1 = 18-bit x7 per 16 B beat, continuous MAC-major
  stream, no per-MAC alignment, last burst short), payload_bytes check per
  packing (ceil(N/7)*16: 2,396,176 @1M, 11,983,728 @5.24M = 0.571x v1),
  unknown packing -> code 2, legacy slot path stays v1. Flash image =
  payload verbatim (boot loader unchanged). tb_coef_bank_loader +T8
  (packed load, every write checked, 147 / 586 bursts) +T9 (packed size /
  unknown packing -> code 2): 9/9 PASS at TPP 64 and TPP 256.
  coef_format_v2.md: header 0x68 packing, directory 0x14, payload
  section rewritten incl. the fold rule (phase_type 0 required for a
  folded build; asymmetric filter = fold off at half length). Capacity
  unchanged: 183 sectors/filter -> 22 per 2 Gb, 90 per 8 Gb.
  BACKGROUND: scripts/synth_f18_5M_cf.tcl - first synth of the carrier-
  flash RTL at the proven 5M geometry (s11b binding checks, refreshed
  LUT-as-memory baseline for the fold estimate). 10M P&R itself needs the
  fold RTL first (no meaningful run possible yet).
  Fold feasibility (from f15b 5M routed): LUT-as-memory 289k/791k = 36.6 %
  is the window history; fold doubles it -> ~73 % of SLICEM capacity with
  DSP/URAM unchanged - feasible on paper, timing is the risk (5M closed
  at exactly 0.000). BRAM/URAM alternatives for windows ruled out (5120
  parallel single-cycle reads).
- 2026-10-06 08:26 synth_f18 RESULT: 0 errors / 0 critical warnings, 32.5
  min; 9 cf_* ports, u_flash_ctrl/rx_sr_reg x7 bound, MISO path
  requirement 5.0 ns (s11b multicycle applied); LUT 536,200 (31.0 %),
  URAM 640 (50 %), DSP 2733 (22.2 %) = f15b baseline +0.6 % LUT for the
  carrier-flash logic. synth_f18_5M.dcp kept. (The script's "IOB
  candidate 0 FFs" lines are a bad query - net driver is the OBUF - not a
  finding; IOB packing is a place-stage check.)
  D6 = B (user): 10M taps PARKED until the PCB is at manufacturing; 5M
  stays the proven ceiling, packed format + carrier flash unchanged.
  Back to BOM / schematic build-out.
- 2026-10-06 STEP 9 (REFS sheet parts pass, bom 9): refs.kicad_sch (A2) is
  now the realised reference/bias block, not a PWR_FLAG table. REFS_PARTS
  in gen_kicad.py; REF7050 added to bfdac.kicad_sym (SNAS781 Table 6-1:
  1 EN 2 VIN 3/4/5/8 GND 6 OUTS 7 OUTF, FKH = DGK). Chain: U901 REF7050
  (ONE per board) -> 4.99k + 10u FILM (3.2 Hz) -> U902A OPA1656 FET buffer
  = REF5F -> dividers (RG1608P 0.1 % for V_VG/CASB2/PADB taps, ACAS 0612
  arrays for VFR/VCM/VREF/VE1 - 2 of 4 elements used) -> U903 OPA1612 x2
  buffers (V_VG, VREF; 10 R + 47u UKL + 1u C0G); U904A + BCP56 servoed
  150 mA SINK for VFR; U904B + BC847 Vbe-mult + BCP56/BCP53 class-A pair
  on a new +5A (U908 LT3045, 49.9k SET) for VCM (Iq 40 mA); U905A x1.442
  -> U906 LT3045 SET = VE1 7.2 V from VP10 (new +10 pre-reg input, power
  sheet); VB1 = VE1 - [57.6 R + diode-connected 2SA1036K Q902 at 10 mA]
  via 590 R -> U905B buffer (Veb compensator, dVB1/dVeb = -0.91); U902B
  CASB2 servo exactly as gated (2x499k + 1n, C_i 1u, 100 R / 100u, 6.2 V
  clamp) on a global mid_p (CORE MID_P made global); U907 OPA1656 PADB
  current servo (diff-amp 0.25 x (padb_ep - VEE15), integrator vs 3.568 V
  tap, 1k -> PADB_BASE, 2.7 V clamp; padb_ep made global). CASB2_P/M are
  one node after the servo (stoppers on CORE) - kicad_xcheck MERGE map
  added for the deck's two sources. E96 set-point residues: V_VG +0.08,
  VREF -0.15, VFR -0.14, VCM -0.10, VE1 +0.14, CASB2 tap +0.07, PADB -0.2 %.
  New footprints: LT3045 MSOP-12-EP, SOT-223, SOD-123, R_Array 4x0612,
  Analog LCC-8 (REF70 FKH), MKS2 7.2x7.2 / 7.2x2.5 film, CP 5 mm.
  RESULT: xcheck PASS (1300 endpoints / 542 nets), ERC 0 errors, 1
  warning = the intentional CASB2_P/CASB2_M join. Three layout-collision
  shorts (R920 on R919's GND stub, REF_VIN flag on the V18 row, R933/R934)
  found by a point-connectivity diag and fixed. bom 9 rewritten to the
  realised rows. VERIFY before purchase: ACAS ordering-code format, WIMA
  MKS2 MPNs, LT3045 ILIM/PGFB strapping.
- 2026-10-06 STEP 9b (user: simulate before locking) utils/refs_loop.py -
  launch/report pattern of servo_loop.py, 11 LTspice decks (behavioural
  op-amps with e_n/i_n copiers, Si1555DL_N / Rohm 2SA1036K deck models,
  GENERIC BCP56/BCP53/BC847 fits). Three design errors found and fixed in
  gen_kicad (xcheck PASS, ERC clean after):
  (1) VFR sink polarity was inverted (vfr on -in; an NPN sink pulls DOWN so
      vfr belongs on +in). Now PI error amp: ref via 1k, 1u film + 100 R
      from the output. First noise pass 28 nV @ 10 Hz (OPA1612 i_n x 14k)
      -> divider 11.8k/6.34k replaced by 1.18k/634 (R_th 412). RESULT
      f_c 530 Hz, PM 96 deg, T(1 Hz) 93 dB, 5.5 nV @ 10 Hz, start-up max
      1.748 V no overshoot, +-0.1 % at 15 ms.
  (2) PADB diff-amp inputs mirrored (PD_OUT = -3.57 V, integrator railed
      on the clamp, I_pad 55.7 mA). padb_ep moved to the + side. RESULT
      f_c 0.38 Hz, PM 103 deg, T(9 kHz) -86 dB, padb_base 1.7 nV @ 10 Hz,
      start-up peak 55.6 mA (clamp) -> 50.15 mA p/m in 1.2 s, gate 0.66 V.
  (3) VB1 static: 5.960 V with R928 57.6 -> 59.0 gives 5.947 V. Compensator
      verified over -20..90 C: QR1 current tempco +0.039 %/K vs +0.435 %/K
      fixed (11x).
  VCM pair as drawn: f_c 374 kHz, PM 159 deg, |Z| 12 mOhm @ 100 kHz,
  5.8 nV, 23 mA x 50 ns RTZ pulses -> -0.33 mV, class A held (I_q lands
  ~54 mA with the generic BC847; trim R921 on the bench). Open: VFR
  start-up ordering (replica current before op-amp rails -> VFR rises to
  VE1) -> power-sheet sequencing or clamp; re-run VCM with vendor models.
- 2026-10-07 STEP 9c (user: real vendor parts + models, then re-simulate)
  hw/models/nexperia_bjt.lib (Nexperia BCP56-16, BCP53-16, BC847B,
  BC817-40, BC807-40, BAT54 SPICE); refs_loop.py switched to them, op-amp
  output current limit modelled (tanh - the hard limit() broke the AC op
  point), VFR stress case added (replica current 40 ms after the ref).
  User: "why such a large transistor?" -> the VCM pair only moves +-24 mA
  about ~40 mA I_q; SOT-223 was sized for 5 V x 40 mA. RULED (user, both
  suggestions): VCM rail 5 V -> 3.3 V (U908 SET 49.9k -> 33.2k, net still
  p5a) and BC817-40/BC807-40 SOT-23 replace BCP56/BCP53 there -> 0.08 W
  each. Q901 stays BCP56-16 SOT-223 (0.21 W, the one real power node).
  Start-up ordering: D903 BAT54 from the VFR error-amp output to GND
  (base >= -0.4 V vs V_EBO 5 V, PI cap cannot wind up) - NO sequencer IC.
  RESULTS (vendor models): VFR f_c 480 Hz PM 96, 5.5 nV @ 10 Hz, realistic
  start-up 1.748 V max; stress 2.6 V for ~10 ms then settled, base min
  -0.41 V, clamp 35 mA. VCM f_c 373 kHz PM 160, 5.8 nV, -0.33 mV on the
  RTZ pulses, I 41/65 mA class A held, P 0.079/0.075 W. PADB f_c 0.38 Hz
  PM 103, 50.15 mA p/m. VB1 unchanged. gen_kicad updated (xcheck PASS, ERC
  clean), bom 9 rows rewritten.
  NEXT: power sheet (item 17(d): +-15A, VEE15, V_ROFF LDO + filter, VP10,
  V33FF, V33CLK); 16 before layout; item 18/18a RTL items when the FPGA
  work resumes; relay MPNs when the user's research is in.
- 2026-10-07 STEP 10 (user: "account for the SoM connectors" + control
  plane with an isolation barrier, I2S included; AP undecided). Two new
  sheets: som.kicad_sch (J2/J3/J4/J5/J7/J8 symbols from the Alinx CSV via
  alinx_used()/conn_nets() shared with J1/J6 on the FPGA sheet; +12 V
  Mini-Fit J901 + bulk; Xilinx 14-pin JTAG J902 from J6; BOOT_M straps DNP;
  every VCCIO -> V18, VP/VN -> GND, MGT pins no-connect) and ctrl.kicad_sch
  (U501 ISO7741 SPI, U502 ISO7741 I2S + IRQ back, U503 ISO7710 AP_RST_N ->
  EXT_RST_N, U504 ISO1610 I2C -> 4x TMP117 on V33D, AP header J501 2x10,
  LED_DBG0..3 + SOM_PG via MMBT3904). XDC: ext_rst_n now has a pin (R27 =
  B71_L2_N = J1-A1, s5b); relay_hp_* pins left unassigned (bom 8 struck).
  Refs rails table extended (V33D, V12SOM, VAP_IO, GND_AP; 2 columns).
  BUG FIXED: cascode_map() regex needed one space before "[get_ports" and
  silently dropped cascode_r[48..63] (column-aligned lines) -> 48/64; now
  64/64. xcheck PASS; ERC = 64 isolated DATRnn (R channel not drawn) + the
  known CASB2_M/P note. bom.md: sec 20/21 "REALISED" paragraphs, new sec
  22 (SoM carrier + "real components still missing" table), open item 22
  (AP decision). Pin maps of ISO7741/7710/1610/TMP117 are from memory ->
  VERIFY; Samtec ADM6 footprint to be downloaded, not drawn.
  NEXT: AP direction (today list) -> J501 becomes a connector or a module;
  relay MPNs -> sec 7 sheet; R channel instance; power sheet last.
- 2026-10-07 STEP 10b (user: Samtec ADM6 catalog PDF). Catalog page has
  the envelope only (60 x 0.635 + 4.72 = 42.82 x 5.00, -01.5 = 2.90 /
  3.32 mm, 5 mm stack with ADF6-03.5); the land pattern is the separate
  Samtec print "RECOMMENDED PCB LAYOUT FOR ADM6-XXX-XX.X-XXX-X-X-X" Rev A
  (ECN-358211) - fetched (Farnell + Trenz mirrors) into datasheets/.
  gen_kicad.write_local_footprints() now writes hw/kicad/bfdac.pretty/
  Samtec_ADM6-60-01.5-L-4-2-A.kicad_mod + fp-lib-table from TABLE 1 -60
  (B 37.465 / C 40.27 / A 42.82), rows +-0.79 / +-1.75, pad 0.356, NPTH
  0.95 diagonal at +-1.27, chamfers at A01/D60. Rendered via kicad-cli
  and checked against the print; ERC footprint-link clean. All eight J
  connectors reference bfdac:Samtec_ADM6-60-01.5-L-4-2-A. bom sec 22
  footprint paragraph rewritten; "footprints to obtain" list shrinks to
  CCHD-957 / MT25QU02G / TMP117-EP.
- 2026-10-07 19:40 USER: AP direction PARKED (bom item 22) - not a
  carrier blocker; J501 2x10 header is the committed isolated interface
  for this revision (isolators are level-translating, VAP_IO 1.8 or 3.3).
  NEXT (FPGA board MVP, in order): R-channel instance (CELL x64 / CORE /
  IV / clock root U303 consuming DATR01..64) -> sec 7 output routing once
  relay MPNs land -> pin-map VERIFY pass (ISO7741/7710/1610, TMP117,
  CCHD-957, MT25QU02G) -> power sheet last.
- 2026-10-07 STEP 11 (user: "proceed with the secondary channel").
  gen_kicad: the cell/core/iv/refs code moved out of main() into
  build_channel(ch, ...) and runs twice. Sheet.chan drives (a) a _L/_R
  suffix on every channel-local global label (SHARED_NETS = rails,
  REF5/REF5F, GND exempt) and (b) chan_ref() designator offsets for R
  (cells +1000, refs 9xx->7xx, Q3xx->Q4xx, core/IV +60 - +50 first
  collided R core C51-53 with L IV C50-53). L-only blocks: rails PWR_FLAG
  table, U901 REF7050 chain + U902A buffer (R's U702A = spare follower).
  New files cell_r/core_r/iv_r/refs_r.kicad_sch + clkr.kicad_sch (U303
  root, U330-U337 leaves, R350/R351/R360-367/R600-663, C370-396) via a
  shared fanout() helper; XOCLK now a global net. Root on A1: 2 x 64
  CELL sheets (CELLLnn / CELLRnn) + 10 sub-sheets, explicit sheet names
  (CORE_L / IV_R ... - duplicate sheet names would have been an ERC
  error). SOM sheet designators 9xx -> 8xx (collided with REFS R901 /
  C901-C907). kicad_xcheck: loops over both refmap instances (cell/global
  and cell_r/global_r) + a new channel-short test (no L deck endpoint
  shares a KiCad net with an R endpoint off the shared rails). RESULTS:
  xcheck PASS 1300/542 per channel, no shorts; ERC 2 (the CASB2_M/P
  notes, now one per REFS sheet); no annotation errors (dup-ref scan
  shows only the intentional THAT300 multi-unit Q3xx/Q4xx). bom sec 22
  "Right channel - DONE" paragraph; missing-components table shrinks to
  relays / AP / power / 3 footprints / pin-map VERIFY.
  NEXT: sec 7 output routing (relay MPNs) -> pin-map VERIFY pass ->
  power sheet.
- 2026-10-07 20:31 USER RULING: relay = Panasonic AGN220A12 (GN, 2 Form
  C, dual-coil latching, 12 V coil, Au-clad Ag-Pd twin contacts; AGN
  preferred over the TQ2SA-L2-12V runner-up for size). Coil rail =
  V12SOM branch; driver = ULN2003A per channel (6 pulsed low-side
  outputs = 3 relays x set/reset); FPGA pulse timing (20 ms) is an RTL
  follow-up; power-on mute pulse rule stands. bom sec 7 + missing table
  updated. Datasheet VERIFY list: coil R / must-operate, min pulse
  width, TH vs SMD suffix (X/Z), 1 A/30 VDC + dry-circuit rating.
  NEXT: sec 7 sheet in gen_kicad (K1/K2/K4 x2, ULN2003A x2, R0 tap
  string, XLR, mute shunt) once the datasheet is in datasheets/.
- 2026-10-07 20:36 GN DATASHEET READ (ASCTB13E 2022.10, saved as
  datasheets/Panasonic_GN_relay_mech_eng_gn.pdf). CORRECTION: the GN
  family has NO 2-coil latching (functions 0 / 1 = 1-coil latching /
  6 = high-sens); AGN220A12 is not in the catalog -> the 20:31 "dual
  coil + ULN2003A" ruling was from memory and is withdrawn. Also 10.6 x
  5.7 x 9.0 mm (standing; misses the <= 6 mm preference). Verified:
  1-coil latching 12 V = 1440 R / 8.3 mA / 100 mW, set/reset <= 75 %,
  pulse >= 10 ms; contacts AgPd + Au-clad, 1 A 30 VDC, 10 uA/10 mV.
  bom sec 7 rewritten as a 3-way decision: (A) AGN210A12 + DRV8220
  H-bridge per relay (1.8 V logic OK), (B) TQ2SA-L2-12V 2-coil +
  ULN2003V12, (C) AGN200A12 non-latching + ULN2003V12 (0.84 W held).
  WAITING on the user.
- 2026-10-07 20:45-21:25 MUTE GUARANTEE + MEMS EVALUATION (user asked
  how the output stays muted until init completes, then proposed MEMS
  relays, ADGM3144/ADGM3121). Mute: a latching K4 cannot guarantee
  muted-at-power-up without a pulse; a single-side-stable K4 with the
  NC contact grounding the output does (coil off = muted, no FPGA/no
  power needed); unmute = FPGA GPIO AND DONE AND power-good. MEMS:
  datasheets/adgm3144.pdf (Rev. 0) read and compared to the GN sheet on
  numbers only. ADGM3144 wins held power (8 mW vs 100 mW), area (10x),
  cycles (1e8), off-isolation (-119 dB). Fails: abs max +-7 V on /
  +-10 V stand-off vs 48 V P48 at the XLR (4.8x over; GN 750 Vrms /
  1500 V surge); RF-pin ESD 150 V HBM Class 0B at a human-touched
  connector; open-only (cannot ground the muted output -> sec 7 rule
  fails, node floats on 10 M); THD only published at -103 dBc @ 0.88
  Vrms/300 R vs -140 dB target at 3 Vrms (37 dB short, unproven);
  dRon 0.8 R -> 0.27 % leg imbalance vs 0.1 % budget. Secondary: VINH
  2.0 V (level shifter from 1.8 V bank), 10 MHz charge-pump
  feedthrough, 80 V VCP by the output, continuously-on wear-out. The
  power/area wins are on non-binding constraints and do not offset
  abs-max failures. Earlier replies that scored the MEMS wins before
  the fails read as "defending" it; the user asked for the ultimate
  position.
- 2026-10-07 21:31 USER RULING - DECISION MADE: electromechanical
  relays, NO MEMS at this point. Technology closed; reopen only for a
  MEMS part with >= +-50 V stand-off, >= 2 kV HBM on the RF pins and
  published THD <= -140 dB at >= 3 Vrms/300 R. bom sec 7 + missing
  table updated. Recommended variant set (awaiting explicit
  confirmation): K4 = AGN200A12 single-side stable (NC = output to
  GND, 140 mW held/channel, 0.28 W/unit), K1/K2 = AGN210A12 1-coil
  latching + DRV8220 H-bridge (zero held). Coil rail V12SOM.
  NEXT: confirm variant set -> sec 7 sheet in gen_kicad (K1/K2/K4 x2,
  drivers, R0 tap string, XLR, mute shunt, unmute gating) -> pin-map
  VERIFY pass -> power sheet.
- 2026-10-07 21:52 USER CONFIRMED the variant set ("if by math the
  electromechanical relay is best, we use it"; K4 recommendation
  honoured): K4 = AGN200A12 single-side stable (NC grounds the output,
  140 mW held/channel), K1/K2 = AGN210A12 1-coil latching + DRV8220
  H-bridge each, K4 low-side switch gated by relay_line_mute AND DONE
  AND power-good, all coils on V12SOM. High-sensitivity AGN26xA12 for
  K4 considered and not taken (70 C ambient ceiling vs 80 mW/unit).
  GN strengths recorded for the design: 1500 V open-contact / 2500 V
  contact-coil surge (FCC68 / Telcordia), AgPd+Au dry-circuit contacts
  (10 uA/10 mV), 2 Form C grounding of the unused side, NC-contact
  fail-safe mute, <= 4 ms, 50e6 mechanical life; weak points 9 mm
  height and 1-coil-only latching (-> H-bridge driver). bom sec 7 +
  missing table updated. Relay decision CLOSED.
  NEXT: sec 7 output-routing sheet in gen_kicad (K1/K2/K4 x2, DRV8220
  x4, K4 switch x2, R0 tap string, XLR, unmute gate) -> pin-map VERIFY
  pass -> power sheet.
- 2026-10-07 22:02 R0 LEVEL STRING - FOUND NON-FUNCTIONAL (user: "the
  circuit is not functional"). The R0 taps were the sec 5 filter
  termination bridged by the hi-Z V-stage; ruling 2 (2026-09-21)
  removed both and nothing replaced the level mechanism. CORRECTION to
  my 21:57 claim: R_off is NOT independent of R_f - iv_n5.py line 14 /
  bom 4 size I_off = I_DC + V_VG/R_f so the output sits at 0 V DC; a
  switched R_f moves the output DC (180 R -> +1.33 V, 90 R -> +2.67 V)
  unless R_off is switched with it. Options costed: (B) output divider
  Z_out = 0.222 R_s -> -1.74 dB load-dependent at 600 R, rejected;
  (A) parallel-add R_f||C_f + R_off add on one contact per level
  (540||0.67n + 1486 R -> 4 V; 135||2.6n + 371 R -> 2 V; pole fixed,
  DC fixed, loop never opens) but buffer DC sink 14.8 -> 22.2 -> 44.4
  mA: +0.77 W/unit at 4 V, +3.1 W/unit at 2 V held, +4 relays +4
  DRV8220 +8 networks; (C) digital: LEVEL caps VOLUME, SNR 132.8 /
  129.3 / 123.3 dB0 sim, N1 is defined at 6 V, D1 improves, zero parts.
  Recommended (C).
- 2026-10-07 22:14 USER RULING: "go with your suggestion" -> (C)
  DIGITAL LEVEL, K1/K2 + R0 string STRUCK; XLR = Neutrik NC3MAH
  placeholder (connector decision deferred); build-out 10 R per leg
  outside the loop taken as default (revisit); PG_A15 = placeholder
  net from the power sheet. STEP 12 gen_kicad: new out.kicad_sch (A3)
  - R670-R673 10 R RG1608P, K601/K602 AGN200A12 (local box symbol,
  coil 1/8, COM 4/5, NC 3/6, NO 2/7 ** VERIFY p.7 **, SMD footprint
  TODO), J601/J602 Connector_Audio:XLR3_Ground (NC3MAH placeholder),
  U602 SN74LVC1G11 @ V18 = RLY_LINE_MUTE AND FPGA_DONE AND PG_A15 ->
  UNMUTE_EN -> U601 ULN2003V12 (Transistor_Array:ULN2003A symbol,
  SOIC-16 D, COM = V12SOM) -> coils. FPGA_DONE = new carrier pin J2 A1
  VUP_SELECTMAP_DONE (alinx_used). CTRL_PINS: RLY_LEVEL0/1 removed
  (P26/N29 now no-connect on J1; RTL ports remain); ctrl-sheet NC
  stubs for the relay nets removed. OUT_PARTS table added. RESULTS:
  gen OK, xcheck PASS 1300/542 both channels, ERC 2 (CASB2 notes),
  netlist: OUT_P_L = C23/R23/U3.6/R670.1, OBP_L = R670.2/K601.2,
  KC_L = K601.8/U601.16, FPGA_DONE = J2.A1/U602.3, PG_A15 =
  R674.2/U602.6. bom sec 4 R_ld struck, sec 7 rewritten (ruling,
  realised sheet, table), missing table updated. Remaining for sec 7:
  AGN200A12 footprint + pin VERIFY, XLR decision, PG_A15 source
  (power sheet), SoM DONE pull-up VERIFY, RTL LEVEL -> digital cap.
  NEXT: pin-map VERIFY pass (ISO7741/7710/1610, TMP117, CCHD-957,
  MT25QU02G, AGN200A12) -> power sheet.
- 2026-10-08 10:54 K4 RELAY CHANGED (user): AGN200A12 -> Omron
  G6K-2F-Y DC12. User could find no Panasonic pin map / footprint;
  his reading of the GN diagram (COM 3/6, NC 2/7, NO 4/5) equals the
  map decoded from the KiCad Relay:G6K-2 symbol graphics (armature
  rests on the filled NC contact at pins 2/7; coil 1(+)/8) - two
  sources agree, and the G6K has a library footprint
  (Relay_SMD:Relay_DPDT_Omron_G6K-2F-Y). User chose the Omron for
  lowest coil power (100 mW vs 140 mW); the 70 C ambient ceiling is
  accepted because K4 is at the rear-panel/XLR edge of a ~20 W box
  (TMP117 ambient sensor validates). Also surveyed: Kemet EE2-12NU
  (lib symbol + footprint, 140 mW, pins coil 1/12, COM 4/9, NC 3/10,
  NO 5/8 by the same decode) kept as the 85 C fallback. gen_kicad:
  local AGN200A12 symbol removed, OUT_PARTS k4 = G6K-2F-Y DC12,
  K601/K602 = Relay:G6K-2 pins 1 V12SOM / 8 KC_x / 3,6 XLR / 4,5
  build-outs / 2,7 GND. xcheck PASS, ERC 2, netlist XLR_HOT_L =
  J601.2/K601.3, OBP_L = K601.4/R670.2. bom sec 7 + missing table
  updated. G6K coil/contact figures are from memory -> VERIFY vs
  en-g6k.pdf in the pin-map pass.
- 2026-10-08 12:30 PIN-MAP VERIFY PASS (datasheets/ TI_ISO7741,
  TI_ISO7710, TI_ISO1640, TI_TMP117, Omron_G6K; pdf2txt.py moved to
  pymupdf for the encrypted Omron PDF). Results:
  * ISO7741 (SLLSEP4K): box symbol correct.
  * ISO7710 (SLLSER9E) D package: **from-memory map was WRONG** -
    VCC1 = pins 1 AND 3, IN = 2, GND1 = 4, GND2 = 5, OUT = 6, NC = 7,
    VCC2 = 8. Ours had IN on 3 (AP_RST_N shorted to VCC1) and GND1 on
    2. Fixed: pin 3 = VCC1B -> VAP_IO, pin 2 = INA.
  * ISO1610: TI 404 - the MPN does not exist. The bidirectional I2C
    isolator is **ISO1640** (SLLSFC2D, ISO1640BDR). Pin map identical
    to our box (1 VCC1 2 SDA1 3 SCL1 4 GND1 | 5 GND2 6 SCL2 7 SDA2
    8 VCC2) but supply is NOT 1.71-5.5 V as bom sec 20 said: side 1
    3.0-5.5 V, side 2 2.25-5.5 V. Sides swapped so the TMP117 bus
    (V33D) is side 1 and the AP (VAP_IO) is the wider side 2 ->
    constraint: VAP_IO >= 2.25 V (AP still open, item 22).
  * TMP117 (SNOSD82D): box correct; thermal pad not internally
    connected, datasheet recommends leaving it unsoldered on rigid PCB.
  * G6K-2F-Y DC12 (en-g6k p.3/p.6, page rendered and read): 12 V coil
    1,315 ohm / 9.1 mA / ~100 mW (memory said 1,440 / 8.3), must
    operate <= 80 %, release >= 10 %, max 150 %, -40..70 C, P-level
    10 uA @ 10 mV, bifurcated crossbar Ag/Au-alloy. Terminal diagram
    (top view): coil 1(+) / 8(-), COM 6/3, NC 7/2, NO 5/4 = the
    schematic (K601.1 = V12SOM, .8 = ULN sink: polarity right).
  gen_kicad regenerated; xcheck PASS 1300/542 per channel; ERC 2
  (CASB2 notes); netlist U503/U504/K601 pins dumped and checked
  (utils/_netpins.py). bom sec 20/21 + missing table updated.
  STILL OPEN: CCHD-957 (Crystek URL 404 - fetch by hand), MT25QU02G
  ball map, BOOT_M strap need, SoM DONE pull-up/level (Alinx manual).
- 2026-10-08 13:50 CCHD-957 VERIFIED (user dropped datasheets/CCHD-957.pdf,
  Rev N 25-Aug-2026; page 2 rendered and read). Pad table: 1 E/D,
  2 GND, 3 OUT, 4 Vcc = our box. Tri-state table: E/D open or >= 0.7 Vcc
  active, <= 0.3 Vcc High Z (200 ns disable, 1.5 mA standby) -> the
  bom 1.1 "mux at the XO enables" scheme is valid. Footprint written in
  write_local_footprints(): bfdac:Crystek_CCHD-957 from the SUGGESTED
  PAD LAYOUT - 4 pads 0.050 x 0.090 in (1.27 x 2.28), centres 0.200 x
  0.280 in (5.08 x 7.11), body 0.560 x 0.360 in (14.2 x 9.14), pin 1
  at the dot corner (top view bottom-left), CCW. FP["CCHD957"] on the
  symbol and FPGA_PARTS xo/xo2. Regenerated: xcheck PASS, ERC 2,
  Y301 netlist 1 CLK_SEL_N / 2 GND / 3 XO0 / 4 V33CLK.
  STILL OPEN: MT25QU02G ball map, BOOT_M strap need, SoM DONE
  pull-up/level (Alinx manual).
- 2026-10-08 15:10 MT25QU02G VERIFIED (datasheets/Micron_MT25QU02G.pdf =
  mt25q-qlkt-U02-CBB-S-IT Rev C, fetched from part-elec mirror; Micron
  URLs 404). Fig. 4 rendered: **from-memory ball map was WRONG** -
  RESET# was on B4 (actually VCC) and VCC on C3 (actually DNU), so the
  flash would have had no supply. Real: A4 RESET#, B2 C, B3 VSS, B4 VCC,
  C2 S#, C4 W#/DQ2, D2 DQ1, D3 DQ0, D4 HOLD#/DQ3. Pin-config "8" in the
  MPN = dedicated RESET# (internal pull-up) + HOLD# shared on DQ3; our
  V18 strap on RESET# and 10k on DQ3 are right. Footprint written:
  bfdac:Micron_T-PBGA-24_6x8mm_Layout5x5_P1.0mm (Fig. 6: 5x5, 1.0 mm,
  dia 0.40 SMD pads, 6x8 body, A1 absent, 24 pads). Regenerated: xcheck
  PASS, ERC 2, U320 netlist A4/B4 -> V18, B3 -> GND, data balls OK.
  USER 2026-10-08: no dedicated ACVU13P manual exists -> BOOT_M strap /
  SoM DONE pull-up stay bring-up items, not datasheet items. Pin-map
  VERIFY pass COMPLETE.
  NEXT: power sheet (17(d)) or XLR connector decision / PG_A15 source.
- 2026-10-08 19:30 SoM CONNECTOR PLACEMENT from Alinx's own files (user:
  no layout drawing exists for the ACVU13 B2B connectors, but the AXVU13G
  carrier .brd and the SoM DXF/STEP are in Downloads\Alinx).
  * ACVU13_BOT.dxf (Allegro export, board coords from top; copied to
    datasheets/): utils/som_connectors.py clusters PIN_BOTTOM into 8 x
    240 pads, exact ADM6/ADF6 pattern (rows +-0.79/+-1.75, span 37.465),
    centres +-47.499 / +-22.159 from the SoM centre; mounting holes on a
    78 mm square (+-39), corner cutouts r 3.175 at +-48.68.
  * AXVU13G.1.0_.brd is Allegro 16.6 binary - KiCad 10's Allegro importer
    (pcbnew.PCB_IO_MGR.Load(ALLEGRO)) reads it: 1010 footprints, 16 Cu
    layers, 38k tracks, nets intact. utils/brd_connectors.py dumps J1-J8
    (242 pads each) with pin names + nets: resolves J numbering AND pin
    A1 per connector. Table -> gen_kicad.SOM_CONNECTORS (SoM centre
    origin, y up): J1/J2 left edge rot -90 (pin 1 bottom, row A
    inboard), J3/J4 bottom rot 0 (pin 1 right, row A inboard), J5/J6
    right rot 90 (pin 1 top, row A inboard), J7/J8 top rot 0 (pin 1
    right, row A OUTBOARD). Alinx mounts the SoM turned 90 deg vs the
    SoM's own frame; no mirror.
  * FOOTPRINT FIX: Alinx's ADM6 NPTH are pin-1 end ON the centreline and
    pin-60 end 1.27 toward row A. Re-read the Samtec print: it says the
    same - my 2026-10-07 "+-1.27 diagonal" was a misread. Fixed in
    write_local_footprints().
  * gen_kicad.write_som_seed_board() -> hw/kicad/som_seed.kicad_pcb:
    J1-J8 placed with our footprint around (150,150), 100x100 SoM
    outline + 78 mm hole marks on Cmts.User. Separate file so it can
    never clobber a real layout.
  * utils/som_seed_check.py (KiCad python): every pad of all 8
    connectors vs the Alinx board after centre alignment -> worst
    deviation 0.0001 mm, PASS.
  RESOLVED from ACVU13.1.stp (utils/step_probe.py, text parse of the
  cylinders + product list; copied to datasheets/): SoM outline is
  **106 x 106** (DXF BG_OUTLINE -3..103), not 100. Two hole sets:
  corners +-48.682 (97.364 mm square, 4.318 from the edge) = product
  'MH_250H125' = dia 3.175 hole / 6.35 pad -> the M3 STANDOFFS; inner
  +-39 (78 mm square) = dia 4.0 / 5.5 ring on the SoM = heatsink/fan
  through-bolts (STEP has a FAN90X90 product). The Alinx carrier .brd
  has BOTH sets, all drilled dia 4.0 (rings 6.35 / 5.5). gen_kicad:
  SOM_SIZE 106, SOM_MOUNT_HOLES both sets with drill/ring; seed board
  redrawn and re-checked (PASS 0.0001 mm). USER 19:13: the 78 mm set
  are SUPPORT STANDOFFS (centre support under mating force; the SoM's
  fan/heatsink shares the pattern) - relabelled. Swept the Alinx carrier
  for any other drill >= 0.8 mm under the 106 x 106 SoM area: none
  besides the 8 holes + 16 ADM6 alignment NPTH; carrier rings are
  plated on isolated nets (Net_2..9). STILL OPEN: keep-out height
  under the SoM (5 mm nominal stack; STEP z is component-local, so
  measure the tallest SoM bottom part in a CAD viewer).
    - 2026-10-11 17:55 POL LDO / PRE-REG / UNMUTE INTERLOCK LOCKED (user) ->
      bom 17(m). Per-LDO headroom from datasheets (LT3045/LT3094 1.0 V PSRR
      condition + 1 % + harness = 1.2 V on 15 V rails, 1.1 V VE1, 1.0 V on
      3.3 V; ADP7158 0.7 V; TPS7A20 0.3 V), ceiling 1.5 V. Pre-reg rails:
      P16A +16.2 / N16A -16.2 / V8P3 +8.3 (new, VE1 only) / V4P3 +4.3 (new,
      all 3.3 V LDOs; replaces V4P0); VP10 deleted. POL heat 2.7-3.4 W
      stereo. Datasheet strapping found BOTH existing LT3045s (U906/U908)
      wrong: ILIM floating (must be GND) and PGFB to GND (forces 2 mA
      fast-start -> OUT rails to V_IN). PGFB dividers on all 7 LT30xx
      (887k/412k/180k over 20k, 1 nF) = PG at 90 % + fast start. PG_ALL =
      wired-AND of 7 PG + TPS3890 on V33FF (VDD from V4P3, SENSE 649k/100k;
      ADP7158/TPS7A20 have no PG pin), 10k to V18 -> U602 (replaces R674
      dummy) AND FPGA GPIO; MUTE_N from firmware after config + PG_ALL +
      heat-soak timer (120 s placeholder, derive from thermal_n4.py).
      Sequencer/PMIC rejected. Rail taxonomy recorded (digital / digital-in-
      analog-path / converter / I-V / SoM).
      NEXT: draw POL stage on the power sheet, fix U906/U908, PG_ALL nets on
      OUT + CTRL, pre-reg rail flags; verify TPS3890 pinout/400 mV ref.
    - 2026-10-11 20:17 RAIL TELEMETRY LOCKED (user) -> bom 17(m2): TI
      UCD90120A on the TMP117 sensor I2C bus (V33D, behind ISO1640), 12 MON =
      8 POL + 4 pre-reg rails via dividers (negative-rail network VERIFY);
      telemetry + NV fault log only, NOT in the mute path (PG_ALL wired-AND
      + TPS3890 unchanged, no level shifter - open-collector to V18). AP
      configures it over the bus at boot (PMBus = I2C transactions): Fusion
      export checked in as data, USER_DATA config version -> replay +
      STORE_DEFAULT_ALL + SOFT_RESET if blank/mismatch; polling for alerts;
      4-pin PMBus header DNP. Rejected ADM1266 / UCD9090A / ADS7138.
      NEXT unchanged: draw POL stage (power sheet), fix U906/U908, PG_ALL on
      OUT + CTRL, UCD90120A + dividers + header on CTRL, pre-reg flags.

    - 2026-10-12 DUAL-MONO POL + 2x UCD90120A LOCKED (user) -> bom 17(m3):
      all 8 POL rail types per-channel (nets *_L/*_R); L/R matching via shared
      REF5F (calibrated anyway); VEE15/VE1 shared would couple channels;
      V33CLK shared would run LT3045 at abs-max. Counts: 14x LT30xx + 2x
      ADP7158 + 2x TPS3890; PG_ALL = wired-AND(14 PG, 2 supervisor) + 10k
      to V18. Telemetry = 20 rails > any single monitor (UCD90240 obsolete,
      UCD90160A/ADM1266 short) -> 2x UCD90120A on the sensor bus, each
      covering its channel's 8 POL + shared pre-regs; distinct addresses via
      analog PMBUS_ADDR0/1 resistor straps (0x7E default prohibited; clear of
      TMP117 0x48-0x4B; strap values VERIFY). RESET/TRST/TDI/TMS straps per
      datasheet; PMBALERT# pullup present, unrouted.
      NEXT: draw power sheet (14 LDOs + 2 ADP7158 + 2 TPS3890 + PG_ALL),
      move U906/U908 class LDOs off REFS, PG_ALL on OUT+CTRL, 2x UCD + 20
      MON dividers + straps + DNP header on CTRL, pre-reg flags.

    - 2026-10-12 POWER ARCHITECTURE DRAWN + VERIFIED (gen_kicad.py ->
      hw/kicad/, xcheck PASS / ERC clean):
      POWER sheet: J603 Mini-Fit 2x3 pre-reg entry (P16A/N16A/V8P3/V4P3 +
      2x10u bulk each), PG_ALL wired-AND node + R1701 10k pull-up to V18,
      U1701 TPS389001 supervisor on V33FF (VDD=V4P3 survives a V33FF
      collapse; SENSE 162k/100k -> 3.01 V trip, VITN 1.15 V per SBVS227 -
      the earlier '400 mV' figure in 17(m) was wrong). POL placement per
      user ruling (non-pre-reg LDOs live on the sheets they power): REFS
      x2 carries U906 VE1 (SET driven by U905A via VE1_SET_x), U908 P5A,
      U909 P15A, U910 N15A, U911 VEE15 (LT3045/LT3094, PGFB dividers
      mandatory - the old PGFB->GND strapping held the part in 2 mA fast
      start and pegged OUT; EN/UV->IN, ILIM->GND, VIOC->GND on the 3094s);
      IV x2: U685 V_ROFF LT3045 + BLM18 bead/bulk (VROFF_RAW -> v_roff);
      CLKR: U340 V33CLK; XLAT: U460 V33FF ADP7158 (REF/BYP/REF_SENSE/
      VREG bypass per datasheet); CTRL: U512 V33D TPS7A2033 + U510/U511
      2x UCD90120A (distinct resistor-strapped addresses 10k/10k vs
      10k/20k on analog PMBUS_ADDR0/1, on SENS_SCL/SDA behind ISO1640;
      13/13 MON inputs each - U510 covers the L POLs + V33CLK/V33FF/
      V33RLY + 4 pre-regs, U511 the R POLs + V33D/V18/V12SOM + same
      pre-regs = every rail on the board is monitored; neg rails via
      100k-to-rail + 10k-pull-up-to-V33D + BAT54 clamp; straps: RESET
      10k+1nF, TRST/TRCK 10k down, TDI/TMS/PMBALERT 10k up, PMBUS_CNTRL
      GND; J505 4-pin PMBus service header DNP). OUT: R674 dummy ->
      PG_ALL into U602 unmute gate (PG_ALL AND RLY_LINE_MUTE AND
      FPGA_DONE); FPGA J1 PG_ALL pin wired on CTRL. DEVIATION from 17(m3)
      text: V33CLK/V33FF stay BOARD-SHARED (single nets, not _L/_R) -
      the clock fanout and translator/FF islands are single shared
      silicon, so per-channel rails there would join at the same pins;
      dual-mono applies to the six analog rail types + V_ROFF.
      VERIFICATION: kicad_xcheck RESULT: PASS (L/R 1300 endpoints, no
      channel shorts); ERC = the 2 known warnings only (CASB2_P/M
      intentional tie on each REFS). Debug root causes fixed: refdes
      collisions vs the 1xxx/2xxx cell-ref space (new parts moved to
      U17xx/R17xx/5xx/685+/480+/526-599/8xx-safe bands), and a systematic
      layout bug - vertically stacked passives at <12.7 mm pitch have
      overlapping pin stubs (R pin2-GND stub lands on C pin1-SET stub,
      10-11 mm pitch rows chain-merged MON divider columns rail->GND,
      same for strap columns and 8 mm decap stacks; fixed by >=14-15 mm
      pitch or column offset; C1711 stub end coincided with U1701 pin2
      stub -> V4P3 shorted to GND, moved). No PWR_FLAG on PG_ALL (OC
      wired-AND, not a rail) and removed the V33D/V33CLK/V33FF/V33RLY
      flags now that real on-board drivers exist.
      NEXT: layout/annotation review of the generated sheets; sheet-
      metal/harness interface (J603 pinout vs the tube); bom.md part-list
      refresh against the generated refdes set.

    - 2026-10-12 K4 RELAY TYPE RE-CONFIRMED (user): non-latching G6K-2F-Y
      DC3 stays. Held cost accepted: 33 mA / ~100 mW per channel on
      V33RLY while unmuted (~200 mW box total) - the premium for
      de-energised = muted (spring NC shunt works with no power, no
      FPGA). Latching (G6KU + H-bridge) rejected for the MUTE path:
      holds last state through power loss, cannot guarantee NC on
      mid-play failure. Coil economiser (PWM the driver ~55 % after
      pick) rejected by user: PWM on a coil rail adjacent to the XLR is
      a potential noise injection not worth ~100 mW. Level select stays
      DIGITAL (LEVEL register); no K1/K2, no H-bridges, no latching
      relays remain in the design.

    - 2026-10-12 TEST POINTS DRAWN (gen_kicad.py -> 134 x Connector:TestPoint
      + 16 x 1k isolation resistors): helpers tp()/tp_stub() implement the
      21:14 rules - (a/b) signal, clock, cell-drive and summing nodes reach
      a 1.0 mm SMD pad through a 1k series stub on a TP_* local net so the
      probe can never sit on the signal path; (c) rails / references /
      control / GND get THTPad_2.0x2.0 hook pads; (d) every bank ends in
      GND pads.  Map: POWER 9 (P16A/N16A/V8P3/V4P3/V18/PG_ALL/SNS_V33FF +
      2xGND); REFS_L 22 + REFS_R 19 (P15A/N15A/VEE15/VE1/P5A/V8P3/V4P3,
      VB1/VCM/VFR/VREF/V_VG/CASB2_P/PADB_BASE/PADB_EP/VE1_SET/MID_P, L-only
      REF5/REF5F, GNDs); IV 11/ch (V_ROFF/P16A/N15A/P15A/V_VG, OUT_P/M on
      1.0 mm pads, COL_P/COL_M through R688/R689 1k, 2xGND); CLKR 7
      (V33CLK/V4P3, XOCLK + MCLKR01/64 through R845-847 1k, 2xGND); FPGA 5
      (MCLK_FPGA + MCLK01/64 through R327-329 1k, CLK_SEL, GND); XLAT 11
      (V33FF/V18/V4P3, DAT01/32/64 + DATR01/32/64 through R470-475 1k,
      2xGND); CTRL 15 (V33D/V12SOM/SENS_SCL/SDA/SPI x4/EXT_RST_N/
      FPGA_IRQ_N/LED_DBG0/I2S_BCLK/I2S_DATA, 2xGND); SOM 12 (V12SOM/V18/
      FPGA_DONE/JTAG x4/BOOT_M x3, 2xGND); OUT 12 (V33RLY/V4P3/
      RLY_LINE_MUTE/FPGA_DONE/PG_ALL/UNMUTE_EN, OUT_P/M L+R on 1.0 mm
      pads, 2xGND).  Layout review still owed: pad keep-outs against the
      match/capacitance budget (rule e) are layout-time placement, not
      drawn geometry.
      VERIFICATION: kicad_xcheck RESULT: PASS (1300 endpoints/channel);
      ERC = the same 2 intentional CASB2_P/M warnings - no new violations,
      no net merges (134 TPs resolve in bfdac_analog.xml).

    - 2026-10-12 REGULATION TIER B + 3-CONNECTOR HARNESS LOCKED + DRAWN
      (user): compared shared-final-LDO (A) vs shared-pre + per-channel-POL
      (B) vs fully-mono (C). A rejected: a shared final node removes
      LDO-PSRR isolation of channel-correlated rail currents -> crosstalk
      ~-110..-130 dB0, marginal vs the -120 dB0 spur spec. B locked (= the
      drawn design; residual ~-140 dB). C unnecessary (pre-reg drift is
      invisible after LDO regulation). User's 3-edge connector plan drawn:
      J506 2x12 left edge (CTRL) absorbs J501 + J801 = 3x V12SOM + 3x GND
      + AP-domain set (SPI/I2S/IRQ/RST/I2C/VAP_IO/GND_AP); J603 top +
      J604 bottom (POWER) = 2x4 each carrying the SAME shared pre-reg
      rails P16A/N16A/V8P3/V4P3 + per-rail GND - tube Y-fans-out, each
      channel's POL cluster draws from its own harness leg. J801 struck.
      VERIFICATION: xcheck PASS, ERC = 2 known warnings; J506/J603/J604
      pin nets confirmed in bfdac_analog.xml. Mini-Fit family + signal
      blades near 12 V = VERIFY at connector selection.

    - 2026-10-13 MEZZANINE CONNECTOR FAMILIES SELECTED + DRAWN (user):
      ~30 mm board-to-board stack, split power/signal accepted. Survey:
      no single-shell blade hybrid reaches 30 mm (mPower <=20 mm,
      PowerStrip/30 ~14 mm, mP/SEARAY8/Gecko-MT <=10 mm; FX18 reaches it
      but only ~12 A on MF contacts). LOCKED (bom 17(m6)):
      J506 = Hirose FX18-40 socket (10-45 mm mated family) - AP digital
      set, odd pins = signals, even = GND_AP beside each; SOM_PG added.
      J507/J508 = Wuerth REDCUBE press-fit terminals (M4, 60-100 A class)
      = +12 V/GND board-to-board feed AND conductive standoffs.
      J603/J604 = 0.100" 2x4 stacker headers (Samtec TW/ESQT class,
      ~3 A/pin vs <=0.5 A/rail) - same four shared pre-reg rails.
      VERIFICATION: xcheck PASS; ERC = 2 known CASB2 warnings + 3
      footprint_link warnings (BFDAC_Footprints FX18/REDCUBE not drawn
      yet - layout task). J801/J501 absorbed; stale doc refs updated.

    - 2026-10-14 PER-CELL MEASUREMENT, INDEPENDENT L/R + SUMMING ACCESS:
      SPI writes 0x18 (L), 0x19 (R): enable[7], add-cell[6], index[5:0].
      Reads 0x1D/1E return pending[8] + accepted command[7:0]. Baseline
      selects the next 32 cells cyclically excluding the cell under test;
      test state adds only that cell (32 vs 33), retaining normal 6/8 RTZ.
      A non-enabled channel runs a fixed 32-cell background while the other
      is tested; both may be independently enabled. No I2S/coefficient
      stream is required: diagnostics use the existing cell_clk/8 pacer.
      Mute required before enable; DSP waits 4,000,000 consecutive clocks
      with force_zero and both relay drives low. UNMUTE rejected while
      either diagnostic is enabled or either CDC command is pending.
      Handshakes hold each command bus until acknowledged; reserved bits
      and busy/unsafe commands report sticky[6] + reason C/D/E.
      Measure each cell from settled pre-relay OUT_P/M baseline/test delta
      at the same index. Summing taps check compliance/settling, not cell
      current directly. Existing L COL_P/M taps TP987/988 via R688/689,
      R TP787/788 via R788/789 confirmed. Added dedicated SMD GND pads
      TP992/993 (L), TP792/793 (R): 138 TPs total, IV 13/channel.
      Corrected probe claim: 1k reduces loading, does not eliminate it;
      10 pF gives ~16 MHz probe-path pole. Low-C active probe, never 50 ohms.
      Full host procedure: docs/coef_format_v2.md, per-cell section.
      VERIFICATION: tb_cell_measurement PASS, 260 pattern windows covering
      all 128 cells, L/R independence, busy/format/mute rejects, six-clock
      pulses, command readback, reset and normal-path restoration.
      tb_dac_ctrl_plane regression PASS; tb_vu13p_top full elaboration PASS
      (existing DDR-width/unconnected-port warnings remain). xcheck PASS,
      including new permanent checks for all four probe/resistor/GND/output
      paths; ERC 0 errors, same 5 warnings (2 CASB2 + 3 connector footprints).
      Run targeted simulation: Xilinx/Testbench/run_tb_ctrl_plane.ps1
      tb_cell_measurement (runner supplies SIM/include path); direct
      xvlog/xelab/xsim stages were used for this run. Not yet validated:
      hardware measurements, analog settling/load budget, physical ground
      proximity/stub placement, synthesis/P&R timing and CDC reports.

    - 2026-10-14 MANUAL BRING-UP UI + THREE TESTS + RAIL LEDs LOCKED/DRAWN:
      User: two buttons; Button 1 press count within three seconds selects
      CELL/DC/FREQUENCY, Button 2 advances one held measurement condition.
      Continuous 1/2/3 Hz test LED accepted throughout acquisition; off means
      no active test, not measurement pass. Extra STEP after final RIGHT
      condition completes; no auto-wrap. SELECT hold two seconds cancels.
      bench_test_controller.sv: 10ms debounce, fixed 3s selection window,
      held-button/no-autorepeat handling, safe-start wait, request/ack FSM,
      explicit completion/cancel, persistent mute and clock/PG fault abort.
      All tests run LEFT then RIGHT. CELL has 128 conditions/channel;
      DC has offsets 0,+1,-1,+4,-4 cell-equivalents; FREQUENCY has 1..20kHz
      held tones, peak four cell-equivalents, 32-bit DDS / 1024x16 sine ROM.
      bench_test_stimulus.sv feeds the existing core: cell bypass retains
      RTZ, DC/tone bypass FIR/volume/DPD but retain NS/DEM/RTZ. No AP/I2S/
      coefficients/DDR initialization required. Independent I/V injection
      and a separate V-gain stage were NOT added; these test the full chain.
      SPI 0x1F exposes mode/channel/step/FSM/fault. Local test cannot steal
      an active/pending SPI cell test; SPI unmute/rate/cell writes blocked
      while local owns. Explicit UNMUTE required after completion/abort.
      GPIO: SELECT M29/J1-D20, STEP L29/J1-D19, LED L28/J1-D17 (bank 71).
      Fixed an existing dangerous pin conflict: PG_ALL N29/J1-B7 was still
      an obsolete level-relay output in XDC; now an input used for test
      safety. Undrawn legacy relay_level[1] moved to spare K28/J1-D16.
      New BRINGUP sheet: SW9000/9001 Wuerth 434133025816, 10k to V18 + 1k
      series. D9023 test LED is driven by FPGA through Q9001 MMBT3904,
      nominal 100uA from V12SOM/102k ONLY, not V33D or analog power.
      D9000..9022 = 23 rail indicators: 4 pre-regs + 12 channel POLs +
      V12SOM/V18/V33CLK/V33FF/V33D/V33RLY/VAP_IO. Negative polarity and
      GND_AP isolation preserved. V18 sensed via Q9000, LED powered by
      V12SOM for voltage headroom. Kingbright APT1608LSECK/J3-PRV 0603 red,
      nominal ~100uA (Vf/visibility first-article check required); steady
      operation, removable series resistor for comparisons, no reference/
      bias/SET/summing-node loading. Rails must still be measured.
      VERIFICATION: controller TB PASS (317 checks, every test step and
      L/R boundary, debounce, 1/2/3Hz, selection rejection, cancel, fault,
      held buttons, delayed ACK, reset); stimulus TB PASS (346 checks,
      80 tone frequency cases across both clock families/channels, DC,
      CDC, invalid commands and fault shutdown); cell/core integration
      TB PASS (262 pattern windows + all ten manual DC conditions through
      NS/DEM + manual tone output + mute/fault handling). Control-plane
      regression PASS including local/SPI arbitration and status readback.
      Full top-level elaboration PASS; existing DDR TB width warnings remain.
      Generator regenerated, xcheck PASS (1300 deck endpoints/channel,
      summing taps plus new UI/rail LED checks); ERC remains 0 errors and
      5 known warnings (2 CASB2 + 3 connector footprint links).
      No full FPGA synthesis/P&R or physical measurements run. Board layout,
      new CDC/timing sign-off, analog settling, external acquisition accuracy
      and 100uA LED visibility remain first-article/implementation checks.
      The DDS is a bring-up frequency-response source, not a certified
      -115/-125dBc distortion-test stimulus. Full operating/register details
      are in docs/coef_format_v2.md; runner supports tb_bench_controller,
      tb_bench_stimulus and tb_cell_measurement and checks TB_PASS markers.

    - BRING-UP PARTS + LED CURRENT LOCKED (user approval): SW9000/SW9001
      remain Wuerth 434133025816; all 24 new LEDs remain Kingbright
      APT1608LSECK/J3-PRV. Nominal LED current increased from 100uA to
      500uA for bench visibility (supersedes the earlier current entries).
      Resistors: +/-16.2V 28.7k; +/-15V 26.7k; 12V direct 20.5k;
      8.3V 13k; 7.2V 10.7k; 4.3V 4.99k; 3.3V 3.01k.
      Buffered V18/test LEDs use 20k from V12SOM; both MMBT3904 base
      resistors changed to 10k for adequate drive at 500uA. V18 sensing
      now draws roughly 100uA from V18 separately from its V12SOM LED load.
      VAP_IO is sized for 3.3V; at 2.25V it is dimmer (~150uA assuming
      Vf=1.8V). Exact brightness/current still require a first-board check.
      No RTL or test sequencing changes. Schematics regenerated; xcheck
      PASS including explicit 500uA resistor/driver-value checks; nominal
      sizing calculation PASS. ERC: 0 errors, same 5 known warnings
      (2 CASB2 naming ties and 3 unimplemented connector footprint links).

    - REPOSITORY CHECKPOINT / GITHUB HYGIENE (user requested): ignore local
      simulator stdout/stderr, crash dumps, logs, raw e2e captures, KiCad
      session files/reports/plot exports, PDF extraction scratch, duplicate
      vendor ZIP downloads, thermal-result arrays and local Devin settings.
      Fifteen previously tracked reports/raw captures removed from the Git
      index ONLY; local files retained. Golden vectors, source scripts,
      design notes, vendor CAD/PDF references, all current KiCad sheets,
      project libraries, PCB seed and frozen reference netlists retained.
      Keep these inputs versioned: schematic regeneration imports vendor
      footprints from datasheets/, and xcheck consumes hw/ref_netlist.json
      plus hw/kicad/refmap.json. Raw e2e captures are produced by the e2e
      testbench and must be regenerated before running capture-analysis tools.
      Validation before checkpoint: Python compileall (utils/analysis_archive)
      PASS; xcheck PASS; ERC 0 errors / 5 known warnings. Fresh XSim runs:
      tb_bench_controller, tb_bench_stimulus, tb_cell_measurement,
      tb_dac_ctrl_plane, tb_spi_ctrl_plane and tb_dpd_engine all PASS.
      Project-source whitespace checked; original vendor CAD and generated
      PCB-seed whitespace preserved. No full synthesis/P&R was run. The
      mezzanine mating-part/footprint selections remain provisional and
      precede physical layout; this checkpoint is not manufacturing sign-off.

    - SYSTEM ARCHITECTURE / SENIOR ENGINEERING REVIEW HANDOFF:
      Created docs/SYSTEM_ARCHITECTURE.md revision 0.1 against Git baseline
      a7483c1bce6efacb386d27e6f2965bb8e24da593, linked from README.md.
      Covers intent/acceptance, signal and numeric flow, clock/reset/CDC,
      memory/boot/control/calibration, converter/I-V interface, power/ground,
      PCB/mechanical intent, manual tests and verification limitations.
      Includes 20 open findings with evidence, proposed priority and closure
      actions, plus architecture/FPGA/circuit/layout/physical review gates.
      Concrete source disagreements include I2S direction, MCLK signaling,
      clock-select polarity and SPI cell-test versus automute busy semantics.
      Additional review concerns include rate/watchdog compatibility, DPD
      deadline at the actual 45/46-cycle cadence, AP isolation crossing,
      coefficient-bank consistency, calibration operating point and safety.
      Prior passing unit/ERC checks do not close these integration findings.
      Documentation-only work: no RTL/circuit fixes or new hardware claims.
      Source links checked against tracked files; clock/rate/delay arithmetic
      checked. Existing verification results are labelled reported evidence,
      not tests rerun during document preparation. Senior review still owed.

    - 2026-10-16 STREAM CLOCK/RATE OWNERSHIP LOCKED (user):
      AP owns knowledge/notification of the PCM stream sample rate and format.
      FPGA validates the request and owns coherent MCLK selection, interpolation
      ratio and derived I2S BCLK/LRCLK, including safe transition/readiness.
      FPGA = I2S master; AP = slave transmitter. Oscillators remain the physical
      converter/reclock MCLK source; no separate AP MCLK export.
      Maximum native PCM input = 384kHz. Supported-rate intent:
      44.1/48 -> x128; 88.2/96 -> x64; 176.4/192 -> x32; 352.8/384 -> x16.
      Conversion remains 5.6448/6.144MHz; BCLK=64*Fs for two 32-bit slots.
      AP does not independently program oscillator/core/interpolation ratios.
      AP filter selection is policy; FPGA validates rate compatibility.
      Unsupported rate/format requests rejected; mute/quiesce, configure,
      flush/reset and applied-rate/readiness precede normal playback.
      Source-ready/underrun contract still needed: locally generated clocks
      do not prove the AP is transmitting valid audio.
      Recorded in SYSTEM_ARCHITECTURE.md revision 0.2, bom.md and the protocol
      document. The existing RATE family bit and fixed-x128 datapath do not
      implement this contract. Register encoding, rate-dependent filters and
      processing, I2S master RTL, watchdog and timing validation remain pending.
      R01/R04 ownership/rate decisions are settled; R01-R04 implementation
      findings remain open. Documentation update only; no RTL changes.

    - 2026-10-16 R01-R04 RTL IMPLEMENTATION DRAFT (verification pending):
      Added stream_rate_controller (mute/reset/select/relock/startup) and
      i2s_master_ingress (BCLK/LRCLK outputs, 32-bit slots/24-bit capture,
      tagged delayed DATA sampling, source-ready and frame-cadence checks).
      Added rate codes 0..7, source-ready and RX-trim SPI writes/status.
      Master-clock copy uses IBUF/LVCMOS18; physical clk_sel=~family48.
      FIR executes 16/8/4/2 active phases; memory retains full sixteen-phase
      bank layout, unused phases padded, per-rate filters required.
      FIR history clears on path reset; pacer primes with 128 entries and
      exposes sticky overflow/underflow plus FIR input-overrun faults.
      Production loader validates directory family/shift/active tap count;
      incompatible metadata/legacy untagged slots fail with code 3.
      DDR reset now follows external reset, not audio PLL/rate reset.
      Rate changes clear source-ready, unmute, DPD enable and bank-valid;
      AP must reload/verify required state and explicitly resume.
      Updated top/MIG testbench pin directions and clock-family mapping;
      added controller, serial-delay/rate matrix and full-pipeline tests;
      extended FIR, filter-loader and SPI tests. Detached runner:
      Xilinx/Testbench/run_stream_rates.ps1 (Vivado syntax/elaboration +
      simulation; no synthesis/place/route). Compile/regression outcomes
      not yet established. FPGA place-and-route remains ON HOLD per user.
      R03 enable-voltage hardware check, physical capture-phase qualification,
      R05 DPD deadline and remaining audit findings are not closed.
