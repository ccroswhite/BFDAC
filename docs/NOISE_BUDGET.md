# BFDAC Noise Budget & Verification Plan

Consolidates the noise spec, the per-domain allocation, the measured/simulated
line items (with provenance), and the bench isolation ladder. Two reference
domains appear throughout — keep them straight:

- **XLR domain** — re 6.0 Vrms differential full-scale at the connector.
  Spec dBFS numbers and the senior bench plan live here.
- **Internal domain** — re 0.62 Vrms differential fund at −1 dBFS (the
  I/V-node signal level). The `noise_n1.py` / SPICE `.noise` nV stack lives
  here. Internal→XLR gain ≈ 8.6×; 245 nV internal ≈ 2.1 µV at the jack.

## 1. Spec (docs/SYSTEM_ARCHITECTURE.md §N/D/L)

| ID | Requirement | Equivalent |
|----|-------------|------------|
| N1 | ≥120 dB0 noise rejection | ≤6.0 µVrms integrated 20 Hz–20 kHz at 6 Vrms (42.4 nV/√Hz spot) |
| D2 | No spur above −120 dB0 — idle, element-selection, clock, supply products | spur hunt, not just integrated noise |
| L1 | Noise floor changes ≤1 dB from −60 dBFS to digital silence | needs idle/silence records |

Internal design target is tighter than spec: **245 nV internal = 128.1 dB0**
(≈2.1 µV XLR ≈ −129 dBFS), ~9 dB over N1.

## 2. Per-domain gate budget (ship gate: −123.3 dBFS / 4.1 µV XLR)

Corrected for the Round-30 retimer (SN74LVC1G74, not MC100EP52 — the LVPECL
part was vetoed for ~140 mW/cell and is the documented fallback only).

| Domain | Tap | Budget (20–20k) | Primary failure modes |
|--------|-----|-----------------|------------------------|
| D1 RTL digital | `paced_l→dem_cmd_l→cascode_l` @49.152 MHz | ≤−138 dBFS (<0.75 µV) | LEVEL≠6V (−9.54 dB!), `cell_shadow` frame slip, HBx2 ZOH, TPDF/EF3 limit cycles |
| D2 clock+retime | CCHD-957→LMK1C1108→LVC1G74 Q/Q̅ | ≤−130 dBFS (<1.9 µV) | `cell_clk→ff_clk` setup/hold, XO/fanout phase noise × ultrasonic SDM power, FF rail noise |
| D3 cascode+RTZ | 64× DMMT5551 diff I_out± | ≤−126 dBFS (<3.0 µV) | tail-source 1/f+thermal, unit-R mismatch folding (DEM/DPD off), RTZ charge-injection asymmetry |
| D4 I/V+diff V | XLR pins | ≤−130 dBFS (~1.4–1.9 µV) | R_f Johnson, I/V op-amp i_n·R_f + e_n noise-gain, rail PSRR |
| **RSS** | XLR | **≤−123.3 dBFS (4.1 µV)** | clears −120 by 3.3 dB |

### D2 pass criteria (split — do not conflate)

- **Common path** (XO + fanout to LMK leaf): integrated broadband jitter
  <150 fs rms. Tree estimate ≈87–100 fs (bom §1.1).
- **Per-FF additive** (each of 128× LVC1G74, independent per cell → enters at
  0.155× common-path sensitivity = 171 nV/ps): ≤0.8 ps rms required, ≤0.6 ps
  comfortable (bom item 213 / open item 10 — **the #1 unmeasured number in
  the budget; bench-verify gate**).

## 3. Measured/simulated line items (provenance)

| Line item | Value | Source of truth |
|-----------|-------|-----------------|
| Code-domain quant+dither floor | 26 nV analytic; `noise_n1.py` measures in-band SNR at −1/−60 dBFS, multi-seed | `utils/noise_n1.py` + `ns_ef3_gen.py` (integer-exact vs `noise_shaper_ef3.sv`) |
| Full-plant `.noise` (28R domain) | plant+I/V+rails 193–213 nV; ⊕jitter 150 ⊕quant 26 = **246–261 nV = 128.1–127.6 dB0** | `utils/gen_noise100.py` (docs/schematic.html noise row) |
| Biggest plant lines | tails 144 static-ON (~125–130 at RTZ duty), OPA e_n 73, R_off 67, Qpad base shot 65 (→0 w/ MOSFET pad), THAT tails 55, steering 45, R_f 45, Rpad 43, Rg5 27 (→3 at 10 Ω) | same `.noise` gate |
| Clock tree common jitter | ≈87 fs (√(82²+20²+20²)) | bom.md §1.1 (post-LMK00304 removal) |
| Jitter→noise sensitivity | 171 nV/ps per-FF (0.155× common); RTZ formula → ~−130 dBFS @150 fs common | bom.md gate 98; RTZ SNR_j ≈ −20log(√2πf_RTZ·σ·√(2·20k/f_RTZ)) |
| NS in-band SNDR | 136.0 dB (EF3, verified integer-exact) | `noise_shaper_ef3` + `ns_ef3_gen.py`, Round-30 entry progress.md |
| HB3 chain SNDR | 163.7 dB (e2e, bit-identical across REVIEW-10/11) | `tb_e2e_sine` + `e2e_final_fft.py` |
| LDO cascade | TPS7A4501→LT3041 analytical stack | `utils/ldo_cascade_noise.py` + docs/LDO_CASCADE_NOISE.md |

