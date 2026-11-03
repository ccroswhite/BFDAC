"""First-order TPS7A4501 (4.3 V) -> LT3041 (3.3 V) noise study.

Run: python utils/ldo_cascade_noise.py

Analytical frequency-domain estimate, NOT a transistor/transformer simulation
or a guaranteed noise limit. See docs/LDO_CASCADE_NOISE.md for assumptions.
LT3041 PSRR/noise points are approximate readings of Rev. 0 Figures 48/54.
TPS PSRR is an explicitly assumed engineering curve, not measured/digitized
device data. TPS broadband PSD shapes are sensitivity cases normalized to
the application-text RMS estimate. No credit for increased output capacitance.
"""

import math
import numpy as np

KB = 1.380649e-23
TEMP_K = 300.0
F = np.geomspace(10.0, 100_000.0, 20_001)
ANCHOR_F = np.array(
    [10, 20, 50, 100, 200, 300, 500, 1000, 2000, 5000,
     10000, 20000, 50000, 100000], dtype=float
)
# Typical curves, 1 A load, CSET = 4.7 uF, COUT = 10 uF || 10 uF.
# Use the 0.6 V curve as a lower-headroom sensitivity case for both topologies.
LT_PSRR_DB = {
    "1.0 V headroom": [83, 83, 89, 96, 115, 110, 108, 104, 100, 93, 88, 81, 75, 71],
    "0.6 V headroom": [77, 78, 84, 91, 100, 100, 99, 97, 94, 88, 82, 74, 69, 65],
}
LT_NOISE_NV = np.array(
    [36, 33, 18, 10, 6, 5, 4, 3.5, 3, 3, 2.8, 2.7, 3.1, 3.8]
)
# Assumed first-stage PSRR, intended as a scenario with less rejection than
# typical catalog claims. NOT a guaranteed lower bound at 4.3 V / low headroom.
TPS_PSRR_F = np.array([10, 100, 1000, 10000, 100000], dtype=float)
TPS_PSRR_DB = np.array([50, 60, 55, 45, 25], dtype=float)
TPS_RMS = 14e-6 * 4.3 / 1.21
FINAL_RMS = 1e-6
RTOP, RBOT = 2550.0, 1000.0

# Interstage filter nominal model; ceramic capacitance is EFFECTIVE under bias.
# Electrolytic is evaluated at -20% capacitance tolerance.
RF = 0.1
CBULK = 220e-6 * 0.8
RBULK = 0.1
CCER = 20e-6
RCER = 0.01


def integral(y, x):
    return np.trapezoid(y, x)


def band_rms(psd, band):
    mask = (F > band[0]) & (F < band[1])
    x = np.concatenate(([band[0]], F[mask], [band[1]]))
    y = np.interp(x, F, psd)
    return math.sqrt(float(integral(y, x)))


def gain_from_db(f, anchor_f, db):
    if np.any(f < anchor_f[0]) or np.any(f > anchor_f[-1]):
        raise ValueError("Do not extrapolate PSRR beyond the modeled band")
    return 10 ** (-np.interp(np.log10(f), np.log10(anchor_f), db) / 20)


def normalized_psd(shape, rms):
    return shape * rms ** 2 / integral(shape, F)


def filter_response(f, enabled):
    if not enabled:
        return np.ones_like(f, dtype=complex), np.zeros_like(f)
    omega = 2 * np.pi * f
    zbulk = RBULK + 1 / (1j * omega * CBULK)
    zcer = RCER + 1 / (1j * omega * CCER)
    zshunt = 1 / (1 / zbulk + 1 / zcer)
    h = zshunt / (RF + zshunt)
    # All passive resistor/ESR Johnson noise with the ideal source shorted.
    zthevenin = 1 / (1 / RF + 1 / zshunt)
    thermal_psd = 4 * KB * TEMP_K * np.real(zthevenin)
    return h, thermal_psd


