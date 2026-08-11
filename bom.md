# BFDAC — Consolidated Bill of Materials

Single source of truth for all board-level parts. Organized per block; **BOM
section N documents schematic.html figure N** — the two files are an
authoritative pair and MUST be edited in lock-step (any part added, removed or
revalued in one is reflected in the other in the same change). Netlist values
(`bfdac_*.cir`) are authoritative for analog values; this document tracks
realized MPNs and quantities.

| BOM § | Block | Schematic | MPN status |
|---|---|---|---|
| 1 | Master clock tree & reclock | Fig. 1b | **LOCKED (Round 30, ratified)** — RTZ coding + SN74LVC1G74 single-FF reclock |
| 2 | Unit cell array | Fig. 2 | **LOCKED (Round 29)** — BJT steering cell (DMMT5551) |
| 3 | Per-rail output stage | Fig. 3 | values locked, MPNs TBD |
| 4 | I/V converter | Fig. 4 | values locked, MPNs TBD |
| 5 | Reconstruction filter | Fig. 4b | values locked, coils custom |
| 6 | Line V-stage | Fig. 4c | shares §8 MPNs |
| 7 | Output routing & relays | Fig. 4d | relay class chosen, MPN TBD |
| 8 | Headphone amplifier | Fig. 4e | selected (Rounds 19–20) |
| 9 | Supplies & references | Fig. 5 | values locked, LDO/refs TBD |
| 10 | Common-mode servo | Fig. 5b | pairs selected, support TBD |

