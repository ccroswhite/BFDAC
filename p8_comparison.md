# P8 - BFDAC (simulation) vs dCS Vivaldi APEX (published / measured)

Date: 2026-09-26, **revised 2026-09-28 to the real-base-drive gates (R114), 65k two-tone + k2 trim (R115/R116)**.
Plant: locked P5 TIA (V_VG 4.0 V, R_f 270 || C_f 1.3 nF, R_off 132.4/116.4
from +15F, OPA1612 single), C_col 12 nF, Si1555 MOSFET padding mirror, Rg5
100R, 45 C, **cells driven by the hardware network** (LVC1G74 Rout 25 R ->
rs 1.35 k / rp 301 -> VCM 1.345 V). Digital chain as shipped:
`cosim125lut_inl.npy` (4-chop static LUT), kernel `cosim125c3jw3` (Volterra
2nd+3rd order, cubic static), LUT bow trim K2TRIM 0.985 (R116), EF3
modulator with TPDF dither and +0.5 code input offset (DC nulled by MIDCODE
32.5 R_off sizing). Ideal-drive figures
(gates 112/113/117, 2026-09-26) are kept in brackets where they differ. All BFDAC numbers are LTspice
co-simulations of the full 64-cell analog channel read with the R109 LP-LS /
Kaiser readers (sensing floor -136 dBc at 65k points).

dCS sources: Vivaldi APEX spec sheet; Stereophile bench (APx500, 6 V out,
600 R load). 0 dB0 = full-scale sine (6 Vrms).

