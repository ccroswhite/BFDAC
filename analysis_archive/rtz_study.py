# Round 30: RTZ-DEM feasibility (leg 1 of reclock-redesign verification)
# Physics under RTZ: every selected cell emits exactly one rise+fall per sample.
#   Per-cell per-sample charge = Q_nom * (1 + m_j + a0 + d_j)
#     m_j = static element mismatch (0.1% sigma, existing budget)
#     a0  = COMMON duty error (tPLH-tPHL)/t_pulse  -> a0*code = gain + a0-scaled
#           shaped quantization noise (quantified below, NOT assumed benign)
#     d_j = PER-CELL duty-error spread             -> extra static mismatch, DEM-shaped
#   k (selection transition count) no longer enters the error -> transition-count
#   limiting (const-k) is no longer required; DWA classic becomes eligible again.
# This script quantifies: (1) the a0*code residue, (2) SNDR vs sigma_d for the
# chosen const-k scheme AND DWA classic, (3) the resulting REQUIREMENT on
# cell-to-cell |tPLH-tPHL| spread in ps for the 81.4ns RTZ pulse (6.144MHz cell
# rate, 50% duty).
import numpy as np

src = open("dem_study.py").read()
prefix = src[: src.index("schemes = [")]
g = {}
exec(compile(prefix, "dem_study.py", "exec"), g)

run_constk = g["run_constk"]
run_scheme = g["run_scheme"]
code = g["code"]
u = g["u"]
NCELL = g["NCELL"]
NFFT = g["NFFT"]
BAND = g["BAND"]
BIN = g["BIN"]
RNG = np.random.default_rng(11)
SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2

def err_sndr(e):
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

# ---------- (1) common duty error a0: e = a0*code (exact, by construction) ----------
print("=== (1) common duty error a0 -> a0*code residue (gain excluded at fundamental) ===")
for a0 in (2.7e-2, 1e-2, 5e-3, 1e-3):
    print(f"  a0={a0:8.1e}  -> in-band residue SNDR = {err_sndr(a0 * code.astype(float)):6.1f} dB"
          f"  (a0-scaled shaped QN of the code stream)")

# ---------- (2)+(3) per-cell duty spread as extra mismatch, per scheme ----------
# selection sequences (selection matrix reconstructed per sample to apply per-cell weights)
def sel_stream_constk():
    # re-run chosen scheme capturing selections
    sels = np.zeros((NFFT, NCELL), bool)
    src2 = g  # use same machinery via a wrapper: rerun with weight trick below
    return None  # not used; weights applied via linearity trick instead

# Linearity trick: error from weights vec v is e_v[i] = sum_{j in sel_i} v_j.
# run_constk/run_scheme already compute y_mis = w[sel].sum() with w = 1+mismatch.
# Re-running with w replaced is invasive; instead exploit that both engines are
# deterministic given (code, params): monkey-patch g["w"] and re-run per case.
T_PULSE_NS = 81.4  # 6.144MHz cell update, 50% RTZ duty

cases = [0.0, 5e-4, 1e-3, 2e-3, 5e-3, 1e-2, 2e-2]
print()
print("=== (2) SNDR vs per-cell duty spread sigma_d (0.1% element mismatch included) ===")
print(f"{'scheme':<24}" + "".join(f"  sd={sd:7.0e}" for sd in cases))
for label, runner in (
    ("const-k K=4 par+2nd", lambda: run_constk(4, shape_par=True, greedy=True, g2=0.5, name="ck4")),
    ("DWA classic",         lambda: run_scheme("dwa", lambda c: c)),
    ("partial rot r=8",     lambda: run_scheme("pr8", lambda c: 8)),
):
    row = f"{label:<24}"
    for sd in cases:
        g["w"] = 1.0 + g["RNG"].normal(0, 1e-3, NCELL) * 0 + \
                 np.sqrt(1e-3**2 + sd**2) * RNG.standard_normal(NCELL)
        name, y_mis, k, carr = runner()
        row += f"  {err_sndr(y_mis - carr):10.1f}"
    row_k = f"(k_mean={k.mean():.1f})"
    print(row + "  " + row_k)

print()
print("=== (3) requirement conversion: sigma_d -> cell-to-cell |tPLH-tPHL| spread ===")
print(f"  RTZ pulse width t_pulse = {T_PULSE_NS:.1f} ns (6.144 MHz cell rate, 50% duty)")
for sd in cases[1:]:
    print(f"  sigma_d = {sd:7.0e}  ->  sigma(duty mismatch) = {sd * T_PULSE_NS * 1e3:7.1f} ps")