Open sync items are listed at the [bottom](#open-sync-items).

---

# 1. Master clock tree & cascode reclocking (Fig. 1b, Round 24)

Round 24 architecture: clock selection moved off-chip. FPGA receives a single
muxed MCLK and drives `clk_sel`; the same buffer tree clocks the external
reclock flip-flops so cascode edge timing is set by the OCXO chain, not the
FPGA fabric (~23 dB timing-SNDR gain, `reclock_study.py`, Round 23).

> **DATASHEET-VERIFIED (Round 30, 2026-07-22):** all §1 jitter/skew/timing
> figures below updated from MC10EP52/D rev 7 (onsemi), LMK00304 SNAS578G
> rev G, LMK1C110x SNAS717A, SN74LVC1G74 rev G (TI).
>
> **RATIFIED (Round 30, 2026-07-22, user):** the cell coding is **RTZ at
> 75 % duty** (each selected cell emits one identical charge pulse per
> sample: 6-of-8 mclk cycles high = 122.1 ns at the 6.144 MHz cell rate)
> and the reclock stage is **one SN74LVC1G74 per cell** (single-FF package
> — MANDATED by the SSN code² analysis, see §1.2). DEM is the
> unconstrained sort-based 2nd-order vector shaper (RTL). Verification:
> 4-leg battery, `progress.md` Round 30 "RTZ-DEM VERIFICATION"
> (`rtz_study.py`, `bfdac_cosim28j.cir`, `rtz_noise.py`, `dwa_tones*.py`).
> Key consequence for layout: **sub-ns length matching is retired** — RTZ
> pulse-position invariance relaxes clock-tree skew to ±5 ns and Q/Q̅
> intra-pair mismatch to ~700 ps (~12 cm).

## 1.1 Clock selection & distribution

| Ref | Qty | Part | Function | Key specs |
|---|---|---|---|---|
| U301 | 1 | TI **LMK00304** | 2:1 input mux + 1:4 fanout | VERIFIED: 51 fs RMS additive jitter (12 kHz–20 MHz, LVPECL); output skew 30 ps typ / 50 ps max; tpd(LVPECL) 180–540 ps; CLKin_SEL from FPGA `clk_sel` (J26, LVCMOS18); **not glitch-free** — CONFIRMED by TI (E2E #1348412: async mux, runt pulses expected) — hardware switch sequencer mutes + holds MMCM in reset (Round 30) |
| U302–U319 | 18 | TI **LMK1C1108** | 1:8 LVCMOS clock fanout, two-level tree (2 roots → 16 leaves → 128 FF clock traces; Round 29: 128 single-FF MC100EP52 packages) | VERIFIED @3.3 V: output–output skew 35 ps typ / 55 ps max per device; **part-to-part skew 280 ps max** (dominates leaf-to-leaf across different chips — still inside the 1 ns FPGA-vs-FF budget; inter-bank static skew benign, DEM decorrelates, Round 23); additive jitter 12 fs typ / 20 fs max; tpd 1.3–2.2 ns; fmax 250 MHz; **length matching RETIRED (Round 30 RTZ ratification):** tree skew tolerance ±5 ns (pulse-position invariance; skew spread even staggers SSN edge groups) — route for signal integrity only |
| R3xx | 1 per clock trace + 2 | 22–33 Ω 0402 | Series termination at each buffer clock output | at driver pin, no stubs |

## 1.2 Reclock flip-flops — **LOCKED (Round 30, ratified): RTZ + SN74LVC1G74**

> **HARD CONSTRAINT (Round 30 user ruling — was implicit, now explicit):
> the reclock/drive electronics sit millimeters from the matched DMMT5551
> steering pairs and the timing-critical clock tree. The thermal budget
> there is very small: per-cell heat sources cause gradient drift across
> the matched parts (Vbe/alpha tempco → INL drift, timing drift). Target:
> per-cell drive electronics ≤ ~10 mW (CMOS-class dynamic power only);
> reclock array total ≤ ~1–1.5 W. The MC100EP52 (≈140 mW/cell static,
> ≈18 W array — verified Round 30) is VETOED. Any future drive-stage
> candidate must pass this constraint BEFORE electrical evaluation.**
>
> **RESOLVED (Round 30 ratification): SN74LVC1G74 @ ≈5–7 mW/cell passes
> the constraint** (3–4 mW FF dynamic + 2.9 mW drive network, sim-measured
> `bfdac_cosim28j.cir` p_net1). Array < 1 W.

### Round 30 ratified design: RTZ coding + SN74LVC1G74 per cell

Architecture: **one FPGA data pin per cell (128 total, LVCMOS18)** carrying
the **RTZ-encoded** pattern (selected cell → 6-of-8 mclk cycles high per
cell period; unselected → low); a **single-bit 1.8→3.3 V translator**
(AXC1T45-class, MPN at §9 pass) feeds the **SN74LVC1G74** D input; the FF —
clocked from the LMK1C1108 tree at mclk — retimes the pulse and its true
Q/Q̅ outputs drive the DMMT5551 steering pair (§2) through the rs/rp
network. Translator/data-path timing errors are retimed away by the FF;
only the FF's own edges reach the cell.

Why RTZ (Round 30, 4-leg verification, `progress.md`): every selected cell
emits an *identical, self-contained* charge pulse per sample, so
(a) rise-vs-fall duty asymmetry — the defect that killed every NRZ CMOS
candidate at 1.1–1.4e-2/ns — becomes a pure **gain** error (−2.43 % at the
worst measured dtrf, k-variation ≤ 3.3e-4, sim-verified); (b) per-cell
static spreads (duty, Q/Q̅ trace skew) become DEM-shaped mismatch;
(c) pulse position is charge-invariant → clock skew is benign. Costs:
−2.5 dB amplitude (75 % duty) and real width-jitter sensitivity (needs
tree broadband floor ≤ 150 fs — actual 50–80 fs ✓; per-FF additive jitter
≤ 1 ps — bench-verify).

Why single-FF packages (MANDATORY): under RTZ all selected cells switch
simultaneously; on a shared die the SSN edge pushout (β·switching-count,
rise-vs-fall coefficients differ) makes pulse WIDTH depend on packmate
activity → code² distortion at 75–100 dB class for a quad (even Δβ =
0.05 ps/cell → 104.7 dB, `rtz_noise.py`). One FF per package reduces SSN
to a per-cell static effect (DEM-shaped). Each FF package gets local rail
isolation (R/ferrite + C, values at open item #11) so board-rail droop
stays width-symmetric.

Derived layout tolerances (Round 30): Q/Q̅ intra-pair trace mismatch
≤ ~700 ps ≈ 12 cm; clock-tree skew ≤ ±5 ns ≈ ±80 cm; data traces
untimed (retimed away). Only the analog cell matching constraints (§2)
remain sub-ns/precision class.

| Ref | Qty | Part | Function | Key specs |
|---|---|---|---|---|
| U311–U438 | 128 | TI **SN74LVC1G74** (single D-FF, true Q/Q̅, SOT-23-6/DCU, VCC = 3.3 V) | Retime 1 RTZ data line → complementary base-drive pair (1 per cell, placed adjacent to its DMMT5551 pair) | VERIFIED (rev G): fmax 175–200 MHz @3.3 V (vs 49.152 MHz clock); tpd 2.2–7.1 ns; "balanced outputs"; Icc static 10 µA; ~3–4 mW dynamic at RTZ activity. **BENCH-VERIFY (not datasheet-spec'd):** part-to-part \|tPLH−tPHL\| spread σ ≤ ~600 ps; additive jitter ≤ 1 ps (open item #10) |
| U440–U567 | 128 | **AXC1T45-class** single-bit 1.8→3.3 V translator (MPN at §9 pass) | FPGA LVCMOS18 data → LVC1G74 D input (VIH @3.3 V = 2.0 V > 1.8 V, direct drive fails) | timing benign (pre-FF, retimed away); single-gate package keeps the SSN locality argument; ~negligible power |
| R43x | 2/cell (256) | 1.41 kΩ 0402 1% | FF Q/Q̅ → base series (rs, per `bfdac_cosim28j.cir`) | with R44x sets base swing 1.36–1.85 V from the 3.3 V CMOS swing |
| R44x | 2/cell (256) | 246 Ω 0402 1% | base node → buffered **VCM 1.85 V rail** (rp) | complementary pair → per-cell VCM rail current ≈ constant (benign); rail buffer OPA1678-class (repurposed from the retired EP52 threshold design, MPN at §9) |
| L/C4xx | 128 sets | ferrite/R + local C per FF package | per-package 3.3 V rail isolation | values from open item #11 bound (board-rail SSN width-symmetry) |
| U390 | 1/channel | TI **TPS7A4700** 1 A low-noise LDO | dedicated 3.3 V FF/translator rail | load now ≈ 0.2–0.3 A/channel (was 2.7 A with EP52) — single LDO per channel is again sufficient; NOT shared with digital 3.3 V |

### Round 29 EP52 design (SUPERSEDED by Round 30 ratification; kept for record)

Architecture (Rounds 27–29): **one FPGA data pin per cell (128 total,
LVCMOS18)**; reclock FF is a **differential LVPECL D-FF** whose true/complement
outputs drive the BJT steering pair (§2) through a resistive level-shift
network. Rationale (Round 28 sims): the cell needs Q/Q̅ skew ≤ ~0.4 ns with
matched complementary edge shapes to hold |asym| ≤ 1e-3; ECLinPS-EP guarantees
≤ 30 ps skew and inherently matched differential edges (→ asym ~1e-4, back at
the verified 151.7 dB glitch budget). No CMOS translator is needed: the FPGA’s
1.8 V output is resistively shifted into the FF’s differential D input against
an external threshold reference (see finding below).

> **VERIFIED FINDING (Round 30): the MC100EP52 has NO V_BB output pin.**
> SOIC-8 pinout is CLK/CLK̅, D/D̅, Q/Q̅, VCC, VEE only (the IBB row in the
> maximum-ratings table is EP-family boilerplate).
>
> **THRESHOLD-RAIL DESIGN (Round 30, closes open item #8).** Three buffered
> rails per channel replace the assumed on-chip V_BB (all derive from the
> clean FF 3.3 V LDO rail — partial ratiometric tracking):
>
> - **Offset rail 2.49 V** (revised from 2.31 V): feeds all 128 × 1 kΩ
>   offset legs (D and CLK networks). With the unchanged 3.6k/1k values the
>   D pin then swings 1.95–2.34 V (center ≈ 2.15 V) and the CLK pin
>   1.95–2.67 V (center ≈ 2.31 V). Load ≈ 40 mA avg per channel, partly
>   data-dependent (D legs) — buffer must source AND sink stiffly.
> - **THR_D = 2.15 V**: all 64 D̅ pins. Worst-case 64 × IIH(150 µA) =
>   9.6 mA, **data-dependent** (IIL is only 0.5 µA) — which is exactly why
>   it must NOT share a rail with the clock thresholds.
> - **THR_CLK = 2.31 V** (= CLK mid-swing): all 64 CLK̅ pins. ≤ 9.6 mA,
>   periodic (benign). Kept at mid-swing for symmetric noise margin; the
>   larger clock swing keeps pin slew ≈ 0.6–1.4 V/ns (LMK 20–80% edge
>   0.3–0.7 ns × network attenuation 0.217).
>
> Margins (verified limits): VIHCMR 2.0–3.3 V — low-state more-positive
> input = 2.15 V (D) / 2.31 V (CLK), ≥ 150/310 mV above the 2.0 V floor
> (old design sat exactly AT it); VPP(min) 150 mV vs 390 mV (D) / 720 mV
> (CLK) differential swing ✓. Accuracy: 1% divider + LDO ≈ ±35 mV — inside
> the ±150 mV window ✓.
>
> Jitter budget: CLK̅ threshold noise converts at σt = σv / slew (worst
> 0.6 V/ns) — buffered divider + per-pin RC keeps σv < 10 µV → < 17 fs,
> negligible vs the 0.2–1 ps FF jitter. Slow drift is common to all FFs in
> a group = static skew, DEM/inter-bank benign (Round 23 ruling).
>
> Realization per rail: E96 divider from FF 3.3 V rail → RC (1 µF, fc
> ≈44 Hz) → op-amp buffer (dual handles THR_D+THR_CLK; OPA1678-class, MPN
> final at §9) → 2.2 Ω into 10 µF bulk (cap-load isolation, DC feedback
> after the resistor) → star distribution → **10 Ω + 100 nF at every FF
> pin** (kickback isolation; 150 µA × 10 Ω = 1.5 mV static, negligible).

| Ref | Qty | Part | Function | Key specs |
|---|---|---|---|---|
| ~~U311–U438~~ | 128 | onsemi **MC100EP52** (ECLinPS-EP differential D-FF, LVPECL, VCC = 3.3 V) | SUPERSEDED — was: reclock 128 data lines → 128 complementary base-drive pairs (1 per cell) | VERIFIED (MC10EP52/D rev 7): tpd 330 ps typ / 410 ps max (85 °C); random clock jitter 0.2 ps typ / 1 ps max RMS; setup 50 ps min, **hold 0 ps min**; tr/tf (20–80%) 80–180 ps; fmax 4 GHz typ; Q/Q̅ skew not separately specified — inherent to the single differential output stage (matched complementary edges, the Round-28 requirement); **no V_BB pin** (see finding above) |
| R41x | 2/FF (256) | 3.6 kΩ + 1 kΩ 0402 1% | FPGA LVCMOS18 → D input level shift (swing 1.95–2.34 V, offset leg to the 2.49 V rail); D̅ → 10 Ω + 100 nF → THR_D 2.15 V rail | DC-coupled (cell lines are not DC-balanced; no AC coupling); values unchanged from Round 29, only the rails moved (see threshold-rail design above) |
| R42x | 2/FF (256) | 3.6 kΩ + 1 kΩ 0402 1% | LMK1C1108 3.3 V CMOS clock → CLK input (swing 1.95–2.67 V, same 2.49 V offset leg); CLK̅ → 10 Ω + 100 nF → THR_CLK 2.31 V rail | single-ended clock vs mid-swing external reference; separate rail from THR_D so data-dependent D̅ input current cannot modulate the clock threshold |
| U390 | TBD (≥3/channel) | TI **TPS7A4700** 1 A low-noise LDO (or 1× TPS7A85 4 A per channel — decide at §9 power design) | dedicated 3.3 V PECL/FF rail | NOT shared with digital 3.3 V. **VERIFIED FINDING (Round 30): IEE = 35 mA typ / 47 mA max per FF (85 °C) + ≈7 mA output-network load ⇒ ≈42 mA typ / 54 mA max per FF → 64 FFs ≈ 2.7 A typ / 3.5 A max PER CHANNEL (~18 W array dissipation total).** Old estimate (25–35 mA/FF, 1–1.6 A/channel) was low — one 1 A LDO per channel is INSUFFICIENT: use ≥3 × TPS7A4700 per channel (≤22 FFs each, ≈0.9 A) or one 4 A-class low-noise LDO. Draw is code-INDEPENDENT (differential) — still true |
| — | — | ~~SN74LVC74A / SN74AVC16T245~~ | **REMOVED (Round 29)** — CMOS FF + translator replaced by MC100EP52 + resistive shift | Q/Q̅ skew and edge-shape mismatch of CMOS FFs fail the asym ≤ 1e-3 requirement (Round 28) |
| R4xx | 256 | 100 Ω 0402 1% | FF Q/Q̅ → steering-pair base series (2 per cell) | with R4yx forms the PECL pulldown + attenuator (§2) |
| R4yx | 256 | 165 Ω 0402 1% | base node → buffered 1.0 V rail (2 per cell) | sets base swing 1.36–1.86 V from PECL 1.6–2.4 V; PECL DC pulldown 1.6–3.6 mA |

## 1.3 FPGA interface summary

| Signal | Direction | Pin | Notes |
|---|---|---|---|
| `mclk_p/n` | in | J28/J29 (B71_L12, true GC) | LVDS output from LMK00304 |
| `clk_sel` | out | J26 (B71_L13_P) | quasi-static, **SPI reg 0x03** (single register drives DSP family + OCXO mux, Round 30; 0x06 retired); H26 (B71_L13_N) now free |
| `cascode_l/r[63:0]` | out | **ASSIGNED (Round 30)**: L = banks 64+65, R = banks 67+69, explicit `PACKAGE_PIN` list in XDC §8 (L-pair sites only, conflict-checked vs connector CSV) | 128 pins, 1 per cell, IOB-registered on `cell_clk` (mclk-rate MMCM output, phase-aligned to the FF clock); **carries the RTZ pattern (Round 30): selected cell = 6-of-8 mclk cycles high per 6.144 MHz cell period** — pattern generated in the DEM/staging RTL; output timing vs virtual `ff_clk` (LVC1G74 capture); per-cell pin order free to remap at layout (DEM decorrelates) |

## 1.4 Timing budget (49.152 MHz worst case, 20.35 ns period)

| Item | Value |
|---|---|
| FPGA Tco (IOB, LVCMOS18) | 3–5 ns |
| Board flight FPGA → FF | 0.5–1 ns |
| Translator (AXC1T45-class) | ≈ 1–2 ns (budget; retimed away, only setup-path relevant) |
| FF setup (SN74LVC1G74) | ≤ 2.5 ns budget (conservative; transcribe exact rev G value at XDC pass) |
| Clock skew FPGA vs FF | ±5 ns TOLERANCE (Round 30 RTZ position-invariance — was <1 ns); actual ≈ 0.35 ns worst (LMK00304 50 ps + LMK1C1108 part-to-part 280 ps + trace) |
| **Setup margin** | **≈ 9–13 ns** (XDC virtual-clock numbers stay conservative) |
| Hold | verify at XDC pass: Tco(min) ~2 ns + translator ~1 ns vs LVC1G74 t_h (budget 1.5 ns) + 0.35 ns skew — expected pass, TRANSCRIBE exact t_h |

---

# 2. Unit cell array (Fig. 2) — LOCKED (Round 29): BJT steering cell

Per cell; **64 cells per channel, 128 per stereo unit**, one FPGA pin per cell
(RTL: `cascode_l/r[63:0]`, 128 pins); the complementary base-drive pair comes
from the reclock FF's differential Q/Q̅ outputs (§1.2).

**Round 28/29 redesign: the switch-FET pair is replaced by a same-die NPN
emitter-coupled steering pair** (classic ECL-driven bipolar current-steering,
PCM63 lineage). Bases swing 1.36–1.86 V (0.5 V differential crossing, set by
the §1.2 attenuator); the pair steers within ±~120 mV of crossing, the emitter
node never collapses (no dead zone), and injection is ~100× lower than any
FET/rail combination. Deck-verified (`bfdac_cosim27*`): bus disturbance
2.2 mV vs 89 mV (FET), asym 7.6e-5 at zero skew, temp corners −20/+85 °C
stable, k-linearity clean.

| Ref | Role | Qty/cell | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| Q1a, Q1b | Steering pair, same-die matched NPN | 1 pkg | 128 | **DMMT5551** (Diodes Inc dual, SOT-363) | same die → ΔV_be < 1 mV sets crossing symmetry; V_CE ≈ 0.58 V on-state (bus 1.75 V, emitter 1.17 V); α error (I_c/I_e) is a static per-cell gain term → absorbed by DEM mismatch shaping |
| Rb1, Rb2 | Base series 100 Ω | 2 | 256 | 100 Ω 0402 1% | same physical parts as §1.2 R4xx (counted once) |
| Rp1, Rp2 | Base shunt to 1.0 V rail, 165 Ω | 2 | 256 | 165 Ω 0402 1% | same as §1.2 R4yx; V_CM noise is common-mode → rejected by pair |
| Q4 | Tail transistor | 1 (¼ pkg) | 32 pkg | **THAT300** matched quad NPN array | 4 cells share one package |
| Rt | Tail set 750 Ω | 1 | 128 | 750 Ω thin film | I_cell = (1.25 − V_be)/750 ≈ 0.774 mA |
| Rb | q4_base feed 100 Ω | shared | per netlist | 100 Ω | common base line, 1.25 V ref |
| Cb | Base-line bypass | 1/channel | 2 | 1000 µF | shared ×1 per channel; 1.6 Hz corner makes noise floor code-independent (`noise1b`, Round 14) |

---

# 3. Per-rail output stage (Fig. 3)

Per rail; **2 rails per channel, 4 per stereo unit**. Values deck-locked
(`bfdac_cosim24.cir` final); discrete MPNs not yet selected.

| Ref | Role | Qty/rail | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| R_off | Offset injection | 1 | 4 | 180 Ω (+rail) / **180.18 Ω** (−rail) 0.1% | fed from filtered +15F/−15F only (§9) |
| I_pad ×2 | 50 mA padding CCS (from +15, to −15) | 2 | 8 | discrete CCS, **MPN TBD** | keeps Q5 ≥ 50 mA over code |
| Q5 | Shared cascode NPN | 1 | 4 | **DMMT5551-class matched NPN** — package grouping of Q5/Q5R/Q5C triple TBD | I_C = 52–95 mA over code |
| Q5R | Replica cascode, diode-connected | 1 | 4 | matched to Q5 | pins bus at 1.75 V via V_be(I) feed-forward |
| Q5C | I_b-comp cascode | 1 | 4 | matched to Q5 | V_CE match via vfr (Round 12: HD3 −122.7 → −143.9 dB) |
| QM1, QM2 | I_b sense PNP | 2 | 8 | matched pair, **MPN TBD** | QM1 diode-connected |
| QN1, QN2 | I_b-copy sink NPN | 2 | 8 | matched pair, **MPN TBD** | QN1 diode-connected |
| C_bus | Bus capacitor | 1 | 4 | 10 nF C0G | swamps ≈1.6 nF nonlinear junction C; phase-audited (`cosim17f/18`) |
| R_bleed | Bus bleed | 1 | 4 | 910 Ω | ≈1.9 mA |
| R_f | I/V feedback | 1 | 4 | 56 Ω 0.1% | sets ±2.4 V rail swing |
| C_f | I/V feedback | 1 | 4 | 390 pF C0G | ‖ R_f |
| R_sn, C_sn | Sum-node snubber | 1+1 | 4+4 | 4.7 Ω + 2.2 nF | — |
| I_ff, I_snk | Replica-DAC currents | 2 | 8 | realization: FPGA aux outputs (Fig. 1) + V-I, **TBD** | 0.774m·N(t) + 51.92 mA; ±5% / 2 ns skew tolerant (`cosim24`) |

---

# 4. I/V converter (Fig. 4)

Per rail (×4 per unit).

| Ref | Role | Qty/rail | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| U_iv | Front amp | 1 | 4 | **OPA1612-class** (behavioral-verified; final MPN TBD) | GBW 40 MHz, slew 27 V/µs, A_OL 120 dB; inputs sum_p vs 2.4 V ref |
| QA, QB | Diamond buffer drivers (NPN/PNP) | 2 | 8 | **MPN TBD** | class AB inside loop |
| QD, QC | Diamond buffer output (NPN source / PNP sink) | 2 | 8 | **MPN TBD** | ±15 rails |
| I_ba, I_bb | Diamond bias CCS | 2 | 8 | 5 mA discrete CCS, **MPN TBD** | — |

---

# 5. Reconstruction filter (Fig. 4b)

Per leg; **2 legs per channel, 4 per stereo unit**. 3rd-order Bessel,
f−3dB = 450 kHz, singly-terminated; exact synthesis (`bfdac_filt1.cir`).

| Ref | Role | Qty/leg | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| L1 | Series inductor | 1 | 4 | **77.6 µH air-core, DCR 1.5 Ω** (custom wound) | L = (5/6)R0/ωs; ±5% OK (delay 583–644 ns, flatness survives) |
| C2 | Shunt capacitor | 1 | 4 | **1.99 nF C0G** (e.g. 1.8 n + 180 p‖) | C = (12/25)/(R0·ωs); per leg to ground |
| L3 | Series inductor | 1 | 4 | **15.5 µH air-core, DCR 0.4 Ω** (custom wound) | L = (1/6)R0/ωs |
| R0 | Termination, tapped | 1 (string) | 4 | **150 Ω total, taps at 1/3 & 2/3** → 3× 50 Ω 0.1% string | taps = 2/4/6 Vrms level select (Fig. 4d); bridged by hi-Z V-stage |

**Layout rule:** air-core coils orthogonal orientation + spacing; keep away
from mains/rail magnetics.

---

# 6. Line V-stage (Fig. 4c)

Per leg; **2 legs per channel, 4 per stereo unit**. Same topology and
semiconductor MPNs as the HP front end (§8.1) with line-specific values.
Decks: `bfdac_vstage1/1b/1o/1n/1t/2/2b`. Fixed gain 1.769; never
relay-switched (level set upstream at the R0 taps).

| Ref | Role | Qty/leg | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| LTP pair | Input, low-noise NPN | 2 | 8 | ZTX851 (per §8.1) | 6 mA/side, **33 Ω degeneration** |
| Tail CCS | BJT tail | 1 | 8 | 2N5551 (per §8.1) | 12 mA |
| Mirror + QH | PNP mirror load + β-helper | 3 | 12 | 2N5401 (per §8.1) | **200 Ω degeneration** (HP uses 100 Ω), 22 k bleed |
| QV0, QV, QVC | Darlington VAS + cascode | 3 | 12 | 2N5401 / KSA992 (per §8.1) | QV 6 mA (Rev 130 Ω); cascode base +8 V |
| Miller | Compensation | 1+1 | 4+4 | 1 nF C0G + 100 Ω series | back to LTP output node |
| Diamond | Class-A output, m=3 | — | — | per §8.1 driver parts | Idq 25 mA; stoppers 22 Ω / 10 Ω |
| Zobel | — | 1+1 | 4+4 | 10 Ω + 100 nF | — |
| Rf | Feedback | 1 | 4 | 150 Ω 0.1% thin film 25 ppm | — |
| Rg | Feedback | 1 | 4 | 195 Ω → **use 196 Ω E96** (gain −0.03%, FPGA-trimmable) | matching sets XLR balance |

Min load 600 Ω differential. Verified: −140 dB THD @ 1 k, SNR 132.8 dB @ 6 V.

---

# 7. Output routing & relays (Fig. 4d)

Per channel (×2 per unit). All relays **telecom-class, bifurcated Au
contacts** (class: TE Axicom IM / Omron G6K — final MPN TBD); switched only
while muted so contacts never break current. De-energized = muted everywhere.

| Ref | Function | Qty/ch | Qty/unit | De-energized state | FPGA pin (XDC) |
|---|---|---|---|---|---|
| K1, K2 | Level taps (R0 string, 2/4/6 Vrms) | 2 | 4 | 2 V tap | `relay_level[1:0]` (P26/N29) |
| K3 | Input select (line/HP), DPDT | 1 | 2 | —, unused side grounded | (shared with level code, see automute) |
| K4 | Line mute | 1 | 2 | open + shunt (muted) | `relay_line_mute` (R28) |
| K5 | HP mute | 1 | 2 | jack shorted (muted) | `relay_hp_mute` (T28) |
| K6 | HP rails | 1 | 2 | HP stage unpowered | `relay_hp_rails` (N26) |
| U7xx | Relay coil driver | 1 | 2 | — | **ULN2003A-class** Darlington w/ flyback diodes |

Rule: unpowered-stage input must be relay-disconnected AND grounded (b-c
junction to collapsed rails clamps at ~0.6 V).

---

# 8. Headphone amplifier (Fig. 4e, Rounds 19–20)

Per `bfdac_hp1/hp2` decks. One leg as listed. **Stereo unit = 4 legs**
(2 bridged legs x 2 channels). Qty columns give per-leg and per-stereo-unit counts.
All primary MPNs chosen for ACTIVE production status as of selection date —
verify stock before ordering; alternates listed in preference order.

## 8.1 Semiconductors

| Ref (deck) | Role | Qty/leg | Qty/unit | Primary MPN | Pkg | Alternates | Notes |
|---|---|---|---|---|---|---|---|
| QI1, QI2 | LTP input, low-noise NPN (`QLN`) | 2 | 8 | ZTX851 (Diodes Inc) | TO-92 (E-Line) | BC550C x2 paralleled (onsemi); KSC1845F | rbb' <= 3R required to hold 3.3nV floor. ZTX851 rbb' ~1.7R, 60V Vceo OK on +/-15V. Match Vbe pairs to <2mV |
| QT | Tail current source NPN | 1 | 4 | 2N5551 (onsemi) | TO-92 | PN2222A; KSC2690A | Jellybean, multi-source |
| QP1, QP2, QH | Mirror + beta helper PNP (`QMPNP`) | 3 | 12 | 2N5401 (onsemi) | TO-92 | BC556B; KSA992 | Match QP1/QP2 from same tape |
| QV0, QV, QVC | Darlington VAS + cascode PNP (`Q5401`) | 3 | 12 | 2N5401 (onsemi) | TO-92 | KSA992; KSA1220A for QV if dissipation concern | QV runs 10mA/~7V = 70mW, TO-92 OK |
| QLV, QL0 | VAS current-source load NPN | 2 | 8 | 2N5551 (onsemi) | TO-92 | PN2222A | — |
| QA | Diamond driver NPN (m=2 in sim) | 1 | 4 | KSC2690A (onsemi) | TO-126 | TTC004B; 2x 2N5551 paralleled | Single medium-power part replaces m=2. Mount on main heatsink (Vbe tracking, see progress Round 19) |
| QB | Diamond driver PNP (m=2 in sim) | 1 | 4 | KSA1220A (onsemi) | TO-126 | TTA004B; 2x 2N5401 paralleled | Complement of QA, same heatsink |
| QD | Output power NPN (`QPWN`) | 1 | 4 | TTC004B (onsemi) | TO-220F | 2SC5171; MJE15032 (fT 3x lower — MUST re-run PM/osc decks first) | 2.4W idle class-A, isolated tab, heatsink required (~2C/W per channel) |
| QC | Output power PNP (`QPWP`) | 1 | 4 | TTA004B (onsemi) | TO-220F | 2SA1930; MJE15033 (same fT caveat) | Complement of QD |

## 8.2 Resistors

| Ref | Value | Qty/leg | Qty/unit | Type / MPN class | Notes |
|---|---|---|---|---|---|
| Re1, Re2 | 33R | 2 | 8 | 0.1% thin film 0805 (Vishay TNPW / Susumu RG) | LTP degeneration — matching sets gain balance |
| Rm1, Rm2 | 100R | 2 | 8 | 0.1% thin film | Mirror degeneration — matching sets offset |
| Rhb | 22k | 1 | 4 | 1% thick film | Helper bias |
| Rbl | 1k | 1 | 4 | 1% thick film | Darlington leak |
| Rev | 130R | 1 | 4 | 1% thin film | VAS current set — value is compliance-critical (Round 16 latch rule) |
| Rle, Rl0 | 120R | 2 | 8 | 1% thin film | VAS load CCS set |
| Rset | 4.7k | 1 | 4 | 1% thick film | CCS reference |
| Rmc | 100R | 1 | 4 | 1% thick film | Miller zero |
| RbA, RbB | 22R | 2 | 8 | 1% thick film | Driver base stoppers |
| RbC, RbD | 4.7R | 2 | 8 | 1% thick film 1206 | Power base stoppers |
| Red, Rec | 0.47R | 2 | 8 | 1206 thick-film current-sense, 0.25-0.5W 1% (Panasonic ERJ / Vishay CRCW-HP / Bourns CRA) | Dissipation only ~12mW quiescent, ~17mW full power — jellybean chip part. Sets Idq=162mA |
| Rz | 10R | 1 | 4 | 1W metal film | Zobel |
| Rf | 150R | 1 | 4 | 0.1% thin film 25ppm | Feedback — THD/gain critical |
| Rg | 195R | 1 | 4 | 0.1% thin film — **195R is not E96: use 196R (gain -0.03%, FPGA-trimmable) or 390R x2 parallel** | Feedback — matching across legs sets bridge balance (0.5% tested OK, 0.1% better) |

## 8.3 Capacitors

| Ref | Value | Qty/leg | Qty/unit | Type | Notes |
|---|---|---|---|---|---|
| C_m | 1nF | 1 | 4 | C0G/NP0 50V 0805 (TDK/Murata/Kemet) | Miller comp — value verified, do not substitute X7R |
| Cz | 100nF | 1 | 4 | Film PP/PET 63V (Wima MKS2) or C0G 50V | Zobel |

## 8.4 Bias networks — realized and verified (bfdac_hp4, Round 20)

| Ref | Function | Qty/leg | Qty/unit | Part | Notes |
|---|---|---|---|---|---|
| Dln, Dlp | LED voltage references (Vf ~1.8-2.0V) | 2 | 8 | Any jellybean green LED, 3mm/0805 (e.g., Kingbright) | Rail-tracking refs: tail/bias currents immune to rail sag |
| Rln, Rlp | LED feed, 2.7k | 2 | 8 | 1% thick film | ~4.9mA LED current |
| Cln, Clp | LED bypass, 100uF 25V | 2 | 8 | Alu electrolytic or polymer | LED noise filter |
| QCA / QCB | Diamond bias CCS | 2 | 8 | 2N5551 / 2N5401 | Replaces ideal Iba/Ibb (13.6/14.1mA) |
| Rea, Reb | CCS set, 75R | 2 | 8 | 1% thin film | — |
| Rte | Tail CCS set, 91R | 1 | 4 | 1% thin film | Tail 11.3mA (replaces Vtb + 900R) |
| Rc1, Rc2 | Cascode divider 3.3k/3.9k | 2 | 8 | 1% thick film | 8.1V ref (replaces Vbcas) |
| Cc1 | Cascode bypass, 10uF | 1 | 4 | X7R 25V or film | — |

Verified with full battery: THD/stability/temp corners unchanged vs ideal
sources (progress.md Round 20). Remaining schematic-level item before layout:
relay/mute interface.

## 8.5 Availability review flags

- **ZTX851** — single-source (Diodes Inc). If unobtainable: BC550C paralleled is the fully-jellybean fallback (noise re-sim recommended, expect ~+0.3dB).
- **KSC2690A/KSA1220A** — legacy Fairchild lines under onsemi; verify lifecycle status. TTC004B/TTA004B are the drop-in alternates and are shared with the output position (BOM consolidation option: use TTC004B/TTA004B for BOTH driver and output = one NPN/PNP power part number).
- **TTC004B/TTA004B** — onsemi active, but single-source. MJE15032/33 are the multi-source fallback pending a PM re-sim.
- All TO-92 small-signal parts are multi-source jellybeans.

---

# 9. Supplies & references (Fig. 5)

Rail filter feeds **R_off only** (offset injection, the sensitive path); raw
±15 feeds diamond buffers and current pads. One filter per rail polarity per
channel (+15F and −15F identical).

| Ref | Role | Qty/rail | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| R9a | Series element | 1 | 4 | 0.01 Ω | — |
| L9a | Series inductor | 1 | 4 | 30 nH | — |
| FB9 ‖ R9b | Ferrite bead + damp | 1+1 | 4+4 | bead 1 µH ‖ 100 Ω | damped — no bead resonance |
| C9a | Bulk | 1 | 4 | 10 µF | at +15F node |
| C9b | HF | 1 | 4 | 100 nF, 0.01 Ω ESR | — |
| U9x | ±15 V LDO rails | — | — | **MPN TBD** | upstream of filter |
| — | Reference ladder 1.25 / 1.75 / 2.40 V | 3 refs | 6 | buffered, low-Z, **realization TBD** | 1.25 V: cell tail base line; 1.75 V: vfr (absorbs 100–190 mA replica current — buffer must sink); 2.40 V: I/V set point |
| — | **1.00 V steering-bias rail** (Round 29) | 1 ref | 2 | buffered op-amp rail, realization with ladder above | Thevenin return for 128 base networks (§1.2/§2); net current ≈ code-independent; noise appears common-mode at the pairs |
| — | **2.49 V offset rail** (Round 30, was 2.31 V Round 29) | 1 ref | 2 | buffered divider from FF 3.3 V rail | offset leg of all 128 FPGA/LMK → EP52 input shift networks (§1.2); ≈40 mA avg, partly data-dependent — buffer must source and sink |
| — | **THR_D 2.15 V threshold rail** (Round 30, new) | 1 ref | 2 | divider + RC + ½ dual op-amp (OPA1678-class, MPN TBD) + 2.2 Ω/10 µF | D̅ reference for 64 FFs (§1.2); ≤9.6 mA data-dependent; 10 Ω + 100 nF at each pin |
| — | **THR_CLK 2.31 V threshold rail** (Round 30, new) | 1 ref | 2 | divider + RC + ½ dual op-amp (same package) + 2.2 Ω/10 µF | CLK̅ reference for 64 FFs (§1.2); ≤9.6 mA periodic; MUST be separate from THR_D (data→clock jitter isolation) |
| — | Reclock FF 3.3 V LDO | — | 2 | TPS7A4700 (§1.2) | dedicated, not digital 3.3 V |

---

# 10. Common-mode servo (Fig. 5b)

One complete instance **per mono channel** (×2 per unit). Verified
`bfdac_servo1/2/3`: 75.9 dB DC gain, 11.7 mHz crossover, 89° PM; residual CM
95–135 µV; noise −153.9 dB rel 2 Vrms. Both caps in servo branch, not audio path.

| Ref | Role | Qty/ch | Qty/unit | Part / value | Notes |
|---|---|---|---|---|---|
| Rs1, Rs2 | CM sense | 2 | 4 | 10 k matched thin film | (out_p + out_m)/2 |
| QI1, QI2 | Input pair | 1 pkg | 2 | **SSM2212** matched NPN | matched 5 k base source impedances cancel I_b drops |
| Rd1, Rd2 | LTP degeneration | 2 | 4 | 4.7 k | — |
| Rt10 | Tail set | 1 | 2 | 143 k | 100 µA tail |
| Ri | iref source impedance | 1 | 2 | 5 k | = sense R_th → I_b drops cancel |
| QP1, QP2 | Mirror | 1 pkg | 2 | **SSM2220** matched PNP | degenerated 10 k ×2 |
| Rm10, Rm11 | Mirror degeneration | 2 | 4 | 10 k | — |
| QH10 | β-helper | 1 | 2 | 2N5401-class, **MPN TBD** | — |
| QS0, QS | Darlington 2nd stage | 2 | 4 | 2N5401-class, **MPN TBD** | kills base-current steal at vint1; 470 k bleed |
| Rbl10 | Darlington bleed | 1 | 2 | 470 k | — |
| QL1, QL0 | Current-source load | 2 | 4 | 2N5551-class, **MPN TBD** | 100 µA (293 k set) |
| Rl10 | CCS set | 1 | 2 | 293 k | — |
| C_int | Integrator (Miller) | 1 | 2 | **10 µF film** | servo branch |
| Rpf | Post-filter | 1 | 2 | 100 k | — |
| C_pf | Post-filter / noise wall | 1 | 2 | **1 µF film** | 1.6 Hz; pole 130× above crossover |
| QA1, QA2 | Vernier actuators | 2 | 4 | matched NPN, **MPN TBD** | 1.43 mA ±0.71 mA into sum_p/sum_m; ±40 mV CM authority |
| Ra1, Ra2 | Actuator degeneration | 2 | 4 | 2 k | 1% actuator mismatch → −153.9 dB noise |

---

# Open sync items

1. ~~Gate-count discrepancy~~ **RESOLVED (Round 27, user ruling):** one FPGA data pin per cell = **128 pins** (`cascode_l/r[63:0]`); the reclock FF stage generates the complementary gate pair from Q/Q̅ at ≈ 3.3 V. The per-cell ODELAY crossing-trim knob stays retired (post-FF RC trim = bring-up fallback).
2. ~~Cell redesign~~ **RESOLVED (Round 29):** BJT steering cell (DMMT5551) locked, §2; verified `bfdac_cosim27*`.
3. ~~Reclock stage MPNs~~ **RESOLVED (Round 29); datasheet verification DONE (Round 30):** MC100EP52 checked against MC10EP52/D rev 7 — timing better than budgeted (setup 50 ps, hold 0), but **no V_BB pin** (see §1.2 finding: external ~2.1 V threshold rail required) and per-FF current higher than estimated (see item 7).
4. MPN selection pending: output-stage/I-V discretes (§3, §4), relays (§7), ±15 LDO + reference ladder buffers (§9), servo support transistors (§10).
5. ~~§1 clock-tree figures from-memory~~ **RESOLVED (Round 30):** all §1 jitter/skew/Tco/setup/hold figures datasheet-verified (LMK00304 rev G, LMK1C110x, MC10EP52/D rev 7); §1.1/§1.2/§1.4 updated.
6. Replica-DAC (I_ff/I_snk) circuit realization not yet designed (§3) — FPGA aux outputs exist (2 per rail, Fig. 1).
7. ~~FF rail power redesign~~ **OVERTAKEN (Round 30 user veto):** the verified ≈18 W MC100EP52 array is unacceptable (thermal-gradient drift on matched parts — see §1.2 hard constraint). §1.2 REOPENED; reclock stage to be redesigned around ≤ ~10 mW/cell.
8. ~~EP52 threshold rail~~ **RETIRED (Round 30 ratification):** the three-rail design goes with the EP52; the single buffered **VCM 1.85 V** rail (§1.2 R44x row) replaces it (buffer MPN carries over to the §9 pass).
9. ~~Reclock stage redesign~~ **RESOLVED (Round 30, user-ratified):** RTZ coding (75 % duty) + 1× SN74LVC1G74 per cell + AXC1T45-class translator; 4-leg verification in `progress.md`. Clock tree UNCHANGED (128 single-FF leaves as in Round 29, but length matching retired); FF LDO shrinks to 1/channel.
10. **NEW (Round 30): LVC1G74 bench-verify** — part-to-part \|tPLH−tPHL\| spread (need σ ≤ ~600 ps) and additive jitter (need ≤ 1 ps) across a sample lot; neither is datasheet-spec'd. Procedure: drive 10+ samples from one clock leaf, TDR-class scope on Q/Q̅ crossing vs CLK, histogram both.
11. **NEW (Round 30): per-FF-package rail isolation values** — bound board-rail SSN width-symmetry (code-dependent droop must shift rise and fall edges equally): LTspice deck with N packages on a shared isolated rail, then set R/ferrite + C values in §1.2 L/C4xx row.
12. **NEW (Round 30): translator MPN** (AXC1T45-class single-bit 1.8→3.3 V, 128×) — select at §9 MPN pass with the FF rail LDO.