## 4. Measurement methodology (shared)

- **Integration**: always integrate bin power 20 Hz–20 kHz (exclude
  fundamental+harmonics for DNR; exclude fundamental only for THD+N). FFT
  processing gain makes a −110 dB integrated floor *look like* −140 dB per
  bin — never quote spot bins.
- **Window**: coherent 128 ms capture — 6,291,456 `cell_clk` = 786,432
  pace_valid = 131,072×6 input samples, Δf = 7.8125 Hz, integer multiple of
  48k/768k/6.144M/49.152M → rectangular window, zero leakage. For shorter
  runs: Kaiser β=38, mainlobe exclusion K=12 bins (R37 methodology).
- **Setup gate (must-do)**: `SPI_W_LEVEL (0x02) = 3'b010` (6 Vrms,
  17'h10000) AND `SPI_W_VOLUME (0x01) = 24'hFFFFFF` *before* any capture.
  Reset default 3'b000 = 2 Vrms — silently −9.54 dB.
- **Silence record**: u=0 input, TPDF dither still active (L1 needs the
  −60 dBFS→silence comparison; DEM activity drops at silence).

## 5. RTL waterfall probes (one sim, six nodes)

| P | Signal (dac_dsp_core) | Rate / scaling | Expected | Failure points to |
|---|-----------------------|----------------|----------|--------------------|
| P1 | `interp_l` | 768 kHz, 2^41 | ~−146 dBFS | Stage-1A schema-4 merge bug |
| P2 | `vox_l` | 768 kHz, 2^41 | −146 dBFS | voicing bypass leak |
| P3 | `hb3_l` | 6.144 MHz, 2^47 | −146 dBFS | HBx2 phase/rounding |
| P4 | `paced_l` | 6.144 MHz, 28×2^42 | −145.5 dBFS | vol pipe drop/dup, LEVEL≠6V |
| P5 | `dem_cmd_l` | 6.144 MHz | −141..−144 dBFS | EF3 NTF, tpdf scaling, DPD sat |
| P6 | `sum_ones(cascode_l)` avg per pace frame | 49.152 MHz | == P5 | `cell_shadow`/`cell_mid` CDC frame slip |

P6 check is a **sequence correlation** (per-frame popcount == dem_cmd), not
just an SNR comparison — a frame slip shows as a deterministic mismatch.

## 6. Bench isolation ladder (back-to-front, XLR domain)

| Step | State | Active | Target | Over-target diagnosis |
|------|-------|--------|--------|-----------------------|
| A1 | ext_rst_n=0 / relay open | analyzer+cable | <0.6 µV | ground loop, analyzer range |
| A2 | cells off, relay closed | I/V+V stages only | 1.2–1.8 µV | R_f, op-amp e_n/i_n, LDO |
| A3 | **static DC midscale, RTZ held open** — `SPI_W_CELL_TEST_L=0x80` + `SPI_W_CELL_TEST_MODE(0x22)[0]=1` | +64 cells+tails at DC, zero switching | 1.8–2.8 µV | tail current-source noise, CM ref noise, emitter-degeneration shortfall |
| A4 | RTZ switching, fixed code — `CELL_TEST_L=0x80`, dc_hold=0 | +49.152 MHz RTZ on 32+/32− | 2.2–3.5 µV | clock jitter, base-drive charge-injection, I/V slew/EMI rectification |
| A5 | live DAC, −60 dBFS & 0 dBFS, toggle `SPI_W_DPD_EN` | full chain | ≤4.2 µV (−123.0 dBFS) | A4→A5 jump = SDM/DEM folding in I/V or cell mismatch |

A3↔A4↔A5 separation is the payoff: A3 = DC current noise, A4−A3 = RTZ
edge/jitter rectification, A5−A4 = SDM/DEM mismatch folding + I/V HF
current-step overload (the #1 RTZ-DAC killer — raw <300 ps edges into the
summing node need a passive HF filter before the op-amp input pair).

## 7. New RTL hook (this round)

`SPI_W_CELL_TEST_MODE (0x22)` bit[0] `cell_test_dc_hold`: ORs the RTZ gate
open while a cell test is applied (`dac_dsp_core` `rtz_gate_eff`), giving the
A3 static-DC state — previously impossible since the 6-of-8 gate is
hardwired in the cascode IOB. Inert unless `cell_test_active` (can't engage
mid-stream); clk_200m→cell_clk via 2-FF ASYNC_REG. Verified in
`tb_cell_measurement` (out_l held `baseline(0)` for 5 full frames).

## 8. Open items

1. **LVC1G74 additive jitter bench** — ≤0.8 ps/FF needed; single most
   important unmeasured number (bom item 10). Breakout: LMK leaf edge →
   10+ FFs, histogram Q/Q̅ vs CLK.
2. **Silence capture (L1)** — code-domain `u=0`+dither through `noise_n1.py`
   (easy); idle cosim vector through LTspice (DEM activity collapses).
3. **D2 spur hunt** — idle-vector DEM spur scan; supply-spur injection:
   `ldo_cascade_noise.py` PSD modulating rail nodes in the `.noise` deck.
4. **I/V HF summing-node filter** — verify passive RC/CLC absorbs RTZ edges
   ahead of the op-amp input pair (A4 result decides).
5. Mismatch sim on P6: σ=0.1% static thermometer ≈ −78 dB → DEM 2nd-order
   should push in-band <−132; DPD past −135 — **simulated, not yet measured**.