| Line | dCS Vivaldi APEX | BFDAC (sim) | Gate | Margin | Caveat |
|---|---|---|---|---|---|
| Residual noise, 20 Hz-20 kHz unweighted | better than -113 dB0 | **-128.1 dB0** (246 nV rms re 28R domain; SPICE .noise 5 % mismatch + jitter at its 0.84 ps bound + quantization) | N7 gate 100 + lock | **+15 dB** | 1/f of MOSFET/PNP (analytic 56 nV, inside the copier e_n specs), PSU and PCB not modelled; per-FF additive jitter is a bench item (spec <= 0.8 ps) |
| Spurious, in-band | < -105 dB0 | **-129.2 dB0** at full scale (HD6 -128.2 dBc at -1 dBFS, the highest line, gate 126) [112: -129.5]; **-156.6 dB0** at -60 dBFS [117: -149.8]; **-153.2 dB0** in silence | 126 / 128 / 114 | **+24 dB** | deterministic (noiseless transient); thermal per-bin density at 94.5 Hz bins is -151 dB0 |
| THD+N, 1 kHz, full scale | 0.00026 % (-112 dB) | **-121.9 dB (0.00008 %)** at -1 dBFS = THD -123.5 dBc (RSS HD2..8) RSS noise -127.1 dBc [112: -123.3 dB] | 126 + N7 | **+10 dB** | noise term is the N7 budget, not a transient |
| Highest harmonic, 1 kHz | HD3 -127 dB | **HD2 -128.6 / HD6 -128.1 dBc**; HD3 -135.1, HD4 -131.7, HD5 -133.7, HD7 -140.8, HD8 -156.1 [126 untrimmed: HD2 -128.3, HD6 -128.2; 112 ideal drive: HD6 -129.5, HD2 -137.4] | 131 (M 65536, all in band) | **+1.1 dB** on the worst line, +8 dB on HD3 | two seeds (126/131) agree within 0.3 dB; HD2 is a ~0.9 % residual of the -88 dBc bow predistortion (in-phase part trimmed by K2TRIM, -0.5 % quadrature part remains = slow 2nd-order memory outside the 5-lag kernel), HD3 cancelled 22 dB by the identified kernel |
| IMD 19 + 20 kHz, 2nd-order difference (1 kHz) | -130 dB | **-133.3 dB** re -3 dBFS peak (65k record, sensing floor -134.8) [129 untrimmed: -127.3; 113 ideal drive: -156.4] | 132 | **+3.3 dB** | resolved by the 65k gate: untrimmed it was a real -127.3 (2.45 % in-phase over-correction of the LUT bow); K2TRIM 0.985 takes it to -133.3, at the record's sensing floor. 3rd-order 2f1-f2 -137.7, 2f2-f1 -137.7 [113: -136.6 / -139.3] |
| Resolution / low-level linearity | >= 20 bit | -60 dBFS: analog floor -146.7 dB0, added -142.8, fund reads -60.0 [117: -143.4]; -90 dBFS: floor -142.1 dB0, fund reads -90.0, no line above the thermal per-bin density | 128 / 118 | thermal-limited at **~21.2 bit** (128.1 dB0) | pattern floor level-flat within 1.7 dB silence -> -60 dBFS |
| Idle / low-level tones | (not published; Stereophile shows none) | none: worst bin over median = pure-noise statistics (8-10 dB) at silence, -90, -60 dBFS | 114 / 117 / 118 + idle_scan | - | requires the +0.5 code offset (breaker); without it a -131 dB0 idle line exists (gate 110) |
| L-R crosstalk | -115 dB spec / > 125 dB measured (113 dB at 20 kHz) | **not simulated** | P4 open | - | channel decks are single-channel; shared rails / reference / reclock bus not yet modelled |
| Clock jitter | (not published) | common path 109 nV (CCHD-957 + LMK tree, validated model, gate 97/98); per-FF independence ratio 0.155 | 97 / 98 | - | per-FF additive jitter bench-verify (SN74LVC1G74 not spec'd) |
| Output level / load | 6 V (2/6 V), 600 R | 6.0 Vrms balanced directly from the I/V; 600 R tap string for 4/2 V | P5 | - | stage 2 buffer noise penalty 1.1 dB at 6 V (vstage1n) |

## Reading

- With the hardware base drive every simulable dCS line is beaten: worst
  harmonic by 1.1 dB, HD3 by 8 dB, spurs by 24 dB, the two headline lines
  (noise, THD+N) by 15 and 10 dB, the 19+20 kHz difference product by 3.3 dB
  (65k gate; the ideal-drive plant read -156).
- The real drive costs HD2 (-137 -> -128): the FF output resistance shifts
  the levels the passive replica-ff sums, tripling the static bow, and the
  LUT leaves a ~1 % 2nd-order residual (-128 dBc HD2). R115/116 showed the
  residual is not chop noise (12-chop LUT: same bow, HD2 -124) but a
  frequency-dependent mismatch of the bow (2.4 % at 750 Hz, 0.8 % at 2 kHz,
  same sign): a one-scalar bow trim K2TRIM 0.985 splits the difference,
  f2-f1 -127 -> -133 with HD2 unchanged. The remaining -0.5 % quadrature
  part is a slow 2nd-order memory the 5-lag kernel does not model (VCM /
  base-network time constants); pulling HD2 to the ideal-drive -137 would
  need that term identified. All acceptance gates and both stretches are
  met (progress.md R114/R116).
- The margins on distortion are otherwise limited by the readers: gate 126's
  odd harmonics sit 5-20 dB above the -136 dBc sensing floor.
- What is not in the simulation: crosstalk (P4), 1/f, PSU/PCB, per-FF
  jitter. Of these only crosstalk has a dCS number; the others are
  budgeted analytically inside the 128.1 dB0 line.

## Measurement-floor notes (R109)

The pre-R109 readers (truncated-record LS, exact full-M FFT) were
leakage-limited at -109 dB (16k) / -120 dBc (65k) by the shaped
out-of-band noise; R108's D1/D3 "misses" were partly that floor. The LP-LS
readers (utils/lp_ls.py) remove the leakage and are stable against the
discard length and cutoff; all table values are LP-LS or Kaiser-38
floor_read values.

## Go / no-go

Simulation set complete for every dCS line except crosstalk. Recommended:
GO for schematic capture and hardware, with P4 (two-channel crosstalk
stub) run in parallel with layout, and the two bench items (per-FF
additive jitter, Si1555 1/f corner) as the first hardware-test gates.