def main():
    # Approximate LT3041 spectral shape, normalized to its 1 uV typical
    # integrated specification. Audio-band result is shape-dependent.
    lt_asd = 1e-9 * np.exp(
        np.interp(np.log(F), np.log(ANCHOR_F), np.log(LT_NOISE_NV))
    )
    lt_psd = normalized_psd(lt_asd ** 2, FINAL_RMS)
    tps_shapes = {
        "flat PSD": np.ones_like(F),
        "LF-weighted PSD": 1 + 1000 / F,
    }
    # TPS feedback-divider Johnson noise, approximate closed-loop gain.
    # LT3041 SET resistor noise is already included in the 1 uV budget.
    divider_psd = 4 * KB * TEMP_K * (RTOP + RTOP ** 2 / RBOT)
    bands = [(10.0, 100000.0), (20.0, 20000.0)]
    print(f"TPS intrinsic estimate: {TPS_RMS * 1e6:.2f} uV RMS, 10 Hz-100 kHz")
    print("No transformer, rectifier conduction, startup or loop-stability simulation.")
    print("PSRR values are typical/assumed, not guaranteed PVT limits.")
    for band in bands:
        print(f"LT intrinsic, {band[0]:g}-{band[1]:g} Hz: "
              f"{band_rms(lt_psd, band) * 1e6:.4f} uV RMS")
    for name, db in LT_PSRR_DB.items():
        hlt = gain_from_db(F, ANCHOR_F, db)
        for filtered in (False, True):
            hf, passive_psd = filter_response(F, filtered)
            for shape_name, shape in tps_shapes.items():
                for scale in (1, 2):
                    # 2x source RMS is a sensitivity check, not another spec.
                    source_psd = normalized_psd(shape, TPS_RMS * scale)
                    transferred = (source_psd + divider_psd) * abs(hf * hlt) ** 2
                    passive_out = passive_psd * hlt ** 2
                    total = lt_psd + transferred + passive_out
                    print(f"PSRR reference: {name}; {'RC' if filtered else 'direct'}; "
                          f"{shape_name}; TPS noise x{scale}")
                    for band in bands:
                        print(f"  {band[0]:g}-{band[1]:g} Hz: "
                              f"upstream={band_rms(transferred, band) * 1e9:.3f} nV, "
                              f"passive={band_rms(passive_out, band) * 1e9:.4f} nV, "
                              f"total={band_rms(total, band) * 1e6:.6f} uV RMS")
            # Rectifier ripple is separate from regulator-generated noise.
            # Sawtooth Vpp=0.3 V, harmonics limited to 100 kHz.
            for fundamental in (100.0, 120.0):
                n = np.arange(1, int(100000 / fundamental) + 1)
                freq = n * fundamental
                raw_rms = 0.3 / (np.pi * np.sqrt(2) * n)
                h1 = gain_from_db(freq, TPS_PSRR_F, TPS_PSRR_DB)
                h2 = gain_from_db(freq, ANCHOR_F, db)
                hr, _ = filter_response(freq, filtered)
                residual = raw_rms * h1 * h2 * abs(hr)
                print(f"  {fundamental:g} Hz assumed reservoir sawtooth: "
                      f"fundamental={residual[0] * 1e9:.3f} nV RMS; "
                      f"harmonics to 100 kHz={np.linalg.norm(residual) * 1e9:.3f} nV RMS")
                # RMS including the separately reported deterministic ripple.
                baseline = lt_psd + (
                    normalized_psd(np.ones_like(F), TPS_RMS) + divider_psd
                ) * abs(hf * hlt) ** 2 + passive_psd * hlt ** 2
                for band in bands:
                    mask = (freq >= band[0]) & (freq <= band[1])
                    combined = math.sqrt(
                        band_rms(baseline, band) ** 2 + np.sum(residual[mask] ** 2)
                    )
                    print(f"    noise + ripple, {band[0]:g}-{band[1]:g} Hz: "
                          f"{combined * 1e6:.6f} uV RMS (flat TPS PSD case)")
    print("Filter attenuation (dB):")
    for f in [100, 1000, 10000, 100000]:
        h, _ = filter_response(np.array([float(f)]), True)
        print(f"  {f:g} Hz: {-20 * np.log10(abs(h[0])):.3f}")
    print("Conditional shape-independent bounds, TPS intrinsic source only:")
    for db in (60, 40):
        upstream = TPS_RMS * 10 ** (-db / 20)
        print(f"  If final PSRR >= {db} dB across band: upstream <= "
              f"{upstream * 1e9:.2f} nV; total <= "
              f"{math.hypot(FINAL_RMS, upstream) * 1e6:.5f} uV RMS")
    # Allocated tolerance envelope for this exercise; not a production signoff.
    min_input = 4.3 * 0.96 - 0.030 - RF * 1.01 * (1 + 0.050)
    max_output = 3.3 * 1.012
    print(f"Allocated DC corner: LT input >= {min_input:.4f} V, "
          f"headroom >= {min_input - max_output:.4f} V")
    print(f"Filter loss at 1.05 A: {RF * 1.05 ** 2:.4f} W nominal.")


if __name__ == "__main__":
    main()
