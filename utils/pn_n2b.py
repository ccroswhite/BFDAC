# P3 / N2b (2026-09-12): clock phase-noise -> in-band output-noise line.
#
# Mechanism (RTZ, both pulse edges retimed by the same 49.152 MHz clock, 6
# cycles = 122 ns apart): a common edge displacement tau(t) leaves the pulse
# WIDTH (charge) unchanged and only moves its POSITION. Charge error per pulse
# is tau(t_fall) - tau(t_rise), i.e. the jitter spectrum weighted by
#   H_w(f) = |1 - exp(-j 2 pi f Tw)|^2 = 4 sin^2(pi f Tw)
# which kills everything below ~1 MHz. Position modulation is a time-warp
# s(t - tau) -> error -s'(t) tau(t): sidebands 2 pi f_sig tau_rms re the tone.
#
# Inputs: oscillator L(f) mask (dBc/Hz at the carrier f0), log-log
# interpolated, floor held flat to the Nyquist of the divided clock; tree
# additive jitter (LMK00304 51 fs, LMK1C1108, LVC1G74) RSS'd as white.
# Output: effective width-jitter tau_w (fs rms), in-band noise via the N2
# measured sensitivity (0.9-1.3 uV in-band per ps rms white, -1 dBFS,
# 0.62 Vrms fund; use 1.1), time-warp sideband level at 1 k / 20 k.
import numpy as np

F0 = 49.152e6
TW = 6 * (162.7604e-9 / 8)
FNYQ = F0 / 2
SENS_UV_PER_PS = 1.1            # N2 slope, in-band, -1 dBFS, jitter COMMON to all cells
BUDGET_NV = 100.0               # jitter line allocation of the 245 nV budget
# common-path additive (bom.md s1, datasheet-verified R30): mux + 2 fanout levels
TREE_FS = {"LMK00304 mux": 51.0, "LMK1C1108 level 1": 20.0, "LMK1C1108 level 2": 20.0}
# per-cell reclock FF additive jitter: INDEPENDENT per cell -> enters as
# sqrt(64) cells vs the common path's signal-weighted (2k-64) ~ 40 cells rms
# at -1 dBFS: paper estimate sqrt(64)/40 = 0.2; MEASURED 0.155 (gate 98,
# jitter_n2c.py, 10 ps independent per cell/edge, floor-corrected). NOT
# datasheet-spec'd (bom open item #10, bench-verify): sweep.
FF_INDEP_RATIO = 0.155
FF_FS_SWEEP = [200.0, 400.0, 700.0, 1000.0]

# (offset Hz, L dBc/Hz). Floor entry = last point, held flat to FNYQ.
MASKS = {
    "Crystek CCHD-957 (from memory - VERIFY)": [(10, -100), (100, -130), (1e3, -150),
                                                (1e4, -160), (1e5, -167), (1e6, -169)],
    "NDK NZ2520SDA audio grade (NDKT02-00008)": [(10, -100), (100, -130), (1e3, -158),
                                                  (1e4, -165), (1e5, -172), (1e6, -172)],
    "Taitien OX-U (XO-0135)": [(10, -100), (100, -130), (1e3, -150), (1e4, -161),
                               (1e5, -173), (1e6, -173)],
    "Generic -160 floor XO": [(10, -90), (100, -120), (1e3, -140), (1e4, -155),
                              (1e5, -160), (1e6, -160)],
}

f = np.logspace(0, np.log10(FNYQ), 20000)
df = np.gradient(f)

def L_of(mask):
    fo = np.array([m[0] for m in mask], float)
    lo = np.array([m[1] for m in mask], float)
    L = np.interp(np.log10(f), np.log10(fo), lo)
    L[f > fo[-1]] = lo[-1]
    return 10 ** (L / 10)

def tau_psd(Lf):                 # s^2/Hz, single-sideband L -> phase PSD 2L
    return 2 * Lf / (2 * np.pi * F0) ** 2

Hw = 4 * np.sin(np.pi * f * TW) ** 2

print(f"f0 {F0/1e6:.3f} MHz, Tw {TW*1e9:.1f} ns, width-jitter transfer -3dB ~ "
      f"{1/(6*TW)/1e6:.2f} MHz; common tree additive RSS "
      f"{np.sqrt(sum(v**2 for v in TREE_FS.values())):.0f} fs\n")
tree2 = sum(v ** 2 for v in TREE_FS.values()) * 1e-30
for name, mask in MASKS.items():
    S = tau_psd(L_of(mask))
    tau_tot = np.sqrt(np.sum(S * df))                      # all offsets, unweighted
    tau_ib = np.sqrt(np.sum((S * df)[f <= 20e3]))          # close-in (position only)
    tau_w = np.sqrt(np.sum(S * Hw * df) / 2)               # width jitter, per-edge equiv
    tau_w_all = np.sqrt(tau_w ** 2 + tree2)
    nv_common = tau_w_all * 1e12 * SENS_UV_PER_PS * 1e3
    sb1k = 20 * np.log10(2 * np.pi * 1e3 * tau_ib)
    sb20k = 20 * np.log10(2 * np.pi * 20e3 * tau_ib)
    print(f"{name}")
    print(f"  tau total (1 Hz..Nyq) {tau_tot*1e15:7.0f} fs | close-in <=20 kHz "
          f"{tau_ib*1e15:6.0f} fs -> time-warp sidebands {sb1k:.0f} dBc @1k, {sb20k:.0f} dBc @20k")
    print(f"  width-jitter (osc only) {tau_w*1e15:5.0f} fs | + common tree {tau_w_all*1e15:5.0f} fs "
          f"-> common line {nv_common:6.1f} nVrms")
    for ff in FF_FS_SWEEP:
        nv_ff = ff * 1e-3 * SENS_UV_PER_PS * FF_INDEP_RATIO * 1e3
        tot = np.hypot(nv_common, nv_ff)
        print(f"    + per-FF {ff:5.0f} fs indep -> FF line {nv_ff:6.1f} nV, total "
              f"{tot:6.1f} nVrms  {'PASS' if tot <= BUDGET_NV else 'FAIL'}")
