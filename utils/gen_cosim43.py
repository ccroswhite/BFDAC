# Round 43a: CLAMPED-COLUMN discriminator (ideal I/V stand-in).
# Hypothesis: the tau~4-period bilinear residual is column swing (28R||12n,
# tau=336ns) modulating the M6 cascode -> ema(code) x code products.
# Replace the passive 28R/12n loads with fixed-voltage clamps and sense
# current; diffout = rload*(Im - Ip) keeps the same scale/convention.
# Vectors: UNCORRECTED pwl37 (same as Round 39) -> direct HD comparison
# against -84.0/-80.8 dBc. If the mechanism is column swing, both the static
# bow and the dynamic residual should drop hard.
import os

OUT = r"C:\Users\ccros\Documents\LTspice"
src = open(os.path.join(OUT, "bfdac_cosim39.cir")).read().splitlines()

# clamp at the code-32 static operating point: 9 - 28*(50m+32*1.1m) = 6.6144
CLAMP_V = 6.6144
out = []
for ln in src:
    if ln.startswith("* BFDAC CO-SIM"):
        out.append("* BFDAC CO-SIM v43a - CLAMPED COLUMNS (ideal I/V), "
                   "Si1555, uncorrected pwl37 vectors")
    elif ln.startswith("R_load_p") or ln.startswith("R_load_m"):
        pass                       # remove passive loads
    elif ln.startswith("C_col_p"):
        out.append(f"Vcl_p col_p 0 DC {CLAMP_V}")
    elif ln.startswith("C_col_m"):
        out.append(f"Vcl_m col_m 0 DC {CLAMP_V}")
    elif ln.startswith("B_diff"):
        # old diffout = 28*(Im-Ip); I(Vcl_x) = -Ix (source supplies the node)
        out.append("B_diff  diffout  0  V={rload*(I(Vcl_p)-I(Vcl_m))}")
    else:
        out.append(ln)
with open(os.path.join(OUT, "bfdac_cosim43.cir"), "w") as f:
    f.write("\n".join(out) + "\n")
print("bfdac_cosim43.cir written (clamped columns, pwl37 vectors)")
